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

import Synchronization

/// Errors surfaced by the client role.
///
/// Foundation-free, matching the framework's error convention: `Sendable`,
/// `Equatable`, and `CustomStringConvertible` (use `description` for readable
/// messages).
public enum MCPClientError: Error, Sendable, Equatable {
    /// The client is not in a state that permits the request (not connected,
    /// or already shut down).
    case notConnected
    /// The connection dropped (EOF) while a request was pending, or the peer
    /// closed without answering.
    case connectionClosed
    /// A request exceeded its configured deadline without a reply.
    case callTimeout
    /// The `initialize` handshake exceeded its configured deadline.
    case negotiationTimeout
    /// The server answered with a protocol version outside the supported set.
    case unsupportedProtocolVersion(String)
    /// The peer answered with a JSON-RPC error object.
    case remoteError(code: Int, message: String)
    /// A reply could not be decoded into the expected shape.
    case invalidResponse(String)
    /// The transport could not be brought up: spawn/pipe failure (subprocess)
    /// or connect failure (TCP).
    case spawnFailed(String)
    /// The TCP connection could not be established.
    case connectionFailed(String)
}

extension MCPClientError: CustomStringConvertible {
    /// A readable description of the error.
    public var description: String {
        switch self {
        case .notConnected:
            return "MCP client is not connected"
        case .connectionClosed:
            return "MCP connection closed"
        case .callTimeout:
            return "MCP call timed out"
        case .negotiationTimeout:
            return "MCP initialize handshake timed out"
        case .unsupportedProtocolVersion(let version):
            return "MCP server negotiated unsupported protocol version: \(version)"
        case .remoteError(let code, let message):
            return "MCP remote error \(code): \(message)"
        case .invalidResponse(let detail):
            return "MCP invalid response: \(detail)"
        case .spawnFailed(let detail):
            return "MCP spawn failed: \(detail)"
        case .connectionFailed(let detail):
            return "MCP connection failed: \(detail)"
        }
    }
}

/// A ``ClientTransport``-level helper that runs a body exactly once across
/// racing tasks.
///
/// Used to resolve a continuation exactly once when two independent paths (a
/// response arriving vs. a timeout reaper firing) compete for it. Task-group
/// racing for this is deliberately avoided: group-child scheduling proved
/// unreliable in strict-concurrency builds on this toolchain, while plain
/// unstructured `Task`s (the read loop, the run/ladder tasks) are consistent.
/// The winners are both unstructured tasks; exactly one passes this gate.
final class ResumeOnce: @unchecked Sendable {
    private let lock = Mutex<Bool>(false)

    func run(_ body: @escaping @Sendable () -> Void) {
        let first = lock.withLock { (resumed: inout Bool) -> Bool in
            if resumed {
                return false
            }
            resumed = true
            return true
        }
        if first {
            body()
        }
    }
}

/// A carrier for ``MCPClient`` frames.
///
/// The client is deliberately carrier-agnostic: subprocess (SwiftSlash + NIO
/// pipe channels), TCP (NIO socket), and in-process (network-free) carriers all
/// drive the same actor. A carrier owns one connection's lifecycle:
///
/// - `start()` brings the medium up (spawn the child, open the pipe channel,
///   connect the socket — or prepare the in-process surface). Idempotent.
/// - `sendFrame(_:)` writes one complete JSON-RPC frame, write-to-completion,
///   with real backpressure into the medium.
/// - `frames()` yields every frame the peer emits, until EOF or `stop()`.
/// - `stop()` terminates the connection. For the subprocess carrier this runs
///   the shutdown ladder: (cooperative `shutdown` →) EOF on the child's stdin
///   → grace → SIGTERM → SIGKILL, with the reap guaranteed on every rung.
public protocol ClientTransport: Sendable {
    /// Brings the transport up for the first time.
    ///
    /// idempotent: a second call while started is a no-op.
    func start() async throws

    /// Sends one complete newline-delimited JSON-RPC frame.
    ///
    /// must be write-to-completion: partial writes are internally looped, and
    /// requests take the flush-backed path so a slow peer is never overrun.
    ///
    /// - Parameter bytes: The frame payload (without the framing newline).
    func sendFrame(_ bytes: [UInt8]) async throws

    /// Frames emitted by the peer, in arrival order, until EOF or `stop()`.
    ///
    /// Backpressured: the carrier pauses the peer when this stream's consumer
    /// is slow; frames are never dropped.
    nonisolated func frames() -> ClientFrameSequence

    /// Whether the peer understands the best-effort `shutdown` extension.
    ///
    /// Stdio-style peers (a server that exits when its stdin hits EOF) can be
    /// asked to drain in-flight work before the change; networked/process-free
    /// carriers have no such handshake. Default `false`.
    var supportsCooperativeShutdown: Bool { get }

    /// Terminates the connection.
    ///
    /// must make `frames()` end and release the medium (for the subprocess
    /// carrier: run the shutdown ladder and reap the child).
    func stop() async throws
}

extension ClientTransport {
    /// Non-cooperative by default; the subprocess carrier opts in.
    public var supportsCooperativeShutdown: Bool { false }
}
