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
import QuickJSON
import Synchronization

/// The client's send leg must be bounded like its response await: a peer that
/// stops draining its pipe (wedged event loop, stopped process, deadlocked
/// plugin) fills the pipe and `sendFrame`'s write-to-completion never
/// completes. These tests wedge the send with a gated carrier and verify the
/// request deadline frees the caller, the session tears down instead of
/// leaving a zombie, and `close()`'s cooperative-shutdown handshake can never
/// hold the process ladder hostage.
@Suite(.serialized)
struct MCPClientSendDeadlineTests {

    /// A one-slot park for `sendFrame`: a parked call waits until `release()`
    /// resumes it, standing in for a child that never drains its stdin.
    final class SendGate: @unchecked Sendable {
        // @unchecked Sendable: `armed` and `parked` are only touched under
        // `lock`; the continuation travels inside this class, so no other
        // synchronization is needed.
        private let lock = Mutex<Bool>(false)
        private var parked: CheckedContinuation<Void, Never>?

        /// Suspends until `release()` (or, when already released, returns
        /// immediately).
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { armed in
                    if armed {
                        continuation.resume()
                    } else {
                        parked = continuation
                    }
                }
            }
        }

        /// Lets every later send pass, and resumes one currently parked.
        func release() {
            let parked = lock.withLock { _ in
                let parked = self.parked
                self.parked = nil
                return parked
            }
            parked?.resume()
        }
    }

    /// A carrier that answers the MCP handshake with canned frames but whose
    /// `sendFrame` parks on `gate` for the wedged methods — a live peer that
    /// never drains. Real calls that fail (nothing answers) are not part of
    /// these tests; every request flows through the client and is torn down by
    /// its deadlines.
    ///
    /// - Note: `@unchecked Sendable` because `clientFrames` is mutated from
    ///   `sendFrame` (a client-side send task) and `stop()` (the ladder); the
    ///   underlying NIO producer is documented safe for exactly this.
    final class GatedTransport: ClientTransport, @unchecked Sendable {
        private let gate: SendGate
        private let blockToolsCall: Bool
        private let blockShutdown: Bool
        private let clientFrames = ClientFrames()

        /// Creates a gated carrier.
        ///
        /// - Parameters:
        ///   - gate: The park to wedge sends on.
        ///   - blockToolsCall: Whether `tools/call` parks on the gate.
        ///   - blockShutdown: Whether `shutdown` parks on the gate.
        init(gate: SendGate, blockToolsCall: Bool = false, blockShutdown: Bool = false) {
            self.gate = gate
            self.blockToolsCall = blockToolsCall
            self.blockShutdown = blockShutdown
        }

        nonisolated func frames() -> ClientFrameSequence { clientFrames.sequence }

        var supportsCooperativeShutdown: Bool { true }

        func start() async throws {}

        func sendFrame(_ bytes: [UInt8]) async throws {
            guard let object = try? QuickJSON.decode([String: AnyCodable].self, from: bytes),
                  let method = object["method"]?.value as? String else {
                return
            }
            let requestID: JSONRPCID = {
                guard let idValue = object["id"] else { return .null }
                let idData = (try? QuickJSON.encode(AnyCodable(idValue.value))) ?? []
                return (try? QuickJSON.decode(JSONRPCID.self, from: idData)) ?? .null
            }()
            switch method {
            case "initialize":
                queue(JSONRPCResponse(id: requestID, result: InitializeResult(
                    protocolVersion: MCPServer.latestProtocolVersion,
                    capabilities: ServerCapabilities(tools: true),
                    serverInfo: ImplementationInfo(name: "gated", version: "1.0.0")
                )))
            case "tools/list":
                queue(JSONRPCResponse(id: requestID, result: ToolsListResult(tools: [])))
            case "tools/call":
                if blockToolsCall {
                    await gate.wait()
                }
                queue(JSONRPCResponse(id: requestID, result: ToolsCallResult(content: [.text("ok")], isError: false)))
            case "shutdown":
                if blockShutdown {
                    await gate.wait()
                }
                queue(JSONRPCResponse(id: requestID, result: [String: AnyCodable]()))
            default:
                break   // notifications carry no id and need no response.
            }
        }

        func stop() async throws {
            clientFrames.source.finish()
        }

        /// Yields a response into the frame stream from an unstructured task.
        ///
        /// The extra hop keeps the client's in-flight registration (itself one
        /// actor-hop away) ahead of this response, mirroring how a real wire
        /// carrier's latency behaves — the registration is up before the byte
        /// round-trips.
        private func queue(_ response: some Encodable & Sendable) {
            guard let bytes = try? QuickJSON.encode(response) else { return }
            Task { _ = self.clientFrames.source.yield(bytes) }
        }
    }

    @Test("a wedged send cannot outlive the request deadline (no hang, teardown)")
    func wedgedSendFiresDeadline() async throws {
        let gate = SendGate()
        let transport = GatedTransport(gate: gate, blockToolsCall: true)
        var configuration = MCPClient.ClientConfiguration()
        configuration.callTimeout = .milliseconds(300)
        configuration.shutdownCooperationTimeout = .milliseconds(300)
        let client = MCPClient(transport: transport, configuration: configuration)

        try await client.connect()
        _ = try await client.listTools()

        // the call never reaches the peer: its frame blocks on the gate
        // forever, so only the request deadline may free the caller — the
        // regression this fix targets (previously the send was unbounded).
        let outcome = await MCPClientTests().within(.seconds(3)) {
            do {
                _ = try await client.callTool("wedged", arguments: [:])
                Issue.record("expected callTimeout, got a result")
            } catch MCPClientError.callTimeout {
                // expected: the send deadline fired.
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(outcome == .completed)

        // the teardown ran: the session is disconnected and the carrier
        // stopped, so no wedged peer outlives the failed request.
        #expect(await client.currentState() == .disconnected)

        // close() after a torn-down session is prompt (nothing left to stop).
        let closed = await MCPClientTests().within(.seconds(1)) { await client.close() }
        #expect(closed == .completed)

        // hygiene: release the parked send so no task lingers suspended.
        gate.release()
    }

    @Test("close() with a wedged cooperative shutdown still reaches the ladder promptly")
    func wedgedCooperativeShutdownDoesNotBlockClose() async throws {
        let gate = SendGate()
        // the peer answers the handshake but wedges on `shutdown` — the exact
        // close() deadlock the watchdog exists for.
        let transport = GatedTransport(gate: gate, blockShutdown: true)
        var configuration = MCPClient.ClientConfiguration()
        configuration.shutdownCooperationTimeout = .milliseconds(300)
        let client = MCPClient(transport: transport, configuration: configuration)

        try await client.connect()

        // close() asks the peer to drain first (supportsCooperativeShutdown);
        // the peer never takes the frame, so only the bounded handshake — the
        // send deadline and the watchdog — may release close() and let the
        // ladder run.
        let outcome = await MCPClientTests().within(.seconds(3)) {
            await client.close()
        }
        #expect(outcome == .completed)
        #expect(await client.currentState() == .disconnected)

        gate.release()
    }

    @Test("a send that drains before the deadline round-trips normally")
    func healthySendRoundTrips() async throws {
        let gate = SendGate()
        let transport = GatedTransport(gate: gate, blockToolsCall: false)
        let client = MCPClient(transport: transport)

        try await client.connect()
        _ = try await client.listTools()

        let result = try await client.callTool("echo", arguments: [:])
        #expect(result.flattenedText == "ok")

        await client.close()
        #expect(await client.currentState() == .disconnected)
    }
}
