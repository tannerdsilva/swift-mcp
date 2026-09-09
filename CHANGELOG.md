# Changelog

## 1.1.0 — Unreleased

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
- Unified NIO transport core, shared by server and client: `MCPFrameCodec`
  (newline framing + per-frame size cap), `MCPMessageRouter` (JSON-RPC
  routing + tool registries), `MCPMessageHandler`, `TransportMessageHandler`.
- `MCPFixtureServer` — test-fixture `@MCPApplication` stdio server
  (echo/add/slow) spawned by the client test suite.
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

### Fixed

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

### Removed

- `MCPDemo` (earlier); the poll-based stdio read loop; the
  `SubprocessFrameBridge` name (now `ClientFrameBridge`, shared across
  carriers).

## 1.0.0

Macro-driven MCP server framework: `@MCPCommand`, `@FuncTool`,
`@MCPApplication`, `@MCPOptionGroup`; `MCPServer` as a `Service` over
`StdioTransport` / `TCPTransport`; Foundation-free wire layer on QuickJSON v2;
typed `MCPToolDispatcher` dispatch; access control per tool.
