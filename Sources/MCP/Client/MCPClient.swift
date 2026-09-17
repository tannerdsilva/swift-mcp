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

import QuickJSON

/// An actor that owns the client role of the MCP protocol over a
/// ``ClientTransport`` carrier.
///
/// State machine: `idle → spawning → handshake → ready → shuttingDown →
/// disconnected`. The client runs `initialize` (protocol-version negotiation),
/// `tools/list`, and `tools/call`; the remote catalog is invalidated on a
/// `notifications/tools/list_changed` notification.
///
/// Every request is correlated by JSON-RPC id through an actor-owned in-flight
/// table (out-of-order replies are safe), and every request carries a deadline
/// on its send and its response — a stuck peer, one that never answers or one
/// that stops draining its pipe, can never hang the caller.
///
/// ## Two Laws
///
/// The client is an actor; the read loop is one task over the carrier's
/// `frames()`; per-call timeouts race `Task.sleep`; the carrier (subprocess)
/// runs its lifecycle ladder inside `stop()`. No raw threads, no semaphores,
/// no `DispatchQueue`.
public actor MCPClient {

    /// The client connection state.
    public enum State: Sendable, Equatable {
        case idle
        case spawning
        case handshake
        case ready
        case shuttingDown
        case disconnected
    }

    /// Client-side protocol and timeout configuration.
    public struct ClientConfiguration: Sendable {
        /// How long the `initialize` handshake may take. Defaults to 10s.
        public var negotiationTimeout: Duration = .seconds(10)
        /// Per-request deadline. Defaults to 120s.
        public var callTimeout: Duration = .seconds(120)
        /// How long `close()` waits for a cooperative `shutdown` peer to drain
        /// in-flight work before falling back to EOF and the signal ladder.
        /// Defaults to 5s.
        public var shutdownCooperationTimeout: Duration = .seconds(5)
        /// The `clientInfo.name` sent during `initialize`.
        public var clientName: String = "mcp-swift-client"
        /// The `clientInfo.version` sent during `initialize`.
        public var clientVersion: String = "1.0.0"
        /// Invoked (best-effort) whenever the remote `tools/list_changed`
        /// notification invalidates the cached catalog.
        ///
        /// The catalog is rebuilt by the next `listTools()` call; this hook
        /// exists so a harness (e.g. a tool registry syncing remote servers)
        /// can react — re-list, diff, or flag the server for respawn — without
        /// polling. Runs on the client actor; keep it cheap.
        public var catalogInvalidated: (@Sendable () -> Void)?

        /// Creates a default configuration.
        public init() {}
    }

    /// An in-flight request: its id's continuation, awaiting the response.
    private struct InFlight {
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    /// The carrier this client speaks over.
    private let transport: any ClientTransport
    private let configuration: ClientConfiguration

    private var state: State = .idle
    private var nextID: Int = 0
    /// Requests awaiting their response, keyed by JSON-RPC id. Actor-owned —
    /// continuations are stored and fulfilled within one isolation domain, so
    /// no locks and no `@unchecked Sendable` anywhere near this table.
    private var inFlight: [JSONRPCID: InFlight] = [:]
    /// The remote tool catalog, from the last `tools/list`.
    private var catalog: [String: RemoteToolDescriptor] = [:]
    private var negotiatedProtocolVersion: String?
    /// The single task consuming the carrier's `frames()`.
    private var readLoopTask: Task<Void, Never>?
    /// One-shot waiter for the ``MCPClientService`` (`waitForDisconnection`).
    private var disconnectContinuation: CheckedContinuation<Void, Never>?

    /// Creates a client over the given carrier.
    ///
    /// - Parameters:
    ///   - transport: The carrier (subprocess, TCP, or local).
    ///   - configuration: Timeouts and client identity.
    public init(transport: any ClientTransport, configuration: ClientConfiguration = ClientConfiguration()) {
        self.transport = transport
        self.configuration = configuration
    }

    /// The current connection state.
    public func currentState() -> State {
        state
    }

    /// The protocol version negotiated during `initialize`, once `ready`.
    public func negotiatedVersion() -> String? {
        negotiatedProtocolVersion
    }

    // MARK: - Lifecycle

    /// Brings the carrier up and completes the `initialize` handshake.
    ///
    /// On success the client is `ready`. The request version is the server's
    /// `latestProtocolVersion`; a server answer outside `supportedProtocolVersions`
    /// fails the handshake.
    ///
    /// - Note: one-shot per client instance. After `close()` the instance is
    ///   `disconnected` and cannot be reused.
    public func connect() async throws {
        guard state == .idle else {
            throw MCPClientError.notConnected
        }

        state = .spawning
        do {
            try await transport.start()
        } catch {
            state = .disconnected
            throw error
        }

        // Start the read loop over the carrier's frame stream; it routes
        // replies by id, invalidates the catalog on list_changed, and converts
        // EOF into a disconnected state with every in-flight request failed.
        let frames = transport.frames()
        let loopTask = Task { [frames] in
            var iterator = frames.makeAsyncIterator()
            while let frame = await iterator.next() {
                await self.handleIncoming(frame)
            }
            await self.handleTransportClosed()
        }
        readLoopTask = loopTask

        state = .handshake
        do {
            let response = try await requestRaw(
                method: "initialize",
                params: initializeParams,
                timeout: configuration.negotiationTimeout,
                duringHandshake: true
            )
            let object = try decodeSuccessObject(response)
            guard let result = object["result"] else {
                throw MCPClientError.invalidResponse("initialize result missing")
            }
            let initResult = try QuickJSON.decode(InitializeResult.self, from: QuickJSON.encode(result))
            negotiatedProtocolVersion = initResult.protocolVersion
            guard MCPServer.supportedProtocolVersions.contains(initResult.protocolVersion) else {
                throw MCPClientError.unsupportedProtocolVersion(initResult.protocolVersion)
            }
            // acknowledge: notifications/initialized is fire-and-forget.
            try? await transport.sendFrame(try QuickJSON.encode(JSONRPCNotification(method: "notifications/initialized")))
            state = .ready
        } catch {
            state = .disconnected
            try? await transport.stop()
            throw error
        }
    }

    /// Closes the connection.
    ///
    /// For a peer that understands the best-effort `shutdown` extension
    /// (stdio-style servers), the client first asks it to drain in-flight work
    /// and wind down — the common case then exits cleanly with code 0 instead
    /// of racing the ladder. Unsupported peers and timeouts fall back to the
    /// carrier's termination (subprocess: EOF on the child's stdin → grace →
    /// SIGTERM → SIGKILL, with the reap guaranteed). Finally every in-flight
    /// request fails with `connectionClosed` and the client moves to
    /// `disconnected`.
    public func close() async {
        guard state != .idle, state != .disconnected else { return }

        // cooperative shutdown first, while still .ready: the peer drains what
        // it has and ack; then EOF exits it cleanly.
        if transport.supportsCooperativeShutdown, state == .ready {
            await requestShutdown()
        }

        state = .shuttingDown
        try? await transport.stop()
        await handleTransportClosed()
    }

    /// Best-effort: asks the peer to drain and wind down.
    ///
    /// A peer that does not know the extension answers `-32601` (ignored) and a
    /// stalled peer times out (ignored) — EOF and the carrier's ladder remain
    /// the guaranteed path, so a cooperative close can never wedge the client.
    private func requestShutdown() async {
        // watchdog: bound the whole cooperative handshake, not just each leg.
        // `requestRaw` bounds its own send and response await by the same
        // timeout, but the outer gate keeps `close()` prompt even if that
        // invariant ever regresses — the ladder must never wait on the peer.
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                do {
                    _ = try await self.requestRaw(
                        method: "shutdown",
                        params: nil,
                        timeout: configuration.shutdownCooperationTimeout
                    )
                } catch {
                    // deliberately ignored: unsupported (-32601), timed out, or dropped.
                }
                once.run { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: configuration.shutdownCooperationTimeout)
                once.run { continuation.resume() }
            }
        }
    }

    /// Suspends until the connection drops (EOF or `close()`).
    ///
    /// Used by ``MCPClientService`` so a host `Service` ends its `run()` when
    /// the remote session ends.
    func waitForDisconnection() async {
        if state == .disconnected { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            disconnectContinuation = continuation
        }
    }

    // MARK: - Requests

    /// The `initialize` request parameters the client sends.
    private var initializeParams: [String: AnyCodable] {
        [
            "protocolVersion": AnyCodable(MCPServer.latestProtocolVersion),
            "capabilities": AnyCodable(["tools": [:] as [String: Any]] as [String: Any]),
            "clientInfo": AnyCodable([
                "name": configuration.clientName,
                "version": configuration.clientVersion,
            ] as [String: Any]),
        ]
    }

    /// Sends a JSON-RPC notification (fire-and-forget, no response expected).
    private func sendNotification(_ method: String) async throws {
        try await transport.sendFrame(try QuickJSON.encode(JSONRPCNotification(method: method)))
    }

    /// Sends a request and awaits its response, enforcing `timeout`.
    ///
    /// The in-flight continuation and its timeout reaper are set up BEFORE the
    /// frame is sent: a carrier that routes synchronously (the network-free
    /// `LocalClientTransport` answers inside `sendFrame`) can otherwise race
    /// the registration and have its response dropped as unknown. Registering
    /// first also means the timeout window correctly includes local tool
    /// execution time.
    private func requestRaw(
        method: String,
        params: [String: AnyCodable]?,
        timeout: Duration,
        duringHandshake: Bool = false
    ) async throws -> [UInt8] {
        guard state == .ready || (duringHandshake && state == .handshake) else {
            throw MCPClientError.notConnected
        }
        let id = JSONRPCID.int(nextID)
        nextID += 1
        let frame = try QuickJSON.encode(JSONRPCRequest(id: id, method: method, params: params))

        let responseTask = makeResponseTask(
            id: id,
            timeout: timeout,
            error: duringHandshake ? .negotiationTimeout : .callTimeout
        )
        // Task cancellation of the caller aborts the call: from the send on,
        // the in-flight entry and the response await are covered, the peer is
        // told its invocation is no longer awaited, and a pre-cancelled
        // caller never transmits at all. The registered entry and the
        // response await race through the actor's in-flight table
        // (removeValue is exclusive), so a late reply, a timeout, or a
        // concurrent cancel are all exactly-once.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                // the send carries the same deadline as the response: a peer
                // that stops draining its pipe cannot wedge the caller — or,
                // because a request runs on the actor, every later request —
                // past the deadline.
                try await sendFrameWithDeadline(frame, timeout: timeout)
            } catch {
                await handleFailedSend(error)
                throw error
            }
            try Task.checkCancellation()
            return try await responseTask.value
        } onCancel: {
            responseTask.cancel()
            Task { await self.cancelInFlight(id) }
        }
    }

    /// Creates the in-flight waiter for `id` and its deadline reaper.
    ///
    /// The response path (the read loop resuming the in-flight entry) and the
    /// timeout reaper are two unstructured tasks competing through the actor's
    /// in-flight table (`removeValue` is exclusive): exactly one of them
    /// resolves the continuation, so a late reply after a timeout finds no
    /// entry and is dropped — never a double-resume or a leaked continuation.
    /// The reaper is deliberately a plain `Task`, not a task-group child:
    /// group-child scheduling proved unreliable in strict-concurrency builds
    /// on this toolchain, while unstructured `Task`s are consistent.
    private func makeResponseTask(id: JSONRPCID, timeout: Duration, error: MCPClientError) -> Task<[UInt8], Error> {
        Task { [self] () -> [UInt8] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                Task {
                    await self.recordInFlight(id, continuation: continuation)
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    await self.expireInFlight(id, error: error)
                }
            }
        }
    }

    /// Sends one frame to the carrier, bounded by `timeout`.
    ///
    /// The carriers' `sendFrame` contract is write-to-completion with real
    /// backpressure: a peer that stops draining its pipe (a wedged event
    /// loop, a stopped process, a deadlocked plugin) fills the pipe and the
    /// write never completes — with no bound, such a peer would hang the
    /// caller, and every later request with it, past every configured
    /// deadline. The send and a deadline reaper race a `ResumeOnce`, so
    /// exactly one outcome is reported and a frame whose write completes
    /// after the deadline is dropped rather than double-resuming. Mirrors
    /// `makeResponseTask`; the same rationale against task groups applies.
    private func sendFrameWithDeadline(_ frame: [UInt8], timeout: Duration) async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { [transport, frame] in
                do {
                    try await transport.sendFrame(frame)
                    once.run { continuation.resume() }
                } catch {
                    once.run { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.run { continuation.resume(throwing: MCPClientError.callTimeout) }
            }
        }
    }

    /// Ends the session after a request whose frame could not be delivered.
    ///
    /// A `callTimeout` here means the peer stopped draining entirely — the
    /// connection is wedged, not slow — so it is torn down (every in-flight
    /// request fails, the client disconnects, the carrier's termination runs)
    /// rather than left as a zombie that would fail every future request the
    /// same way after another full timeout. The carrier's `stop()` matters:
    /// `close()` skips its stop when the client is already `disconnected`, so
    /// without it a wedged subprocess child would never be reclaimed. Other
    /// send errors (`connectionClosed`, `notConnected`) already describe a
    /// gone peer and conclude with the same idempotent teardown.
    private func handleFailedSend(_ error: Error) async {
        await handleTransportClosed()
        try? await transport.stop()
    }

    private func recordInFlight(_ id: JSONRPCID, continuation: CheckedContinuation<[UInt8], Error>) async {
        inFlight[id] = InFlight(continuation: continuation)
    }

    private func expireInFlight(_ id: JSONRPCID, error: MCPClientError) async {
        guard let entry = inFlight.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: error)
        // Best-effort cancellation signal: tell the server its in-flight
        // invocation for this request id is no longer awaited, so it can stop
        // at its next cooperative suspend point instead of running on with
        // the caller's identity after the caller moved on. Ignored on failure
        // (the connection may already be gone) and never delays the timeout
        // report above.
        guard error == .callTimeout else { return }
        await sendCancelledNotification(id)
    }

    /// Cancels an in-flight request: resolves its waiter with
    /// `CancellationError` and best-effort notifies the peer.
    ///
    /// Wired to task cancellation of the caller via
    /// `withTaskCancellationHandler`. Mirrors ``expireInFlight`` — the
    /// `removeValue` gate is the exclusive exactly-once arbitration across the
    /// response path, the timeout reaper, transport close, and here.
    private func cancelInFlight(_ id: JSONRPCID) async {
        guard let entry = inFlight.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: CancellationError())
        await sendCancelledNotification(id)
    }

    /// Sends a best-effort `notifications/cancelled` for a request id the
    /// client no longer awaits. Ignored on failure (the connection may already
    /// be gone) and never delays the caller's resolution.
    private func sendCancelledNotification(_ id: JSONRPCID) async {
        let frame = try? QuickJSON.encode(JSONRPCNotification(
            method: "notifications/cancelled",
            params: ["requestId": AnyCodable(id.wireValue)]
        ))
        if let frame {
            // bounded: the best-effort cancel must never wedge its own path —
            // the peer just abandoned for not draining will not take this
            // frame either.
            _ = try? await sendFrameWithDeadline(frame, timeout: .seconds(1))
        }
    }

    // MARK: - Inbound routing

    /// Routes one frame from the carrier.
    private func handleIncoming(_ frame: [UInt8]) async {
        guard let object = try? QuickJSON.decode([String: AnyCodable].self, from: frame) else {
            return
        }
        guard let idValue = object["id"] else {
            // Notification. A tools/list_changed invalidates the remote
            // catalog — catalogs are rebuilt, never trusted from memory.
            if let method = object["method"]?.value as? String, method == "notifications/tools/list_changed" {
                catalog = [:]
                configuration.catalogInvalidated?()
            }
            return
        }
        guard let id = try? QuickJSON.decode(JSONRPCID.self, from: QuickJSON.encode(AnyCodable(idValue.value))) else {
            return
        }
        guard let entry = inFlight.removeValue(forKey: id) else { return }
        entry.continuation.resume(returning: frame)
    }

    /// The peer's frame stream ended (EOF or stop): fail every in-flight
    /// request and mark the client disconnected.
    private func handleTransportClosed() async {
        guard state != .disconnected else { return }
        state = .disconnected
        // A size-cap teardown is distinguishable from a crash: the carrier
        // recorded the cap when its inbound codec rejected the oversized
        // frame, so callers see "result too large" instead of a generic
        // closed connection. The session is still dead either way.
        let error: MCPClientError
        if let limit = transport.sizeCapViolation {
            error = .messageTooLarge(limit)
        } else {
            error = .connectionClosed
        }
        for (_, entry) in inFlight {
            entry.continuation.resume(throwing: error)
        }
        inFlight.removeAll()
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }

    // MARK: - Decoding

    /// Decodes a response object, throwing `remoteError` for JSON-RPC errors.
    private func decodeSuccessObject(_ frame: [UInt8]) throws -> [String: AnyCodable] {
        guard let object = try? QuickJSON.decode([String: AnyCodable].self, from: frame) else {
            throw MCPClientError.invalidResponse("response is not a JSON object")
        }
        if let error = object["error"] {
            let details = error.value as? [String: Any]
            throw MCPClientError.remoteError(
                code: details?["code"] as? Int ?? 0,
                message: details?["message"] as? String ?? "remote error"
            )
        }
        return object
    }

    /// Decodes a response's `result` into a decodable type (encode-hop pattern:
    /// re-encode the AnyCodable result, then decode it precisely).
    private func decodeResult<T: Decodable>(_ type: T.Type, from object: [String: AnyCodable]) throws -> T {
        guard let result = object["result"] else {
            throw MCPClientError.invalidResponse("result missing")
        }
        do {
            return try QuickJSON.decode(type, from: QuickJSON.encode(result))
        } catch {
            throw MCPClientError.invalidResponse(String(describing: error))
        }
    }

    // MARK: - Public protocol surface

    /// Fetches the remote tool catalog.
    ///
    /// The result is cached on the client and invalidated by a
    /// `notifications/tools/list_changed` notification.
    public func listTools() async throws -> [RemoteToolDescriptor] {
        let response = try await requestRaw(method: "tools/list", params: nil, timeout: configuration.callTimeout)
        let object = try decodeSuccessObject(response)
        let envelope = try decodeResult(ToolsListEnvelope.self, from: object)
        let descriptors = envelope.tools.map {
            RemoteToolDescriptor(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
        }
        // last-wins, never traps: a server advertising duplicate tool names is
        // server-controlled data and must not crash the client.
        var catalog: [String: RemoteToolDescriptor] = [:]
        for descriptor in descriptors {
            catalog[descriptor.name] = descriptor
        }
        self.catalog = catalog
        return descriptors
    }

    /// The cached remote catalog (empty until the first `listTools()`).
    public func remoteCatalog() -> [String: RemoteToolDescriptor] {
        catalog
    }

    /// Invokes a remote tool.
    ///
    /// A tool-level failure (the server reports `isError: true`) is returned as
    /// an ``MCPToolResult`` with `isError` set; a JSON-RPC-level error throws
    /// ``MCPClientError/remoteError(code:message:)``.
    ///
    /// - Parameters:
    ///   - name: The remote tool name.
    ///   - arguments: The tool's arguments.
    /// - Returns: The tool result.
    public func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let params: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "arguments": AnyCodable(arguments),
        ]
        let response = try await requestRaw(method: "tools/call", params: params, timeout: configuration.callTimeout)
        let object = try decodeSuccessObject(response)
        let envelope = try decodeResult(ToolCallEnvelope.self, from: object)
        return MCPToolResult(content: envelope.content, isError: envelope.isError)
    }

    /// Pings the server (a health check that requires a reply).
    public func ping() async throws {
        _ = try await requestRaw(method: "ping", params: nil, timeout: configuration.callTimeout)
    }
}

/// Decodable shape for the `tools/list` result payload.
private struct ToolsListEnvelope: Decodable, Sendable {
    let tools: [MCPToolDefinition]
}

/// Decodable shape for the `tools/call` result payload.
private struct ToolCallEnvelope: Decodable, Sendable {
    let content: [MCPContent]
    let isError: Bool
}
