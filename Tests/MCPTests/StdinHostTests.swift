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
import QuickJSON
@testable import MCP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Pipe helpers

/// Waits up to `timeout` for data on a pipe fd and returns the available
/// bytes (mirrors the transport end-to-end suite's read path: poll + read, so
/// a short response returns immediately and no EOF is required).
private func hostRead(fd: Int32, timeout: TimeInterval) -> [UInt8] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var pollFds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&pollFds, 1, 50)
        if result > 0, pollFds.revents & Int16(POLLIN) != 0 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Array(bytes[0..<count]) }
            if count == 0 { return [] }
        }
    }
    return []
}

/// Accumulates pipe output until `condition` holds against the text read so
/// far, or the timeout expires.
private func hostReadUntil(fd: Int32, timeout: TimeInterval, condition: (String) -> Bool) -> String {
    var text = ""
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let chunk = hostRead(fd: fd, timeout: 0.2)
        if !chunk.isEmpty { text += String(decoding: chunk, as: UTF8.self) }
        if condition(text) { return text }
    }
    return text
}

// MARK: - Host pair fixture

/// A spawned-tool-shaped fixture: the host wired to real pipes — input frames
/// go into the transport's read end, the host writes responses to the output
/// pipe. The input write end deliberately stays open in tests that prove the
/// one-shot completion contract.
private func makeHostPair<Dispatcher: MCPToolDispatcher>(
    dispatcher: Dispatcher,
    arguments: [String] = ["test-tool"],
    manifestInvocationArguments: [String] = [],
    dialects: [any MCPStdinDialect] = [MCPPluginDialect(), MCPJSONRPCDialect()]
) -> (host: MCPStdinHost<Dispatcher>, inputWrite: FileHandle, outputRead: FileHandle, outputWrite: FileHandle) {
    let input = Pipe()
    let output = Pipe()
    let transport = StdioTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
    var configuration = MCPStdinHost<Dispatcher>.Configuration(dialects: dialects, arguments: arguments)
    configuration.outputFD = output.fileHandleForWriting.fileDescriptor
    configuration.manifestInvocationArguments = manifestInvocationArguments
    let host = MCPStdinHost(
        name: "test-tool",
        version: "1.0.0",
        dispatcher: dispatcher,
        transport: transport,
        configuration: configuration
    )
    return (host, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting)
}

// MARK: - One-shot serving

/// The host's serving contract over real pipes: dialect detection, transcoding
/// through the one router, synchronous response writing, and the exit shape
/// (throw → the entry maps to exit 1).
@Suite("Stdin host — one-shot serving")
struct StdinHostTests {

    @Test("plugin frame completes the run without waiting for stdin EOF")
    func pluginFrameCompletesWithoutEOF() async throws {
        let pair = makeHostPair(dispatcher: AppServer())
        let task = Task { try await pair.host.run() }

        try testWrite(pair.inputWrite.fileDescriptor, Array(#"{"tool":"greet","args":{"name":"Std"}}"#.utf8) + [0x0A])

        // the response arrives while the input write end stays OPEN.
        let response = hostReadUntil(fd: pair.outputRead.fileDescriptor, timeout: 5) { $0.contains("result") }
        #expect(response.contains(#"{"result":"Hello, Std!"}"#))

        // and run() completes with stdin still open — a stdin-holding harness
        // cannot hang.
        try await task.value
    }

    @Test("json-rpc frame answers and the run ends at stdin EOF")
    func jsonrpcFrameAnswersAndEndsAtEOF() async throws {
        let pair = makeHostPair(dispatcher: AppServer())
        let task = Task { try await pair.host.run() }

        try testWrite(pair.inputWrite.fileDescriptor, Array(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8) + [0x0A])

        let response = hostReadUntil(fd: pair.outputRead.fileDescriptor, timeout: 5) { $0.contains("\"greet\"") }
        #expect(response.contains("\"id\":7"))
        #expect(response.contains("\"calculate\""))

        // the session contract: read until EOF, then finish.
        try pair.inputWrite.close()
        try await task.value
    }

    @Test("a pinned json-rpc dialect answers a malformed later frame with the engine's parse error")
    func pinnedDialectAnswersMalformedLaterFrame() async throws {
        let pair = makeHostPair(dispatcher: AppServer())
        let task = Task { try await pair.host.run() }

        // one frame at a time: pipelined frames enter the engine in arbitrary
        // order (each frame is its own task — the §1.2 probe's out-of-order
        // responses), so the pinning contract is exercised serially, as a
        // harness drives it.
        try testWrite(pair.inputWrite.fileDescriptor, Array(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8) + [0x0A])
        var text = hostReadUntil(fd: pair.outputRead.fileDescriptor, timeout: 5) { $0.contains("\"id\":1") }
        #expect(text.contains("\"id\":1"))

        // the dialect is pinned — a frame it does not recognize still reaches
        // the router, which answers with the engine's own classification.
        try testWrite(pair.inputWrite.fileDescriptor, Array("utter garbage".utf8) + [0x0A])
        try pair.inputWrite.close()
        try await task.value

        text += hostReadUntil(fd: pair.outputRead.fileDescriptor, timeout: 5) { $0.contains("Parse error") }
        #expect(text.contains("-32700"))
    }

    @Test("a frame no dialect recognizes fails: stdout stays silent, run() throws")
    func malformedFirstFrameFailsSilently() async throws {
        let pair = makeHostPair(dispatcher: AppServer())
        let task = Task { try await pair.host.run() }

        try testWrite(pair.inputWrite.fileDescriptor, Array("definitely not json".utf8) + [0x0A])

        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected run() to throw for an unrecognized first frame")
            return
        }
        guard let hostError = error as? MCPStdinHostError, case .noDialectRecognized = hostError else {
            Issue.record("expected noDialectRecognized, got \(error)")
            return
        }
        let output = hostRead(fd: pair.outputRead.fileDescriptor, timeout: 0.3)
        #expect(output.isEmpty)
    }

    @Test("empty stdin fails with noInputReceived and silent stdout")
    func emptyInputFails() async throws {
        let pair = makeHostPair(dispatcher: AppServer())
        try pair.inputWrite.close()

        do {
            try await pair.host.run()
            Issue.record("expected run() to throw for empty input")
        } catch let hostError as MCPStdinHostError {
            #expect(hostError == .noInputReceived)
        }
        let output = hostRead(fd: pair.outputRead.fileDescriptor, timeout: 0.3)
        #expect(output.isEmpty)
    }

    @Test("the transport-supplied caller gates the dispatch (in-process, no env)")
    func callerIdentityIsForwarded() async throws {
        let mock = MockTransport()
        mock.receivedMessages = [Array(#"{"tool":"rootOnly","args":{}}"#.utf8)]
        let output = Pipe()
        var configuration = MCPStdinHost<GatedApp>.Configuration()
        configuration.outputFD = output.fileHandleForWriting.fileDescriptor
        let host = MCPStdinHost(
            name: "gated",
            version: "1.0.0",
            dispatcher: GatedApp(),
            transport: mock,
            configuration: configuration
        )

        try await host.run()

        let text = hostReadUntil(fd: output.fileHandleForReading.fileDescriptor, timeout: 5) { $0.contains("result") }
        #expect(text.contains("Error: Access denied: rootOnly"))
        // the host owns stdout: the transport never writes a response itself.
        #expect(mock.sentMessages.isEmpty)
    }

    @Test("plugin frames through a mock transport complete and stop the transport")
    func pluginFrameCompletesAndStopsTransport() async throws {
        let mock = MockTransport()
        mock.receivedMessages = [Array(#"{"tool":"greet","args":{"name":"Mock"}}"#.utf8)]
        let output = Pipe()
        var configuration = MCPStdinHost<AppServer>.Configuration()
        configuration.outputFD = output.fileHandleForWriting.fileDescriptor
        let host = MCPStdinHost(
            name: "mock-tool",
            version: "1.0.0",
            dispatcher: AppServer(),
            transport: mock,
            configuration: configuration
        )

        try await host.run()

        let text = hostReadUntil(fd: output.fileHandleForReading.fileDescriptor, timeout: 5) { $0.contains("result") }
        #expect(text.contains("Hello, Mock!"))
        #expect(mock.sentMessages.isEmpty)
    }

    @Test("a transport start failure propagates from run()")
    func transportStartFailurePropagates() async throws {
        let mock = MockTransport()
        mock.shouldThrowOnStart = true
        let output = Pipe()
        var configuration = MCPStdinHost<AppServer>.Configuration()
        configuration.outputFD = output.fileHandleForWriting.fileDescriptor
        let host = MCPStdinHost(
            name: "mock-tool",
            version: "1.0.0",
            dispatcher: AppServer(),
            transport: mock,
            configuration: configuration
        )

        await #expect(throws: MCPError.self) {
            try await host.run()
        }
    }
}

// MARK: - Introspection

/// Introspection is served before any transport starts: it emits the binary's
/// self-description and never touches stdin.
@Suite("Stdin host — introspection")
struct StdinHostIntrospectionTests {

    @Test("--mcp-list emits the catalog and never reads stdin")
    func listIntrospectionNeverReadsStdin() async throws {
        let pair = makeHostPair(dispatcher: AppServer(), arguments: ["test-tool", "--mcp-list"])

        // stdin stays open and empty: completing proves it was never waited on.
        try await pair.host.run()

        let text = hostReadUntil(fd: pair.outputRead.fileDescriptor, timeout: 2) { $0.hasSuffix("\n") }
        let decoded = try #require(decodeFrame(Array(text.utf8)) as? [String: Any])
        #expect(decoded["name"] as? String == "test-tool")
        #expect(decoded["version"] as? String == "1.0.0")
        let tools = try #require(decoded["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["greet", "calculate"])
    }

    @Test("--mcp-manifest arc emits a manifest the catalog stands behind")
    func manifestIntrospectionMatchesCatalog() async throws {
        let pair = makeHostPair(dispatcher: AppServer(), arguments: ["/usr/bin/true", "--mcp-manifest", "arc"])

        try await pair.host.run()

        let text = hostReadUntil(fd: pair.outputRead.fileDescriptor, timeout: 2) { $0.hasSuffix("\n") }
        let decoded = try #require(decodeFrame(Array(text.utf8)) as? [String: Any])
        #expect(decoded["name"] as? String == "test-tool")
        let tools = try #require(decoded["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["greet", "calculate"])
        #expect(tools.first?["command"] as? String == "/usr/bin/true")
        #expect(tools.first?["toolset"] as? String == "test-tool")
    }

    @Test("--mcp-manifest emits the configured invocation argv prefix")
    func manifestInvocationArguments() async throws {
        let pair = makeHostPair(
            dispatcher: AppServer(),
            arguments: ["/usr/bin/true", "--mcp-manifest", "arc"],
            manifestInvocationArguments: ["plugin"]
        )

        try await pair.host.run()

        let text = hostReadUntil(fd: pair.outputRead.fileDescriptor, timeout: 2) { $0.hasSuffix("\n") }
        let decoded = try #require(decodeFrame(Array(text.utf8)) as? [String: Any])
        let tools = try #require(decoded["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools.allSatisfy { $0["args"] as? [String] == ["plugin"] })
    }

    @Test("unknown manifest formats and unresolved binary paths fail cleanly")
    func manifestIntrospectionFailures() async throws {
        let unknown = makeHostPair(dispatcher: AppServer(), arguments: ["test-tool", "--mcp-manifest", "bogus"])
        do {
            try await unknown.host.run()
            Issue.record("expected run() to throw for an unknown manifest format")
        } catch let error as MCPStdinHostError {
            #expect(error == .manifestFormatUnknown("bogus"))
        }

        let unresolved = makeHostPair(dispatcher: AppServer(), arguments: ["no-such-binary-xyz", "--mcp-manifest", "arc"])
        do {
            try await unresolved.host.run()
            Issue.record("expected run() to throw when the executable path cannot be resolved")
        } catch let error as MCPStdinHostError {
            #expect(error == .executablePathUnresolved)
        }
    }
}