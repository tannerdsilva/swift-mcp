# TRANSPORT UNIFICATION PLAN

**One NIO pipeline, deployed as TCP or as a SwiftSlash-spawned subprocess.**

- **Status:** Proposed / implementation plan — supersedes the subprocess IO mechanics of
  `INTERPROCESS_PLAN.md` §6 (which assumed SwiftSlash 4.0's built-in stream pipeline).
  The vision in that document is unchanged: MCP-by-subprocess, one annotation → three
  bindings, no new projects.
- **Enabling release:** SwiftSlash **5.0.0** "Bring Your Own Data Channels" (tagged; resolved
  and building as a dependency of this package since this plan was written).
- **Dependencies added:** exactly one — `tannerdsilva/SwiftSlash` `from: "5.0.0"`
  (dependency-free, Swift 6.0+, macOS 15+ — compatible with this package's floor).
- **Implementation status (Sep 2026):** Phases 0–4 ✅ (shared NIO core; server stdio on
  NIO pipes; MCPClient + SubprocessClientTransport via SwiftSlash v5 BYO; TCPClientTransport;
  network-free LocalClientTransport). Phase 5 ✅ (verification matrix — every meaningful
  cell green, rendered in AGENTS.md). Phase 6 ✅ (DocC rewritten/extended warning-free for
  this module; MCPClientRole + MCPBySubprocess articles; CHANGELOG 1.1.0; skill + AGENTS.md
  records current). Full suite 186 tests green. **The transport-unification plan is
  complete.**
- **Implementation lessons (all test-verified, recorded in the
  `swift-mcp-server-authoring` skill):** the `FD_CLOEXEC` inherited-write-end trap —
  every parent pipe end and NIO dup must be `FD_CLOEXEC` or the child inherits its stdin
  write end and EOF never fires; NIO does not promptly close user-provided pipe fds —
  the transport owns the stdin-write fd and closes it at ladder rung 1; `withTaskGroup`
  child scheduling is unreliable in strict-concurrency builds — timeouts use two
  unstructured `Task`s + the `ResumeOnce` Mutex gate; the frame codec size cap is
  per-frame (guarded before emitting each complete line).
- **Adversarial pass (Sep 2026, `software-skeptic`):** three real defects found and fixed —
  (A) the EOF path leaked the retained pipe fds plus the NIO channel (fixed: `childDidExit`
  releases fds, clears the process handle, and closes the channel; regression test measures
  zero per-session fd growth), (B) `start()` failure paths could hang forever (cancelling a
  plain `run()` signals nothing — fixed: `run(cancellationSignal: SIGTERM)` and the failure
  paths tear down via the `stop()` ladder instead of task cancellation) and double-closed fd
  numbers (fixed: unified teardown), (C) `stop()` racing `start()` could orphan a live child
  during the won-`runTask` publication window (fixed: child+reaper published atomically;
  `signalProcessGroup` waits briefly for `.running`; `stopRequested` aborts a racing
  `start()`), (D) flood unboundedness on the server (fixed: demand-driven reads — `autoRead`
  off, re-armed as the dispatcher queue drains, 128-frame cap → close; client `frames()`
  stays `.unbounded` deliberately — response frames must never be dropped; documented),
  and (E) a client crash on duplicate tool names (`Dictionary(uniqueKeysWithValues:)` trap —
  fixed: last-wins fold; regression test). Survived adversarial review: shared codec/router
  single-sourcing, ladder escalation+reap, CLOEXEC byte-correctness, EOF-with-inflight
  exactly-once failure, out-of-order/duplicate-response table discipline, per-frame cap.

---

## 1. The pivot, in one paragraph

The `INTERPROCESS_PLAN` designed the subprocess client around SwiftSlash 4.0's built-in
stdio pipeline: line-delimited stdout `AsyncSequence`, flush-future-backed `ParentWrite`,
`closeDataChannel()` for EOF. SwiftSlash 5.0 changes the seam: a caller can hand SwiftSlash a
**file descriptor it already owns** (`ChildRead.byo(fd:)` / `ChildWrite.byo(fd:)`); SwiftSlash
`dup2`s it onto the child and then leaves the data path entirely (never reads, writes,
registers, mutates, or closes it — reaping and cancellation stay intact). That makes the
descriptor the interchange point with SwiftNIO: swift-mcp builds **one NIO pipeline** — a
frame codec plus a JSON-RPC router — and deploys it four ways:

| role | carrier | channel |
|---|---|---|
| server | TCP listener / connection | `ServerBootstrap` socket channel (exists) |
| server | child stdio (`fd 0`/`1`) | NIO pipe channel over `dup(0)`/`dup(1)` (migration) |
| client | TCP connection | `ClientBootstrap` socket channel (new) |
| client | spawned child stdio | NIO pipe channel whose child-facing ends are handed to SwiftSlash `.byo(fd:)` (new) |

The client state machine, catalog, timeouts, and access gates are shared across every carrier;
the only difference is how frames enter and leave the process.

## 2. Why this beats the SwiftSlash-4.0 design from `INTERPROCESS_PLAN.md`

| axis | old plan (SwiftSlash 4.0 built-in streams) | this plan (v5 BYO + NIO) |
|---|---|---|
| framing | SwiftSlash line-splits stdout; client trusts it | `MCPFrameCodec` does newline framing on every channel — one implementation, server and client |
| server/client sharing | two separate framing stacks by construction | literally one `ChannelDuplexHandler` |
| backpressure | `ParentWrite.write` flush-future | `channel.writeAndFlush(...).get()` — identical guarantee |
| EOF semantics | `closeDataChannel()` (SwiftSlash-specific) | `channel.close()` — the same call every NIO user already knows |
| shutdown ladder rung 1 | stdin `closeDataChannel()` | NIO channel close → child's stdin read end sees EOF → `StdioTransport` exits cleanly |
| stderr | built-in line stream → Logger | kept on SwiftSlash's built-in stream (mixed built-in + BYO on different fds is explicitly supported) — zero extra NIO plumbing |
| mental model | "swift-mcp drives SwiftSlash's pipes" | "swift-mcp runs NIO channels; SwiftSlash only binds them onto the child and reaps it" |

## 3. The single pipeline — shared NIO core

### 3.1 `MCPFrameCodec` (new, internal)

A `ChannelDuplexHandler` extracted from the framing currently inlined in `TCPTransport.swift`:

```swift
/// newline-delimited JSON-RPC framing for any NIO channel.
/// inbound:  ByteBuffer → complete `[UInt8]` frames (partial reads buffered on the
///           event loop; frames over `maxMessageSize` close the channel).
/// outbound: `[UInt8]` payloads → ByteBuffer with trailing `0x0A`.
final class MCPFrameCodec: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = [UInt8]
    typealias OutboundIn = [UInt8]
    typealias OutboundOut = ByteBuffer
    private var buffer: ByteBuffer?      // event-loop-confined
    private let maxMessageSize: Int
}
```

`maxMessageSize` (10 MiB default, both roles) moves in here so the cap is enforced identically
on TCP server, stdio server, TCP client, and subprocess client. This is the same discipline
the server already applies; now there is one enforcement site.

### 3.2 `MCPMessageRouter` (new, internal)

`MCPServer.handleMessage` (now ~400 lines of JSON-RPC routing: batches, id-routing, initialize
negotiation, tools/list, tools/call, access gates, error mapping) is extracted into a pure
bytes-in/bytes-out type:

```swift
/// the byte-level JSON-RPC router. pure function of (bytes, callerInfo) → response bytes.
/// shared by every server carrier AND by LocalClientTransport (which drives it with no socket).
final class MCPMessageRouter: Sendable {
    func route(_ bytes: [UInt8], caller: MCPCallerInfo) async throws -> [UInt8]?
}
```

`MCPServer` keeps its public surface and delegates to the router (dispatcher + registries are
captured in it). `LocalClientTransport` later drives the Router directly — so in-process MCP
shares the *exact* routing code with networked MCP, never a hand-reduced copy.

### 3.3 server glue stays

`TransportMessageHandler` (the ordering/backpressure actor) and the per-connection handler
that bridges `MCPFrameCodec` → handler actor → response write are kept, moved under
`Sources/MCP/Transport/`.

### 3.4 target layout

```
Sources/
  MCP/
    Core/                       existing (unchanged)
    Transport/                  NEW
      MCPFrameCodec.swift           shared framing (server + client)
      MCPMessageRouter.swift        extracted JSON-RPC routing core
      TransportMessageHandler.swift moved from Server/ (unchanged behavior)
    Server/
      MCPServer.swift               delegates to MCPMessageRouter
      TCPTransport.swift            refactored onto MCPFrameCodec + router glue
      Transport.swift               StdioTransport migrated to NIO pipe (kept name/contract)
    Client/                     NEW
      MCPClient.swift               actor state machine (role: client)
      ClientTransport.swift         carrier protocol
      RemoteToolDescriptor.swift    catalog entry type
      SubprocessClientTransport.swift   SwiftSlash v5 BYO + NIO pipe channel
      TCPClientTransport.swift          ClientBootstrap + MCPFrameCodec
      LocalClientTransport.swift        router-driven, zero bytes
      MCPClientService.swift           Service wrapper for harness ServiceGroups
  MCPMacros/                    unchanged — the macros already emit the dispatcher
                                that LocalClientTransport drives
```

## 4. Server role — two carriers on the shared pipeline

### 4.1 TCP (refactor only)

`MCPMessageHandler` drops its inline framing; the pipeline becomes
`MCPFrameCodec` → handler glue → `TransportMessageHandler`. No public API change.
`boundPort`/`boundAddress`, access resolver, dual-stack all stay.

### 4.2 stdio child role (migration, recommended — see Open Decision 1)

Today `StdioTransport` runs a hand-rolled `poll(2)` + one-shot `read(2)` loop (~200 lines of
manual syscall handling) with a history of subtle deadlocks. Migrate it to the same NIO pipe
channel the client will use:

```swift
// protect fd 0/1 from NIO's ownership-taking close:
let stdinDup  = dup(0)   // NIO owns these copies; real std streams untouched
let stdoutDup = dup(1)
let channel = try await NIOPipeBootstrap(group: eventLoopGroup)
    .channelInitializer { $0.pipeline.addHandlers(MCPFrameCodec(maxMessageSize:), serverGlue) }
    .withPipes(inputDescriptor: stdoutDup, outputDescriptor: stdinDup).get()
```

- `channelInactive` (client EOF) ends `start(handler:)` naturally — event-driven instead of
  poll-interval; the graceful-shutdown race in the old loop disappears.
- `stop()` closes the channel — the same wakeup guarantee, with no poll interval.
- `signal(SIGPIPE, SIG_IGN)` retained before any write path.
- the in-process test seam `init(input: FileHandle, output: FileHandle)` is preserved by
  `dup`-ing the injected descriptors.
- macOS `FileHandle.read(upToCount:)` trap is structurally gone — NIO reads the pipe
  non-blocking.

## 5. Client role — the new surface (the headline)

### 5.1 `ClientTransport` (public protocol)

Identical contract to the plan's §5.3, now implemented four times over NIO channels:

```swift
public protocol ClientTransport: Sendable {
    /// one complete JSON-RPC frame. write-to-completion; requests only.
    func sendFrame(_ bytes: [UInt8]) async throws
    /// frames emitted by the peer, until EOF or stop.
    nonisolated func frames() -> AsyncStream<[UInt8]>
    /// terminate the connection (subprocess: run the shutdown ladder).
    func stop() async throws
}
```

NIO carriers implement `frames()` by bridging `MCPFrameCodec.InboundOut` into an
`AsyncStream` continuation from a per-connection `ChannelInboundHandler`; `channelInactive`
finishes the stream (EOF-with-in-flight is the client's signal for a dropped connection).

### 5.2 `MCPClient` (public actor)

As designed in `INTERPROCESS_PLAN.md` §5.2, unchanged in shape:

- state machine `idle → spawning → handshake → ready → shuttingDown → disconnected`
- `inFlight: [JSONRPCID: InFlight]` actor-owned (continuation + deadline) — one isolation
  domain, no locks
- `catalog: [String: RemoteToolDescriptor]`, invalidated on `notifications/tools/list_changed`
- public surface: `connect()`, `listTools()`, `callTool(_:arguments:)`, `close()`
- `connect()` runs `initialize` with version negotiation (client requests
  `latestProtocolVersion`, accepts the server's echoed version when it is in the server's own
  supported set — mirror the server's `supportedProtocolVersions`)
- per-call timeout: `withTaskCancellationHandler` racing `Task.sleep`; loser drops the table
  entry. Defaults: negotiation 10s, call 120s, shutdown grace 2s, `maxMessageSize` 10 MiB.

### 5.3 `SubprocessClientTransport` (public) — the SwiftSlash v5 BYO mechanics

```
pipe(stdin):  [childRead + parentWrite]      parentWrite  → NIO channel output (client writes)
pipe(stdout): [parentRead + childWrite]      parentRead   → NIO channel input (client reads)
pipe(stderr): [parentRead + childWrite]      BUILT-IN SwiftSlash stream → Logger + retained tail
```

```swift
var stdinFds: [Int32] = [0, 0]; pipe(&stdinFds)     // [read, write]
var stdoutFds: [Int32] = [0, 0]; pipe(&stdoutFds)   // [read, write]
var stderrFds: [Int32] = [0, 0]; pipe(&stderrFds)

let child = ChildProcess(
    try Command(binary, arguments: args, environment: env, workingDirectory: wd),
    dataChannels: [
        STDIN_FILENO:  .read(.byo(fd: .init(rawValue: stdinFds[0]))),   // child reads
        STDOUT_FILENO: .write(.byo(fd: .init(rawValue: stdoutFds[1]))), // child writes
        STDERR_FILENO: .write(.toParentProcess(stream: .init(), separator: [0x0A]))
    ]
)
async let exit = child.run()   // cancellation → signal(-pid, sig); reap guaranteed

let channel = try await NIOPipeBootstrap(group: eventLoopGroup)
    .channelInitializer { $0.pipeline.addHandlers(MCPFrameCodec(...), bridgeToFramesStream) }
    .withPipes(inputDescriptor: stdoutFds[0], outputDescriptor: stdinFds[1]).get()
```

Ownership notes (implemented; matches the v5 BYO contract, verified in source):

- **child-facing ends (`stdinFds[0]`, `stdoutFds[1]`) are handed over, never touched again.**
  SwiftSlash takes a private `dup()` at validation and `dup2`s that onto the child at spawn; it
  never closes the caller's copies itself. The transport retains them, and the adversarial
  review (Sep 2026) confirmed the closure happens in `childDidExit` — the reaper observes the
  child's exit and releases the retained fds (plus tears the NIO channel down) on the EOF
  path, and `stop()`'s snapshot does the same on the orderly path. Exactly-once: whichever
  path clears the state first closes them. NIO never sees them.
- **parent-facing ends go to NIO only as `dup`'d copies.** NIO was observed NOT to promptly
  close user-provided pipe fds on channel close, so the transport keeps the originals and
  closes the stdin write end itself at ladder rung 1 (the deterministic EOF), the stdout read
  end in teardown. All pipe ends AND the dups are `FD_CLOEXEC` — an inherited stdin write
  end in the child defeats EOF permanently (the CLOEXEC trap, §8 lessons).
- stderr stays on SwiftSlash's built-in pipeline (mixed BYO + built-in is supported per-fh):
  line-split `AsyncSequence` → `Logger` at `.debug`/`.trace` plus a retained tail for crash
  diagnostics, unchanged from the plan's stderr contract. Zero extra NIO plumbing.

Shutdown ladder (rung 1 changes mechanics, semantics identical to the plan's §6.5):

```
1. try await channel.close()          // NIO closes parentWrite → child stdin EOF
2. await run() with shutdownGrace       // server StdioTransport exits 0; Exit.code(0)
3. timeout → try child.signal(SIGTERM)  // negated-pid group signal, SwiftSlash-native
4. still alive → try child.signal(SIGKILL)
   reap guaranteed on every rung (SwiftSlash run() always reaps).
```

SIGPIPE: `signal(SIGPIPE, SIG_IGN)` in the transport before any write path (mirror server);
NIO's pipe write to a dead child would otherwise kill the client on Linux.

### 5.4 `TCPClientTransport` (public)

`ClientBootstrap(group: .singleton)` + `MCPFrameCodec` + the same frames bridge;
`connect(host:port:)` and Unix-domain variants mirroring `ServerAddress`. Same `MCPClient`,
only the carrier differs. TLS is a later pipeline addition (no design change needed).

### 5.5 `LocalClientTransport<D: MCPToolDispatcher>` (public) — network-free MCP

Drives `MCPMessageRouter` directly: `sendFrame` decodes the request, routes it through the
shared router against the macro-generated dispatcher, encodes the response onto the frames
stream; `frames()` effectively never emits (responses accompany each send). The client actor,
catalog, timeouts, and access gates run fully — with zero bytes, zero negotiation, zero
process. This is the "embedded binding" of `INTERPROCESS_PLAN.md` §8, now sharing the exact
router code instead of a reimplementation.

### 5.6 `MCPClientService` (public, `Service`)

Thin composition for harness groups: owns a `SubprocessClientTransport` + `MCPClient`; `run()`
spawns, negotiates, lists tools, then serves calls until `stop()` runs the ladder. Lives in
swift-mcp so arc-agent (and any harness) wires one `Service` per plugin, per the Second Law.
`successTerminationBehavior` is the host's choice (clean child EOF = expected).

## 6. The Two Laws, mapped to the new mechanics

- **First Law:** the client is an actor; the read loop is one task over `frames()`; timeouts
  are `withTaskCancellationHandler` + `Task.sleep`; the process lifecycle is the awaitable
  `child.run()`. NIO owns all IO threads; SwiftSlash's internal pThread executor handles only
  reaping/signals and does not leak into the usage surface.
- **Second Law:** every carrier is either driven from a `Service.run()` (`MCPServer` today,
  `MCPClientService` for the client) or is a pure value/actor that a Service drives. No
  ad-hoc `shutdown()`, no `atexit`, no background daemons. The ladder runs in `run()`/`stop()`.

## 7. Failure modes (delta from `INTERPROCESS_PLAN.md` §9)

| failure | detection | recovery |
|---|---|---|
| spawn failure / `EBADF` child-facing end | SwiftSlash `SpawnError.invalidByoFileDescriptor` / `byoFileDescriptorWrongDirection` (v5 names) | surfaced at `connect()`; plugin reports `.unavailable` at the harness |
| child crashes mid-call | `channelInactive` → frames stream finishes with in-flight requests | in-flight calls fail `transport closed`; catalog invalidated |
| child ignores SIGTERM | ladder timeout | SIGKILL on the process group; event-driven reap (v5) means `run()` still returns promptly |
| oversized frame either direction | `MCPFrameCodec` cap (one site) | close channel; in-flight fail; no unbounded memory |
| parent write EPIPE (child died) | NIO flush future + SIGPIPE ignored | write surfaces error; EOF path cleans up |
| fd leaks | ownership contract | child-facing ends + parent originals closed exactly once by `childDidExit` (EOF path) or `stop()` (orderly path); NIO dups closed with the channel |

## 8. Phase plan — every phase ends green

### Phase 0 — Extract the shared NIO core (pure refactor)

1. `MCPFrameCodec` + `MCPMessageRouter` as above.
2. `TCPTransport` onto codec + router glue; `MCPServer` delegates to router.
- **Gate:** full existing suite green; wire-behavior probe fixtures byte-identical.

### Phase 1 — Server stdio on NIO pipes (migration)

1. `StdioTransport` re-implemented over `dup(0)`/`dup(1)` + `NIOPipeBootstrap` + codec + glue.
2. Delete the poll/read/`writeRaw` syscall helpers.
3. Keep `MCPTransport` contract, `maxMessageSize`, SIGPIPE ignore, in-process test seam.
- **Gate:** stdio suites green (EOF, stop-during-idle, batches, oversize); **re-run the
  mcp-Python-SDK control experiment + real stdio client** — the deadlock class that burned
  this path before was exactly "poll/read assistant replaced by a different mechanism".
  Do not trust self-round-trip alone.

### Phase 2 — `MCPClient` + `SubprocessClientTransport` (the headline)

1. `ClientTransport`, `RemoteToolDescriptor`, `MCPClient` actor, config defaults.
2. `SubprocessClientTransport` per §5.3 (BYO fd flow, NIO duplex channel, stderr built-in,
   ladder).
3. `MCPClientService`.
- **Gate (unit):** spawn this package's own built server binary over the subprocess carrier:
  initialize/handshake, list, out-of-order replies, per-call timeout, oversize frame, EOF
  clean exit, mid-call kill → clean failure + no zombie, SIGTERM-escalating ladder.
- **Gate (integration):** the control experiment — this client against a **known-good
  third-party** stdio MCP server first; then our client ↔ our server.

### Phase 3 — `TCPClientTransport`

- **Gate:** TCP client ↔ TCP server end-to-end (ephemeral port via `boundPort`); same unit
  matrix as Phase 2 against the same test servers.

### Phase 4 — `LocalClientTransport` (network-free MCP)

- **Gate:** drives `MCPMessageRouter` → dispatcher; `tools/list` catalog + access gates
  byte-identical to the TCP path for the same app; the actor's timeout/catalog logic
  exercised with no process.

### Phase 5 — Full verification matrix

| client \\ server | swift-mcp stdio | swift-mcp TCP | third-party server |
|---|---|---|---|
| `SubprocessClientTransport` | ✅ P2 | — | ✅ P2 control |
| `TCPClientTransport` | — | ✅ P3 | ✅ live if available |
| `LocalClientTransport` | — | ✅ P4 (in-process) | — |
| official mcp SDK | ✅ P1 control | — | ✅ control |

- **Gate:** every cell green; a regression test asserting the control experiment runs in CI.

### Phase 6 — Docs, records, packaging

1. DocC: rewrite `TransportDesign.md` around the unified pipeline; new `MCPClient.md` +
   `MCPBySubprocess.md` articles; symbol docs for the new client surface.
2. Update `INTERPROCESS_PLAN.md` §6 / the skill reference to the v5 BYO contract; AGENTS.md
   project-structure and lifecycle sections; CHANGELOG.
- **Gate:** DocC warning-free; changelog matches shipped API; pre-release bar (squashable
  warnings gone, docs match code).

## 9. Decisions (closed)

All four open items were resolved to the recommendations on 2026-09-08, approved by the
maintainer:

1. **StdioTransport NIO migration (Phase 1) — adopted.** The server's stdio role migrates
   onto `dup(0)`/`dup(1)` + `NIOPipeBootstrap`, deleting the raw poll loop. The mandatory
   control-experiment gate stands as the migration's safety net.
2. **stderr — SwiftSlash built-in stream.** The child's stderr stays on SwiftSlash's
   line-delimited pipeline (Logger + retained tail), not BYO. Zero extra NIO plumbing.
3. **Client protocol-version policy — mirror the server.** The client requests
   `MCPServer.latestProtocolVersion` and accepts the server's echoed version when it is in
   `MCPServer.supportedProtocolVersions`; a disjoint set fails the handshake.
4. **`LocalClientTransport` reuses `MCPMessageRouter`.** The in-process carrier drives the
   exact same routing core as every server carrier — one routing implementation across all
   four deployments. Consequence adopted into Phase 0: the registries move into the router,
   and `MCPServer`'s `register`/`registerInstance`/`unregister` forward to it.
5. **Event loop group — `.singleton`** for all client carriers.
6. **`frames()` bridge — `AsyncStream` + continuation handler** (no `NIOAsyncSequenceProducer`).

## 10. Explicitly out of scope

- HTTP+SSE transport, TLS, streaming responses, resources/prompts — unrelated to this plan.
- dylib tool bundles — stated non-goal, unchanged.
- Any arc-agent consumer work (`ToolEntry(tool:)`, `PluginToolRegistry`) — the plan ends where
  swift-mcp's client surface ends; arc integration is arc's increment path (plan §7).

## 11. Glossary

| term | meaning |
|---|---|
| carrier | concrete medium a transport runs over (TCP socket, child stdio pipes, in-process router) |
| BYO channel | a SwiftSlash data channel `.byo(fd:)` — caller-owned descriptor bound onto the child at spawn; SwiftSlash stays out of the data path |
| owned end | the pipe end NIO holds and closes (parent-write for stdin, parent-read for stdout) |
| child-facing end | the pipe end `dup2`'d into the child; the caller never touches it after construction |
| MCPFrameCodec | the one newline-framing + size-cap implementation shared by every carrier |
| MCPMessageRouter | the one JSON-RPC routing core shared by every server carrier and LocalClientTransport |
