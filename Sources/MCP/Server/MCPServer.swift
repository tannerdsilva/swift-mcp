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
///         services: [server],
///         gracefulShutdownSignals: [.sigterm, .sigint],
///         logger: server.logger
///     )
/// )
/// try await serviceGroup.run()
/// ```
///
/// - Warning: This class uses ``@unchecked Sendable`` because the `tools`
///   dictionary is mutated during registration (setup phase) and read during
///   message handling (runtime phase). These phases do not overlap in practice:
///   all tools are registered before the server starts. The `transport` and
///   `logger` are `let` properties and safe for concurrent access.
public final class MCPServer: Service, @unchecked Sendable {

    private let name: String
    private let version: String
    private var tools: [String: any MCPTool.Type]
    /// Instance-registered tools (name → instance).
    private var toolInstances: [String: any MCPTool] = [:]
    private var _logger: Logger
    private let transport: any MCPTransport

    /// The logger used by this server.
    public var logger: Logger { _logger }

    /// The log level of the server's logger.
    public var logLevel: Logger.Level {
        get { _logger.logLevel }
        set { _logger.logLevel = newValue }
    }

    /// Creates a new MCP server.
    ///
    /// - Parameters:
    ///   - name: The server name (sent to clients during initialization).
    ///   - version: The server version (e.g. "1.0.0").
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    ///     Pass an empty closure `{}` to register tools later via ``register(_:)``.
    public init(
        name: String,
        version: String,
        @MCPToolBuilder tools: () -> [any MCPTool]
    ) {
        self.name = name
        self.version = version
        self.tools = [:]
        self._logger = Logger(label: "mcp.server")
        self.transport = StdioTransport()
        for tool in tools() {
            self.register(tool)
        }
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
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    ///     Pass an empty closure `{}` to register tools later via ``register(_:)``.
    public init(
        name: String,
        version: String,
        address: ServerAddress,
        allowIPv4MappedIPv6: Bool = false,
        @MCPToolBuilder tools: () -> [any MCPTool]
    ) {
        self.name = name
        self.version = version
        self.tools = [:]
        self._logger = Logger(label: "mcp.server")
        self.transport = TCPTransport(
            address: address,
            allowIPv4MappedIPv6: allowIPv4MappedIPv6
        )
        for tool in tools() {
            self.register(tool)
        }
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
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    ///     Pass an empty closure `{}` to register tools later via ``registerInstance(_:instance:)``.
    public convenience init(
        name: String,
        version: String,
        address: ServerAddress,
        allowIPv4MappedIPv6: Bool = false,
        accessResolver: @escaping @Sendable (String) -> AccessLevel,
        @MCPToolBuilder tools: () -> [any MCPTool]
    ) {
        self.init(
            name: name,
            version: version,
            transport: TCPTransport(
                address: address,
                allowIPv4MappedIPv6: allowIPv4MappedIPv6,
                accessResolver: accessResolver
            ),
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
    ///   - tools: A ``MCPToolBuilder`` closure that returns tools to register.
    ///     Pass an empty closure `{}` to register tools later via ``registerInstance(_:instance:)``.
    public init(
        name: String,
        version: String,
        transport: any MCPTransport,
        @MCPToolBuilder tools: () -> [any MCPTool] = { [] }
    ) {
        self.name = name
        self.version = version
        self.tools = [:]
        self._logger = Logger(label: "mcp.server")
        self.transport = transport
        for tool in tools() {
            self.register(tool)
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
    public func register<T: MCPTool>(_ tool: T) {
        let name = T.toolName
        _logger.debug("Registering tool: \(name) (type: \(T.self))")
        if tools[name] != nil {
            _logger.warning("Tool '\(name)' is already registered and will be overwritten")
        }
        tools[name] = T.self
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
    public func registerInstance(_ name: String, instance: any MCPTool) {
        _logger.debug("Registering tool instance: \(name)")
        if tools[name] != nil || toolInstances[name] != nil {
            _logger.warning("Tool '\(name)' is already registered and will be overwritten")
        }
        toolInstances[name] = instance
        _logger.info("Registered tool instance: \(name)")
    }

    /// Unregisters a tool from the server by name.
    ///
    /// - Parameter name: The name of the tool to remove.
    ///
    /// After unregistration, the tool is no longer available via `tools/list`
    /// or `tools/call`. Calling ``unregister(_:)`` with a name that has not
    /// been registered is a no-op.
    ///
    /// ```swift
    /// server.register(Greet())
    /// server.unregister("greet")  // greet is no longer available
    /// ```
    public func unregister(_ name: String) {
        guard tools.removeValue(forKey: name) != nil else {
            _logger.warning("Attempted to unregister unknown tool: \(name)")
            return
        }
        _logger.info("Unregistered tool: \(name)")
    }

    // MARK: - Service Conformance

    /// Stops the server and its transport.
    ///
    /// This method calls ``MCPTransport/stop()`` on the underlying transport,
    /// which causes the read loop to exit and the server to shut down gracefully.
    public func stop() async throws {
        try await transport.stop()
    }

    /// Starts the transport and begins handling messages.
    ///
    /// This method conforms to the ``Service`` protocol from Swift Service
    /// Lifecycle. It wraps the transport in a ``ClosureService`` and runs it
    /// inside a ``ServiceGroup``.
    ///
    /// - Important: Do not call this method directly. Use ``runService(gracefulShutdownSignals:)``
    ///   instead, which provides signal-based graceful shutdown. Calling this
    ///   method directly will **not** set up signal handling, meaning the
    ///   process may not shut down cleanly on SIGTERM or SIGINT.
    ///
    /// - Note: This method is required by the ``Service`` protocol. It is
    ///   exposed as `public` only because the protocol requires it.
    public func run() async throws {
        _logger.info("Starting MCP server: \(name) v\(version)")

        // Wrap the transport as a Service using ClosureService
        let transportService = ClosureService { [weak self] in
            guard let self else { return }
            try await self.transport.start { [weak self] (data: Data, caller: MCPCallerInfo) in
                guard let self else { return nil as Data? }
                return try await self.handleMessage(data, caller: caller)
            }
        }

        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [transportService],
                logger: _logger
            )
        )
        try await serviceGroup.run()
    }

    /// Runs the server inside a ``ServiceGroup`` with signal-based graceful shutdown.
    ///
    /// This is the recommended way to run the server. It wraps the server in a
    /// ``ServiceGroup`` that listens for the specified signals and triggers
    /// graceful shutdown when they are received.
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
                services: [self],
                gracefulShutdownSignals: gracefulShutdownSignals,
                logger: _logger
            )
        )
        try await serviceGroup.run()
    }

    // MARK: - Message Handling

    /// Routes an incoming JSON-RPC message to the appropriate handler.
    ///
    /// - Parameters:
    ///   - data: The raw JSON-RPC message data.
    ///   - caller: Information about the caller.
    /// - Returns: Response data, or `nil` for notifications.
    private func handleMessage(_ data: Data, caller: MCPCallerInfo) async throws -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return nil
        }

        let id = json["id"]
        _logger.trace("Received message: method=\(method), id=\(id.map { "\($0)" } ?? "nil")")

        let response: Data?

        switch method {
        case "initialize":
            response = try await handleInitialize(request: json)
        case "ping":
            response = makeSuccessResponse(id: id, result: [:])
        case "tools/list":
            response = try await handleToolsList(request: json, caller: caller)
        case "tools/call":
            response = try await handleToolsCall(request: json, caller: caller)
        case "notifications/initialized":
            response = nil
        case "notifications/cancelled":
            response = nil
        default:
            _logger.warning("Unknown method: \(method)")
            response = makeErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }

        if let response, let responseMethod = methodFromResponse(response) {
            _logger.trace("Sent response: method=\(responseMethod)")
        }

        return response
    }

    /// Extracts the method name from a JSON-RPC response for logging.
    private func methodFromResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if json["error"] != nil { return "error" }
        if json["result"] != nil { return "result" }
        return nil
    }

    // MARK: - Initialize

    /// Handles the `initialize` request.
    ///
    /// Returns server capabilities including supported protocol version and
    /// available features.
    private func handleInitialize(request: [String: Any]) async throws -> Data {
        let id = request["id"]

        let result: [String: Any] = [
            "protocolVersion": "2025-06-18",
            "capabilities": [
                "tools": [:] as [String: Any]
            ],
            "serverInfo": [
                "name": name,
                "version": version
            ]
        ]

        return makeSuccessResponse(id: id, result: result)
    }

    // MARK: - Tools List

    /// Handles the `tools/list` request.
    ///
    /// Builds a list of tool definitions with auto-generated JSON Schema
    /// for each registered tool that the caller has access to.
    private func handleToolsList(request: [String: Any], caller: MCPCallerInfo) async throws -> Data {
        let id = request["id"]

        var toolDefinitions: [[String: Any]] = []

        for (_, toolType) in tools {
            let config = toolType.configuration

            // Filter by access level
            guard caller.accessLevel >= config.requiredAccess else { continue }

            let toolName = toolType.toolName
            let schema = JSONSchemaBuilder.buildSchema(for: toolType)

            var def: [String: Any] = [
                "name": toolName,
                "inputSchema": schema
            ]
            if !config.description.isEmpty {
                def["description"] = config.description
            }

            toolDefinitions.append(def)
        }

        // Include instance-registered tools
        for (toolName, instance) in toolInstances {
            let config = type(of: instance).configuration
            guard caller.accessLevel >= config.requiredAccess else { continue }

            let toolType = type(of: instance)
            let schema = JSONSchemaBuilder.buildSchema(for: toolType)

            var def: [String: Any] = [
                "name": toolName,
                "inputSchema": schema
            ]
            if !config.description.isEmpty {
                def["description"] = config.description
            }

            toolDefinitions.append(def)
        }

        let result: [String: Any] = [
            "tools": toolDefinitions
        ]

        return makeSuccessResponse(id: id, result: result)
    }

    // MARK: - Tools Call

    /// Handles the `tools/call` request.
    ///
    /// Finds the requested tool, checks access level, applies the provided
    /// arguments, invokes the tool, and returns the result.
    private func handleToolsCall(request: [String: Any], caller: MCPCallerInfo) async throws -> Data {
        let id = request["id"]

        guard let params = request["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return makeErrorResponse(id: id, code: -32602, message: "Invalid params: missing tool name")
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        guard let toolType = tools[toolName] else {
            // Check instance-registered tools
            if let instance = toolInstances[toolName] {
                // Enforce access control for instance-registered tools exactly
                // as for type-registered ones.
                guard caller.accessLevel >= type(of: instance).configuration.requiredAccess else {
                    _logger.warning("Access denied for instance tool: \(toolName) (caller level \(caller.accessLevel.rawValue))")
                    return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
                }
                // Use the instance directly
                var mutableInstance = instance
                try mutableInstance.apply(arguments: arguments)
                let context = MCPContext(arguments: arguments, callerInfo: caller)
                let result = try await mutableInstance.invoke(context: context)
                let resultDict: [String: Any] = [
                    "content": encodeContent(result.content),
                    "isError": result.isError
                ]
                return makeSuccessResponse(id: id, result: resultDict)
            }
            return makeErrorResponse(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }

        // Enforce access control
        guard caller.accessLevel >= toolType.configuration.requiredAccess else {
            return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
        }

        do {
            var tool = toolType.init()
            try tool.apply(arguments: arguments)

            let context = MCPContext(arguments: arguments, callerInfo: caller)
            let result = try await tool.invoke(context: context)

            let resultDict: [String: Any] = [
                "content": encodeContent(result.content),
                "isError": result.isError
            ]

            return makeSuccessResponse(id: id, result: resultDict)
        } catch let error as MCPError {
            return makeErrorResponse(id: id, code: -32603, message: error.localizedDescription)
        } catch {
            return makeErrorResponse(id: id, code: -32603, message: "Tool execution error: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Creates a JSON-RPC success response.
    private func makeSuccessResponse(id: Any?, result: Any) -> Data {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id {
            response["id"] = id
        } else {
            response["id"] = NSNull()
        }

        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    /// Creates a JSON-RPC error response.
    private func makeErrorResponse(id: Any?, code: Int, message: String) -> Data {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id {
            response["id"] = id
        } else {
            response["id"] = NSNull()
        }

        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    /// Encodes an array of ``MCPContent`` values to a JSON-compatible format.
    private func encodeContent(_ content: [MCPContent]) -> [[String: Any]] {
        content.map { block in
            switch block {
            case .text(let text):
                return ["type": "text", "text": text]
            case .image(let data, let mimeType):
                return ["type": "image", "data": data, "mimeType": mimeType]
            case .resource(let uri, let mimeType, let text):
                var dict: [String: Any] = ["type": "resource", "uri": uri]
                if let mimeType { dict["mimeType"] = mimeType }
                if let text { dict["text"] = text }
                return dict
            }
        }
    }
}

/// A result builder for constructing arrays of MCP tools.
@resultBuilder
public enum MCPToolBuilder: Sendable {
    /// Combines multiple tool arrays into a single array.
    public static func buildBlock(_ components: [any MCPTool]...) -> [any MCPTool] {
        components.flatMap { $0 }
    }

    /// Wraps a single tool expression in an array.
    public static func buildExpression<T: MCPTool>(_ expression: T) -> [any MCPTool] {
        [expression]
    }

    /// Handles optional tool blocks.
    public static func buildOptional(_ component: [any MCPTool]?) -> [any MCPTool] {
        component ?? []
    }

    /// Handles the first branch of a conditional.
    public static func buildEither(first component: [any MCPTool]) -> [any MCPTool] {
        component
    }

    /// Handles the second branch of a conditional.
    public static func buildEither(second component: [any MCPTool]) -> [any MCPTool] {
        component
    }

    /// Handles array-building from loops.
    public static func buildArray(_ components: [[any MCPTool]]) -> [any MCPTool] {
        components.flatMap { $0 }
    }
}
