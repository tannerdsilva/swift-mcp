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

import Logging
import ServiceLifecycle

/// A `Service` that owns one subprocess MCP plugin for a host's `ServiceGroup`.
///
/// A thin composition over ``SubprocessClientTransport`` + ``MCPClient`` for
/// the Second Law: the process lifecycle and shutdown ladder run inside
/// ``run()``, driven by the enclosing group's graceful-shutdown — no ad-hoc
/// `shutdown()`, no `atexit`, no background daemons.
///
/// ```swift
/// let plugin = MCPClientService(transport: SubprocessClientTransport(
///     configuration: .init(executable: "/usr/local/bin/tool-server")
/// ))
/// let group = ServiceGroup(configuration: .init(
///     services: [ServiceGroupConfiguration.ServiceConfiguration(
///         service: plugin,
///         successTerminationBehavior: .gracefullyShutdownGroup
///     )],
///     gracefulShutdownSignals: [.sigterm, .sigint]
/// ))
/// try await group.run()
/// ```
///
/// `run()` spawns the child, completes the `initialize` handshake, fetches the
/// remote catalog (so the plugin is registered before any call is served), and
/// then waits — ending when the connection drops (child EOF) or the group
/// shuts down (the ladder runs). The host chooses the service's
/// `successTerminationBehavior`: a clean child EOF is the expected outcome for
/// an MCP session, so `.gracefullyShutdownGroup` (or `.ignore`) fits better
/// than the default `.cancelGroup`.
public struct MCPClientService: Service {

    /// The spawned plugin's environment-merged client.
    public let client: MCPClient
    private let transport: SubprocessClientTransport
    private let logger: Logger

    /// Creates a plugin service.
    ///
    /// - Parameters:
    ///   - transport: The subprocess carrier (spawn configuration).
    ///   - configuration: Client timeouts and identity.
    ///   - logger: The logger used for service-level diagnostics.
    public init(
        transport: SubprocessClientTransport,
        configuration: MCPClient.ClientConfiguration = MCPClient.ClientConfiguration(),
        logger: Logger? = nil
    ) {
        self.transport = transport
        self.client = MCPClient(transport: transport, configuration: configuration)
        self.logger = logger ?? Logger(label: "mcp.client")
    }

    /// Spawns, negotiates, lists, then serves until disconnection or group
    /// shutdown.
    ///
    /// - Note: This method is required by the `Service` protocol. It is
    ///   exposed as `public` only because the protocol requires it.
    public func run() async throws {
        logger.info("Starting MCP client service")
        try await withGracefulShutdownHandler {
            try await self.client.connect()
            _ = try await self.client.listTools()
            logger.info("MCP client service ready")
            await self.client.waitForDisconnection()
        } onGracefulShutdown: {
            // The shutdown callback is synchronous, so a short-lived task fans
            // the ladder out to the client. The client's close() runs the
            // subprocess ladder (EOF → grace → TERM → KILL) and ends the
            // waitForDisconnection, so run() returns promptly.
            Task { await self.client.close() }
        }
        logger.info("MCP client service shut down")
    }
}
