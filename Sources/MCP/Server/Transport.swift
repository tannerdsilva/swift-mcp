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
import QuickJSON
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - MCPTransport Protocol

/// A transport layer for MCP communication.
///
/// MCP supports two transport modes:
/// - **stdio**: JSON-RPC messages over standard input/output (for CLI-based MCP servers)
/// - **HTTP+SSE**: Server-Sent Events for server-to-client, HTTP POST for client-to-server
///
/// The ``MCPTransport`` protocol abstracts the communication channel so that
/// the server can work with any transport implementation. The default
/// implementation is ``StdioTransport``.
public protocol MCPTransport: Sendable {
    /// Start the transport and begin processing messages.
    ///
    /// - Parameter handler: The message handler to invoke for incoming requests.
    ///   The handler receives raw JSON-RPC bytes and caller information, and
    ///   returns optional response bytes. Return `nil` for notifications that
    ///   do not require a response.
    func start(handler: @Sendable @escaping ([UInt8], MCPCallerInfo) async throws -> [UInt8]?) async throws

    /// Stop the transport.
    ///
    /// This method should cause `start(handler:)` to return. After calling
    /// `stop()`, the transport should no longer invoke the handler.
    func stop() async throws
}

// MARK: - Stdio Transport

/// A transport that reads JSON-RPC messages from stdin and writes to stdout.
///
/// This is the standard transport for MCP servers that are launched as
/// subprocesses by MCP clients (e.g., Claude Desktop, VS Code extensions).
/// Messages are newline-delimited JSON: each line is a complete JSON-RPC
/// message, and responses are written as a single line to stdout.
///
/// ## Message Format
///
/// ```json
/// {"jsonrpc":"2.0","id":1,"method":"tools/list"}
/// {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
/// ```
///
/// Each message must be terminated by a newline character (`0x0A`). The
/// transport reads one line at a time, processes it, and writes the response
/// followed by a newline.
///
/// The transport runs on the shared NIO framing pipeline (`MCPFrameCodec`):
/// the standard streams (or injected test handles) are duplicated and bound
/// to a `NIOPipeBootstrap` pipe channel, so framing, the size cap, EOF, and
/// shutdown are the same machinery every other carrier uses — event-driven,
/// no polling. Client EOF on stdin deactivates the channel and ends
/// `start(handler:)`; `stop()` closes the channel to the same effect.
///
/// - Warning: This class uses `@unchecked Sendable` because `channel` and
///   `stopRequested` are mutated from `start(handler:)` and `stop()` — which
///   graceful shutdown deliberately overlaps. All access is serialized through
///   `stateLock`; a `stop()` that lands before the channel exists records
///   `stopRequested` so the fresh channel is closed the moment it appears.
public final class StdioTransport: MCPTransport, @unchecked Sendable {

    private let logger: Logger?
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let eventLoopGroup: EventLoopGroup
    /// The maximum size of a single newline-delimited JSON-RPC message.
    ///
    /// A frame larger than this is rejected and the connection is closed,
    /// bounding per-connection memory on the stdio transport.
    public static let defaultMaxMessageSize: Int = 10 * 1024 * 1024
    private let maxMessageSize: Int
    /// The pre-encoded `-32700 Message too large` error frame handed to the
    /// shared frame codec.
    private let oversizeErrorFrame: [UInt8]
    /// Guards `channel` and `stopRequested`.
    private let stateLock = Mutex<()>(())
    private var channel: Channel?
    /// Set by `stop()` so a stop that lands before the channel is bound is
    /// honored once the channel exists.
    private var stopRequested = false

    /// Creates a new stdio transport.
    ///
    /// The transport uses `FileHandle.standardInput` for reading and
    /// `FileHandle.standardOutput` for writing.
    ///
    /// - Parameters:
    ///   - logger: An optional logger for transport-level diagnostics.
    ///   - maxMessageSize: The maximum size in bytes of a single
    ///     newline-delimited JSON-RPC message. Defaults to
    ///     `defaultMaxMessageSize`.
    public init(logger: Logger? = nil, maxMessageSize: Int = StdioTransport.defaultMaxMessageSize) {
        self.logger = logger
        self.maxMessageSize = maxMessageSize
        self.inputHandle = FileHandle.standardInput
        self.outputHandle = FileHandle.standardOutput
        self.eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        self.oversizeErrorFrame =
            (try? QuickJSON.encode(JSONRPCErrorResponse(id: .null, code: -32700, message: "Message too large"))) ?? []
    }

    /// Creates a stdio transport bound to explicit input/output handles.
    ///
    /// Intended for in-process testing: injecting a pipe's read end as input
    /// and a pipe's write end as output lets EOF, shutdown, and message
    /// handling be exercised without a subprocess.
    init(input: FileHandle, output: FileHandle, logger: Logger? = nil, maxMessageSize: Int = StdioTransport.defaultMaxMessageSize) {
        self.logger = logger
        self.maxMessageSize = maxMessageSize
        self.inputHandle = input
        self.outputHandle = output
        self.eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        self.oversizeErrorFrame =
            (try? QuickJSON.encode(JSONRPCErrorResponse(id: .null, code: -32700, message: "Message too large"))) ?? []
    }

    /// Starts the transport and begins reading from stdin.
    ///
    /// Standard input and output are duplicated first: NIO's pipe channel
    /// takes ownership of the descriptors it is handed and closes them when
    /// the channel closes, so the real std streams — or any injected test
    /// handles — are never touched by the transport.
    ///
    /// Frames are processed by the shared `MCPMessageHandler` in the order
    /// received. `start(handler:)` returns when the client closes stdin (EOF
    /// deactivates the channel) or `stop()` closes the channel.
    ///
    /// - Parameter handler: The message handler to invoke for incoming requests.
    public func start(handler: @Sendable @escaping ([UInt8], MCPCallerInfo) async throws -> [UInt8]?) async throws {
        // Ignore SIGPIPE so we don't crash if the client disconnects
        #if canImport(Darwin)
        _ = signal(SIGPIPE, SIG_IGN)
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif

        // NIO's pipe channel takes ownership of the descriptors it is handed,
        // so the standard streams — or any injected test handles — are
        // duplicated first. The transport never touches the originals; NIO
        // closes the copies when the channel closes.
        let stdinDescriptor = dup(inputHandle.fileDescriptor)
        guard stdinDescriptor >= 0 else {
            throw MCPError.transportError("stdio: unable to duplicate stdin descriptor (\(String(cString: strerror(errno))))")
        }
        let stdoutDescriptor = dup(outputHandle.fileDescriptor)
        guard stdoutDescriptor >= 0 else {
            close(stdinDescriptor)
            throw MCPError.transportError("stdio: unable to duplicate stdout descriptor (\(String(cString: strerror(errno))))")
        }

        // The caller identity a spawned server applies. A harness may inject an
        // access level and identity over the environment (see
        // `SubprocessClientTransport.Configuration.trustLevel` /
        // `callerIdentity`): the child's server then applies the same access
        // gates a networked caller would. Absent the variables, a stdio caller
        // is `.root` as before.
        let accessLevel = Self.environmentCallerAccessLevel()
        let callerIdentity = Self.environmentString("MCP_CALLER_IDENT")
        let caller = MCPCallerInfo(
            sourceAddress: callerIdentity.map { "stdio:\($0)" } ?? "stdio",
            accessLevel: accessLevel
        )

        let bootstrap = NIOPipeBootstrap(group: eventLoopGroup)
            // a client EOF on stdin half-closes the channel instead of killing
            // the output side: the handler drains pending responses, then
            // closes. without this the EOF close races in-flight replies.
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            // demand-driven reads: MCPMessageHandler arms/re-arms reads as its
            // queue drains, bounding buffered memory under a flooding client.
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { [logger, maxMessageSize, oversizeErrorFrame] channel in
                channel.pipeline.addHandlers(
                    MCPFrameCodec(maxMessageSize: maxMessageSize, oversizeErrorFrame: oversizeErrorFrame),
                    MCPMessageHandler(handler: handler, caller: caller, logger: logger, closeOnInputClosed: true)
                )
            }

        let channel: Channel
        do {
            channel = try await bootstrap
                .takingOwnershipOfDescriptors(input: stdinDescriptor, output: stdoutDescriptor)
                .get()
        } catch {
            // NIO returned a failed future: we still own the descriptors.
            close(stdinDescriptor)
            close(stdoutDescriptor)
            throw error
        }

        // Publish the channel under the lock. If stop() raced ahead and
        // observed no channel yet (the pre-bind window), it recorded
        // stopRequested — close the fresh channel here so start() returns
        // instead of blocking on the close future forever.
        let stopWhileBinding: Bool = stateLock.withLock { _ in
            self.channel = channel
            return stopRequested
        }

        if stopWhileBinding {
            logger?.info("stop() arrived during bind; closing stdio channel immediately")
            try await channel.close(mode: .all)
        } else {
            // Wait for the channel to close: client EOF on stdin (channel
            // inactive on read EOF) or stop().
            try await channel.closeFuture.get()
        }

        stateLock.withLock { _ in
            self.channel = nil
        }
    }

    /// Stops the transport and closes the pipe channel.
    ///
    /// Closing the channel makes `start(handler:)` return. If the channel has
    /// not been bound yet, the stop is recorded and applied the moment the
    /// channel appears, so `start(handler:)` never deadlocks on a stop that
    /// arrived during startup.
    public func stop() async throws {
        let activeChannel: Channel? = stateLock.withLock { _ in
            stopRequested = true
            return channel
        }
        try await activeChannel?.close(mode: .all)
    }
}

// MARK: - Environment-driven caller identity

extension StdioTransport {
    /// The harness-injected caller access level (`MCP_ACCESS_LEVEL`, the raw
    /// `AccessLevel` integer), defaulting to `.root`.
    ///
    /// Set by `SubprocessClientTransport` from `Configuration.trustLevel`
    /// when it spawns the child, so a plugin server applies the same access
    /// gates a networked caller would.
    static func environmentCallerAccessLevel() -> AccessLevel {
        guard let raw = Self.environmentString("MCP_ACCESS_LEVEL"), let value = Int(raw) else {
            return .root
        }
        return AccessLevel(rawValue: value) ?? .root
    }

    /// Reads an environment variable, or `nil` when absent or empty.
    static func environmentString(_ name: String) -> String? {
        guard let pointer = name.withCString({ getenv($0) }) else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }
}
