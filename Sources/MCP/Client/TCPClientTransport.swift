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
import NIOCore
import NIOPosix
import QuickJSON
import Synchronization

/// A ``ClientTransport`` carrier that connects to a networked MCP server over
/// TCP — IPv4/IPv6 hostname or Unix domain socket.
///
/// Reuses the shared NIO framing: the pipeline is `MCPFrameCodec` +
/// `ClientFrameBridge`, the exact composition the subprocess carrier runs
/// over pipe channels. Only the medium differs — `MCPClient` is unchanged on
/// top, so the same actor, in-flight table, timeouts, and catalog logic drive
/// both a spawned tool binary and a networked server.
///
/// - Note: one-shot per instance, matching `SubprocessClientTransport` —
///   `MCPClient` itself is single-`connect()`.
///
/// - Warning: This class uses `@unchecked Sendable` because its runtime state
///   (`started`, `channel`) is mutated from `start()`, `sendFrame()`, and
///   `stop()`, which can overlap. All access is serialized through `stateLock`.
public final class TCPClientTransport: ClientTransport, @unchecked Sendable {

    /// Where and how to connect.
    public struct Configuration: Sendable {
        /// The server address: hostname + port, or a Unix domain socket path.
        public var address: ServerAddress
        /// The maximum client-side frame size. A larger frame from the server
        /// is rejected and the connection closes. Defaults to 10 MiB.
        public var maxMessageSize: Int
        /// How long a connect may take before failing. Defaults to 10s.
        public var connectTimeout: TimeAmount

        /// Creates a connection configuration.
        ///
        /// - Parameters:
        ///   - address: The `ServerAddress` to connect to.
        ///   - maxMessageSize: Max client-side frame size (default 10 MiB).
        ///   - connectTimeout: Connect deadline (default 10s).
        public init(
            address: ServerAddress,
            maxMessageSize: Int = 10 * 1024 * 1024,
            connectTimeout: TimeAmount = .seconds(10)
        ) {
            self.address = address
            self.maxMessageSize = maxMessageSize
            self.connectTimeout = connectTimeout
        }
    }

    private let configuration: Configuration
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger?
    private let oversizeErrorFrame: [UInt8]
    /// Records the size cap when the inbound codec rejects an oversized frame,
    /// so the client can fail in-flight calls with a size-specific error
    /// instead of a generic `connectionClosed`.
    private let sizeCapRecorder = SizeCapRecorder()
    /// The backpressured producer/consumer halves of the frame stream.
    private let clientFrames: ClientFrames

    /// Guards the runtime state below.
    private let stateLock = Mutex<()>(())
    private var started = false
    private var channel: Channel?

    /// Creates a TCP client carrier.
    ///
    /// - Parameters:
    ///   - configuration: The address to connect to and limits.
    ///   - eventLoopGroup: The NIO event loop group. `.singleton` is correct.
    ///   - logger: An optional logger for transport diagnostics.
    public init(
        configuration: Configuration,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.oversizeErrorFrame =
            (try? QuickJSON.encode(JSONRPCErrorResponse(id: .null, code: -32700, message: "Message too large"))) ?? []
        self.clientFrames = ClientFrames()
    }

    /// The remote socket address the connection is bound to, once started.
    public var remoteAddress: SocketAddress? {
        stateLock.withLock { _ in channel?.remoteAddress }
    }

    /// Reports the size cap when the connection was torn down by an oversized
    /// inbound frame, or `nil` for plain EOF/crash.
    public var sizeCapViolation: Int? {
        sizeCapRecorder.value
    }

    /// The local socket address the connection is bound to, once started.
    public var localAddress: SocketAddress? {
        stateLock.withLock { _ in channel?.localAddress }
    }

    // MARK: - ClientTransport

    /// Connects to the configured address and opens the NIO socket channel.
    public func start() async throws {
        let alreadyStarted: Bool = stateLock.withLock { _ in
            if started { return true }
            started = true
            return false
        }
        if alreadyStarted { return }

        let maxMessageSize = configuration.maxMessageSize
        let sizeCapRecorder = self.sizeCapRecorder

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(configuration.connectTimeout)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { [clientFrames, maxMessageSize, oversizeErrorFrame, sizeCapRecorder, logger] channel in
                channel.pipeline.addHandlers(
                    MCPFrameCodec(
                        maxMessageSize: maxMessageSize,
                        oversizeErrorFrame: oversizeErrorFrame,
                        onRejectOversize: { sizeCapRecorder.record(maxMessageSize) }
                    ),
                    ClientFrameBridge(source: clientFrames.source, demand: clientFrames.demand, logger: logger)
                )
            }

        let channel: Channel
        switch configuration.address.value {
        case .hostname(let host, let port):
            do {
                channel = try await bootstrap.connect(host: host, port: port).get()
            } catch {
                stateLock.withLock { _ in self.started = false }
                throw MCPClientError.connectionFailed("cannot connect to \(host):\(port): \(error)")
            }
        case .unixDomainSocket(let path):
            do {
                channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
            } catch {
                stateLock.withLock { _ in self.started = false }
                throw MCPClientError.connectionFailed("cannot connect to unix:\(path): \(error)")
            }
        }

        stateLock.withLock { _ in
            self.channel = channel
        }
    }

    /// Writes one complete JSON-RPC frame to the server, awaiting the flush.
    public func sendFrame(_ bytes: [UInt8]) async throws {
        let channel: Channel? = stateLock.withLock { _ in self.channel }
        guard let channel else {
            throw MCPClientError.notConnected
        }
        do {
            try await channel.writeAndFlush(bytes).get()
        } catch {
            throw MCPClientError.connectionClosed
        }
    }

    /// The frames the server emits, until EOF or `stop()`.
    nonisolated public func frames() -> ClientFrameSequence {
        clientFrames.sequence
    }

    /// Closes the connection. The frames stream finishes; in-flight requests
    /// fail with `connectionClosed`.
    public func stop() async throws {
        let channel: Channel? = stateLock.withLock { _ in
            let active = self.channel
            self.channel = nil
            self.started = false
            return active
        }
        try await channel?.close(mode: .all)
    }
}
