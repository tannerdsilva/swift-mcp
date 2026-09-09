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
/// — a stuck peer can never hang the caller.
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
        /// The `clientInfo.name` sent during `initialize`.
        public var clientName: String = "mcp-swift-client"
        /// The `clientInfo.version` sent during `initialize`.
        public var clientVersion: String = "1.0.0"

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
    /// Runs the carrier's shutdown ladder (subprocess: EOF on the child's
    /// stdin → grace → SIGTERM → SIGKILL, with the reap guaranteed), fails
    /// every in-flight request with `connectionClosed`, and moves the client
    /// to `disconnected`.
    public func close() async {
        guard state != .idle, state != .disconnected else { return }
        state = .shuttingDown
        try? await transport.stop()
        await handleTransportClosed()
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

        let responseTask = makeResponseTask(id: id, timeout: timeout)
        try await transport.sendFrame(frame)
        return try await responseTask.value
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
    private func makeResponseTask(id: JSONRPCID, timeout: Duration) -> Task<[UInt8], Error> {
        Task { [self] () -> [UInt8] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                Task {
                    await self.recordInFlight(id, continuation: continuation)
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    await self.expireInFlight(id)
                }
            }
        }
    }

    private func recordInFlight(_ id: JSONRPCID, continuation: CheckedContinuation<[UInt8], Error>) async {
        inFlight[id] = InFlight(continuation: continuation)
    }

    private func expireInFlight(_ id: JSONRPCID) async {
        guard let entry = inFlight.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: MCPClientError.callTimeout)
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
        for (_, entry) in inFlight {
            entry.continuation.resume(throwing: MCPClientError.connectionClosed)
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
