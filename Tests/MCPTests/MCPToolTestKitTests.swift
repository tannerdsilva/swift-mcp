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

import Testing
import Foundation
import MCPToolTestKit

/// Locates the built fixture binary through the kit's own path helper — this
/// suite tests the shipped API, so it must not reach for a private copy.
private func kitFixturePath(_ name: String = "MCPFixtureTool") throws -> String {
    try builtToolPath(named: name, relativeTo: #filePath)
}

/// Acceptance for `MCPToolTestKit` itself: a pack author depends on this
/// module, so its convenience path is exercised against a real process, not a
/// mock.
@Suite(.serialized)
struct MCPToolTestKitTests {

    @Test("pluginFrame emits exactly one newline-terminated frame carrying tool and args")
    func pluginFrameShape() throws {
        let bytes = try pluginFrame(tool: "echo", args: ["message": "hi"])

        // the trailing newline is the frame delimiter; an interior one would
        // split a single call into two frames.
        #expect(bytes.last == 0x0A)
        #expect(bytes.filter { $0 == 0x0A }.count == 1)
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"tool":"echo","args":{"message":"hi"}}"# + "\n")
    }

    @Test("pluginResult round-trips a result and rejects a line that is not an envelope")
    func pluginResultParsing() throws {
        #expect(try pluginResult(from: #"{"result":"hello"}"#) == "hello")
        // a real tool terminates its response with a newline; that is framing,
        // not part of the value.
        #expect(try pluginResult(from: #"{"result":"hello"}"# + "\n") == "hello")

        #expect(throws: ToolSpawnError.self) { try pluginResult(from: "not json") }
        #expect(throws: ToolSpawnError.self) { try pluginResult(from: "") }
        // an object without `result` is not a response frame.
        #expect(throws: ToolSpawnError.self) { try pluginResult(from: #"{"tool":"x"}"#) }
    }

    @Test("the handle convenience path drives a real tool end to end")
    func handleDrivesRealTool() async throws {
        let tool = try SpawnedTool.spawn(path: try kitFixturePath())
        try tool.writePluginFrame(tool: "echo", args: ["message": "hi"])
        tool.closeStdin()

        #expect(try await tool.waitForExit() == .code(0))
        #expect(try tool.readResult().contains("hi"))
    }

    @Test("a tool-level failure arrives as a result, and the process still exits 0")
    func failureIsAResult() async throws {
        let tool = try SpawnedTool.spawn(path: try kitFixturePath())
        try tool.writePluginFrame(tool: "fail", args: ["message": "boom"])
        tool.closeStdin()

        // the exit contract: a tool that fails still answered, so it is not an
        // error exit. The failure is the payload.
        #expect(try await tool.waitForExit() == .code(0))
        let result = try tool.readResult()
        #expect(result.lowercased().contains("error"))
        #expect(result.contains("boom"))
    }

    @Test("argument values are escaped by the codec, not hand-quoted")
    func argumentEscaping() async throws {
        let tool = try SpawnedTool.spawn(path: try kitFixturePath())
        // a quote in the value must survive as data rather than closing the
        // JSON string early and corrupting the frame.
        try tool.writePluginFrame(tool: "echo", args: ["message": #"a"b"#])
        tool.closeStdin()

        #expect(try await tool.waitForExit() == .code(0))
        #expect(try tool.readResult().contains(#"a"b"#))
    }

    @Test("builtToolPath walks up from a nested test file and reports a missing binary")
    func builtToolPathResolves() throws {
        let path = try builtToolPath(named: "MCPFixtureTool", relativeTo: #filePath)
        #expect(FileManager.default.isExecutableFile(atPath: path))

        #expect(throws: ToolSpawnError.self) {
            _ = try builtToolPath(named: "NoSuchToolZZZ", relativeTo: #filePath)
        }
    }

    @Test("ToolExit separates a normal exit code from a signal")
    func exitDecoding() {
        #expect(ToolExit.decode(0 << 8) == .code(0))
        #expect(ToolExit.decode(1 << 8) == .code(1))
        #expect(ToolExit.decode(9) == .signal(9))     // SIGKILL
        #expect(ToolExit.decode(15) == .signal(15))   // SIGTERM
        #expect(ToolExit.decode(137) == .signal(9))   // a shell's 128+signal
    }
}