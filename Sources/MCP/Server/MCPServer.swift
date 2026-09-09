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
import NIOCore
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
/// and must be run via a `ServiceGroup`. Use `runService(gracefulShutdownSignals:)`
/// for a convenient way to run the server with signal handling, or create your
/// own `ServiceGroup` for full control.
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
/// close on TCP — `run()` returns and the enclosing group applies the
/// service's termination behavior. `runService(gracefulShutdownSignals:)`
/// configures `.gracefullyShutdownGroup` so a completed session ends the
/// process cleanly.
///
/// - Warning: This class uses `@unchecked Sendable` because its mutable
///   tool registries are shared between registration calls and the transports'
///   message-handling actors. All registry access is serialized through an
///   internal lock; the `transport` and `logger` are `let` properties and safe
///   for concurrent access.
public final class MCPServer: Service, @unchecked Sendable {

    private let name: String
    private let version: String
    private var _logger: Logger
    private let transport: any MCPTransport
    /// The byte-level routing core: tool registries, dispatcher surface, and
    /// JSON-RPC message routing. `let` — registration and routing are
    /// serialized internally.
    private let messageRouter: MCPMessageRouter
    public var logger: Logger { _logger }

    /// The log level of the server's logger.
    public var logLevel: Logger.Level {
        get { _logger.logLevel }
        set { _logger.logLevel = newValue }
    }

    /// The address the transport bound to, if it can report one.
    ///
    /// `nil` for stdio, for transports that do not expose a bound address, or
    /// before a TCP transport has started. Pairs with `boundPort` for
    /// ephemeral binds (`ServerAddress.hostname("127.0.0.1", port: 0)`).
    public var boundAddress: SocketAddress? {
        (transport as? MCPTransportAddressProviding)?.boundAddress
    }

    /// The port the transport bound to, if it can report one.
    ///
    /// Makes an ephemeral port bind discoverable end-to-end without reaching
    /// into the transport. `nil` for stdio or before startup.
    public var boundPort: Int? {
        (transport as? MCPTransportAddressProviding)?.boundPort
    }

    /// Creates a new MCP server over the standard stdio transport.
    ///
    /// - Parameters:
    ///   - name: The server name (sent to clients during initialization).
    ///   - version: The server version (e.g. "1.0.0").
    ///   - dispatcher: An optional compile-time-known tool dispatcher — the
    ///     macro-generated surface from `MCPApplication`. Tools it knows are
    ///     served through typed, exhaustive dispatch; tools added via
    ///     `register(_:)`/`registerInstance(_:instance:)` remain served
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
    ///     `init(name:version:dispatcher:tools:)`).
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
    ///     `init(name:version:dispatcher:tools:)`).
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
    /// custom `TCPTransport/init(address:eventLoopGroup:allowIPv4MappedIPv6:accessResolver:)`
    /// so you can control per-connection authorization (see <doc:AccessControl>).
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - version: The server version.
    ///   - transport: The transport to use.
    ///   - dispatcher: An optional compile-time-known tool dispatcher (see
    ///     `init(name:version:dispatcher:tools:)`).
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
    /// (e.g. `.trace` for accept-resolver decisions) follow `logLevel`.
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
        self.transport = transport
        self._logger = logger
        self.messageRouter = MCPMessageRouter(
            name: name,
            version: version,
            logger: logger,
            dispatcher: dispatcher
        )
        for tool in repeat each tools() {
            // Register the instance itself so any configuration the caller
            // passed to the tool's initializer survives into invocation —
            // register(_:) stores only the type and would silently discard it.
            messageRouter.registerInstance(type(of: tool).toolName, instance: tool)
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
    ///   existing tool is silently overwritten. Use `unregister(_:)` to
    ///   remove a tool before re-registering.
    ///
    /// Registration is safe to call while the server is running; the registry
    /// is guarded against concurrent access with the transports.
    public func register<T: MCPTool>(_ tool: T) {
        messageRouter.register(tool)
    }

    /// Registers a tool instance with the server.
    ///
    /// Unlike `register(_:)` which stores the type and creates new instances
    /// for each call, this method stores the instance directly. Use this for
    /// tools with dynamic configuration that cannot be created via `init()`.
    ///
    /// - Parameter name: The name to register the tool under.
    /// - Parameter instance: The tool instance to register.
    ///
    /// Registration is safe to call while the server is running; the registry
    /// is guarded against concurrent access with the transports.
    public func registerInstance(_ name: String, instance: any MCPTool) {
        messageRouter.registerInstance(name, instance: instance)
    }

    /// Unregisters a tool from the server by name.
    ///
    /// - Parameter name: The name of the tool to remove.
    ///
    /// After unregistration, the tool is no longer available via `tools/list`
    /// or `tools/call`. Calling `unregister(_:)` with a name that has not
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
        messageRouter.unregister(name)
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
    /// This method conforms to the `Service` protocol from Swift Service
    /// Lifecycle. It drives the transport directly; when the transport
    /// completes — client EOF on stdio, or listener close on TCP — `run()`
    /// returns and the enclosing `ServiceGroup` applies the service's
    /// success termination behavior.
    ///
    /// When the enclosing group initiates graceful shutdown (via a signal or
    /// the host), a shutdown handler calls ``MCPTransport/stop()``, waking the
    /// transport's read loop so it can unwind promptly.
    ///
    /// - Note: This method is required by the `Service` protocol. It is
    ///   exposed as `public` only because the protocol requires it.
    public func run() async throws {
        _logger.info("Starting MCP server: \(name) v\(version)")

        try await withGracefulShutdownHandler {
            try await self.transport.start { [weak self] (bytes: [UInt8], caller: MCPCallerInfo) in
                guard let self else { return nil as [UInt8]? }
                return try await self.handleMessage(bytes, caller: caller)
            }
        } onGracefulShutdown: {
            // The shutdown callback is synchronous, so a short-lived task fans
            // the stop out to the transport. The transport's read loop is
            // poll-based and observes the stop flag within poll timeout.
            Task { try? await self.transport.stop() }
        }
    }

    /// Runs the server inside a `ServiceGroup` with signal-based graceful shutdown.
    ///
    /// This is the recommended way to run the server. It wraps the server in a
    /// `ServiceGroup` that listens for the specified signals and triggers
    /// graceful shutdown when they are received.
    ///
    /// When the transport completes on its own — client EOF on stdio, or
    /// listener close on TCP — the server is configured with
    /// `.gracefullyShutdownGroup` termination behavior, so `runService`
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
    ///   - bytes: The raw JSON-RPC message bytes.
    ///   - caller: Information about the caller.
    /// - Returns: Response bytes, or `nil` for notifications.
    private func handleMessage(_ bytes: [UInt8], caller: MCPCallerInfo) async throws -> [UInt8]? {
        try await messageRouter.route(bytes, caller: caller)
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
    /// `supportedProtocolVersions` or omits one.
    static let latestProtocolVersion = "2025-11-25"
}

/// The user-facing description of an arbitrary thrown error.
///
/// Prefers a `LocalizedError`'s `errorDescription` (the canonical readable
/// message tool authors provide) and falls back to the Swift description —
/// the Foundation-`localizedDescription` contract without coupling callers
/// to Foundation.
func readableErrorDescription(_ error: Error) -> String {
    if let localized = error as? any LocalizedError, let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}

/// A result builder that carries each tool expression with its concrete type.
///
/// Unlike an existential-array builder (`[any MCPTool]`), every
/// `buildExpression` result is returned as its own type and combined into a
/// heterogeneous tuple by `buildBlock`, so the server's generic initializers
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
