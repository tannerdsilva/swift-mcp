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

/// The reference pack's binary, located through the kit.
private func packPath() throws -> String {
    try builtToolPath(named: "MCPToolPack", relativeTo: #filePath)
}

/// Decodes one recovered frame into a dictionary.
private func frame(_ text: String) throws -> [String: Any] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
        throw ToolSpawnError.malformedFrame(trimmed.isEmpty ? "<empty stdout>" : trimmed)
    }
    return object
}

/// Spawns the pack, writes one envelope frame, closes stdin, and returns
/// (exit, result).
private func call(_ tool: String, _ args: [String: String] = [:]) async throws -> (ToolExit, String) {
    let handle = try SpawnedTool.spawn(path: try packPath())
    try handle.writePluginFrame(tool: tool, args: args)
    handle.closeStdin()
    let exit = try await handle.waitForExit()
    return (exit, try handle.readResult())
}

/// The stderr a one-shot tool authors itself, with the known dependency noise
/// filtered out.
///
/// QuickJSON prints a construction banner from `makeDefaultLogger` — a
/// `newLogger.debug(...)` at a level hardcoded to `.debug`, emitted the moment
/// the default logger is *created*. So it fires before any framework code runs,
/// and the framework cannot suppress it: assigning `.critical` reads the
/// property, which is what creates the logger in the first place. Measured at
/// 346 bytes on every invocation, and one line ahead of the single diagnostic
/// line on every failure.
///
/// Filtered rather than tolerated so these tests still assert the framework's
/// OWN discipline strictly: nothing on success, exactly one line on failure.
/// The dependency-side fix (defaulting `makeDefaultLogger` to `.critical`, or
/// dropping the banner) would make the filter a no-op.
private func frameworkStderr(_ tool: SpawnedTool) -> [String] {
    tool.drainStderr()
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { !$0.contains("com.tannersilva.quickjson.") }
}

/// The reference pack, driven the way a harness drives it.
///
/// Twelve tools in one process is the fleet model under test: the assertions
/// below are about *shape coverage* — that every return shape the facade
/// supports really does survive the envelope — not about the tools' text.
@Suite(.serialized)
struct ToolPackTests {

    /// Ordered as declared, so a reordering is a visible diff rather than a
    /// silent one.
    private static let expectedNames = [
        "echo", "upper", "lineCount", "wordCount", "textStats",
        "jsonPretty", "jsonMinify", "base64Encode", "base64Decode",
        "ping", "debugEcho", "adminEcho",
    ]

    @Test("--mcp-list advertises all twelve tools, without reading stdin")
    func catalogListsTwelveTools() async throws {
        let tool = try SpawnedTool.spawn(path: try packPath(), arguments: ["--mcp-list"])
        #expect(try await tool.waitForExit() == .code(0))

        let catalog = try frame(tool.drainStdout())
        let tools = try #require(catalog["tools"] as? [[String: Any]])
        #expect(tools.count == 12)
        #expect(tools.compactMap { $0["name"] as? String } == Self.expectedNames)
        // the pack's own identity rides along, so a harness can attribute a
        // tool to the binary that serves it.
        #expect(catalog["name"] as? String == "mcp-tool-pack")
        #expect(catalog["version"] as? String == "1.0.0")
    }

    @Test("--mcp-describe returns one tool, and it agrees with the catalog entry")
    func describeOneTool() async throws {
        let described = try SpawnedTool.spawn(path: try packPath(), arguments: ["--mcp-describe", "textStats"])
        #expect(try await described.waitForExit() == .code(0))
        let single = try frame(described.drainStdout())

        #expect(single["name"] as? String == "textStats")
        #expect(single["tools"] == nil)   // one tool, not the catalog

        let listed = try SpawnedTool.spawn(path: try packPath(), arguments: ["--mcp-list"])
        #expect(try await listed.waitForExit() == .code(0))
        let catalog = try frame(listed.drainStdout())
        let tools = try #require(catalog["tools"] as? [[String: Any]])
        let entry = try #require(tools.first { $0["name"] as? String == "textStats" })

        #expect(single as NSDictionary == entry as NSDictionary)
    }

    @Test("--mcp-manifest arc emits one entry per tool, all on the same command")
    func manifestHasTwelveEntries() async throws {
        let tool = try SpawnedTool.spawn(path: try packPath(), arguments: ["--mcp-manifest", "arc"])
        #expect(try await tool.waitForExit() == .code(0))

        let manifest = try frame(tool.drainStdout())
        let entries = try #require(manifest["tools"] as? [[String: Any]])
        #expect(entries.count == 12)
        #expect(entries.compactMap { $0["name"] as? String } == Self.expectedNames)

        // the fleet claim: twelve registrations, ONE process to spawn. The
        // command is absolute and executable, and no entry carries arguments —
        // the pack takes none, so a harness spawns it bare.
        let commands = Set(entries.compactMap { $0["command"] as? String })
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(command.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: command))
        #expect(entries.allSatisfy { ($0["args"] as? [String])?.isEmpty == true })
        #expect(entries.allSatisfy { $0["toolset"] as? String == "mcp-tool-pack" })
    }

    @Test("two tools dispatch correctly through the envelope")
    func dispatchesByEnvelope() async throws {
        let echoed = try await call("echo", ["message": "hi"])
        #expect(echoed.0 == .code(0))
        #expect(echoed.1 == "hi")

        let uppered = try await call("upper", ["text": "ab"])
        #expect(uppered.0 == .code(0))
        #expect(uppered.1 == "AB")
    }

    @Test("an Int return arrives as its decimal text")
    func scalarIntResult() async throws {
        let (exit, result) = try await call("wordCount", ["text": "a b c"])
        #expect(exit == .code(0))
        #expect(result == "3")
    }

    @Test("a Codable return carries its fields")
    func structuredResult() async throws {
        let (exit, result) = try await call("textStats", ["text": "one two\nthree"])
        #expect(exit == .code(0))
        // asserted structurally, not byte-wise: the exact rendering of a
        // structured return is the render surface's contract, not the pack's.
        #expect(result.contains("words"))
        #expect(result.contains("3"))
        #expect(result.contains("13"))
    }

    @Test("a Void tool still answers, so its exit stays 0")
    func voidToolAnswers() async throws {
        let (exit, result) = try await call("ping")
        // a Void tool completed; "no payload" must not be reported as a fault.
        #expect(exit == .code(0))
        #expect(result.isEmpty)
    }

    @Test("a throwing tool delivers its failure as a result, not an exit code")
    func throwingToolFailsAsResult() async throws {
        let (exit, result) = try await call("base64Decode", ["text": "not!"])
        #expect(exit == .code(0))
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("not base64"))

        // the same tool succeeds on well-formed input — the failure is the
        // input's, not the tool's.
        let (okExit, okResult) = try await call("base64Decode", ["text": "aGk="])
        #expect(okExit == .code(0))
        #expect(okResult == "hi")
    }

    @Test("the JSON tools share one parser and disagree only in layout")
    func jsonTools() async throws {
        let (minExit, minified) = try await call("jsonMinify", ["json": "{\n \"a\": 1\n}"])
        #expect(minExit == .code(0))
        #expect(minified == #"{"a":1}"#)

        let (prettyExit, pretty) = try await call("jsonPretty", ["json": #"{"b":1,"a":[1,2]}"#])
        #expect(prettyExit == .code(0))
        // keys are sorted, so the layout is a function of the value alone.
        #expect(pretty.contains("\n"))
        #expect(pretty.contains(#""a""#))
        #expect(pretty.firstIndex(of: "a")! < pretty.firstIndex(of: "b")!)

        // invalid input is the shared failure path, whichever tool is asked.
        let (badExit, bad) = try await call("jsonPretty", ["json": "{oops"])
        #expect(badExit == .code(0))
        #expect(bad.hasPrefix("Error:"))
        #expect(bad.contains("not JSON"))
    }

    @Test("a debug-only tool is present in a debug build")
    func debugOnlyToolIsPresent() async throws {
        let (exit, result) = try await call("debugEcho", ["message": "z"])
        #expect(exit == .code(0))
        #expect(result == "debug:z")
    }

    @Test("an admin-gated tool is allowed for the local caller that owns the process")
    func accessGatedToolIsAllowed() async throws {
        // a one-shot tool is spawned by the harness that owns it, so the caller
        // is the local process (`.root`) and clears the tool's `.admin` bar.
        let (exit, result) = try await call("adminEcho", ["message": "z"])
        #expect(exit == .code(0))
        #expect(result == "admin:z")
    }

    @Test("a shell-style redirect is refused loudly instead of hanging")
    func regularFileStreamsAreRefused() async throws {
        // no introspection flag: those bypass the transport on purpose (so
        // `--mcp-manifest > file` keeps working), which means only a real
        // transport start reaches the preflight.
        // the pack inherits the host's guard: the one failure mode a harness
        // must never meet is silence.
        let tool = try SpawnedTool.spawnWithFileStreams(
            path: try packPath(),
            stdoutFile: FileManager.default.temporaryDirectory
                .appendingPathComponent("mcp-tool-pack-stdout-probe.txt").path
        )
        let exit = try await tool.waitForExit()
        #expect(exit == .code(1))

        let diagnostic = tool.drainStderr()
        #expect(diagnostic.contains("stdout"))
        #expect(diagnostic.contains("fd 1"))
    }

    @Test("a successful invocation authors nothing at all on stderr")
    func successfulInvocationAuthorsNoStderr() async throws {
        // the exit contract promises stdout carries the response and a SUCCESS
        // writes no diagnostic. the QuickJSON banner is a dependency's, not the
        // framework's, so it is filtered — see `frameworkStderr`.
        let tool = try SpawnedTool.spawn(path: try packPath())
        try tool.writePluginFrame(tool: "echo", args: ["message": "hi"])
        tool.closeStdin()

        #expect(try await tool.waitForExit() == .code(0))
        #expect(try tool.readResult() == "hi")
        #expect(frameworkStderr(tool).isEmpty)
    }

    @Test("a failure authors exactly one stderr line, and nothing else")
    func failurePathAuthorsExactlyOneLine() async throws {
        // the other half of the same contract: a failure is ONE line a harness
        // can forward verbatim, not one line behind a banner.
        let tool = try SpawnedTool.spawnWithFileStreams(
            path: try packPath(),
            stdoutFile: FileManager.default.temporaryDirectory
                .appendingPathComponent("mcp-tool-pack-oneline-probe.txt").path
        )
        #expect(try await tool.waitForExit() == .code(1))

        let lines = frameworkStderr(tool)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("stdout") == true)
    }
}