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
@testable import MCP

/// Cancellation semantics for client requests: a cancelled caller task must
/// stop the remote invocation (via `notifications/cancelled`), surface
/// `CancellationError` promptly, and never disturb sibling calls.
@Suite(.serialized)
struct MCPClientCancellationTests {

    @Test("cancelling a callTool task stops the remote invocation")
    func subprocessCancelStopsRemoteCall() async throws {
        let transport = try SubprocessClientTransport(
            configuration: .init(executable: MCPClientTests().fixtureServerPath(), shutdownGrace: .seconds(2))
        )
        let client = MCPClient(transport: transport)

        try await client.connect()
        _ = try await client.listTools()

        let call = Task { try await client.callTool("slow", arguments: ["seconds": 5.0]) }
        // let the call reach the server before cancelling
        try await Task.sleep(for: .milliseconds(500))
        call.cancel()

        let started = ContinuousClock.now
        do {
            _ = try await call.value
            Issue.record("expected CancellationError, got a result")
        } catch is CancellationError {
            // expected: the caller's task was cancelled
        }
        // prompt: the caller must not wait out the tool's 5s sleep
        #expect(ContinuousClock.now - started < .seconds(3))

        // end-to-end: the notification reached the tool — the fixture's `slow`
        // catches CancellationError and writes a marker to stderr.
        let markerSeen = await MCPClientTests().within(.seconds(6)) {
            while !transport.stderrTailSnapshot().contains(where: { $0.contains("fixture slow-cancelled") }) {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(markerSeen == .completed)

        await client.close()
        #expect(await client.currentState() == .disconnected)
    }

    @Test("cancelling a network-free call also stops the local invocation")
    func localCancelStopsLocalInvocation() async throws {
        // the local carrier is deliberately exercised too: it answers inside
        // sendFrame (register-before-send ordering) and drives the same router,
        // so cancellation must work with zero bytes and zero processes.
        let transport = LocalClientTransport(dispatcher: MCPClientTests.LocalAppDispatcher())
        let client = MCPClient(transport: transport)

        try await client.connect()
        _ = try await client.listTools()

        let call = Task { try await client.callTool("slow", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(300))
        call.cancel()

        let started = ContinuousClock.now
        do {
            _ = try await call.value
            Issue.record("expected CancellationError, got a result")
        } catch is CancellationError {
            // expected: the caller's task was cancelled
        }
        #expect(ContinuousClock.now - started < .seconds(3))

        // the 30s slow invocation was interrupted, not left running: a follow-up
        // call completes promptly instead of queuing behind it.
        let quickStarted = ContinuousClock.now
        let greet = try await client.callTool("greet", arguments: ["name": "Taylor"])
        #expect(greet.flattenedText == "Hello, Taylor!")
        #expect(ContinuousClock.now - quickStarted < .seconds(5))

        await client.close()
    }
}
