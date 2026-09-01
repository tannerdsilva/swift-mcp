//===----------------------------------------------------------------------===//
//
// This source file is part of the MCP open source project
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import UnixSignals

/// An MCP server that hosts tools and handles the MCP protocol.
///
/// ``MCPServer`` is the main entry point for creating an MCP server. It is
/// inspired by Hummingbird's `HBApplication` and Swift Argument Parser's
/// `ParsableCommand`. It manages tool registration, JSON-RPC message handling,
/// and transport I/O.
///
/// The server conforms to the `Service` protocol from Swift Service Lifecycle
/// and must be run via a ``ServiceGroup``. Use ``runService(gracefulShutdownSignals:)``
/// for a convenient way to run the server with signal handling, or create your
/// own ``ServiceGroup`` for full control.
///
/// ## Basic Usage
///
/// ```swift
/// let server = MCPServer(name: "MyServer", version: "1.0.0")
/// server.register(GetWeather())
/// server.register(Greet())
/// try await server.runService()
/// ```
///
/// ## Declarative Builder
///
/// ```swift
/// let server = MCPServer(name: "MyServer", version: "1.0.0") {
///     GetWeather()
///     Greet()
/// }
/// try await server.runService()
/// ```
///
/// ## Custom ServiceGroup
///
/// ```swift
/// let server = MCPServer(name: "MyServer", version: "1.0.0") {
///     GetWeather()
///     Greet()
/// }
/// let serviceGroup = ServiceGroup(
///     configuration: .init(
///         services: [
///             ServiceGroupConfiguration.ServiceConfiguration(
///                 service: server,
///                 successTerminationBehavior: .gracefullyShutdownGroup
///             )
///         ],
///         gracefulShutdownSignals: [.sigterm, .sigint],
///         logger: server.logger
///     )
/// )
/// try await serviceGroup.run()
/// ```
///
/// When the server's transport completes — client EOF on stdio, or listener
/// close on TCP — ``run()`` returns and the enclosing group applies the
/// service's termination behavior. ``runService(gracefulShutdownSignals:)``
/// configures `.gracefullyShutdownGroup` so a completed session ends the
/// process cleanly.
///
/// - Warning: This class uses ``@unchecked Sendable`` because its mutable
///   tool registries are shared between registration calls and the transports'
///   message-handling actors. All registry access is serialized through an
///   internal lock; the `transport` and `logger` are `let` properties and safe
///   for concurrent access.
public final class MCPServer: Service, @unchecked Sendable {

    private let name: String
    private let version: String
    private var tools: [String: any MCPTool.Type]
    /// Instance-registered tools (name → instance).
    private var toolInstances: [String: any MCPTool] = [:]
    /// Guards the tool registries.
    ///
    /// ``register(_:)``/``registerInstance(_:instance:)``/``unregister(_:)`` are
    /// public and documented as runtime-capable, while the transports read the
    /// registries from the message-handling actors — so all access is
    /// serialized through this lock.
    private let toolsLock = Mutex<()>(())
    private var _logger: Logger
    private let transport: any MCPTransport
    /// Optional compile-time-known tool dispatch surface (macro-generated).
    ///
    /// Consulted before the dynamic registry for both `tools/list` and
    /// `tools/call`. `let` and `Sendable` — no synchronization needed.
    private let toolDispatcher: (any MCPToolDispatcher)?

    /// The logger used by this server.
    public var logger: Logger { _logger }

    /// The log level of the server's logger.
    public var logLevel: Logger.Level {
        get { _logger.logLevel }
        set { _logger.logLevel = newValue }
    }

    /// Creates a new MCP server over the standard stdio transport.
    ///
    /// - Parameters:
    ///   - name: The server name (sent to clients during initialization).
    ///   - version: The server version (e.g. "1.0.0").
    ///   - dispatcher: An optional compile-time-known tool dispatcher — the
    ///     macro-generated surface from ``MCPApplication``. Tools it knows are
    ///     served through typed, exhaustive dispatch; tools added via
    ///     ``register(_:)``/``registerInstance(_:instance:)`` remain served
    ///     through the dynamic registry.
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    ///     Each tool is carried concretely by the builder and registered as an
    ///     instance, so configuration passed to its initializer survives at
    ///     invocation time. Pass an empty closure `{}` to register tools later.
    public convenience init<each Tool: MCPTool>(
        name: String,
        version: String,
        dispatcher: (any MCPToolDispatcher)? = nil,
        @MCPToolBuilder tools: () -> (repeat each Tool) = {}
    ) {
        let logger = Logger(label: "mcp.server")
        self.init(
            name: name,
            version: version,
            transport: StdioTransport(logger: logger),
            logger: logger,
            dispatcher: dispatcher,
            tools: tools
        )
    }

    /// Creates a new MCP server bound to a specific address.
    ///
    /// This convenience initializer creates a ``TCPTransport`` bound to the
    /// given ``ServerAddress``, supporting IPv4, IPv6, dual-stack, and Unix
    /// domain socket bindings.
    ///
    /// - Parameters:
    ///   - name: The server name (sent to clients during initialization).
    ///   - version: The server version (e.g. "1.0.0").
    ///   - address: The ``ServerAddress`` to bind to.
    ///   - allowIPv4MappedIPv6: When `true`, binding to an IPv6 address like
    ///     `::` also accepts IPv4 connections. On Darwin this is default; on
    ///     Linux this disables `IPV6_V6ONLY`. Defaults to `false`.
    ///   - dispatcher: An optional compile-time-known tool dispatcher (see
    ///     ``init(name:version:dispatcher:tools:)``).
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    public convenience init<each Tool: MCPTool>(
        name: String,
        version: String,
        address: ServerAddress,
        allowIPv4MappedIPv6: Bool = false,
        dispatcher: (any MCPToolDispatcher)? = nil,
        @MCPToolBuilder tools: () -> (repeat each Tool) = {}
    ) {
        let logger = Logger(label: "mcp.server")
        self.init(
            name: name,
            version: version,
            transport: TCPTransport(
                address: address,
                allowIPv4MappedIPv6: allowIPv4MappedIPv6,
                logger: logger
            ),
            logger: logger,
            dispatcher: dispatcher,
            tools: tools
        )
    }

    /// Creates a new MCP server bound to a specific address with a caller
    /// access resolver.
    ///
    /// This initializer behaves like the address-based one, but lets you
    /// supply the underlying ``TCPTransport`` access resolver directly — the
    /// hook that maps a caller's source address string to an ``AccessLevel``
    /// once per connection, at accept time.
    ///
    /// - Parameters:
    ///   - name: The server name (sent to clients during initialization).
    ///   - version: The server version (e.g. "1.0.0").
    ///   - address: The ``ServerAddress`` to bind to.
    ///   - allowIPv4MappedIPv6: When `true`, binding to an IPv6 address like
    ///     `::` also accepts IPv4 connections. Defaults to `false`.
    ///   - accessResolver: A closure mapping a caller's source address string
    ///     to an ``AccessLevel``. Run once per connection, at accept time.
    ///   - dispatcher: An optional compile-time-known tool dispatcher (see
    ///     ``init(name:version:dispatcher:tools:)``).
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    public convenience init<each Tool: MCPTool>(
        name: String,
        version: String,
        address: ServerAddress,
        allowIPv4MappedIPv6: Bool = false,
        accessResolver: @escaping @Sendable (String) -> AccessLevel,
        dispatcher: (any MCPToolDispatcher)? = nil,
        @MCPToolBuilder tools: () -> (repeat each Tool) = {}
    ) {
        let logger = Logger(label: "mcp.server")
        self.init(
            name: name,
            version: version,
            transport: TCPTransport(
                address: address,
                allowIPv4MappedIPv6: allowIPv4MappedIPv6,
                accessResolver: accessResolver
            ),
            logger: logger,
            dispatcher: dispatcher,
            tools: tools
        )
    }

    /// Creates a new MCP server with a custom transport.
    ///
    /// Use this initializer to inject a ``TCPTransport`` configured with a
    /// custom ``TCPTransport/init(address:eventLoopGroup:allowIPv4MappedIPv6:accessResolver:)``
    /// so you can control per-connection authorization (see <doc:AccessControl>).
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - version: The server version.
    ///   - transport: The transport to use.
    ///   - dispatcher: An optional compile-time-known tool dispatcher (see
    ///     ``init(name:version:dispatcher:tools:)``).
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    public convenience init<each Tool: MCPTool>(
        name: String,
        version: String,
        transport: any MCPTransport,
        dispatcher: (any MCPToolDispatcher)? = nil,
        @MCPToolBuilder tools: () -> (repeat each Tool) = {}
    ) {
        self.init(
            name: name,
            version: version,
            transport: transport,
            logger: Logger(label: "mcp.server"),
            dispatcher: dispatcher,
            tools: tools
        )
    }

    /// Designated initializer shared by the conveniences above.
    ///
    /// `logger` is owned by the server; conveniences that construct a
    /// transport pass the same instance so transport-level log settings
    /// (e.g. `.trace` for accept-resolver decisions) follow ``logLevel``.
    private init<each Tool: MCPTool>(
        name: String,
        version: String,
        transport: any MCPTransport,
        logger: Logger,
        dispatcher: (any MCPToolDispatcher)? = nil,
        @MCPToolBuilder tools: () -> (repeat each Tool) = {}
    ) {
        self.name = name
        self.version = version
        self.tools = [:]
        self.transport = transport
        self._logger = logger
        self.toolDispatcher = dispatcher
        for tool in repeat each tools() {
            // Register the instance itself so any configuration the caller
            // passed to the tool's initializer survives into invocation —
            // register(_:) stores only the type and would silently discard it.
            self.registerInstance(type(of: tool).toolName, instance: tool)
        }
    }

    /// Registers a tool with the server.
    ///
    /// - Parameter tool: An instance of the tool to register. The tool's type
    ///   is used to derive its name and configuration.
    ///
    /// After registration, the tool becomes available via `tools/list` and
    /// `tools/call` requests. The tool's ``MCPTool/toolName`` is used as the
    /// lookup key.
    ///
    /// - Warning: If a tool with the same name is already registered, the
    ///   existing tool is silently overwritten. Use ``unregister(_:)`` to
    ///   remove a tool before re-registering.
    ///
    /// Registration is safe to call while the server is running; the registry
    /// is guarded against concurrent access with the transports.
    public func register<T: MCPTool>(_ tool: T) {
        let name = T.toolName
        _logger.debug("Registering tool: \(name) (type: \(T.self))")
        toolsLock.withLock { _ in
            if tools[name] != nil {
                _logger.warning("Tool '\(name)' is already registered and will be overwritten")
            }
            tools[name] = T.self
        }
        _logger.info("Registered tool: \(name)")
    }

    /// Registers a tool instance with the server.
    ///
    /// Unlike ``register(_:)`` which stores the type and creates new instances
    /// for each call, this method stores the instance directly. Use this for
    /// tools with dynamic configuration that cannot be created via `init()`.
    ///
    /// - Parameter name: The name to register the tool under.
    /// - Parameter instance: The tool instance to register.
    ///
    /// Registration is safe to call while the server is running; the registry
    /// is guarded against concurrent access with the transports.
    public func registerInstance(_ name: String, instance: any MCPTool) {
        _logger.debug("Registering tool instance: \(name)")
        toolsLock.withLock { _ in
            if tools[name] != nil || toolInstances[name] != nil {
                _logger.warning("Tool '\(name)' is already registered and will be overwritten")
            }
            toolInstances[name] = instance
        }
        _logger.info("Registered tool instance: \(name)")
    }

    /// Unregisters a tool from the server by name.
    ///
    /// - Parameter name: The name of the tool to remove.
    ///
    /// After unregistration, the tool is no longer available via `tools/list`
    /// or `tools/call`. Calling ``unregister(_:)`` with a name that has not
    /// been registered is a no-op. Both type-registered and
    /// instance-registered tools are removed.
    ///
    /// ```swift
    /// server.register(Greet())
    /// server.unregister("greet")  // greet is no longer available
    /// ```
    ///
    /// Unregistration is safe to call while the server is running; the registry
    /// is guarded against concurrent access with the transports.
    public func unregister(_ name: String) {
        let removed: Bool = toolsLock.withLock { _ in
            let typeRemoved = tools.removeValue(forKey: name) != nil
            let instanceRemoved = toolInstances.removeValue(forKey: name) != nil
            return typeRemoved || instanceRemoved
        }
        guard removed else {
            _logger.warning("Attempted to unregister unknown tool: \(name)")
            return
        }
        _logger.info("Unregistered tool: \(name)")
    }

    // MARK: - Tool Registry Access

    /// Snapshots the type-registered tools under the registry lock.
    private func snapshotToolTypes() -> [(name: String, type: any MCPTool.Type)] {
        toolsLock.withLock { _ in tools.map { (name: $0.key, type: $0.value) } }
    }

    /// Snapshots the instance-registered tools under the registry lock.
    private func snapshotToolInstances() -> [(name: String, instance: any MCPTool)] {
        toolsLock.withLock { _ in toolInstances.map { (name: $0.key, instance: $0.value) } }
    }

    /// Looks up a type-registered tool under the registry lock.
    private func toolType(named name: String) -> (any MCPTool.Type)? {
        toolsLock.withLock { _ in tools[name] }
    }

    /// Looks up an instance-registered tool under the registry lock.
    private func toolInstance(named name: String) -> (any MCPTool)? {
        toolsLock.withLock { _ in toolInstances[name] }
    }

    // MARK: - Service Conformance

    /// Stops the server and its transport.
    ///
    /// This method calls ``MCPTransport/stop()`` on the underlying transport,
    /// which causes the read loop to exit and the server to shut down.
    public func stop() async throws {
        try await transport.stop()
    }

    /// Starts the transport and begins handling messages.
    ///
    /// This method conforms to the ``Service`` protocol from Swift Service
    /// Lifecycle. It drives the transport directly; when the transport
    /// completes — client EOF on stdio, or listener close on TCP — ``run()``
    /// returns and the enclosing ``ServiceGroup`` applies the service's
    /// success termination behavior.
    ///
    /// When the enclosing group initiates graceful shutdown (via a signal or
    /// the host), a shutdown handler calls ``MCPTransport/stop()``, waking the
    /// transport's read loop so it can unwind promptly.
    ///
    /// - Note: This method is required by the ``Service`` protocol. It is
    ///   exposed as `public` only because the protocol requires it.
    public func run() async throws {
        _logger.info("Starting MCP server: \(name) v\(version)")

        try await withGracefulShutdownHandler {
            try await self.transport.start { [weak self] (data: Data, caller: MCPCallerInfo) in
                guard let self else { return nil as Data? }
                return try await self.handleMessage(data, caller: caller)
            }
        } onGracefulShutdown: {
            // The shutdown callback is synchronous, so a short-lived task fans
            // the stop out to the transport. The transport's read loop is
            // poll-based and observes the stop flag within poll timeout.
            Task { try? await self.transport.stop() }
        }
    }

    /// Runs the server inside a ``ServiceGroup`` with signal-based graceful shutdown.
    ///
    /// This is the recommended way to run the server. It wraps the server in a
    /// ``ServiceGroup`` that listens for the specified signals and triggers
    /// graceful shutdown when they are received.
    ///
    /// When the transport completes on its own — client EOF on stdio, or
    /// listener close on TCP — the server is configured with
    /// `.gracefullyShutdownGroup` termination behavior, so ``runService``
    /// returns normally and the process exits cleanly.
    ///
    /// - Parameter gracefulShutdownSignals: Signals that trigger graceful
    ///   shutdown. Defaults to `[.sigterm, .sigint]`.
    ///
    /// ```swift
    /// let server = MCPServer(name: "demo", version: "1.0.0") {
    ///     Greet()
    /// }
    /// try await server.runService()
    /// ```
    public func runService(
        gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint]
    ) async throws {
        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [
                    ServiceGroupConfiguration.ServiceConfiguration(
                        service: self,
                        successTerminationBehavior: .gracefullyShutdownGroup
                    )
                ],
                gracefulShutdownSignals: gracefulShutdownSignals,
                logger: _logger
            )
        )
        try await serviceGroup.run()
        _logger.info("MCP server \(name) v\(version) shut down")
    }

    // MARK: - Message Handling

    /// Routes an incoming JSON-RPC message to the appropriate handler.
    ///
    /// - Parameters:
    ///   - data: The raw JSON-RPC message data.
    ///   - caller: Information about the caller.
    /// - Returns: Response data, or `nil` for notifications.
    private func handleMessage(_ data: Data, caller: MCPCallerInfo) async throws -> Data? {
        let requestID: JSONRPCID
        let methodName: String
        let params: [String: AnyCodable]?

        // Peek at the envelope to distinguish requests (which carry an id) from
        // notifications (which must not). An invalid id value — a bool, array,
        // or object — still marks the frame as a request, so it gets a
        // -32600 Invalid Request error with a null id instead of a silent drop.
        let envelope = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
        let hasID = envelope?["id"] != nil

        // Any well-formed object frame carrying a jsonrpc value other than
        // "2.0" is an Invalid Request. JSONRPCRequest decodes the label as a
        // plain String, so the version must be validated explicitly here;
        // missing or non-string jsonrpc is caught by the decode paths below.
        if let envelope, let version = envelope["jsonrpc"]?.value as? String, version != "2.0" {
            _logger.warning("Invalid jsonrpc version '\(version)' in: \(String(decoding: data, as: UTF8.self))")
            return makeErrorResponse(id: envelopeID(from: envelope) ?? .null, code: -32600, message: "Invalid Request")
        }

        if let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) {
            requestID = request.id
            methodName = request.method
            params = request.params
        } else if hasID {
            _logger.warning("Invalid JSON-RPC request id in: \(String(decoding: data, as: UTF8.self))")
            return makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
        } else if let notification = try? JSONDecoder().decode(JSONRPCNotification.self, from: data) {
            _logger.trace("Received notification: method=\(notification.method)")
            // Notifications never produce responses.
            return nil
        } else if envelope != nil {
            // Valid JSON, but neither a decodable request nor a notification —
            // e.g. a request missing the jsonrpc field with no id. The JSON-RPC
            // spec reserves -32700 for input that is not valid JSON; anything
            // that parses but is malformed is an Invalid Request.
            _logger.warning("Invalid JSON-RPC message: \(String(decoding: data, as: UTF8.self))")
            return makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
        } else {
            _logger.warning("Unable to parse JSON-RPC message: \(String(decoding: data, as: UTF8.self))")
            return makeErrorResponse(id: .null, code: -32700, message: "Parse error")
        }

        guard let method = MCPMethod(rawValue: methodName) else {
            _logger.warning("Unknown method: \(methodName)")
            return makeErrorResponse(id: requestID, code: -32601, message: "Method not found: \(methodName)")
        }

        _logger.trace("Received request: method=\(methodName), id=\(requestID)")

        let response: Data?

        switch method {
        case .initialize:
            response = try await handleInitialize(request: params, id: requestID)
        case .ping:
            response = makeSuccessResponse(id: requestID, result: [String: AnyCodable]())
        case .toolsList:
            response = try await handleToolsList(id: requestID, caller: caller)
        case .toolsCall:
            response = try await handleToolsCall(params: params, id: requestID, caller: caller)
        case .initialized, .cancelled:
            // These methods are defined as notifications, but a client that
            // sends one with an id has made it a request — JSON-RPC requires
            // a response to every request, so acknowledge with an empty
            // success instead of silently hanging the caller.
            response = makeSuccessResponse(id: requestID, result: [String: AnyCodable]())
        case .resourcesList, .resourcesRead, .promptsList, .promptsGet:
            response = makeErrorResponse(id: requestID, code: -32601, message: "Method not found: \(methodName)")
        }

        return response
    }

    // MARK: - Initialize

    /// The protocol versions this server supports.
    ///
    /// The MCP wire surface this server implements (`initialize`, `ping`,
    /// `tools/list`, `tools/call`, and the two notification no-ops) is stable
    /// across these revisions, so any of them may be negotiated.
    static let supportedProtocolVersions: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18",
        "2025-11-25",
    ]

    /// The newest protocol version this server supports.
    ///
    /// Answered when the client requests a version outside
    /// ``supportedProtocolVersions`` or omits one.
    static let latestProtocolVersion = "2025-11-25"

    /// Negotiates the response protocol version.
    ///
    /// Echoes the client's requested version when it is supported — the MCP
    /// spec's expectation and what mainstream SDKs verify against the server's
    /// reply — otherwise answers with the newest supported version.
    private func negotiateProtocolVersion(requested: String?) -> String {
        guard let requested, Self.supportedProtocolVersions.contains(requested) else {
            return Self.latestProtocolVersion
        }
        return requested
    }

    /// Handles the `initialize` request.
    ///
    /// Returns server capabilities including the negotiated protocol version
    /// and available features.
    private func handleInitialize(request params: [String: AnyCodable]?, id: JSONRPCID) async throws -> Data {
        // Lenient: read the requested version straight from the params — clients
        // may omit fields the strict InitializeParams model requires, and only
        // the version string is needed for negotiation.
        let requestedProtocolVersion = params?["protocolVersion"]?.value as? String

        if let params,
           let initParams = try? JSONDecoder().decode(InitializeParams.self, from: try JSONEncoder().encode(params)) {
            _logger.info(
                "Client initialized: \(initParams.clientInfo.name) v\(initParams.clientInfo.version) (protocol \(initParams.protocolVersion))"
            )
        }

        let result = InitializeResult(
            protocolVersion: negotiateProtocolVersion(requested: requestedProtocolVersion),
            capabilities: ServerCapabilities(tools: true),
            serverInfo: ImplementationInfo(name: name, version: version)
        )

        return makeSuccessResponse(id: id, result: result)
    }

    // MARK: - Tools List

    /// Handles the `tools/list` request.
    ///
    /// Builds a list of tool definitions with auto-generated JSON Schema
    /// for each registered tool that the caller has access to.
    private func handleToolsList(id: JSONRPCID, caller: MCPCallerInfo) async throws -> Data {
        var toolDefinitions: [MCPToolDefinition] = []

        // Dispatcher (macro-generated, typed) catalog first — the generated
        // implementation filters by the caller's access level itself.
        if let dispatcher = toolDispatcher {
            for descriptor in dispatcher.toolCatalog(for: caller.accessLevel) {
                toolDefinitions.append(toolDefinition(from: descriptor))
            }
        }

        for (_, toolType) in snapshotToolTypes() {
            let config = toolType.configuration

            // Filter by access level
            guard caller.accessLevel >= config.requiredAccess else { continue }

            let schema = JSONSchemaBuilder.buildObjectSchema(properties: toolType.discoverParameters())
            toolDefinitions.append(
                MCPToolDefinition(
                    name: toolType.toolName,
                    description: config.description.isEmpty ? nil : config.description,
                    inputSchema: schema
                )
            )
        }

        // Include instance-registered tools
        for (toolName, instance) in snapshotToolInstances() {
            let config = type(of: instance).configuration
            guard caller.accessLevel >= config.requiredAccess else { continue }

            let schema = JSONSchemaBuilder.buildObjectSchema(properties: type(of: instance).discoverParameters())
            toolDefinitions.append(
                MCPToolDefinition(
                    name: toolName,
                    description: config.description.isEmpty ? nil : config.description,
                    inputSchema: schema
                )
            )
        }

        return makeSuccessResponse(id: id, result: ToolsListResult(tools: toolDefinitions))
    }

    /// Converts a compile-time-known tool descriptor into a wire definition.
    private func toolDefinition(from descriptor: MCPToolDescriptor) -> MCPToolDefinition {
        MCPToolDefinition(
            name: descriptor.name,
            description: descriptor.description.isEmpty ? nil : descriptor.description,
            inputSchema: JSONSchemaBuilder.buildObjectSchema(properties: descriptor.parameters)
        )
    }

    // MARK: - Tools Call

    /// Handles the `tools/call` request.
    ///
    /// Finds the requested tool, checks access level, applies the provided
    /// arguments, invokes the tool, and returns the result.
    private func handleToolsCall(
        params: [String: AnyCodable]?,
        id: JSONRPCID,
        caller: MCPCallerInfo
    ) async throws -> Data {
        guard let params, let toolName = params["name"]?.value as? String else {
            return makeErrorResponse(id: id, code: -32602, message: "Invalid params: missing tool name")
        }

        let arguments = (params["arguments"]?.value as? [String: Any]) ?? [:]

        // Dispatcher (macro-generated, typed) path first: the server keeps
        // authorization policy in one place by reading the tool's required
        // access from the dispatcher, then drops into the exhaustive typed
        // switch for the invocation itself.
        if let dispatcher = toolDispatcher {
            guard let requiredAccess = dispatcher.requiredAccess(named: toolName) else {
                // Unknown to the dispatcher — fall through to the dynamic
                // registry so hybrid servers keep hand-registered tools.
                return await handleToolsCallFromRegistry(
                    id: id, toolName: toolName, arguments: arguments, caller: caller
                )
            }
            guard caller.accessLevel >= requiredAccess else {
                _logger.warning("Access denied for tool: \(toolName) (caller level \(caller.accessLevel.rawValue))")
                return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
            }

            return await invokeTool(id: id, toolName: toolName, arguments: arguments, caller: caller) {
                guard let result = try await dispatcher.callTool(
                    named: toolName,
                    arguments: arguments,
                    context: MCPContext(arguments: arguments, callerInfo: caller)
                ) else {
                    throw MCPError.toolNotFound(toolName)
                }
                return result
            }
        }

        return await handleToolsCallFromRegistry(id: id, toolName: toolName, arguments: arguments, caller: caller)
    }

    /// Resolves a tool through the dynamic registry (type- or instance-path).
    private func handleToolsCallFromRegistry(
        id: JSONRPCID,
        toolName: String,
        arguments: [String: Any],
        caller: MCPCallerInfo
    ) async -> Data {
        if let toolType = toolType(named: toolName) {
            guard caller.accessLevel >= toolType.configuration.requiredAccess else {
                _logger.warning("Access denied for tool: \(toolName) (caller level \(caller.accessLevel.rawValue))")
                return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
            }

            return await invokeTool(id: id, toolName: toolName, arguments: arguments, caller: caller) {
                var tool = toolType.init()
                try tool.apply(arguments: arguments)
                let context = MCPContext(arguments: arguments, callerInfo: caller)
                return try await tool.invoke(context: context)
            }
        } else if let instance = toolInstance(named: toolName) {
            guard caller.accessLevel >= type(of: instance).configuration.requiredAccess else {
                _logger.warning("Access denied for instance tool: \(toolName) (caller level \(caller.accessLevel.rawValue))")
                return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
            }

            return await invokeTool(id: id, toolName: toolName, arguments: arguments, caller: caller) {
                var mutableInstance = instance
                try mutableInstance.apply(arguments: arguments)
                let context = MCPContext(arguments: arguments, callerInfo: caller)
                return try await mutableInstance.invoke(context: context)
            }
        } else {
            return makeErrorResponse(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
    }

    /// Applies arguments, invokes a tool, and maps the outcome to a response.
    ///
    /// Client faults — missing or mistyped arguments — are protocol errors
    /// (`-32602` Invalid params). Failure inside the tool's own execution,
    /// however, is reported as a result with `isError: true` per the MCP
    /// spec's Error Handling section, not as a JSON-RPC error.
    private func invokeTool(
        id: JSONRPCID,
        toolName: String,
        arguments: [String: Any],
        caller: MCPCallerInfo,
        invocation: () async throws -> MCPToolResult
    ) async -> Data {
        do {
            let result = try await invocation()
            return makeSuccessResponse(id: id, result: ToolsCallResult(content: result.content, isError: result.isError))
        } catch let error as MCPError {
            switch error {
            case .missingArgument, .typeMismatch, .toolNotFound:
                _logger.warning("Tool \(toolName) rejected arguments: \(error.description)")
                return makeErrorResponse(id: id, code: -32602, message: error.description)
            default:
                _logger.warning("Tool \(toolName) failed: \(error.description)")
                return makeErrorResponse(id: id, code: -32603, message: error.description)
            }
        } catch {
            _logger.warning("Tool \(toolName) execution error: \(error.localizedDescription)")
            return makeSuccessResponse(
                id: id,
                result: ToolsCallResult(content: [.text(error.localizedDescription)], isError: true)
            )
        }
    }

    // MARK: - Helpers

    /// Extracts the request id from a decoded object envelope so an error
    /// response can echo a valid string/number id. Returns `nil` when the id
    /// is absent or is not a legal JSON-RPC id (bool, array, object).
    private func envelopeID(from envelope: [String: AnyCodable]) -> JSONRPCID? {
        guard let id = envelope["id"] else { return nil }
        guard let data = try? JSONEncoder().encode(id) else { return nil }
        return try? JSONDecoder().decode(JSONRPCID.self, from: data)
    }

    /// Encodes a JSON-RPC success response.
    private func makeSuccessResponse<Result: Encodable & Sendable>(id: JSONRPCID, result: Result) -> Data {
        do {
            return try JSONEncoder().encode(JSONRPCResponse(id: id, result: result))
        } catch {
            _logger.error("Failed to encode success response: \(error)")
            return makeErrorResponse(id: id, code: -32603, message: "Internal error: failed to encode response")
        }
    }

    /// Encodes a JSON-RPC error response.
    private func makeErrorResponse(id: JSONRPCID, code: Int, message: String) -> Data {
        do {
            return try JSONEncoder().encode(JSONRPCErrorResponse(id: id, code: code, message: message))
        } catch {
            // A fixed-shape error frame cannot realistically fail to encode.
            _logger.critical("Failed to encode error response: \(error)")
            return Data()
        }
    }
}

/// A result builder that carries each tool expression with its concrete type.
///
/// Unlike an existential-array builder (`[any MCPTool]`), every
/// ``buildExpression`` result is returned as its own type and combined into a
/// heterogeneous tuple by ``buildBlock``, so the server's generic initializers
/// receive the tools concretely — no type erasure at the call site. The price
/// is that the builder only supports flat lists of tools: conditional blocks
/// (`if`/`else`) and array literals like `{ [] }` are not representable with
/// typed packs. Hand-written servers needing dynamic selection should register
/// tools at runtime with ``MCPServer/register(_:)``/``MCPServer/registerInstance(_:instance:)``.
@resultBuilder
public enum MCPToolBuilder {
    /// Preserves a tool expression's concrete type.
    public static func buildExpression<T: MCPTool>(_ expression: T) -> T {
        expression
    }

    /// Combines tool expressions into a heterogeneous tuple, preserving each
    /// element's concrete type.
    public static func buildBlock<each Tool: MCPTool>(_ components: repeat each Tool) -> (repeat each Tool) {
        (repeat each components)
    }
}
