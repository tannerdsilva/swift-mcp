# INTERPROCESS PLAN

**A protocol layer for effortless Swift-tool ↔ harness integration**

- **Status:** Proposed / design draft
- **Owner:** swift-mcp (this package becomes the narrow waist)
- **Consumers:** arc-agent (and any Swift agent harness), standalone Swift tool packages
- **Dependencies added:** exactly one — `tannerdsilva/SwiftSlash` (dependency-free, Swift 6.0+)

---

## 1. Problem statement

Integrating a Swift-built agentic tool into a harness is today a hand-written,
error-prone ritual. The tool's contract exists in **parallel universes** that
nothing cross-checks:

| Universe | Who consumes it | Hand-written every time |
|---|---|---|
| `ToolEntry` (arc) | The harness tool registry | name, toolset, description, JSON schema, untyped `[String:Any]`→typed argument casting, handler closure |
| `MCPTool` conformance (swift-mcp) | The MCP server surface | name, description, parameter metadata, argument application, invocation |
| JSON Schema | Whatever the LLM sees | a *second* hand-built description of the same parameters |

Every one of those fields is derivable from **one** Swift declaration — the
tool's own signature. Nothing derives them today; every tool rewrites the glue
by hand, with zero compiler help. This reproduces, in Swift, the bug class we
have already fought in the wild: schema descriptions that drift from the types
that back them; untyped argument plumbing that turns a missing key or a wrong
type into a runtime crash instead of a compile error.

This plan makes the portability layer **own the derivation**, the same way
rawdog's `@RAW_staticbuff` derives storage machinery from an annotated struct
and QuickLMDB's `@MDB_transact` derives transaction boundaries from an
annotated method.

## 2. Goals

1. **One annotation → three bindings.** A tool author writes a single
   annotated Swift type. From it derive: the `MCPTool` conformance, the
   harness `ToolEntry`, and a standalone tool-server binary.
2. **One protocol, two roles.** swift-mcp already serves tools. This plan adds
   the client role in the same package, on the same transport/framing core —
   so server and client cannot drift.
3. **No new projects.** Everything lands in swift-mcp (protocol + client) and
   arc-agent (consumer-side adapter + remote registry). Tool authors depend on
   swift-mcp only.
4. **Both interop modes are the same code.** In-process, compile-time
   (embedded) and out-of-process, runtime (subprocess MCP) — same annotated
   types, same registry protocol below `ToolEntry`.
5. **Second-Law and First-Law compliance.** The client is a `Service`; all
   concurrency is `async`/`await` + actors + task groups.

## 3. Non-goals

- **Dynamic precompiled libraries (`.dylib` tool bundles) are explicitly out
  of scope.** Swift has no stable module ABI across toolchain versions; a
  dylib loaded into a differently-compiled host is a crash-on-startup class;
  and post-ship extensibility is already served by subprocess MCP while
  network-free in-process composition is served by link-time dependency. A
  dylib loader is dominated on every axis and is documented here as a stated
  non-goal so it is not resurrected.
- **Replacing arc's `ToolRegistry`.** It stays the narrow waist. This plan
  grows *implementations* of it (`PluginToolRegistry`), not replacements.
- **A new "toolkit" package.** The shared surface lives in swift-mcp; the
  arc-side adapter lives in arc.

## 4. Architectural summary

```
                  ┌──────────────────────────────────────────────┐
                  │               swift-mcp (the waist)           │
                  │                                                │
   tool author     │  MCPTool protocol         (the contract)      │
  (external pkg)   │  @MCPCommand / @FuncTool   (schema+dispatch)  │
        │          │  Server role               (exists today)     │
        │          │    StdioTransport / TCPTransport              │
        │          │  Client role               (NEW in this plan) │
        │          │    MCPClient — actor state machine            │
        │          │    SubprocessClientTransport (SwiftSlash)     │
        │          │    TCPClientTransport                         │
        │          │    LocalInProcessTransport (network-free)     │
        └──────────┼──►  @MCPApplication → standalone server binary │
                   └───────┬───────────────┬───────────────────────┘
                           │               │
                 embedded (link time)      │ subprocess (runtime)
                           ▼               ▼
                   ┌──────────────────────────────┐
                   │       arc-agent (consumer)   │
                   │  ToolEntry(tool:) adapter    │
                   │  PluginToolRegistry          │
                   │  ToolRegistry (unchanged)    │
                   └──────────────────────────────┘
```

The one source of truth is the annotated tool type. swift-mcp provides every
binding; arc provides only a thin consumer adapter; tool authors write nothing
beyond the annotation.

## 5. The protocol layer — what lands in swift-mcp

### 5.1 Target layout (new)

```
Sources/
  MCP/                     existing core
  MCP/Client/              NEW
    MCPClient.swift            the actor state machine (role: client)
    ClientTransport.swift      protocol for client-side carriers
    FrameEngine.swift          newline-frame encoder/decoder + size cap
    SubprocessClientTransport.swift   SwiftSlash-backed (spawn)
    TCPClientTransport.swift         mirrors the server's TCP code
    LocalClientTransport.swift       in-process: direct dispatcher calls
  MCPMacros/               existing macro implementations
```

### 5.2 `MCPClient` (core type)

An `actor` owning the connection state, the in-flight request table, the
remote catalog, and the process handle:

```swift
public actor MCPClient {
    public enum State: Sendable, Equatable {
        case idle, spawning, handshake, ready, shuttingDown, disconnected
    }

    public struct ClientConfiguration: Sendable {
        public var negotiationTimeout: Duration     // default 10s
        public var callTimeout: Duration            // default 120s
        public var shutdownGrace: Duration          // default 2s
        public var maxMessageSize: Int              // default 10 MiB
    }

    private var state: State = .idle
    private var nextID: UInt64 = 0
    private var inFlight: [JSONRPCID: InFlight] = [:]   // actor-owned, no locks
    private var catalog: [String: RemoteToolDescriptor] = [:]
}
```

Public surface:

```swift
public func connect() async throws        // spawn (if subprocess) + initialize
public func listTools() async throws -> [RemoteToolDescriptor]
public func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPToolResult
public func close() async                 // graceful ladder: EOF, grace, TERM, KILL
```

### 5.3 Carrier abstraction

```swift
public protocol ClientTransport: Sendable {
    /// Send one frame to the peer. Must be write-to-completion (partial
    /// writes internally looped), never fire-and-forget for requests.
    func sendFrame(_ bytes: [UInt8]) async throws

    /// Consume frames from the peer until EOF or stop.
    nonisolated func frames() -> AsyncStream<[UInt8]>

    /// Terminate the connection. Subprocess: EOF on stdin → grace → signal → kill.
    func stop() async throws
}
```

`MCPClient` is deliberately **carrier-agnostic**: Subprocess, TCP, and Local
all drive the same actor. This is what makes network-free MCP a configuration,
not a fork (see §8).

## 6. The IO contract — MCP over subprocess, in detail

### 6.1 Framing

MCP stdio is **newline-delimited JSON-RPC**: one complete message per physical
line, `0x0A`-terminated. No `Content-Length` framing. This is safe because
JSON string literals escape newlines — a literal `0x0A` byte can only be a
frame boundary, so a partially-received buffer is never mistaken for a frame.

SwiftSlash's default stdout channel is already line-delimited
(`separator: [0x0A]`), which matches MCP framing by construction:

```
child.stdout  →  ParentRead (Element [[UInt8]], line-delimited)  →  FrameEngine  →  MCPClient
child.stdin   ←  ParentWrite (write = flush-future-backed)       ←  FrameEngine  ←  MCPClient
child.stderr  →  separate ParentRead line stream                 →  Logger (never the protocol channel)
```

### 6.2 The client read loop

The heartbeat of the client. A single task consumes the stdout
`AsyncSequence` and routes every parsed frame:

- **response with id** → fulfill or throw the matching continuation in the
  in-flight table. Replies may arrive out of order; correlation is **by id**,
  never by arrival order.
- **notification** (`notifications/tools/list_changed`) → invalidate the
  cached catalog. Catalogs are always rebuilt, never trusted from memory.
- **EOF** (`next()` returns nil) → fail every in-flight continuation with a
  `transport closed` error and move to `.disconnected`.

The in-flight table is the only mutable cross-cut structure and it lives
inside the actor: continuations are stored and fulfilled within one isolation
domain, so no locks and no `@unchecked Sendable`.

### 6.3 Request dispatch and timeouts

- Requests write through `ParentWrite.write(_:)`, which is Future-backed and
  awaits the actual flush — real backpressure into the child's pipe instead of
  overrunning its 64 KiB kernel buffer.
- Fire-and-forget (`yield`) is used **only** for JSON-RPC notifications.
- Every in-flight request carries a deadline. Per-call timeout:
  a `withTaskCancellationHandler` racing a `Task.sleep`; the loser releases
  the table entry. A stuck child can never hang the agent loop; a
  consistently hanging child escalates to the lifecycle ladder (§6.5).

### 6.4 stderr routing

stderr is for diagnostics, never protocol. Lines go to a `Logger` at
`.debug`/`.trace`, and the last N lines are retained so a crashed tool server
reports a meaningful tail in the failure surfaced to the agent.

### 6.5 Lifecycle ladder

Graceful shutdown is strictly ordered:

```
1. stdin.closeDataChannel()               → server StdioTransport sees EOF
2. await run() with shutdownGrace         → server exits cleanly (code 0)
3. timeout reached → childProcess.signal(SIGTERM)
4. still alive      → SIGKILL
   reap guaranteed on every rung (SwiftSlash run() always reaps)
```

MCP has no shutdown RPC: **EOF on stdin is the shutdown signal.** The
subprocess transport's `stop()` implements exactly the ladder above. The
client is wrapped as a `Service` in the harness `ServiceGroup` so the ladder
runs on graceful group shutdown, not in an ad-hoc `deinit` or `atexit`.

Task cancellation composes cleanly: cancelling the `run()` task has SwiftSlash
send `SIGTERM` to `-pid` (the whole process group — descendants such as a
`git` or `swift` child die with the server), reap, and surface
`CancellationError`.

### 6.6 The discipline traps (test-verified, do not regress)

| Trap | Guard |
|---|---|
| `FileHandle.read(upToCount:)` on a pipe — macOS loops until buffer-full or EOF → both sides block (the classic stdio deadlock) | One-shot `read(2)` after `POLLIN` (server, existing); SwiftSlash FIFO + single-shot reads (client). Never reintroduce blocking `read(upToCount:)` on either side. |
| SIGPIPE kills the *client* when the child dies mid-write | `signal(SIGPIPE, SIG_IGN)` in the subprocess transport before any write path runs (mirror the server). |
| Partial writes on a frame above the pipe-buffer size | Frame writes are write-to-completion; a partially-written frame is not-yet-sent, never a corrupt frame. |
| Unbounded frames from a buggy/garbage peer | `maxMessageSize` cap on the decode path; overflow closes the connection. Memory stays bounded regardless of peer behavior. |
| Zombie children / leaked FDs on abort | SwiftSlash guarantees the reap and FD cleanup on every path. |
| EOF-vs-error ambiguity | State machine distinguishes "EOF after all in-flight resolved" (clean) from "EOF with in-flight" (dropped connection → those calls fail). |
| Half-dead process trees | `kill(-pid, ...)` targets the process group established at spawn. |

## 7. The arc-agent consumer side

### 7.1 `ToolEntry(tool:)` — in-process adapter

The macro-generated `MCPTool` conformance is the single source. The adapter
derives arc's `ToolEntry` from it:

```swift
extension ToolEntry {
    public init<T: MCPTool>(tool: T) {
        self.init(
            name: T.toolName,
            toolset: T.configuration.toolset,          // carried in ToolMetadata (§7.3)
            description: T.configuration.description,
            schema: SchemaAdapter(Self.discoverParameters()),  // ONE schema type
            handler: { args in
                var instance = T()
                try instance.apply(arguments: args)
                switch try await instance.invoke(context: MCPContext(arguments: args)) {
                case .text(let s): return s
                case .error(let s): throw ToolError.mcpFailure(s)
                }
            }
        )
    }
}
```

Every field the tool author used to hand-write is gone: name from symbol,
description from the attribute/doc comment, schema from the parameter
metadata, dispatch from `run()`.

### 7.2 `PluginToolRegistry` — subprocess adapter

Remote tools arrive as **wire descriptors** from `tools/list`, not as
compile-time conformances. The same adapter pattern generalizes:

```swift
public final class PluginToolRegistry: ToolRegistry {
    // one MCPClientService per configured plugin
    public func refresh() async throws {
        for plugin in plugins {
            let catalog = try await plugin.client.listTools()
            for desc in catalog where lookup(name: desc.name) == nil {
                try register(ToolEntry(remote: desc, via: plugin.client))
            }
        }
    }
}
```

`ToolEntry(remote:via:)` maps the wire schema into arc's `JSONSchema` (the
**one** schema type) and sets the handler to `client.callTool(name, args)`.
**Defense in depth:** arc re-validates inbound arguments against
`ToolEntry.schema` *before* framing them to the child — the probe-validation
lesson from the Hermes `tool_call` work applies verbatim; the wire trusts
neither the model's arguments nor the child's claims.

Below `ToolEntry`, in-process and subprocess tools are indistinguishable: the
agent loop's schema array and dispatch path do not change.

### 7.3 Portable metadata

MCP lacks arc's `toolset` dimension. The shared surface adds a thin
`ToolMetadata` carried alongside `MCPToolConfiguration` (or as a companion
conformance) so tool-group gating is declared once and reused by both the
embedded registry and any grouped exposure. `checkFn` / `requiresEnv` remain
local registry concerns (env probes and credential pooling are harness
business, not portable tool business).

### 7.4 Lifecycle wiring

Each plugin is a `MCPClientService: Service` in the gateway `ServiceGroup`:

- `run()`: spawn child (SwiftSlash `ChildProcess` with the MCP data channels),
  `initialize` (protocol-version negotiation `2024-11-05` … `2025-11-25` —
  the server already echoes the negotiated version), `listTools`, merge catalog
  into the `PluginToolRegistry`, then serve calls until `stop()` runs the
  shutdown ladder.
- The toolset enabled/disabled filter in `ToolRegistry.buildToolSchemas`
  applies to remote tools unchanged.

## 8. Network-free MCP

The "one more target" intuition from the exploratory work turns out to be a
**zero-new-target**: `MCPToolDispatcher` — the thing `@MCPApplication` already
generates — *is* a network-free MCP endpoint. It carries the tool ID enum, the
exhaustive typed `callTool`, the access gates, and the catalog; the server is
only a carrier around it.

`LocalClientTransport` therefore drives `MCPClient` with **no bytes at all**:

```swift
public struct LocalClientTransport<Dispatcher: MCPToolDispatcher>: ClientTransport {
    nonisolated func frames() -> AsyncStream<[UInt8]> { ... never emits ... }
    func sendFrame(_ bytes: [UInt8]) async throws {
        // decode frame → dispatcher.callTool(named:arguments:context:) → encode result
    }
}
```

Consequences:

- **Compile-time (embedded) bindings** use `LocalClientTransport` + link-time
  composition — no JSON, no negotiation, no process.
- **Ship-time (adjacent) bindings** use `SubprocessClientTransport` — released
  binaries adopt new tools without a rebuild.
- The client state machine, catalogs, timeouts, and access gates are shared
  across both — the only difference is the carrier.

## 9. Failure modes

| Failure | Detection | Recovery / behavior |
|---|---|---|
| Spawn failure (binary missing, exec error) | SwiftSlash `SpawnError` at connect | Report `.unavailable`; skip plugin at startup with a logged reason; `tools/list` sees the plugin absent, not broken. |
| Child crashes mid-call | EOF with in-flight requests | In-flight calls fail with `transport closed`; registry refreshes on a `list_changed`-invalidation or reconnect policy (exponential backoff). |
| Call timeout | Per-call deadline reaper | `-32602`-style structured error to the agent; no hang. |
| Protocol-version mismatch | `initialize` response | Negotiate to the greatest mutually supported version; fail handshake only if disjoint. |
| Oversized frame | `maxMessageSize` on decode | Close connection; remaining in-flight calls fail; no memory spike. |
| Peer writes garbage | QuickJSON strict decode throws | Per-frame rejection with an error response; connection retained unless frames are structurally invalid. |
| Agent session aborted | ServiceGroup stop / task cancellation | Shutdown ladder; pgroup TERM; reap guaranteed. No zombies. |

## 10. The Two Laws, mapped

**First Law — Structured Concurrency.** `MCPClient` is an actor; the read loop
is one task; per-call timeouts are `withTaskCancellationHandler` +
`Task.sleep`; the process lifecycle is driven by the awaitable
`ChildProcess.run(cancellationSignal:)`. No raw threads, no semaphores, no
`DispatchQueue`, no blocking continuation tricks. (SwiftSlash's internal
pThread executor is the library's own event-loop substitute and does not leak
into the client's usage surface.)

**Second Law — Service Lifecycle.** The client is a `Service` in the harness
`ServiceGroup`. There is no ad-hoc `shutdown()`, no `atexit` cleanup, no
`DispatchMain`. The graceful ladder runs inside `run()`; parent-side cleanup
happens in the group's stop path. `successTerminationBehavior` is set so a
clean child EOF (e.g. the tool server exits on its own) is recorded as the
expected outcome rather than a `serviceFinishedUnexpectedly` error.

## 11. Increment path

Every phase ends green: tests pass, the documented verification gate holds.

### Phase 0 — In-process adapter (no new surface)

- Add `ToolEntry(tool:)` to arc; refactor one built-in tool
  (`ReadFileTool` → `@MCPCommand` + adapter).
- **Gate:** arc's existing 160-test suite passes; the hand-written schema and
  `[String:Any]` casting disappear from that file; `tool describe` for the
  refactored tool is byte-identical to before.

### Phase 1 — Client + subprocess transport

- `MCPClient`, `FrameEngine`, `SubprocessClientTransport` using SwiftSlash.
- **Gate (unit):** in-process pipe tests drive the client against a real
  `StdioTransport`-backed server (EOF, version negotiation, out-of-order
  replies, timeouts, oversize frames) — the same discipline used to test
  `StdioTransport` without spawning.
- **Gate (integration):** client against a real third-party server. Run the
  **control experiment first**: official MCP SDK / known-good server; only
  then against swift-mcp's own server. Never trust self-round-trip tests
  alone (the framing subtlety that once produced a client hang is exactly the
  class this gate exists to catch).

### Phase 2 — Remote registry

- `PluginToolRegistry` + plugin manifest in arc config; `arc serve` spawns
  configured plugin servers as Services; catalogs merge; toolset gating
  applies unchanged.
- **Gate:** integration tests register a plugin, list tools, call one,
  kill the child mid-call, and confirm the in-flight calls fail cleanly with
  no zombie.

### Phase 3 — Scaffold

- A SwiftPM command plugin (`arc generate-tool-server` in the tool package, or
  a documented two-file template) that turns an annotated tool package into a
  standalone server binary + a one-line arc plugin entry.
- **Gate:** a fresh external package following the scaffold builds a server,
  is consumed by arc end-to-end, and passes Phase 1's integration gate.

## 12. Open decisions (need your call)

1. **SwiftSlash into swift-mcp as a dependency** (recommended): swift-mcp
   currently depends only on QuickJSON; SwiftSlash adds several sub-targets
   (FIFO, Future, EventTrigger, serial executors). It is dependency-free and
   is exactly the process layer the client needs, but the footprint grows.
   Alternative: keep swift-mcp lean with a byte-stream `ClientTransport` and
   locate the SwiftSlash-backed binding in arc. This plan assumes the former,
   per the "one project or the other" constraint.
2. **Client-side protocol version policy:** default to the server's
   `latestProtocolVersion`, negotiate down on mismatch — confirm the accepted
   set should mirror the server's `supportedProtocolVersions` exactly.
3. **Remote catalog consistency:** full invalidation on `list_changed`
   (recommended) vs. re-list on every agent turn (simpler, slightly costlier).
4. **Toolset metadata for remote tools:** whether `ToolMetadata` becomes a
   first-class part of the MCP tool configuration or an arc-side manifest
   field. This plan recommends in-configuration so grouping survives export
   to non-arc hosts as a benign no-op.

## 13. Appendix — glossary

| Term | Meaning |
|---|---|
| **Binding** | One consumer-facing shape derived from a single annotated tool type (MCPTool conformance / ToolEntry / server binary). |
| **Carrier** | The concrete medium a transport uses (stdio pipes, TCP, in-process direct calls). |
| **Frame** | One complete newline-delimited JSON-RPC message. |
| **In-flight table** | Actor-owned map from JSON-RPC id to the awaiting continuation + deadline. |
| **Network-free MCP** | The MCP message vocabulary (`tools/list`, `tools/call`, access gates) executed without a byte carrier, via `MCPToolDispatcher` directly. |
| **Shutdown ladder** | The ordered close sequence: EOF on stdin → grace → SIGTERM → SIGKILL → reap. |
