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
@testable import MCP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The std-stream preflight: a regular file can never carry a frame, and NIO
/// only says so opaquely — `Operation unsupported` at transport start, after
/// the harness has lost the thread. The host rejects it first and names the
/// offending stream.
///
/// These are in-process tests over injected handles; the spawned, real-process
/// shape lives in `StdinToolE2ETests`.
@Suite("Stdin host — std-stream preflight")
struct StdinHostPreflightTests {

    /// Writes `contents` to a fresh regular file and returns its path.
    private func makeRegularFile(_ contents: String, suffix: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-stdin-preflight-\(UUID().uuidString)-\(suffix)")
            .path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Builds a host over the given handles, writing results to `outputFD`.
    private func makeHost(
        input: FileHandle,
        output: FileHandle,
        outputFD: Int32,
        arguments: [String] = ["test-tool"]
    ) -> MCPStdinHost<AppServer> {
        let transport = StdioTransport(input: input, output: output)
        var configuration = MCPStdinHost<AppServer>.Configuration(arguments: arguments)
        configuration.outputFD = outputFD
        return MCPStdinHost(
            name: "test-tool",
            version: "1.0.0",
            dispatcher: AppServer(),
            transport: transport,
            configuration: configuration
        )
    }

    @Test("a regular-file stdin is rejected before the transport starts")
    func regularFileStdinIsRejected() async throws {
        let path = try makeRegularFile(#"{"tool":"greet","args":{"name":"X"}}"# + "\n", suffix: "in")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? input.close() }
        let output = Pipe()

        let host = makeHost(input: input, output: output.fileHandleForWriting, outputFD: output.fileHandleForWriting.fileDescriptor)

        await #expect(throws: MCPStdinHostError.standardStreamIsNotAPipe(stream: "stdin", descriptor: input.fileDescriptor)) {
            try await host.run()
        }
    }

    @Test("a regular-file stdout is rejected before the transport starts")
    func regularFileStdoutIsRejected() async throws {
        let path = try makeRegularFile("", suffix: "out")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let input = Pipe()
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? output.close() }

        let host = makeHost(input: input.fileHandleForReading, output: output, outputFD: output.fileDescriptor)

        await #expect(throws: MCPStdinHostError.standardStreamIsNotAPipe(stream: "stdout", descriptor: output.fileDescriptor)) {
            try await host.run()
        }
    }

    @Test("introspection still succeeds with a regular-file stdout — the install path")
    func introspectionSucceedsWithRegularFileStdout() async throws {
        // `my-tool --mcp-list > catalog.json`: introspection is answered before
        // the transport starts, so the preflight must not stand in its way.
        let path = try makeRegularFile("", suffix: "catalog")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let input = Pipe()
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))

        let host = makeHost(
            input: input.fileHandleForReading,
            output: output,
            outputFD: output.fileDescriptor,
            arguments: ["test-tool", "--mcp-list"]
        )

        try await host.run()
        try output.close()

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written.contains("\"greet\""))
        #expect(written.contains("\"calculate\""))
    }

    @Test("real pipes pass the preflight untouched — no over-reach")
    func pipedStreamsPassThePreflight() async throws {
        // The check must be invisible to a correct harness: with pipes on both
        // sides the run proceeds to the transport, which ends at stdin EOF —
        // and an empty stdin is the host's own `noInputReceived`, far past the
        // preflight. Asserting on that error is what proves the preflight did
        // not fire.
        let input = Pipe()
        let output = Pipe()
        let host = makeHost(input: input.fileHandleForReading, output: output.fileHandleForWriting, outputFD: output.fileHandleForWriting.fileDescriptor)

        try input.fileHandleForWriting.close()

        await #expect(throws: MCPStdinHostError.noInputReceived) {
            try await host.run()
        }
    }
}