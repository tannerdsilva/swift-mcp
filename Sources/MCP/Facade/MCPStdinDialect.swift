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

import QuickJSON

/// A stdin wire dialect for one-shot tool binaries.
///
/// A dialect is a **pure byte transcoder**: it recognizes a harness frame,
/// rewrites it to a JSON-RPC frame for the one shared `MCPMessageRouter`, and
/// rewrites the router's response back to the harness envelope. No dialect may
/// interpret call semantics — routing, access gates, error mapping, and schema
/// generation all stay in the router, so the facade and the server cannot
/// drift.
///
/// ## Contract
///
/// - `recognizes` classifies a raw frame without side effects. The host tries
///   the configured dialects in order on the first frame and pins the match.
/// - `route` converts a harness frame to JSON-RPC bytes. The JSON-RPC identity
///   dialect passes every frame through unchanged (the router owns
///   classification); envelope dialects throw ``MCPStdinDialectError`` when a
///   frame cannot be represented as a request.
/// - `respond` converts response bytes back to the harness envelope, or to
///   `nil` when the response must be suppressed (notifications).
/// - `completesAfterFirstRequest` tells the host whether one attempt completes
///   the invocation: harnesses that spawn one process per call may keep stdin
///   open, so a completing dialect must finish after its response without
///   waiting for EOF.
public protocol MCPStdinDialect: Sendable {
    /// The dialect's name, used in diagnostics and manifest metadata.
    static var dialectName: String { get }

    /// Whether `frame` is shaped like this dialect's envelope.
    ///
    /// Pure classification: no side effects, no interpretation. A frame that
    /// parses as a JSON object carrying a `jsonrpc` key — or as a JSON array
    /// (a batch) — is JSON-RPC; an object carrying `tool`/`args` is the plugin
    /// envelope; anything else belongs to neither.
    static func recognizes(_ frame: [UInt8]) -> Bool

    /// Whether one request completes the invocation.
    ///
    /// `true` for harness dialects whose callers spawn one process per call
    /// and may hold stdin open: after the response is written the host stops
    /// reading and finishes, so the caller can never hang. `false` keeps the
    /// session contract — read until EOF.
    static var completesAfterFirstRequest: Bool { get }

    /// Transcodes a harness frame into a JSON-RPC frame for the router.
    ///
    /// - Throws: ``MCPStdinDialectError`` when the frame cannot be represented
    ///   as a JSON-RPC request. The JSON-RPC identity dialect never throws.
    func route(_ frame: [UInt8]) throws -> [UInt8]

    /// Transcodes a JSON-RPC response back into this dialect's envelope.
    ///
    /// - Parameters:
    ///   - response: The router's response bytes, or `nil` when the frame
    ///     produced no response (a notification).
    ///   - frame: The original harness frame, for context.
    /// - Returns: The harness-visible bytes, or `nil` to suppress output.
    /// - Throws: ``MCPStdinDialectError`` when the response cannot be
    ///   represented in the envelope.
    func respond(_ response: [UInt8]?, to frame: [UInt8]) throws -> [UInt8]?
}

/// A transcode fault in a stdin dialect.
///
/// Thrown by ``MCPStdinDialect/route(_:)`` and
/// ``MCPStdinDialect/respond(_:to:)`` when a frame or response cannot be
/// represented in the dialect's envelope. The host surfaces these as a
/// diagnostic on stderr and an exit code of `1` — never as stdout output,
/// because the harness reads stdout as the result channel.
public enum MCPStdinDialectError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The frame does not decode as this dialect's request envelope.
    case malformedFrame(String)
    /// The JSON-RPC response cannot be represented in this dialect's envelope.
    case unrepresentableResponse(String)

    public var description: String {
        switch self {
        case .malformedFrame(let detail):
            "malformed frame: \(detail)"
        case .unrepresentableResponse(let detail):
            "unrepresentable response: \(detail)"
        }
    }
}

/// The JSON-RPC identity dialect: the engine's native wire, unchanged.
///
/// This is the no-op transcoder. `route` is byte-identity — every frame,
/// including malformed bytes, reaches the router exactly as received, so the
/// one-shot facade answers precisely what a session server would (parse
/// errors, invalid requests, method-not-found included). `respond` passes
/// responses through unchanged and maps a `nil` response (a notification) to
/// no output.
///
/// Detection: a JSON object carrying a `jsonrpc` key, or a JSON array (a
/// batch). A frame that parses but is neither — for example an object without
/// `jsonrpc` — is *not* recognized as JSON-RPC; if no other dialect claims it,
/// the host reports "no dialect recognized" on stderr and exits `1`.
///
/// The EOF contract is retained: JSON-RPC sessions read until stdin closes.
public struct MCPJSONRPCDialect: MCPStdinDialect {
    public static let dialectName = "jsonrpc"

    /// `false` — a JSON-RPC session reads frames until EOF.
    public static let completesAfterFirstRequest = false

    /// Creates the identity dialect.
    public init() {}

    public static func recognizes(_ frame: [UInt8]) -> Bool {
        // Object envelope with a `jsonrpc` key.
        if let envelope = try? QuickJSON.decode([String: AnyCodable].self, from: frame) {
            return envelope["jsonrpc"] != nil
        }
        // Batch: a top-level array. Element shape is the router's business.
        if (try? QuickJSON.decode([AnyCodable].self, from: frame)) != nil {
            return true
        }
        return false
    }

    public func route(_ frame: [UInt8]) throws -> [UInt8] {
        // Identity, deliberately: the router classifies every byte (parse
        // error, invalid request, method not found), so facade and server
        // answer alike.
        frame
    }

    public func respond(_ response: [UInt8]?, to frame: [UInt8]) throws -> [UInt8]? {
        // Identity; `nil` (notification) stays suppressed.
        response
    }
}