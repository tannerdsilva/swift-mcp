# Changelog

## 2.0.0

Transport unification and the client role: one NIO pipeline serves every
deployment, and the package now both serves and consumes MCP — including
MCP-by-subprocess via SwiftSlash 5.0 bring-your-own data channels.

### Added

- **Client role** — `MCPClient` actor (state machine, in-flight table keyed by
  JSON-RPC id, per-call deadlines, remote catalog with `list_changed`
  invalidation, protocol-version negotiation) over a `ClientTransport`
  carrier protocol.
- `SubprocessClientTransport` — spawn a standalone tool-server binary and
  speak MCP over its stdio, via SwiftSlash **5.0** BYO data channels + a NIO
  pipe channel (stderr on the built-in line stream, retained tail for crash
  diagnostics). Shutdown ladder: stdin EOF → grace → SIGTERM → SIGKILL to the
  process group, reap guaranteed.
- `TCPClientTransport` — networked carrier over `ServerAddress` (hostname +
  port or Unix domain socket).
- `LocalClientTransport<D: MCPToolDispatcher>` — **network-free MCP**: drives
  the shared routing core with zero bytes, zero processes.
- `MCPClientService` — `Service` wrapper so a host `ServiceGroup` owns one
  MCP-plugin subprocess (Second Law everywhere).
- `MCPClientError` (Foundation-free, `Equatable`, `CustomStringConvertible`),
  `RemoteToolDescriptor`, `ClientFrameBridge`.
- Client requests (`callTool`, `listTools`, `ping`) are now **task-cancellable**:
  cancelling the caller's `Task` surfaces `CancellationError` promptly and emits
  `notifications/cancelled`, so the remote invocation stops at its next
  cooperative suspend point instead of outliving the caller.
- Unified NIO transport core, shared by server and client: `MCPFrameCodec`
  (newline framing + per-frame size cap), `MCPMessageRouter` (JSON-RPC
  routing + tool registries), `MCPMessageHandler`, `TransportMessageHandler`.
- `MCPFixtureServer` — test-fixture `@MCPApplication` stdio server
  (echo/add/slow) spawned by the client test suite.
- **One-shot stdin tool facade** — `interface: .oneShot` on `@MCPApplication`
  (with `description:`; `address`/`transport` rejected by diagnostic):
  - `MCPStdinHost` (`Service`) — drives the shared router + transport through
    pluggable dialects, writes responses synchronously, maps the exit contract
    in `runMain()`, and serves introspection before any transport starts.
  - `MCPStdinDialect` (byte transcoders over the one router) with
    `MCPPluginDialect` (`{"tool","args"}` ⇄ `{"result"}`, completes after the
    first request — stdin-holding harnesses cannot hang) and
    `MCPJSONRPCDialect` (byte identity; the router classifies).
  - `MCPToolCatalog` / `MCPToolManifestFormat` / `MCPManifestContext` /
    `ArcPluginManifest` — self-description from the compiled surface
    (`--mcp-list`, `--mcp-manifest arc`), canonical sorted-key output.
  - `MCPFixtureTool` — test-fixture one-shot binary spawned by the end-to-end
    suite (plugin, JSON-RPC, introspection, exit contract, `MCP_ACCESS_LEVEL`).
- **Tool packs** — authoring a fleet of one-shot tools as one binary
  (`Sources/MCP/Documentation.docc/ToolPacks.md`):
  - `--mcp-describe <tool>` (one canonical tool object) and `--version`
    introspection. An unserved format or an unknown tool exits `1` with one
    diagnostic line on stderr and nothing on stdout.
  - `@MCPApplication(manifestInvocationArguments:)` — a pack whose one-shot
    entry sits behind a subcommand advertises the real argv in its generated
    manifest; `.session` with the attribute is a diagnostic.
  - `MCPStdinHost.Configuration.firstFrameTimeout` — an opt-in deadline that
    turns a silent no-frame hang into a named exit `1`; the default still
    waits indefinitely.
  - Standard-stream preflight — a regular-file stdin or stdout is refused
    *before* the transport starts, naming the offending stream and descriptor
    (`MCPStdinHostError.standardStreamIsNotAPipe`). `/dev/null` and other
    character devices stay allowed.
  - `MCPToolTestKit` — the spawn harness exported as a library target
    (`SpawnedTool`, `ToolExit`, `drain(fd:)`, `pluginFrame(tool:args:)`), so a
    pack's spawned end-to-end test is ~10 lines instead of ~110.
  - `MCPToolPack` (twelve tools spanning every return shape the facade
    supports) and `MCPTwoFilePack` (MCP tools and an `ArgumentParser` argv
    front door in separate files) — compiled reference packs the suite drives
    as real spawned processes.
- Dependency: `tannerdsilva/SwiftSlash` 5.0.0 (dependency-free).

### Changed

- `StdioTransport` rewritten on a NIO pipe channel over duplicated fd 0/1 —
  the hand-rolled `poll(2)` read loop is gone; EOF, framing, and shutdown are
  event-driven like every other carrier.
- `TCPTransport` refactored onto the shared `MCPFrameCodec`; the duplicated
  per-transport framing is deleted.
- Routing and the tool registries moved into `MCPMessageRouter`;
  `MCPServer` is a facade over it (public API unchanged).
- The frame size cap now applies per frame — a single complete oversized line
  is rejected (was: only partial accumulation was bounded).
- Client requests register their in-flight entry and reaper before sending,
  so synchronously-answering carriers (local) cannot race registration.
- Server reads are demand-driven — `autoRead` off, re-armed as the dispatcher
  queue drains, with a 128-frame queue cap that closes a flooding peer
  (bounded memory under load).
- The subprocess reaper signals on cancellation (`run(cancellationSignal:)`),
  publishes child + reaper atomically, and releases the retained pipe fds and
  channel when the child exits on its own.
- Client `frames()` is a backpressured `ClientFrameSequence` (high/low
  watermark demand; never drops; both networked carriers pause peer reads).
- Subprocess close is cooperative: a best-effort `shutdown` extension lets an
  EOF-exit peer drain and exit cleanly with code 0 before the ladder runs
  (unsupported peers sees `-32601`/timeout → EOF + ladder; EOF remains the
  authoritative termination).
- `StdioTransport` applies a harness-injected access level and identity
  (`MCP_ACCESS_LEVEL` / `MCP_CALLER_IDENT`); `SubprocessClientTransport`
  now takes `trustLevel` + `callerIdentity` so plugins get real access gates.
  `MCPClient` is explicitly one-shot by design — with no network layer there
  is nothing to retry.
- `SubprocessClientTransport` exposes the child's stderr as a live line
  stream (`stderrLines()`) via the built-in SwiftSlash pipeline.
- `ArcPluginManifest` emits **compact** canonical JSON by default — sorted keys
  at every depth, no insignificant whitespace (2266 B across 88 lines → 1484 B
  across 1 on the fixture pack; a harness reads these bytes on every load, so
  their size is a token cost). The two-space reviewable form is the same format
  under its own name, `ArcPluginManifest.Pretty` (`--mcp-manifest arc-pretty`),
  and both spellings decode to the same document.
- A tool's return value now renders by its shape (`MCPToolResult.render`):
  `String` verbatim, any `Encodable` as compact JSON, anything else
  `String(describing:)`. This **changes observable output** for tools returning
  an `Encodable` other than `String`: they previously reached the caller as
  Swift debug text (`Foo(a: 1, b: 2)`) and now arrive as a JSON document.

### Fixed

- The client's request deadline now bounds the **send** leg, not just the
  response await: a peer that stops draining its pipe (wedged event loop,
  stopped process, deadlocked plugin) previously left `sendFrame`'s
  write-to-completion hanging the caller — and, running on the client actor,
  every later request and `close()` with it — past every configured timeout.
  A send that misses its deadline fails the request with `callTimeout`,
  tears the wedged connection down through the carrier ladder (reclaiming a
  wedged subprocess child that a torn-down `close()` would otherwise skip),
  and `close()`'s cooperative `shutdown` handshake is additionally bounded
  by a watchdog so the ladder is always reached on time. Regression-tested
  with a gated carrier that blocks the send path.
- EOF-ended subprocess sessions leaked the transport's pipe fds and channel
  (retained until `stop()`); they are now released exactly once when the
  child exits — regression-tested with zero per-session fd growth.
- `SubprocessClientTransport.start()` failure paths closed some fd numbers
  twice (via a later `stop()`) and could hang forever when cancelling a
  child that ignores stdin EOF; both now tear down through the shutdown
  ladder exactly once.
- `stop()` racing `start()` during the launch window could orphan a live,
  unsignaled child (public-API concurrent use); child + reaper are now
  published atomically and a racing `start()` aborts cleanly.
- `MCPClient.listTools` no longer traps when a server advertises duplicate
  tool names (last-wins catalog).
- `MCPServer`'s drain-then-close and the client read loop are order-safe
  under the new demand-driven reads (verified against the real mcp Python
  SDK in both roles).
- The two QuickJSON debug lines that preceded every one-shot invocation's
  output are gone (346 B of construction banner per process). They came from
  QuickJSON's `Encoding.logger`/`Decoding.logger` statics, which were built at
  `logLevel: .debug` while every other statement of that contract — its
  `AGENTS.md`, its own `CHANGELOG`, the `logLevel` parameters on
  `encode`/`decode`, and every container initializer — says `.critical`. There
  was no host-side fix: constructing any container reads the static, so the
  banner was emitted *by* the read that would have suppressed it. Fixed in
  QuickJSON v2.0.2 (pinned here), and `ToolPackTests` now asserts its stderr
  contract against the **raw** stderr rather than a filtered view — a banner
  returning is a failing test, not a tolerated line.

### Removed

- `MCPDemo` (earlier); the poll-based stdio read loop; the
  `SubprocessFrameBridge` name (now `ClientFrameBridge`, shared across
  carriers).

## 1.0.0

Macro-driven MCP server framework: `@MCPCommand`, `@FuncTool`,
`@MCPApplication`, `@MCPOptionGroup`; `MCPServer` as a `Service` over
`StdioTransport` / `TCPTransport`; Foundation-free wire layer on QuickJSON v2;
typed `MCPToolDispatcher` dispatch; access control per tool.
