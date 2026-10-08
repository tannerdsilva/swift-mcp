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

/// Locates a built fixture binary in this package (the spawn harness lives in
/// `MCPToolTestKit`; this is the package-relative path). `swift build` must
/// have run first — a test target does not build the executables it spawns.
private func manifestFixturePath(_ name: String = "MCPFixtureTool") throws -> String {
    try builtToolPath(named: name, relativeTo: #filePath)
}

/// The manifest's byte contract — the most frequently read agent-facing
/// surface, so its size is a token cost on every harness load.
///
/// Measured before the compaction work (2026-10-07): `--mcp-manifest arc`
/// emitted 2266 bytes across 88 lines while `--mcp-list` emitted the same
/// catalog compact in 976 bytes across 1 — 2.3× the bytes for the same
/// information. These tests pin the compact default and the reviewable opt-in.
@Suite(.serialized)
struct ManifestCompactionTests {

    @Test("--mcp-manifest arc is compact canonical, and byte-stable across runs")
    func arcManifestIsCompactCanonical() async throws {
        let first = try await manifestBytes("arc")
        let second = try await manifestBytes("arc")

        // canonical: regeneration is byte-identical, so a harness can detect
        // change by comparing bytes rather than re-normalizing a tree.
        #expect(first == second)

        let text = try #require(String(data: Data(first), encoding: .utf8))
        // exactly one framed line — the host frames the document; the format
        // adds no newline of its own.
        #expect(text.split(separator: "\n", omittingEmptySubsequences: true).count == 1)

        // compact is a fraction of the reviewable form, never a byte more.
        let pretty = try await manifestBytes("arc-pretty")
        #expect(first.count < pretty.count)
        #expect(Double(first.count) <= Double(pretty.count) * 0.75)
    }

    @Test("--mcp-manifest arc-pretty keeps the reviewable indented form")
    func arcPrettyManifestIsReviewable() async throws {
        let pretty = try await manifestBytes("arc-pretty")
        let text = try #require(String(data: Data(pretty), encoding: .utf8))

        #expect(text.contains("\n"))
        #expect(text.contains("\n  \"tools\": ["))
    }

    @Test("the compact and pretty spellings are the same document")
    func compactAndPrettyAgree() async throws {
        // the opt-in changes whitespace only — never content, so a harness that
        // reads compact and a human who reads pretty are looking at one thing.
        let compact = try QuickJSON.decode(AnyCodable.self, from: try await manifestBytes("arc"))
        let pretty = try QuickJSON.decode(AnyCodable.self, from: try await manifestBytes("arc-pretty"))

        #expect(compact == pretty)
    }

    @Test("an unknown manifest format still fails loudly")
    func unknownManifestFormatFails() async throws {
        let tool = try SpawnedTool.spawn(path: try manifestFixturePath(), arguments: ["--mcp-manifest", "nope"])

        #expect(try await tool.waitForExit() == .code(1))
        #expect(drain(fd: tool.stdoutRead, quiet: 0.1).isEmpty)
        #expect(drain(fd: tool.stderrRead).contains("nope"))
    }

    /// Runs the fixture binary in introspection mode for a manifest format and
    /// returns its framed stdout bytes (newline included, exactly as a harness
    /// receives them).
    private func manifestBytes(_ format: String) async throws -> [UInt8] {
        let tool = try SpawnedTool.spawn(path: try manifestFixturePath(), arguments: ["--mcp-manifest", format])
        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))
        return Array(drain(fd: tool.stdoutRead).utf8)
    }
}