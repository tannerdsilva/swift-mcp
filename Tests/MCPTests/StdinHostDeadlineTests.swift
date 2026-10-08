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

/// The opt-in first-frame deadline.
///
/// The transport hands over complete frames only. A producer that omits the
/// terminating newline never delivers a frame, and a producer that holds the
/// stream open never delivers EOF either — so the process waits forever with
/// nothing on either stream. That is the one failure a harness cannot see:
/// no output, no exit, no diagnostic.
///
/// `Configuration.firstFrameTimeout` is the opt-in bound. It is off by
/// default: a session-shaped peer may legitimately idle, and the change must
/// be behavior-preserving.
@Suite("Stdin host — first-frame deadline")
struct StdinHostDeadlineTests {

    /// Builds a host over the given handles with a first-frame deadline.
    private func makeHost(
        input: FileHandle,
        output: FileHandle,
        timeout: Duration?
    ) -> MCPStdinHost<AppServer> {
        let transport = StdioTransport(input: input, output: output)
        var configuration = MCPStdinHost<AppServer>.Configuration(arguments: ["test-tool"])
        configuration.outputFD = output.fileDescriptor
        configuration.firstFrameTimeout = timeout
        return MCPStdinHost(
            name: "test-tool",
            version: "1.0.0",
            dispatcher: AppServer(),
            transport: transport,
            configuration: configuration
        )
    }

    @Test("the deadline fires when nothing is written at all")
    func deadlineFiresWithNoBytes() async throws {
        let input = Pipe()
        let output = Pipe()
        let host = makeHost(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            timeout: .milliseconds(50)
        )

        // the write end stays open for the whole test — this is the shape that
        // hangs a tool forever, because EOF is never reached either.
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: MCPStdinHostError.noFrameWithinDeadline) {
            try await host.run()
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test("the deadline fires on an unterminated frame — the silent hang")
    func deadlineFiresOnUnterminatedFrame() async throws {
        let input = Pipe()
        let output = Pipe()
        let host = makeHost(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            timeout: .milliseconds(80)
        )

        // a byte-perfect plugin envelope, missing only its newline. The
        // transport never delivers a partial frame, and the producer never
        // closes: without a deadline this is a total hang.
        input.fileHandleForWriting.write(Data(#"{"tool":"greet","args":{"name":"X"}}"#.utf8))

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: MCPStdinHostError.noFrameWithinDeadline) {
            try await host.run()
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test("a complete frame disarms the deadline")
    func completeFrameDisarmsTheDeadline() async throws {
        let input = Pipe()
        let output = Pipe()
        let host = makeHost(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            timeout: .milliseconds(300)
        )

        // a terminated frame on an otherwise-open stream: exactly the case the
        // deadline must not punish. A frame arriving claims the once token, so
        // the watchdog can never fire on work that was merely in progress.
        input.fileHandleForWriting.write(Data((#"{"tool":"greet","args":{"name":"World"}}"# + "\n").utf8))

        try await host.run()

        try output.fileHandleForWriting.close()
        let written = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(written.contains("World"))
    }

    @Test("no deadline by default — an idle open stream is still allowed to wait")
    func noDeadlineByDefault() async throws {
        let input = Pipe()
        let output = Pipe()
        let host = makeHost(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            timeout: nil
        )

        // with the default `nil` the frame is served exactly as before the
        // deadline existed: this is the behavior-preservation guard.
        input.fileHandleForWriting.write(Data((#"{"tool":"greet","args":{"name":"Default"}}"# + "\n").utf8))
        try await host.run()

        try output.fileHandleForWriting.close()
        let written = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(written.contains("Default"))
    }
}