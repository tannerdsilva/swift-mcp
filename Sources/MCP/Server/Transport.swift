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
import QuickJSON

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

// MARK: - Message Handler Actor

/// An actor that serializes message handling for a transport.
///
/// This provides:
/// - **Backpressure**: Only one message is processed at a time per actor instance.
/// - **Ordering**: Responses are written in the same order requests are received.
/// - **Cancellation**: A cancelled actor stops processing new messages.
actor TransportMessageHandler {
    private let handler: @Sendable ([UInt8], MCPCallerInfo) async throws -> [UInt8]?
    private let caller: MCPCallerInfo
    private let write: @Sendable ([UInt8]) throws -> Void
    private let makeError: @Sendable ([UInt8], Error) -> [UInt8]?
    private var isCancelled = false

    public init(
        handler: @escaping @Sendable ([UInt8], MCPCallerInfo) async throws -> [UInt8]?,
        caller: MCPCallerInfo,
        write: @escaping @Sendable ([UInt8]) throws -> Void,
        makeError: @escaping @Sendable ([UInt8], Error) -> [UInt8]?
    ) {
        self.handler = handler
        self.caller = caller
        self.write = write
        self.makeError = makeError
    }

    /// Cancel further message processing.
    public func cancel() {
        isCancelled = true
    }

    /// Process a single message. Returns immediately without processing if cancelled.
    public func process(_ data: [UInt8]) async {
        guard !isCancelled else { return }
        do {
            if let response = try await handler(data, caller) {
                try write(response)
            }
        } catch {
            if let errorData = makeError(data, error) {
                try? write(errorData)
            }
        }
    }
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
/// The read loop is poll-based with a short timeout, so it is interruptible:
/// `stop()`-initiated shutdown is observed within one poll interval, and a
/// clean client EOF ends the read loop gracefully instead of trapping.
///
/// - Warning: This class uses `@unchecked Sendable` because the `isRunning`
///   flag is mutated from the read loop and from `stop()`. These are called
///   from different tasks but the flag is only written with simple non-
///   conflicting access patterns. The `messageHandler` actor provides
///   serialized access to message processing.
public final class StdioTransport: MCPTransport, @unchecked Sendable {

    private var isRunning = false
    private var messageHandler: TransportMessageHandler?
    private let logger: Logger?
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    /// The maximum size of a single newline-delimited JSON-RPC message.
    ///
    /// A frame larger than this is rejected and the connection is closed,
    /// bounding per-connection memory on the stdio transport.
    public static let defaultMaxMessageSize: Int = 10 * 1024 * 1024
    private let maxMessageSize: Int

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
    }

    /// Starts the transport and begins reading from stdin.
    ///
    /// This method reads newline-delimited JSON from stdin using an internal
    /// buffer. For each complete message, it dispatches to the message handler
    /// actor for serialized processing. The loop exits when stdin reaches EOF,
    /// raises a poll/read error, or `stop()` is called.
    ///
    /// - Parameter handler: The message handler to invoke for incoming requests.
    public func start(handler: @Sendable @escaping ([UInt8], MCPCallerInfo) async throws -> [UInt8]?) async throws {
        isRunning = true

        let stdin = inputHandle
        let stdout = outputHandle
        let caller = MCPCallerInfo(sourceAddress: "stdio", accessLevel: .root)

        // Ignore SIGPIPE so we don't crash if the client disconnects
        #if canImport(Darwin)
        _ = signal(SIGPIPE, SIG_IGN)
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif

        let handlerActor = TransportMessageHandler(
            handler: handler,
            caller: caller,
            write: { bytes in
                var output = bytes
                output.append(0x0A) // Append newline
                try writeRaw(output, to: stdout.fileDescriptor)
            },
            makeError: { [logger] requestBytes, error in
                guard let request = try? QuickJSON.decode(JSONRPCRequest.self, from: requestBytes) else {
                    // Without an id there is no frame to reply to.
                    return nil
                }
                do {
                    let response = JSONRPCErrorResponse(
                        id: request.id,
                        code: -32603,
                        message: "Internal error: \(readableErrorDescription(error))"
                    )
                    return try QuickJSON.encode(response)
                } catch {
                    // A fixed-shape error frame cannot realistically fail to encode.
                    logger?.warning("Failed to encode stdio error response: \(error)")
                    return nil
                }
            }
        )
        self.messageHandler = handlerActor

        // Read in chunks, scanning for newlines
        let chunkSize = 4096
        let pollInterval: Int32 = 250
        var buffer: [UInt8] = []

        pollLoop: while isRunning {
            switch pollStdin(timeoutMilliseconds: pollInterval, fileDescriptor: stdin.fileDescriptor) {
            case .timeout:
                continue

            case .readable:
                let chunk: [UInt8]
                do {
                    chunk = try readAvailableBytes(fileDescriptor: stdin.fileDescriptor, maxBytes: chunkSize)
                } catch {
                    logger?.warning("stdio read failed: \(error)")
                    break pollLoop
                }

                guard !chunk.isEmpty else {
                    // EOF — the client closed the pipe. This ends the session
                    // cleanly; the enclosing service group applies its success
                    // termination behavior.
                    logger?.info("stdio client closed the connection")
                    break pollLoop
                }

                buffer.append(contentsOf: chunk)

                // Process all complete lines in the buffer
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]
                    buffer = Array(buffer[newlineIndex.advanced(by: 1)...])

                    guard isRunning else { break }

                    let message = Array(lineData)
                    await handlerActor.process(message)
                }

                // A leftover partial frame larger than the cap is a single
                // unbounded message. Reject it and end the loop so memory
                // stays bounded no matter what the peer streams.
                guard buffer.count <= maxMessageSize else {
                    logger?.warning("stdio message exceeds maximum size (\(maxMessageSize) bytes); closing connection")
                    if let errorData = try? QuickJSON.encode(
                        JSONRPCErrorResponse(id: .null, code: -32700, message: "Message too large")
                    ) {
                        var output = errorData
                        output.append(0x0A)
                        try? writeRaw(output, to: stdout.fileDescriptor)
                    }
                    break pollLoop
                }

            case .closed:
                logger?.info("stdio closed by peer")
                break pollLoop

            case .pollError(let message):
                logger?.warning("\(message)")
                break pollLoop
            }
        }

        await handlerActor.cancel()
        self.messageHandler = nil
    }

    /// Stops the transport.
    ///
    /// Sets the running flag to `false`, which causes the poll-based read loop
    /// in `start(handler:)` to exit within one poll interval.
    public func stop() async throws {
        isRunning = false
        await messageHandler?.cancel()
    }
}

// MARK: - Interruptible stdin polling

/// The outcome of a single stdin poll.
private enum StdinPollEvent {
    /// No input was available within the poll timeout.
    case timeout
    /// Input is available to read.
    case readable
    /// The peer closed the stream (HUP/ERR/NVAL).
    case closed
    /// The poll syscall itself failed.
    case pollError(String)
}

/// Polls stdin for readability with a bounded timeout.
///
/// Unlike a blocking `read`, this lets the read loop observe `isRunning` and
/// task cancellation between polls, so shutdown is prompt even while the peer
/// is silent.
private func pollStdin(timeoutMilliseconds: Int32, fileDescriptor: Int32) -> StdinPollEvent {
    var pollFds = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
    let result = poll(&pollFds, 1, timeoutMilliseconds)

    if result < 0 {
        let errorNumber = errno
        if errorNumber == EINTR {
            return .timeout
        }
        return .pollError("stdio poll failed: \(String(cString: strerror(errorNumber)))")
    }

    if result == 0 {
        return .timeout
    }

    let events = pollFds.revents
    if events & Int16(POLLIN) != 0 {
        return .readable
    }
    if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
        return .closed
    }
    return .timeout
}

/// Reads up to `maxBytes` bytes that are currently available on the fd.
///
/// This is a single raw `read(2)`. It must not be replaced with
/// `FileHandle.read(upToCount:)`: on macOS that method loops until the
/// requested count is satisfied or EOF, so after a short request the read
/// blocks waiting for a full buffer — while the client, having sent its
/// request, waits for the reply with its write end still open. That is a
/// deadlock. A poll-driven loop calls this only after `POLLIN`, so one read
/// returns the available chunk immediately. Returns an empty array at EOF.
private func readAvailableBytes(fileDescriptor fd: Int32, maxBytes: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: maxBytes)
    let count = bytes.withUnsafeMutableBytes { buffer in
        read(fd, buffer.baseAddress, buffer.count)
    }
    if count < 0 {
        throw MCPError.transportError("stdio read failed: \(String(cString: strerror(errno)))")
    }
    return Array(bytes[0..<max(0, count)])
}

/// Writes the given bytes to the fd, looping over short writes.
///
/// Uses raw `write(2)` so no Foundation byte container or `FileHandle` write
/// path is involved.
private func writeRaw(_ bytes: [UInt8], to fd: Int32) throws {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw in
            write(fd, raw.baseAddress?.advanced(by: offset), bytes.count - offset)
        }
        if written < 0 {
            throw MCPError.transportError("stdio write failed: \(String(cString: strerror(errno)))")
        }
        if written == 0 {
            throw MCPError.transportError("stdio write failed: connection closed")
        }
        offset += written
    }
}
