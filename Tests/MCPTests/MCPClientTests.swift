import Testing
import Foundation
@testable import MCP
import QuickJSON
import NIOCore
import NIOPosix
import SwiftSlash
import Synchronization

@Suite(.serialized)
struct MCPClientTests {


// MARK: - Fixture location

/// Locates the built `MCPFixtureServer` binary.
///
/// `swift build` must have run first (the test target does not build the
/// executable itself). Resolved relative to this file, so the suite works from
/// any checkout.
func fixtureServerPath() throws -> String {
    let source = URL(fileURLWithPath: #filePath)
    let repoRoot = source
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        repoRoot.appendingPathComponent(".build/debug/MCPFixtureServer"),
        repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/MCPFixtureServer"),
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path.path) {
        return path.path
    }
    throw MCPClientError.spawnFailed("MCPFixtureServer binary not found; run `swift build` first")
}

// MARK: - Timing helpers

enum RaceOutcome: Sendable, Equatable {
    case completed
    case timedOut
}

/// Resolves a continuation exactly once across racing tasks.
///
/// (The framework uses the same shape in `ResumeOnce`; tests are public-API
/// only, so this mirrors it locally.)
private final class TestOnce: @unchecked Sendable {
    private let lock = Mutex<Bool>(false)

    func run(_ body: @escaping @Sendable () -> Void) {
        let first = lock.withLock { (used: inout Bool) -> Bool in
            if used {
                return false
            }
            used = true
            return true
        }
        if first {
            body()
        }
    }
}

/// Runs the operation and reports whether it finished before `bound` (its
/// result — success or throw — is asserted by the caller's own expectations).
///
/// Deliberately not a task group: group-child scheduling proved unreliable in
/// strict-concurrency builds on this toolchain, while plain unstructured
/// `Task`s are consistent.
func within(
    _ bound: Duration,
    _ operation: @escaping @Sendable () async throws -> Void
) async -> RaceOutcome {
    await withCheckedContinuation { (continuation: CheckedContinuation<RaceOutcome, Never>) in
        let once = TestOnce()
        Task {
            try? await operation()
            once.run { continuation.resume(returning: .completed) }
        }
        Task {
            try? await Task.sleep(for: bound)
            once.run { continuation.resume(returning: .timedOut) }
        }
    }
}

/// Structural JSON equality: dictionaries compare as key sets, arrays compare
/// in order, scalars by value (with cross Int/Double coercion). JSON object
/// key order is not significant, so two semantically-equal documents compare
/// equal regardless of encoding order.
private func jsonValueEquals(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case let (x as String, y as String): return x == y
    case let (x as Bool, y as Bool): return x == y
    case let (x as Int, y as Int): return x == y
    case let (x as Int, y as Double): return Double(x) == y
    case let (x as Double, y as Int): return x == Double(y)
    case let (x as Double, y as Double): return x == y
    case let (x as [Any], y as [Any]):
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { jsonValueEquals($0, $1) }
    case let (x as [String: Any], y as [String: Any]):
        guard x.count == y.count else { return false }
        return x.allSatisfy { key, value in
            guard let other = y[key] else { return false }
            return jsonValueEquals(value, other)
        }
    default:
        return false
    }
}

/// Decodes JSON bytes into the value tree used by `jsonValueEquals`.
private func decodedJSONValue(_ bytes: [UInt8]) -> Any? {
    (try? QuickJSON.decode(AnyCodable.self, from: bytes))?.value
}

// MARK: - Client round trip

// The Phase 2/3 third-party controls are run manually against a local venv
// (cwd=/tmp/mcp-interop; `pip install mcp`; control_server.py spawns
// `mcp.server.mcpserver.MCPServer` over stdio). Not committed because the venv
// path is machine-local. Both directions verified green after the Sep 2026
// adversarial + stdio-parity cycles: SDK client → fixture server, and our
// client → SDK server (including the cooperative-close `-32601` fallback).

@Test("MCPClient round-trips initialize/list/call over a spawned server")
func clientRoundTripOverSubprocess() async throws {
    let transport = SubprocessClientTransport(configuration: .init(executable: try fixtureServerPath()))
    let client = MCPClient(transport: transport)

    #expect(await client.currentState() == .idle)
    try await client.connect()
    #expect(await client.currentState() == .ready)
    #expect(await client.negotiatedVersion() == "2025-11-25")

    let tools = try await client.listTools()
    #expect(tools.map(\.name) == ["echo", "add", "slow", "big", "envget", "admin"])
    if let error = tools.first(where: { $0.name == "echo" })?.description {
        #expect(error == "Echo a message back verbatim")
    }

    // the catalog is cached after listTools
    #expect(await client.remoteCatalog()["add"]?.name == "add")

    let echo = try await client.callTool("echo", arguments: ["message": "hi"])
    #expect(!echo.isError)
    guard case .text(let echoed) = echo.content.first else {
        Issue.record("expected text content, got \(echo.content)")
        return
    }
    #expect(echoed == "hi")

    let sum = try await client.callTool("add", arguments: ["a": 2, "b": 3])
    guard case .text(let sumText) = sum.content.first else {
        Issue.record("expected text content, got \(sum.content)")
        return
    }
    #expect(sumText == "5")

    try await client.ping()

    await client.close()
    #expect(await client.currentState() == .disconnected)

    // requests after close fail with notConnected
    await #expect(throws: MCPClientError.notConnected) {
        _ = try await client.listTools()
    }
}

// MARK: - Timeouts

@Test("MCPClient enforces the per-call timeout against a stuck tool")
func clientCallTimeout() async throws {
    var configuration = MCPClient.ClientConfiguration()
    configuration.callTimeout = .seconds(1)
    let transport = SubprocessClientTransport(configuration: .init(executable: try fixtureServerPath()))
    let client = MCPClient(transport: transport, configuration: configuration)

    try await client.connect()
    _ = try await client.listTools()

    let started = ContinuousClock.now
    await #expect(throws: MCPClientError.callTimeout) {
        _ = try await client.callTool("slow", arguments: ["seconds": 30.0])
    }
    #expect(ContinuousClock.now - started < .seconds(5))

    // The timed-out call must have sent `notifications/cancelled`, and the
    // child's in-flight `slow` tool must have observed it (the sleep throws and
    // the fixture writes an observable marker to stderr) — the cancellation lie
    // is closed: the child does NOT keep running a timed-out tool.
    let cancellationSeen = await within(.seconds(10)) {
        while !transport.stderrTailSnapshot().contains(where: { $0.contains("fixture slow-cancelled") }) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    #expect(cancellationSeen == .completed)

    // close() still runs the full ladder even though the tool is in flight.
    let closed = await within(.seconds(15)) {
        await client.close()
    }
    #expect(closed == .completed)
}

// MARK: - Mid-call kill

@Test("MCPClient fails in-flight calls cleanly when the server dies mid-call")
func clientMidCallKillFailsClean() async throws {
    let transport = SubprocessClientTransport(
        configuration: .init(executable: try fixtureServerPath(), shutdownGrace: .seconds(1))
    )
    let client = MCPClient(transport: transport)

    try await client.connect()
    _ = try await client.listTools()

    let call = Task {
        try await client.callTool("slow", arguments: ["seconds": 60.0])
    }
    try await Task.sleep(for: .milliseconds(500))

    let started = ContinuousClock.now
    await client.close()
    // the in-flight call must fail promptly (EOF → connectionClosed), not hang.
    await #expect(throws: (any Error).self) {
        _ = try await call.value
    }
    #expect(ContinuousClock.now - started < .seconds(12))
    #expect(await client.currentState() == .disconnected)
}

// MARK: - Oversize frames

@Test("MCPClient closes the connection on an oversized inbound frame")
func clientOversizeFrameCloses() async throws {
    // the client-side cap: the fixture's initialize response (~160 bytes)
    // exceeds 128 bytes, so the codec rejects it and the connection closes
    // during the handshake — and the in-flight call must fail with a
    // size-specific error, not a generic "connection closed".
    let transport = SubprocessClientTransport(
        configuration: .init(executable: try fixtureServerPath(), maxMessageSize: 128)
    )
    let client = MCPClient(transport: transport)

    await #expect(throws: MCPClientError.messageTooLarge(128)) {
        try await client.connect()
    }
    #expect(await client.currentState() == .disconnected)
}

@Test("MCPClient reports a size-specific error when a tool result exceeds the cap")
func clientMessageTooLargeToolCall() async throws {
    // cap the client at 1 KiB; the fixture's `big` tool returns 5000 chars
    // (~5 KiB), so the response frame is rejected and the CALL fails with
    // messageTooLarge — distinguishable from a crash.
    let transport = SubprocessClientTransport(
        configuration: .init(executable: try fixtureServerPath(), maxMessageSize: 1024)
    )
    var clientConfig = MCPClient.ClientConfiguration()
    clientConfig.callTimeout = .seconds(10)
    let client = MCPClient(transport: transport, configuration: clientConfig)

    try await client.connect()
    // (no listTools: the 6-tool catalog itself would exceed the 1 KiB cap and
    // fail there first — the tool RESULT is what must trip it.)

    await #expect(throws: MCPClientError.messageTooLarge(1024)) {
        _ = try await client.callTool("big", arguments: ["count": 5000])
    }
    #expect(await client.currentState() == .disconnected)
}

@Test("MCPClient surfaces negotiationTimeout, not callTimeout, for a silent peer")
func clientNegotiationTimeoutIsLabeled() async throws {
    // a raw NIO acceptor that accepts the connection and then says nothing:
    // the handshake must fail with the handshake-specific error.
    let group = MultiThreadedEventLoopGroup.singleton
    let acceptorChannel = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 1)
        .childChannelInitializer { _ in group.next().makeSucceededVoidFuture() }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    defer { Task { try? await acceptorChannel.close() } }
    guard let port = acceptorChannel.localAddress?.port else {
        Issue.record("acceptor bound without a port")
        return
    }

    var configuration = MCPClient.ClientConfiguration()
    configuration.negotiationTimeout = .seconds(2)
    let transport = TCPClientTransport(configuration: .init(address: .hostname("127.0.0.1", port: port)))
    let client = MCPClient(transport: transport, configuration: configuration)

    let started = ContinuousClock.now
    await #expect(throws: MCPClientError.negotiationTimeout) {
        try await client.connect()
    }
    #expect(ContinuousClock.now - started < .seconds(6))
}

@Test("MCPClient spawns the child with the parent environment inherited")
func clientInheritsParentEnvironment() async throws {
    // the fixture reports child env values back over a tool; a variable the
    // test sets in ITS environment must be visible in the child by default.
    setenv("MCP_TEST_INHERITED_VAR", "hello-inherited", 1)
    defer { unsetenv("MCP_TEST_INHERITED_VAR") }

    let transport = SubprocessClientTransport(configuration: .init(executable: try fixtureServerPath()))
    let client = MCPClient(transport: transport)
    try await client.connect()
    _ = try await client.listTools()

    let result = try await client.callTool("envget", arguments: ["key": "MCP_TEST_INHERITED_VAR"])
    #expect(result.flattenedText == "hello-inherited")
    await client.close()
}

@Test("MCPClient scrubs the child environment when inheritance is disabled")
func clientScrubbedEnvironmentWhenDisabled() async throws {
    setenv("MCP_TEST_SCRUB_VAR", "should-not-leak", 1)
    defer { unsetenv("MCP_TEST_SCRUB_VAR") }

    // no inheritance + one explicit var: PATH and the leaky var must both be
    // absent from the child (the env dict is the child's COMPLETE envp).
    let transport = SubprocessClientTransport(
        configuration: .init(
            executable: try fixtureServerPath(),
            environment: ["MCP_TEST_SCRUB_VAR": "explicit-value"],
            inheritParentEnvironment: false
        )
    )
    let client = MCPClient(transport: transport)
    try await client.connect()
    _ = try await client.listTools()

    let leaked = try await client.callTool("envget", arguments: ["key": "MCP_TEST_SCRUB_VAR"])
    #expect(leaked.flattenedText == "explicit-value")
    let path = try await client.callTool("envget", arguments: ["key": "PATH"])
    #expect(path.flattenedText == "(unset)")
    await client.close()
}

/// A canned-frame carrier: yields a fixed frame sequence (paced) and then
/// ends, driving the client's read loop through its public surface in-process
/// without any real connection.
private final class CannedTransport: ClientTransport, @unchecked Sendable {
    private let frameStream = ClientFrames()
    private let payloads: [[UInt8]]
    private let delay: Duration

    init(payloads: [[UInt8]], delay: Duration = .milliseconds(50)) {
        self.payloads = payloads
        self.delay = delay
    }

    nonisolated func frames() -> ClientFrameSequence {
        frameStream.sequence
    }

    var supportsCooperativeShutdown: Bool { false }

    func start() async throws {
        let source = frameStream.source
        let payloads = self.payloads
        let delay = self.delay
        Task {
            for payload in payloads {
                try? await Task.sleep(for: delay)
                _ = source.yield(contentsOf: [payload])
            }
            source.finish()
        }
    }

    func sendFrame(_ bytes: [UInt8]) async throws {
        // requests are answered by the canned payloads; nothing to write.
    }

    func stop() async throws {
        frameStream.source.finish()
    }
}

@Test("MCPClient invalidates the catalog and fires the hook on list_changed")
func clientListChangedFiresCatalogHook() async throws {
    let flag = Mutex<Bool>(false)
    var configuration = MCPClient.ClientConfiguration()
    configuration.catalogInvalidated = { flag.withLock { $0 = true } }

    // canned sequence: initialize response (id 0) → tools/list response (id 1)
    // → list_changed notification → EOF
    let initFrame = Array(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"canned","version":"1.0.0"}}}"#.utf8)
    let catalogFrame = Array(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"one","description":"d","inputSchema":{"type":"object","properties":{}}}]}}"#.utf8)
    let listChanged = Array(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)

    let transport = CannedTransport(payloads: [initFrame, catalogFrame, listChanged])
    let client = MCPClient(transport: transport, configuration: configuration)

    try await client.connect()
    _ = try await client.listTools()
    #expect(await client.remoteCatalog().count == 1)

    let fired = await within(.seconds(5)) {
        while !flag.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    #expect(fired == .completed)
    #expect(await client.remoteCatalog().count == 0)
}

// MARK: - TCP client carrier

/// Polls the server's ephemeral bound port (group-free, see `within` note).
private func waitForServerPort(_ server: MCPServer) async throws -> Int {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if let port = server.boundPort {
            return port
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw MCPClientError.connectionFailed("server did not expose a bound port")
}

@Test("MCPClient round-trips over a TCP client/server pair (ephemeral port)")
func tcpClientRoundTripOverNetwork() async throws {
    let server = MCPServer(name: "tcp-test", version: "1.0.0", address: .hostname("127.0.0.1", port: 0)) {
        Greet()
    }
    let serverTask = Task { try? await server.runService() }
    defer {
        // best-effort teardown even on assertion failure; safe to stop twice.
        Task { try? await server.stop() }
    }

    let port = try await waitForServerPort(server)
    let transport = TCPClientTransport(configuration: .init(address: .hostname("127.0.0.1", port: port)))
    let client = MCPClient(transport: transport)

    try await client.connect()
    #expect(await client.negotiatedVersion() == "2025-11-25")
    // the socket round trip carries a real peer address on the transport.
    #expect(transport.remoteAddress != nil)

    let tools = try await client.listTools()
    #expect(tools.map(\.name) == ["greet"])

    let result = try await client.callTool("greet", arguments: ["name": "TCP"])
    guard case .text(let text) = result.content.first else {
        Issue.record("expected text content, got \(result.content)")
        return
    }
    #expect(text == "Hello, TCP!")

    await client.close()
    #expect(await client.currentState() == .disconnected)

    try await server.stop()
    _ = await serverTask.value
}

@Test("MCPClient round-trips over a TCP Unix-domain socket")
func tcpClientRoundTripOverUnixSocket() async throws {
    let socketPath = "/tmp/mcp-client-test-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    let server = MCPServer(name: "uds-test", version: "1.0.0", address: .unixDomainSocket(path: socketPath)) {
        Greet()
    }
    let serverTask = Task { try? await server.runService() }
    defer {
        Task { try? await server.stop() }
    }

    try await Task.sleep(for: .milliseconds(300))  // let the listener bind
    let transport = TCPClientTransport(configuration: .init(address: .unixDomainSocket(path: socketPath)))
    let client = MCPClient(transport: transport)

    try await client.connect()
    let result = try await client.callTool("greet", arguments: ["name": "UDS"])
    guard case .text(let text) = result.content.first else {
        Issue.record("expected text content, got \(result.content)")
        return
    }
    #expect(text == "Hello, UDS!")

    await client.close()
    try await server.stop()
    _ = await serverTask.value
}

@Test("MCPClient reports a connection failure when nothing is listening")
func tcpClientConnectFailure() async throws {
    // bind a listener to find a free port, then close it — nothing listening.
    let probe = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { $0.pipeline.addHandler(EchoIgnoreHandler()) }
    let probeChannel = try await probe.bind(host: "127.0.0.1", port: 0).get()
    let port = probeChannel.localAddress!.port!
    try await probeChannel.close()

    let transport = TCPClientTransport(
        configuration: .init(address: .hostname("127.0.0.1", port: port), connectTimeout: .seconds(3))
    )
    let client = MCPClient(transport: transport)
    await #expect(throws: MCPClientError.self) {
        try await client.connect()
    }
    #expect(await client.currentState() == .disconnected)
}

/// Minimal no-op channel handler for the connect-failure probe listener.
private final class EchoIgnoreHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
}

// MARK: - Local (network-free) client carrier

/// A hand-written `MCPToolDispatcher` exercising the same surface the
/// `@MCPApplication` macro generates: a compile-time catalog, access gates,
/// and typed dispatch — here over the macro-built `Greet` tool plus a slow
/// probe.
struct LocalAppDispatcher: MCPToolDispatcher {
    func toolCatalog(for callerAccessLevel: AccessLevel) -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(name: "greet", description: "Greet someone by name", parameters: Greet.discoverParameters()),
            MCPToolDescriptor(name: "slow", description: "Sleep and return", parameters: []),
        ]
    }

    func requiredAccess(named name: String) -> AccessLevel? {
        name == "greet" || name == "slow" ? .public : nil
    }

    func callTool(named name: String, arguments: [String: Any], context: MCPContext) async throws -> MCPToolResult? {
        switch name {
        case "greet":
            var tool = Greet()
            try tool.apply(arguments: arguments)
            return try await tool.invoke(context: context)
        case "slow":
            // long enough that a short client deadline must fire first.
            try await Task.sleep(for: .seconds(30))
            return .text("done")
        default:
            return nil
        }
    }
}

@Test("MCPClient round-trips over the network-free local carrier")
func localClientFullRoundTrip() async throws {
    let transport = LocalClientTransport(dispatcher: LocalAppDispatcher())
    let client = MCPClient(transport: transport)

    #expect(await client.currentState() == .idle)
    try await client.connect()   // no process, no socket — pure in-process router
    #expect(await client.currentState() == .ready)
    #expect(await client.negotiatedVersion() == "2025-11-25")

    let tools = try await client.listTools()
    #expect(tools.map(\.name) == ["greet", "slow"])
    #expect(await client.remoteCatalog()["greet"]?.description == "Greet someone by name")

    let result = try await client.callTool("greet", arguments: ["name": "Local"])
    guard case .text(let text) = result.content.first else {
        Issue.record("expected text content, got \(result.content)")
        return
    }
    #expect(text == "Hello, Local!")

    await client.close()
    #expect(await client.currentState() == .disconnected)
    await #expect(throws: MCPClientError.notConnected) {
        _ = try await client.listTools()
    }
}

@Test("Local and TCP carriers produce byte-identical catalogs for the same dispatcher")
func localVsTCPByteIdenticalCatalog() async throws {
    let dispatcher = LocalAppDispatcher()

    // local (network-free) binding — same dispatcher the server uses.
    let localClient = MCPClient(transport: LocalClientTransport(dispatcher: dispatcher))
    try await localClient.connect()
    _ = try await localClient.listTools()

    // TCP binding — the routed server with the SAME dispatcher attached.
    let server = MCPServer(
        name: "local-echo", version: "1.0.0",
        address: .hostname("127.0.0.1", port: 0),
        dispatcher: dispatcher
    )
    let serverTask = Task { try? await server.runService() }
    defer {
        Task { try? await server.stop() }
    }
    let port = try await waitForServerPort(server)
    let tcpClient = MCPClient(
        transport: TCPClientTransport(configuration: .init(address: .hostname("127.0.0.1", port: port)))
    )
    try await tcpClient.connect()
    _ = try await tcpClient.listTools()

    let localCatalog = await localClient.remoteCatalog()
    let tcpCatalog = await tcpClient.remoteCatalog()

    #expect(localCatalog.map(\.key).sorted() == tcpCatalog.map(\.key).sorted())
    for name in localCatalog.keys.sorted() {
        let local = localCatalog[name], tcp = tcpCatalog[name]
        #expect(local?.description == tcp?.description)
        // the JSON Schema must be semantically identical across carriers
        // (JSON object key order is not significant).
        let localSchema = (try? QuickJSON.encode(local?.inputSchema ?? [:])) ?? []
        let tcpSchema = (try? QuickJSON.encode(tcp?.inputSchema ?? [:])) ?? []
        #expect(jsonValueEquals(decodedJSONValue(localSchema) ?? [], decodedJSONValue(tcpSchema) ?? []))
    }

    await localClient.close()
    await tcpClient.close()
    try await server.stop()
    _ = await serverTask.value
}

@Test("MCPClient enforces the call deadline with no process (local slow tool)")
func localClientCallTimeout() async throws {
    var configuration = MCPClient.ClientConfiguration()
    configuration.callTimeout = .milliseconds(500)

    let transport = LocalClientTransport(dispatcher: LocalAppDispatcher())
    let client = MCPClient(transport: transport, configuration: configuration)

    try await client.connect()
    _ = try await client.listTools()

    let started = ContinuousClock.now
    await #expect(throws: MCPClientError.callTimeout) {
        _ = try await client.callTool("slow", arguments: [:])
    }
    #expect(ContinuousClock.now - started < .seconds(5))

    await client.close()
}

/// A dispatcher whose `slow` tool records whether it observed cancellation, so
/// the in-process cancellation chain can be asserted end-to-end.
private final class CancellationProbe: @unchecked Sendable {
    let cancelled = Mutex<Bool>(false)
}

private struct CancellationRecordingDispatcher: MCPToolDispatcher {
    let probe = CancellationProbe()

    func toolCatalog(for callerAccessLevel: AccessLevel) -> [MCPToolDescriptor] {
        [MCPToolDescriptor(name: "slow", description: "Sleep and record cancellation", parameters: [])]
    }

    func requiredAccess(named name: String) -> AccessLevel? {
        .public
    }

    func callTool(named name: String, arguments: [String: Any], context: MCPContext) async throws -> MCPToolResult? {
        do {
            try await Task.sleep(for: .seconds(60))
            return .text("done")
        } catch is CancellationError {
            probe.cancelled.withLock { $0 = true }
            throw CancellationError()
        }
    }
}

@Test("MCPClient's timed-out call cancels the in-process tool invocation")
func localTimedOutCallCancelsTool() async throws {
    let dispatcher = CancellationRecordingDispatcher()
    var configuration = MCPClient.ClientConfiguration()
    configuration.callTimeout = .milliseconds(500)

    let transport = LocalClientTransport(dispatcher: dispatcher)
    let client = MCPClient(transport: transport, configuration: configuration)

    try await client.connect()
    _ = try await client.listTools()

    await #expect(throws: MCPClientError.callTimeout) {
        _ = try await client.callTool("slow", arguments: [:])
    }

    // the timed-out call must have emitted notifications/cancelled; the local
    // carrier routes it into the router, which cancels the in-flight
    // invocation task — observable as the tool's CancellationError catch.
    let seen = await within(.seconds(5)) {
        while !dispatcher.probe.cancelled.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    #expect(seen == .completed)

    await client.close()
}

// MARK: - Transport lifecycle (ladder + processes)

@Test("Subprocess transport closes cooperatively and the child exits cleanly")
func subprocessCooperativeShutdownExitsCleanly() async throws {
    let transport = SubprocessClientTransport(configuration: .init(executable: try fixtureServerPath()))
    let client = MCPClient(transport: transport)
    try await client.connect()
    _ = try await client.listTools()

    // the cooperative `shutdown` extension: the fixture drains (nothing in
    // flight) and acks; the child then exits cleanly on EOF. the child exit
    // code is 0 and the whole close is far under the signal-ladder grace —
    // proving no escalation happened.
    let started = ContinuousClock.now
    await client.close()
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .milliseconds(1500))
    guard case .code(let code)? = transport.childExit else {
        Issue.record("expected code-0 exit, got \(String(describing: transport.childExit))")
        return
    }
    #expect(code == 0)
}

@Test("Subprocess plugin access gates are driven by the declared trust level")
func subprocessAccessGateFromTrustLevel() async throws {
    // the harness declares the plugin's trust; the child's server honors it
    // (identical gates a networked caller gets). trust .public must hide and
    // deny the fixture's admin tool; .admin must expose and allow it. the env
    // is scoped to the child — no process-global mutation, parallel-safe.
    let publicTransport = SubprocessClientTransport(
        configuration: .init(executable: try fixtureServerPath(), trustLevel: .public)
    )
    let publicClient = MCPClient(transport: publicTransport)
    try await publicClient.connect()
    let publicTools = try await publicClient.listTools()
    #expect(!publicTools.contains { $0.name == "admin" })
    await #expect(throws: MCPClientError.self) {
        _ = try await publicClient.callTool("admin", arguments: [:])
    }
    await publicClient.close()

    let adminTransport = SubprocessClientTransport(
        configuration: .init(
            executable: try fixtureServerPath(),
            trustLevel: .admin,
            callerIdentity: "harness"
        )
    )
    let adminClient = MCPClient(transport: adminTransport)
    try await adminClient.connect()
    let adminTools = try await adminClient.listTools()
    #expect(adminTools.contains { $0.name == "admin" })
    let result = try await adminClient.callTool("admin", arguments: ["message": "x"])
    guard case .text(let text) = result.content.first else {
        Issue.record("expected text content, got \(result.content)")
        return
    }
    #expect(text == "admin:x")
    await adminClient.close()
}

@Test("Subprocess transport streams live stderr lines via the built-in pipeline")
func subprocessStderrStreamDelivers() async throws {
    let transport = SubprocessClientTransport(
        configuration: .init(executable: "/bin/sh", arguments: ["-c", "echo live-stderr-line >&2; exit 0"])
    )
    try await transport.start()

    var iterator = transport.stderrLines().makeAsyncIterator()
    let deadline = ContinuousClock.now + .seconds(3)
    var received: String?
    while ContinuousClock.now < deadline {
        if let line = await iterator.next() {
            received = line
            break
        }
    }
    #expect(received?.contains("live-stderr-line") == true)
}

/// Counts the calling process's open file descriptors (macOS /dev/fd view).
private func openFDCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

private func waitForChildExit(_ transport: SubprocessClientTransport, within limit: Duration = .seconds(3)) async -> ChildProcess.Exit? {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if let exit = transport.childExit {
            return exit
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

@Test("Subprocess transport releases its pipe fds when the child exits on its own")
func subprocessEOFReleasesOwnedFDs() async throws {
    // regression for the EOF-path 4-fd leak: a child that exits on its own
    // (server EOF / crash — no stop() ever runs) must release the transport's
    // retained pipe ends. repeated self-exiting sessions must not grow the
    // process fd table.
    //
    // One-time warm-up: the first channel boots the NIO `MultiThreadedEventLoop
    // Group(.singleton)` (its per-loop fds appear once), which would otherwise
    // skew the baseline. Measure only the *session* cost.
    let warmup = SubprocessClientTransport(
        configuration: .init(executable: "/bin/sh", arguments: ["-c", "exit 0"])
    )
    try await warmup.start()
    _ = await waitForChildExit(warmup)

    let baseline = openFDCount()
    for _ in 0..<10 {
        let transport = SubprocessClientTransport(
            configuration: .init(executable: "/bin/sh", arguments: ["-c", "exit 0"])
        )
        try await transport.start()
        let exit = await waitForChildExit(transport)
        #expect(exit != nil)
    }
    // let the (async) channel close from childDidExit settle before counting.
    try await Task.sleep(for: .milliseconds(250))
    let after = openFDCount()
    // near-zero session cost; allow a small epsilon for global churn, but the
    // 4-per-session leak would show up as ~+40 here.
    #expect(after - baseline <= 4)
}

@Test("MCPClient survives a server that advertises duplicate tool names")
func localClientDuplicateToolNamesDoNotCrash() async throws {
    let transport = LocalClientTransport(dispatcher: DuplicateNameDispatcher())
    let client = MCPClient(transport: transport)

    try await client.connect()
    // a bad server advertises the name twice; the client must not trap.
    let tools = try await client.listTools()
    #expect(tools.map(\.name) == ["dupe", "greet", "dupe"])
    // the cached catalog is deduplicated (last wins), never a crash.
    let catalog = await client.remoteCatalog()
    #expect(catalog.keys.sorted() == ["dupe", "greet"])

    let result = try await client.callTool("greet", arguments: ["name": "D"])
    guard case .text = result.content.first else {
        Issue.record("expected text content, got \(result.content)")
        return
    }
    await client.close()
}

/// A dispatcher that (like a buggy or malicious server) lists one tool twice.
private struct DuplicateNameDispatcher: MCPToolDispatcher {
    func toolCatalog(for callerAccessLevel: AccessLevel) -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(name: "dupe", description: "first", parameters: []),
            MCPToolDescriptor(name: "greet", description: "Greet someone by name", parameters: Greet.discoverParameters()),
            MCPToolDescriptor(name: "dupe", description: "first, again", parameters: []),
        ]
    }

    func requiredAccess(named name: String) -> AccessLevel? {
        name == "dupe" || name == "greet" ? .public : nil
    }

    func callTool(named name: String, arguments: [String: Any], context: MCPContext) async throws -> MCPToolResult? {
        guard name == "greet" else { return nil }
        var tool = Greet()
        try tool.apply(arguments: arguments)
        return try await tool.invoke(context: context)
    }
}


@Test("Subprocess transport reaps a clean child exit on stdin EOF")
func subprocessCleanEOFExit() async throws {
    let transport = SubprocessClientTransport(
        configuration: .init(executable: try fixtureServerPath(), shutdownGrace: .seconds(2))
    )
    try await transport.start()
    #expect(transport.childExit == nil)

    // rung 1 (EOF) alone should let an MCP server exit cleanly with code 0.
    let stopped = await within(.seconds(10)) {
        try await transport.stop()
    }
    #expect(stopped == .completed)
    guard case .code(let code)? = transport.childExit else {
        Issue.record("expected .code exit, got \(String(describing: transport.childExit))")
        return
    }
    #expect(code == 0)
}

@Test("Subprocess transport shutdown ladder escalates TERM to KILL and reaps")
func subprocessLadderEscalatesToKill() async throws {
    // a child that ignores SIGTERM, never exits, and ignores stdin: only the
    // SIGKILL rung can end it. If the ladder hung on the ignored TERM, the
    // within-bound below would fail.
    let transport = SubprocessClientTransport(
        configuration: .init(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while true; do sleep 1; done"],
            shutdownGrace: .seconds(1)
        )
    )
    try await transport.start()

    let stopped = await within(.seconds(15)) {
        try await transport.stop()
    }
    #expect(stopped == .completed)
    guard case .signal(let code)? = transport.childExit else {
        Issue.record("expected .signal exit, got \(String(describing: transport.childExit))")
        return
    }
    #expect(code == 9)
}

@Test("Subprocess transport retains a child stderr tail for diagnostics")
func subprocessStderrTail() async throws {
    let transport = SubprocessClientTransport(
        configuration: .init(
            executable: "/bin/sh",
            arguments: ["-c", "echo diagnostics-to-stderr >&2; cat"]
        )
    )
    try await transport.start()

    // poll for the drained line (the stderr task is async).
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if transport.stderrTailSnapshot().contains(where: { $0.contains("diagnostics-to-stderr") }) {
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(transport.stderrTailSnapshot().contains(where: { $0.contains("diagnostics-to-stderr") }))

    try await transport.stop()
}
}
