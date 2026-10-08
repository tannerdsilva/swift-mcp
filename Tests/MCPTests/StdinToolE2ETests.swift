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
import MCP
import MCPToolTestKit
import QuickJSON

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Fixture location

/// Locates a built fixture binary in this package.
///
/// The spawn harness itself now lives in `MCPToolTestKit`; this is the
/// package-relative path to it. `swift build` must have run first — a test
/// target does not build the executables it spawns.
private func fixtureToolPath(_ name: String = "MCPFixtureTool") throws -> String {
    try builtToolPath(named: name, relativeTo: #filePath)
}

// MARK: - The spawned binary's faces

/// End-to-end acceptance for a compiled `interface: .oneShot` binary: every
/// face of the facade, driven the way a harness drives it — a real process,
/// real pipes, real exit codes.
@Suite(.serialized)
struct StdinToolE2ETests {

    @Test("plugin frame answers with stdin held open, then the process exits 0")
    func pluginFrameCompletesWithStdinOpen() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array(#"{"tool":"echo","args":{"message":"hi"}}"#.utf8) + [0x0A])

        // stdin stays OPEN (the write end is never closed): the process must
        // still answer and exit — a stdin-holding harness cannot hang.
        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"result":"hi"}"#)
    }

    @Test("json-rpc frames are served and stdin EOF exits 0")
    func jsonrpcFrameServedAtEOF() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8) + [0x0A])
        close(tool.stdinWrite)

        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.contains("\"id\":1"))
        #expect(stdout.contains("\"echo\""))
        #expect(stdout.contains("\"admin\""))
    }

    @Test("tool-level failures are results, not exit codes")
    func toolFailureIsAResult() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array(#"{"tool":"fail","args":{"message":"boom"}}"#.utf8) + [0x0A])
        close(tool.stdinWrite)

        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"result":"Error: boom"}"#)
    }

    @Test("introspection runs without stdin: --mcp-list and --mcp-manifest arc")
    func introspectionWithoutStdin() async throws {
        let listTool = try SpawnedTool.spawn(path: try fixtureToolPath(), arguments: ["--mcp-list"])
        let listExit = try await listTool.waitForExit()
        #expect(listExit == .code(0))
        let listText = drain(fd: listTool.stdoutRead)
        let catalog = try #require((try? QuickJSON.decode(AnyCodable.self, from: Array(listText.utf8)))?.value as? [String: Any])
        #expect(catalog["name"] as? String == "mcp-fixture-tool")
        #expect((catalog["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["echo", "add", "fail", "admin"])

        let manifestTool = try SpawnedTool.spawn(path: try fixtureToolPath(), arguments: ["--mcp-manifest", "arc"])
        let manifestExit = try await manifestTool.waitForExit()
        #expect(manifestExit == .code(0))
        let manifestText = drain(fd: manifestTool.stdoutRead)
        let manifest = try #require((try? QuickJSON.decode(AnyCodable.self, from: Array(manifestText.utf8)))?.value as? [String: Any])
        #expect(manifest["name"] as? String == "mcp-fixture-tool")
        let tools = try #require(manifest["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["echo", "add", "fail", "admin"])
        #expect(tools.first?["toolset"] as? String == "mcp-fixture-tool")
        // the manifest's command is this very binary, absolutely resolved.
        #expect(tools.first?["command"] as? String == (try fixtureToolPath()))
    }

    @Test("an unrecognized first frame exits 1 with a stderr diagnostic and silent stdout")
    func malformedFirstFrameExitsOne() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array("definitely not json".utf8) + [0x0A])

        let exit = try await tool.waitForExit()
        #expect(exit == .code(1))

        let stdout = drain(fd: tool.stdoutRead, quiet: 0.1)
        #expect(stdout.isEmpty)
        let stderr = drain(fd: tool.stderrRead, quiet: 0.1)
        #expect(stderr.contains("no dialect recognized the first frame"))
    }

    @Test("the MCP_ACCESS_LEVEL environment gates dispatch in the spawned child")
    func accessLevelEnvironmentGatesDispatch() async throws {
        // public trust: the admin-gated tool must be denied — and the failure
        // is a result (exit 0), never an exit code.
        let tool = try SpawnedTool.spawn(
            path: try fixtureToolPath(),
            environment: ["MCP_ACCESS_LEVEL": "0"]
        )
        try tool.writeFrame(Array(#"{"tool":"admin","args":{"message":"hi"}}"#.utf8) + [0x0A])

        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.contains(#""Error: Access denied: admin""#))
    }

    @Test("a regular-file stdin is rejected before transport start, naming the stream")
    func regularFileStdinIsRejected() async throws {
        let inFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-preflight-stdin-\(UUID().uuidString).json").path
        try Data(#"{"tool":"echo","args":{"message":"hi"}}"#.utf8).write(to: URL(fileURLWithPath: inFile))
        defer { try? FileManager.default.removeItem(atPath: inFile) }

        // the harness shape `< file`: a perfectly valid frame, on a stream that
        // can never deliver it.
        let tool = try SpawnedTool.spawnWithFileStreams(path: try fixtureToolPath(), stdinFile: inFile)
        let exit = try await tool.waitForExit()
        #expect(exit == .code(1))

        let stdout = drain(fd: tool.stdoutRead, quiet: 0.1)
        #expect(stdout.isEmpty)
        let stderr = drain(fd: tool.stderrRead, quiet: 0.1)
        #expect(stderr.contains("stdin"))
        #expect(stderr.contains("regular file"))
        // the whole point of the preflight: not NIO's opaque transport-start
        // failure, which names neither the stream nor the cause.
        #expect(!stderr.contains("Operation unsupported"))
    }

    @Test("a regular-file stdout is rejected for transport, but --mcp-manifest may write to one")
    func regularFileStdoutShape() async throws {
        let dir = FileManager.default.temporaryDirectory

        // (a) the frame path: a redirected stdout is rejected up front, named,
        // and nothing is written into the file.
        let outFile = dir.appendingPathComponent("mcp-preflight-stdout-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: outFile) }
        let transport = try SpawnedTool.spawnWithFileStreams(path: try fixtureToolPath(), stdoutFile: outFile)
        let exit = try await transport.waitForExit()
        #expect(exit == .code(1))
        let stderr = drain(fd: transport.stderrRead, quiet: 0.1)
        #expect(stderr.contains("stdout"))
        #expect(!stderr.contains("Operation unsupported"))
        #expect((try? String(contentsOfFile: outFile, encoding: .utf8))?.isEmpty ?? true)

        // (b) the install path: introspection is answered before the preflight,
        // so `my-tool --mcp-manifest arc > manifest.json` still works.
        let manifestFile = dir.appendingPathComponent("mcp-preflight-manifest-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: manifestFile) }
        let manifest = try SpawnedTool.spawnWithFileStreams(
            path: try fixtureToolPath(),
            arguments: ["--mcp-manifest", "arc"],
            stdoutFile: manifestFile
        )
        let manifestExit = try await manifest.waitForExit()
        #expect(manifestExit == .code(0))
        let written = try String(contentsOfFile: manifestFile, encoding: .utf8)
        #expect(written.contains("\"mcp-fixture-tool\""))
    }

    @Test("/dev/null on stdin stays allowed — a char device is not a regular file")
    func characterDeviceStdinIsAllowed() async throws {
        // the preflight tests S_IFREG, not "is it a tty". /dev/null must keep
        // working, and the failure it does produce must be the host's own
        // empty-stdin contract, never the preflight.
        let tool = try SpawnedTool.spawnWithFileStreams(path: try fixtureToolPath(), stdinFile: "/dev/null")
        let exit = try await tool.waitForExit()
        #expect(exit == .code(1))

        let stderr = drain(fd: tool.stderrRead, quiet: 0.1)
        #expect(!stderr.contains("regular file"))
        #expect(stderr.contains("no request received"))
    }

    // MARK: - the two-file pack (a pack whose one-shot entry sits behind a subcommand)

    @Test("the two-file pack serves its CLI-routed entry: `<bin> plugin`")
    func twoFilePackServesSubcommandRoutedEntry() async throws {
        // the pack's one-shot entry is behind a subcommand, so the harness
        // spawns the argv the manifest advertises — `plugin` — rather than the
        // bare binary.
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath("MCPTwoFilePack"), arguments: ["plugin"])
        try tool.writeFrame(Array(#"{"tool":"greet","args":{"name":"tanner"}}"#.utf8) + [0x0A])
        close(tool.stdinWrite)

        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"result":"hello, tanner"}"#)
    }

    @Test("the two-file pack's manifest advertises the subcommand argv, not an empty one")
    func twoFilePackManifestAdvertisesSubcommandArgv() async throws {
        let binary = try fixtureToolPath("MCPTwoFilePack")
        let tool = try SpawnedTool.spawn(
            path: binary,
            arguments: ["plugin", "--mcp-manifest", "arc"]
        )
        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let text = drain(fd: tool.stdoutRead)
        let manifest = try #require((try? QuickJSON.decode(AnyCodable.self, from: Array(text.utf8)))?.value as? [String: Any])
        let tools = try #require(manifest["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["greet", "reverse"])

        // the point of `manifestInvocationArguments`: without it the emitted
        // argv is `[]`, and a harness has no way to spawn this entry.
        #expect(tools.allSatisfy { ($0["args"] as? [String]) == ["plugin"] })
        // and `command` is the real executable, resolved from argv[0].
        #expect(tools.allSatisfy { $0["command"] as? String == binary })
        #expect(tools.allSatisfy { $0["toolset"] as? String == "mcp-two-file-pack" })
    }

    @Test("the two-file pack answers --mcp-list through its CLI without touching stdin")
    func twoFilePackIntrospectionWithoutStdin() async throws {
        let tool = try SpawnedTool.spawn(
            path: try fixtureToolPath("MCPTwoFilePack"),
            arguments: ["plugin", "--mcp-list"]
        )
        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let text = drain(fd: tool.stdoutRead)
        let catalog = try #require((try? QuickJSON.decode(AnyCodable.self, from: Array(text.utf8)))?.value as? [String: Any])
        #expect(catalog["name"] as? String == "mcp-two-file-pack")
        #expect((catalog["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["greet", "reverse"])
    }
}