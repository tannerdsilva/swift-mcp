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
import NIOPosix

// MARK: - Channel Handler

/// A channel handler that reads newline-delimited JSON messages from a TCP
/// connection and forwards them to the MCP message handler via an actor for
/// serialized processing.
///
/// - Note: marked `Sendable` because NIO's `childChannelInitializer` closure
///   is `@Sendable`; all mutable state stays on the event loop.
final class MCPMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handler: @Sendable (Data, MCPCallerInfo) async throws -> Data?
    private let caller: MCPCallerInfo
    private let logger: Logger?
    private var buffer: ByteBuffer?
    private var actor: TransportMessageHandler?

    init(
        handler: @escaping @Sendable (Data, MCPCallerInfo) async throws -> Data?,
        caller: MCPCallerInfo,
        logger: Logger? = nil
    ) {
        self.handler = handler
        self.caller = caller
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        let handler = self.handler
        let caller = self.caller
        let logger = self.logger
        self.actor = TransportMessageHandler(
            handler: handler,
            caller: caller,
            write: { data in
                var buf = channel.allocator.buffer(capacity: data.count + 1)
                buf.writeBytes(data)
                buf.writeInteger(UInt8(0x0A)) // newline
                channel.writeAndFlush(buf, promise: nil)
            },
            makeError: { requestData, error in
                guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: requestData) else {
                    // Without an id there is no frame to reply to.
                    return nil
                }
                do {
                    let response = JSONRPCErrorResponse(
                        id: request.id,
                        code: -32603,
                        message: "Internal error: \(error.localizedDescription)"
                    )
                    return try JSONEncoder().encode(response)
                } catch {
                    // A fixed-shape error frame cannot realistically fail to encode.
                    logger?.warning("Failed to encode TCP error response: \(error)")
                    return nil
                }
            }
        )
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task { [actor] in
            await actor?.cancel()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inboundData = unwrapInboundIn(data)

        // If we have a leftover buffer from a previous read, prepend it
        if var existing = buffer {
            existing.writeBuffer(&inboundData)
            inboundData = existing
            buffer = nil
        }

        guard let actor = self.actor else { return }

        // Process complete lines
        while let lineEnd = inboundData.readableBytesOfNewline() {
            guard let lineData = inboundData.readBytes(length: lineEnd) else {
                continue
            }
            // Skip the newline bytes
            inboundData.moveReaderIndex(forwardBy: 1)

            let data = Data(lineData)
            // Dispatch to the actor for serialized processing
            Task { await actor.process(data) }
        }

        // Store remaining bytes for next read
        if inboundData.readableBytes > 0 {
            buffer = inboundData
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Channel error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - TCP Transport

/// A transport that listens for TCP connections and communicates using
/// newline-delimited JSON messages.
///
/// This transport supports IPv4, IPv6, dual-stack, and Unix domain sockets.
/// Each connection's source address is resolved to an ``AccessLevel`` using
/// a configurable resolver closure.
///
/// ## Usage
///
/// ```swift
/// let transport = TCPTransport(
///     address: .hostname("127.0.0.1", port: 8080),
///     accessResolver: { address in
///         address.hasPrefix("127.0.0.1") ? .admin : .public
///     }
/// )
/// ```
///
/// - Warning: This class uses ``@unchecked Sendable`` because the `channel`
///   and `isRunning` properties are mutated during startup and shutdown from
///   different tasks. The NIO `channel` is set once during ``start(handler:)``
///   and cleared during ``stop()``; these calls do not overlap. The
///   `accessResolver` closure is `@Sendable` and only read after initialization.
public final class TCPTransport: MCPTransport, @unchecked Sendable {

    private let address: ServerAddress
    private let eventLoopGroup: EventLoopGroup
    private let allowIPv4MappedIPv6: Bool
    private let logger: Logger?
    private var channel: Channel?
    private var isRunning = false
    private let accessResolver: @Sendable (String) -> AccessLevel
    /// The address the server channel bound to, once started.
    ///
    /// Useful when binding an ephemeral port (`ServerAddress.hostname("127.0.0.1", port: 0)`);
    /// readable while the transport is running.
    internal private(set) var boundAddress: SocketAddress?

    /// The port the server channel bound to, or `nil` until started.
    ///
    /// Convenience for ephemeral-port binds, so callers do not need to touch
    /// the NIO `SocketAddress` type directly.
    internal var boundPort: Int? { boundAddress?.port }

    /// Resolves loopback addresses to ``AccessLevel/admin``.
    ///
    /// NIO renders remote socket addresses with a scheme prefix, verified:
    /// `[IPv4]127.0.0.1:49152`, `[IPv6]::1:49152`, and
    /// `[IPv6]::ffff:127.0.0.1:49152` for IPv4-mapped IPv6. The canonical
    /// prefixed forms are matched first; bare and bracket-without-scheme
    /// spellings are also accepted for robustness when the resolver is fed
    /// non-NIO address strings.
    ///
    /// - Parameter address: The caller's source address (the remote socket
    ///   address description passed to the transport's access resolver).
    /// - Returns: ``AccessLevel/admin`` for loopback addresses, otherwise
    ///   ``AccessLevel/public``.
    public static func defaultAccessResolver(_ address: String) -> AccessLevel {
        if address.hasPrefix("[IPv4]127.0.0.1:")
            || address.hasPrefix("[IPv6]::1:")
            || address.hasPrefix("[IPv6]::ffff:127.0.0.1:")
            // robustness for non-NIO spellings
            || address.hasPrefix("127.0.0.1")
            || address.hasPrefix("::1:")
            || address.hasPrefix("::ffff:127.0.0.1")
            || address.hasPrefix("[::1]:")
            || address.hasPrefix("[::ffff:127.0.0.1]:") {
            return .admin
        }
        return .public
    }

    /// Creates a new TCP transport.
    ///
    /// - Parameters:
    ///   - address: The address to bind to.
    ///   - eventLoopGroup: The NIO event loop group to use.
    ///   - allowIPv4MappedIPv6: Whether to allow IPv4-mapped IPv6 connections.
    ///   - accessResolver: A closure that resolves an IP address to an access
    ///     level. The default is ``defaultAccessResolver(_:)``, which grants
    ///     ``AccessLevel/admin`` to IPv4 and IPv6 loopback callers.
    ///   - logger: An optional logger for transport-level diagnostics.
    public init(
        address: ServerAddress,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        allowIPv4MappedIPv6: Bool = false,
        accessResolver: @escaping @Sendable (String) -> AccessLevel = TCPTransport.defaultAccessResolver,
        logger: Logger? = nil
    ) {
        self.address = address
        self.eventLoopGroup = eventLoopGroup
        self.allowIPv4MappedIPv6 = allowIPv4MappedIPv6
        self.accessResolver = accessResolver
        self.logger = logger
    }

    /// Starts the transport and begins listening for connections.
    ///
    /// - Parameter handler: The message handler to invoke for incoming requests.
    ///   The handler receives raw JSON-RPC data and caller information, and
    ///   returns optional response data.
    public func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws {
        isRunning = true

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [accessResolver, handler, logger] channel in
                let remoteAddress = channel.remoteAddress?.description ?? "unknown"
                let accessLevel = accessResolver(remoteAddress)
                let caller = MCPCallerInfo(sourceAddress: remoteAddress, accessLevel: accessLevel)
                return channel.pipeline.addHandler(
                    MCPMessageHandler(handler: handler, caller: caller, logger: logger)
                )
            }
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Configure dual-stack support
        let bootstrapWithOptions: ServerBootstrap
        if allowIPv4MappedIPv6 {
            #if os(Linux)
            bootstrapWithOptions = bootstrap.serverChannelOption(
                ChannelOptions.socketOption(.ipv6_v6only), value: 0
            )
            #else
            bootstrapWithOptions = bootstrap
            #endif
        } else {
            bootstrapWithOptions = bootstrap
        }

        let channel: Channel
        switch address.value {
        case .hostname(let host, let port):
            channel = try await bootstrapWithOptions.bind(
                host: host,
                port: port
            ).get()

        case .unixDomainSocket(let path):
            // Remove existing socket file if present
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            channel = try await bootstrapWithOptions.bind(
                unixDomainSocketPath: path
            ).get()
        }

        self.channel = channel
        self.boundAddress = channel.localAddress

        // Wait for the channel to close (server shutdown)
        try await channel.closeFuture.get()
    }

    /// Stops the transport and closes the listening channel.
    public func stop() async throws {
        isRunning = false
        try await channel?.close(mode: .all)
        channel = nil
        boundAddress = nil
    }
}

// MARK: - ByteBuffer Helpers

extension ByteBuffer {
    /// Returns the number of readable bytes up to and including the first
    /// newline character (0x0A), or `nil` if no newline is found.
    fileprivate func readableBytesOfNewline() -> Int? {
        let readable = self.withUnsafeReadableBytes { ptr in
            ptr.firstIndex(of: 0x0A)
        }
        return readable
    }
}
