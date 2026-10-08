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
import MCP

// MARK: - A structured return

/// A tool that answers with a structure rather than a sentence: the caller
/// decodes it instead of parsing prose back out of a string.
struct TextStats: Codable, Sendable, Equatable {
    let characters: Int
    let words: Int
    let lines: Int
}

/// The pack's one failure mode: input that is not the document the tool
/// promised to read.
///
/// A tool's failure is a *result*, not an exit code — the harness sees it as
/// `{"result":"Error: …"}` and the process still exits 0, because the tool
/// answered.
struct PackInputError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Re-encodes a JSON document, so pretty and minified share one parser and one
/// error message.
///
/// `sortedKeys` makes the output deterministic (the test can assert bytes);
/// without it, key order would follow the input and vary.
private func reformatJSON(_ text: String, options: JSONSerialization.WritingOptions) throws -> String {
    let input = Data(text.utf8)
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: input)
    } catch {
        throw PackInputError(message: "not JSON: \(error)")
    }
    var merged = options
    merged.insert(.sortedKeys)
    let output = try JSONSerialization.data(withJSONObject: object, options: merged)
    return String(decoding: output, as: UTF8.self)
}

// MARK: - Text tools

@MCPCommand(description: "Echo a message back verbatim", name: "echo")
struct Echo {
    @Argument(description: "The message to echo")
    var message: String = ""

    func run() async throws -> String {
        message
    }
}

@MCPCommand(description: "Uppercase a string", name: "upper")
struct Upper {
    @Argument(description: "The text to uppercase")
    var text: String = ""

    func run() async throws -> String {
        text.uppercased()
    }
}

@MCPCommand(description: "Count the lines in a text", name: "lineCount")
struct LineCount {
    @Argument(description: "The text to measure")
    var text: String = ""

    func run() async throws -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

@MCPCommand(description: "Count the words in a text", name: "wordCount")
struct WordCount {
    @Argument(description: "The text to measure")
    var text: String = ""

    func run() async throws -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

@MCPCommand(description: "Character, word, and line counts for a text", name: "textStats")
struct TextStatsTool {
    @Argument(description: "The text to measure")
    var text: String = ""

    func run() async throws -> TextStats {
        TextStats(
            characters: text.count,
            words: text.split(whereSeparator: \.isWhitespace).count,
            lines: text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        )
    }
}

// MARK: - JSON tools

@MCPCommand(description: "Re-indent a JSON document for reading", name: "jsonPretty")
struct JSONPretty {
    @Argument(description: "A JSON document")
    var json: String = ""

    func run() async throws -> String {
        try reformatJSON(json, options: [.prettyPrinted])
    }
}

@MCPCommand(description: "Compact a JSON document", name: "jsonMinify")
struct JSONMinify {
    @Argument(description: "A JSON document")
    var json: String = ""

    func run() async throws -> String {
        try reformatJSON(json, options: [])
    }
}

// MARK: - Encoding tools

@MCPCommand(description: "Base64-encode a UTF-8 string", name: "base64Encode")
struct Base64Encode {
    @Argument(description: "The text to encode")
    var text: String = ""

    func run() async throws -> String {
        Data(text.utf8).base64EncodedString()
    }
}

@MCPCommand(description: "Decode a base64 string back to UTF-8 text", name: "base64Decode")
struct Base64Decode {
    @Argument(description: "The base64 to decode")
    var text: String = ""

    func run() async throws -> String {
        guard let data = Data(base64Encoded: text) else {
            throw PackInputError(message: "not base64: \(text.prefix(32))")
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw PackInputError(message: "base64 decoded to bytes that are not UTF-8")
        }
        return decoded
    }
}

// MARK: - Lifecycle and gated tools

@MCPCommand(description: "Answer with no payload", name: "ping")
struct Ping {
    func run() async throws {
    }
}

@MCPCommand(description: "Debug-build-only echo, absent from a release surface", name: "debugEcho")
struct DebugEcho {
    @Argument(description: "Message to echo")
    var message: String = ""

    func run() async throws -> String {
        "debug:\(message)"
    }
}

@MCPCommand(description: "Admin-gated echo, used to exercise plugin trust levels", name: "adminEcho", requiredAccess: .admin)
struct AdminEcho {
    @Argument(description: "Message to echo")
    var message: String = ""

    func run() async throws -> String {
        "admin:\(message)"
    }
}

// MARK: - The pack

/// A reference pack: twelve tools in one `interface: .oneShot` binary.
///
/// This is the fleet model — one process per *pack*, not per tool, so a harness
/// spawns a pack only when it calls into it. The twelve tools deliberately span
/// every return shape the facade supports: `Void`, `String`, `Int`, a `Codable`
/// structure, a throwing tool, a debug-only tool, and an access-gated tool.
///
/// Nothing here is a shim: `@MCPApplication(interface: .oneShot)` compiles the
/// stdin host straight into this binary, so the harness talks to the tool over
/// the plugin envelope with no interpreter in the path.
@main
@MCPApplication(
    name: "mcp-tool-pack",
    version: "1.0.0",
    description: "Reference tool pack: twelve tools in one shim-less one-shot binary",
    interface: .oneShot
)
struct MCPToolPack {
    @Tool var echo = Echo()
    @Tool var upper = Upper()
    @Tool var lineCount = LineCount()
    @Tool var wordCount = WordCount()
    @Tool var textStats = TextStatsTool()
    @Tool var jsonPretty = JSONPretty()
    @Tool var jsonMinify = JSONMinify()
    @Tool var base64Encode = Base64Encode()
    @Tool var base64Decode = Base64Decode()
    @Tool var ping = Ping()
    @Tool(available: .debug) var debugEcho = DebugEcho()
    @Tool var adminEcho = AdminEcho()
}