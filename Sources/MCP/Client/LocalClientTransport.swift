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

/// A ``ClientTransport`` carrier that drives ``MCPClient`` with **no bytes at
/// all** — network-free MCP.
///
/// `@MCPApplication`'s generated ``MCPToolDispatcher`` (ToolID enum,
/// exhaustive typed `callTool`, catalog, access gates) is a transportless MCP
/// endpoint; that is what this carrier binds to. `sendFrame` decodes the
/// request, routes it through the shared `MCPMessageRouter` — the exact
/// routing core every networked server uses — and delivers the response back
/// into the client's frame stream. The client state machine (initialize
/// negotiation, in-flight table, per-call timeouts, catalog invalidation) runs
/// fully with no process, no pipe, and no socket.
///
/// The caller is the local process, so requests arrive at ``AccessLevel/root``
/// — a compile-time, trusted binding. Network-free MCP is a configuration of
/// the same `MCPClient`, not a fork.
public struct LocalClientTransport<Dispatcher: MCPToolDispatcher>: ClientTransport {

    /// Identity for the local endpoint.
    public struct Configuration: Sendable {
        /// The `serverInfo.name` the router answers with during `initialize`.
        public var serverName: String = "local-mcp"
        /// The `serverInfo.version` the router answers with during `initialize`.
        public var serverVersion: String = "1.0.0"

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - serverName: The local endpoint's identity (default `local-mcp`).
        ///   - serverVersion: The local endpoint's version (default `1.0.0`).
        public init(serverName: String = "local-mcp", serverVersion: String = "1.0.0") {
            self.serverName = serverName
            self.serverVersion = serverVersion
        }
    }

    /// The local caller identity: sourced from `"local"`, trusted at `.root`.
    private static var caller: MCPCallerInfo {
        MCPCallerInfo(sourceAddress: "local", accessLevel: .root)
    }

    private let router: MCPMessageRouter
    /// The backpressured producer/consumer halves of the frame stream.
    private let clientFrames: ClientFrames

    /// Creates a network-free carrier over a compile-time tool dispatcher.
    ///
    /// - Parameters:
    ///   - dispatcher: The macro-generated `MCPToolDispatcher` (or a
    ///     hand-written equivalent) serving the endpoint.
    ///   - configuration: The local endpoint's identity.
    ///   - logger: An optional logger for routing diagnostics.
    public init(
        dispatcher: Dispatcher,
        configuration: Configuration = Configuration(),
        logger: Logger? = nil
    ) {
        self.router = MCPMessageRouter(
            name: configuration.serverName,
            version: configuration.serverVersion,
            logger: logger ?? Logger(label: "mcp.local"),
            dispatcher: dispatcher
        )
        self.clientFrames = ClientFrames()
    }

    // MARK: - ClientTransport

    /// No-op: there is nothing to bring up.
    public func start() async throws {}

    /// Routes one JSON-RPC request through the shared router and delivers any
    /// response into the client's frame stream, exactly like a wire carrier
    /// would. Notifications and unanswerable frames yield nothing.
    ///
    /// Routing runs fire-and-forget so `sendFrame` returns immediately: the
    /// client's in-flight registration + deadline reaper (set up before this
    /// call) decide the outcome — a local tool that outlives the deadline is
    /// timed out while its (now-orphaned) response is safely dropped as
    /// unknown. Real carriers write to a socket and return just as fast.
    public func sendFrame(_ bytes: [UInt8]) async throws {
        Task {
            guard let response = try? await router.route(bytes, caller: Self.caller) else {
                return
            }
            // in-process: yield can only fail after termination (dropped);
            // harmless to ignore — the client is closing or closed.
            _ = clientFrames.source.yield(response)
        }
    }

    /// The frame stream the client's read loop consumes. Responses accompany
    /// each `sendFrame`; the stream never carries unsolicited data.
    nonisolated public func frames() -> ClientFrameSequence {
        clientFrames.sequence
    }

    /// Finished the frame stream so the client ends its read loop.
    public func stop() async throws {
        clientFrames.source.finish()
    }
}
