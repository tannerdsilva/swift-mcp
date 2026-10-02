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

/// The plugin envelope dialect: `{"tool":"<name>","args":{…}}` in,
/// `{"result":"…"}` out — one request completes the process.
///
/// This is the harness envelope (the shape agent hosts use to call one-shot
/// tool binaries): a single JSON object naming a tool and its arguments.
/// `route` synthesizes the matching JSON-RPC `tools/call` request for the one
/// shared router; `respond` flattens the router's reply back into a single
/// `result` string, because the harness contract has no error envelope —
/// failures arrive as text with an `Error: ` prefix and are never distinguishable
/// from success by exit code.
///
/// ## Completion
///
/// `completesAfterFirstRequest == true`: harnesses spawn one process per call
/// and may hold stdin open while reading stdout, so the host finishes after
/// writing the first response instead of waiting for EOF. The synthesized
/// request uses a fixed id because the process serves exactly one plugin
/// request — there is nothing for the id to collide with.
///
/// ## Error mapping
///
/// | router output | harness output |
/// |---|---|
/// | `result` with text content, `isError: false` | `{"result":"<text>"}` |
/// | `result` with text content, `isError: true` | `{"result":"Error: <text>"}` |
/// | JSON-RPC `error` object (parse, access, unknown tool, …) | `{"result":"Error: <message>"}` |
///
/// A frame that does not decode as the envelope, or lacks a string `tool`,
/// throws ``MCPStdinDialectError/malformedFrame(_:)``; the host reports it on
/// stderr and exits `1`.
public struct MCPPluginDialect: MCPStdinDialect {
    public static let dialectName = "plugin"

    /// `true` — one request completes the invocation.
    public static let completesAfterFirstRequest = true

    /// The request id for the synthesized `tools/call`.
    ///
    /// Fixed by design: the plugin process serves exactly one request, so a
    /// counter would only add state without adding safety.
    private static let requestID: JSONRPCID = .int(1)

    /// Creates the plugin envelope dialect.
    public init() {}

    public static func recognizes(_ frame: [UInt8]) -> Bool {
        guard let envelope = try? QuickJSON.decode([String: AnyCodable].self, from: frame) else {
            return false
        }
        return envelope["tool"] != nil
    }

    public func route(_ frame: [UInt8]) throws -> [UInt8] {
        guard let envelope = try? QuickJSON.decode([String: AnyCodable].self, from: frame) else {
            throw MCPStdinDialectError.malformedFrame("not a JSON object")
        }
        guard let toolName = envelope["tool"]?.value as? String, !toolName.isEmpty else {
            throw MCPStdinDialectError.malformedFrame("missing or empty \"tool\" name")
        }

        var arguments: [String: Any] = [:]
        if let argsValue = envelope["args"] {
            guard let argsObject = argsValue.value as? [String: Any] else {
                throw MCPStdinDialectError.malformedFrame("\"args\" must be a JSON object")
            }
            arguments = argsObject
        }

        let request = JSONRPCRequest(
            id: Self.requestID,
            method: "tools/call",
            params: [
                "name": AnyCodable(toolName),
                "arguments": AnyCodable(arguments),
            ]
        )
        do {
            return try QuickJSON.encode(request)
        } catch {
            throw MCPStdinDialectError.malformedFrame("failed to encode tools/call request: \(error)")
        }
    }

    public func respond(_ response: [UInt8]?, to frame: [UInt8]) throws -> [UInt8]? {
        guard let response else { return nil }
        guard let envelope = try? QuickJSON.decode([String: AnyCodable].self, from: response) else {
            throw MCPStdinDialectError.unrepresentableResponse("response is not a JSON object")
        }

        let text: String
        if let errorValue = envelope["error"] {
            guard let errorObject = errorValue.value as? [String: Any],
                  let message = errorObject["message"] as? String
            else {
                throw MCPStdinDialectError.unrepresentableResponse("error object without a message")
            }
            text = "Error: \(message)"
        } else if let resultValue = envelope["result"] {
            guard let resultBytes = try? QuickJSON.encode(resultValue),
                  let toolResult = try? QuickJSON.decode(MCPToolResult.self, from: resultBytes)
            else {
                throw MCPStdinDialectError.unrepresentableResponse("result is not a tool-result payload")
            }
            text = Self.harnessText(from: toolResult)
        } else {
            throw MCPStdinDialectError.unrepresentableResponse("neither \"result\" nor \"error\" present")
        }

        do {
            return try QuickJSON.encode(["result": AnyCodable(text)])
        } catch {
            throw MCPStdinDialectError.unrepresentableResponse("failed to encode result: \(error)")
        }
    }

    /// Flattens a tool result into the harness's single-text shape.
    ///
    /// Mirrors `MCPToolResult.flattenedText`'s block summarization (text
    /// concatenated newline-separated; non-text blocks summarized by kind so
    /// nothing is silently dropped), with the plugin convention's capitalized
    /// `Error: ` prefix for failed invocations.
    private static func harnessText(from result: MCPToolResult) -> String {
        var parts: [String] = []
        for block in result.content {
            switch block {
            case .text(let text):
                parts.append(text)
            case .image:
                parts.append("[image content]")
            case .resource(let uri, _, _):
                parts.append("[resource: \(uri)]")
            }
        }
        let text = parts.joined(separator: "\n")
        return result.isError ? "Error: \(text)" : text
    }
}