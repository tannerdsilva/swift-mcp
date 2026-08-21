//===----------------------------------------------------------------------===//
//
// This source file is part of the MCP open source project
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import Foundation

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
    ///   The handler receives raw JSON-RPC data and caller information, and
    ///   returns optional response data. Return `nil` for notifications that
    ///   do not require a response.
    func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws

    /// Stop the transport.
    ///
    /// This method should cause ``start(handler:)`` to return. After calling
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
    private let handler: @Sendable (Data, MCPCallerInfo) async throws -> Data?
    private let caller: MCPCallerInfo
    private let write: @Sendable (Data) throws -> Void
    private let makeError: @Sendable (Data, Error) -> Data?
    private var isCancelled = false

    public init(
        handler: @escaping @Sendable (Data, MCPCallerInfo) async throws -> Data?,
        caller: MCPCallerInfo,
        write: @escaping @Sendable (Data) throws -> Void,
        makeError: @escaping @Sendable (Data, Error) -> Data?
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
    public func process(_ data: Data) async {
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
/// - Warning: This class uses ``@unchecked Sendable`` because the `isRunning`
///   flag is mutated from the read loop and from ``stop()``. These are called
///   from different tasks but the flag is only written with simple non-
///   conflicting access patterns. The `messageHandler` actor provides
///   serialized access to message processing.
public final class StdioTransport: MCPTransport, @unchecked Sendable {

    private var isRunning = false
    private var messageHandler: TransportMessageHandler?

    /// Creates a new stdio transport.
    ///
    /// The transport uses `FileHandle.standardInput` for reading and
    /// `FileHandle.standardOutput` for writing.
    public init() {}

    /// Starts the transport and begins reading from stdin.
    ///
    /// This method reads newline-delimited JSON from stdin using an internal
    /// buffer. For each complete message, it dispatches to the message handler
    /// actor for serialized processing. The loop exits when stdin reaches EOF
    /// or ``stop()`` is called.
    ///
    /// - Parameter handler: The message handler to invoke for incoming requests.
    public func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws {
        isRunning = true

        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
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
            write: { data in
                var output = data
                output.append(0x0A) // Append newline
                try stdout.write(contentsOf: output)
            },
            makeError: { requestData, error in
                guard let requestJSON = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                      let id = requestJSON["id"] else {
                    return nil
                }
                let errorResponse: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": [
                        "code": -32603,
                        "message": "Internal error: \(error.localizedDescription)"
                    ]
                ]
                return try? JSONSerialization.data(withJSONObject: errorResponse)
            }
        )
        self.messageHandler = handlerActor

        // Read in chunks, scanning for newlines
        let chunkSize = 4096
        var buffer = Data()

        while isRunning {
            let chunk: Data
            do {
                chunk = try stdin.read(upToCount: chunkSize) ?? Data()
            } catch {
                isRunning = false
                break
            }

            guard !chunk.isEmpty else {
                // EOF
                isRunning = false
                break
            }

            buffer.append(chunk)

            // Process all complete lines in the buffer
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer = buffer[newlineIndex.advanced(by: 1)...]

                guard isRunning else { break }

                let message = Data(lineData)
                await handlerActor.process(message)
            }
        }

        await handlerActor.cancel()
        self.messageHandler = nil
    }

    /// Stops the transport.
    ///
    /// Sets the running flag to `false`, which causes the read loop in
    /// ``start(handler:)`` to exit on the next iteration.
    public func stop() async throws {
        isRunning = false
        await messageHandler?.cancel()
    }
}
