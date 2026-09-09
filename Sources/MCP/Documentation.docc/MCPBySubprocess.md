# MCP by Subprocess

MCP-as-subprocess: spawn a standalone tool-server binary and speak MCP over its
stdio, with the process machinery owned by SwiftSlash and every byte on the
wire flowing through the shared NIO pipeline.

## Overview

A precompiled host adopts external Swift tool packages without a rebuild by
spawning each one as an MCP server over stdio and consuming its `tools/list`
catalog. This is the `.dylib` alternative that everyone actually ships (Claude
Desktop, Cursor, agent harnesses): released binaries gain new tools with zero
link-time changes.

``SubprocessClientTransport`` implements this with **SwiftSlash 5.0
bring-your-own data channels** plus a NIO pipe channel:

```
pipe(stdin)  [childRead + parentWrite]   child end → .byo(fd:)   (child reads)
pipe(stdout) [parentRead + childWrite]   child end → .byo(fd:)   (child writes)
stderr                                   SwiftSlash built-in line stream → logger + tail
```

- The **child-facing** pipe ends are handed to SwiftSlash via
  `ChildRead.byo(fd:)` / `ChildWrite.byo(fd:)`. SwiftSlash `dup2`s them onto
  the child and then stays out of the data path entirely — it never reads,
  writes, registers, mutates, or closes them, while reaping and cancellation
  stay intact.
- The **parent-facing** ends become a NIO duplex pipe channel (input = the
  stdout read end, output = the stdin write end) running the same
  `MCPFrameCodec` every carrier uses. SwiftSlash owns the process lifecycle;
  NIO owns all data flow.
- **stderr** stays on SwiftSlash's built-in line stream (mixed built-in + BYO
  per-fd is supported): lines go to the logger and the last 50 are retained for
  crash diagnostics.

## The shutdown ladder

MCP over stdio has no shutdown RPC — **EOF on the child's stdin is the
shutdown signal**. `SubprocessClientTransport.stop()` runs a strictly-ordered
ladder, and SwiftSlash guarantees the reap on every rung:

```
1. close the transport's stdin write end + the channel  → child's stdin EOF
2. wait a grace period (default 2s)                     → clean exit wins
3. SIGTERM to the whole process group (kill(-pid))      → descendants die too
4. SIGKILL to the process group                         → guaranteed reap
```

The transport owns the parent's stdin-write fd itself (NIO gets a duplicate),
so rung 1 is deterministic: an EOF arrives the instant the fd closes, not
whenever NIO happens to release its copy.

## PITFALL: `FD_CLOEXEC` on every parent pipe end

`posix_spawn` inherits every non-CLOEXEC descriptor into the child. If any
parent pipe end (including the duplicates handed to NIO) escapes into the
child, the child holds its own copy of its **stdin write end** — and then
stdin EOF can never arrive, so the clean-shutdown ladder always escalates to
signals (and leaked children pile up across runs).

The carrier therefore marks every pipe end `FD_CLOEXEC` at creation and every
NIO duplicate the same way. At exec, the child holds exactly its stdio, bound
through SwiftSlash's BYO file actions. The server side follows the same
discipline in `StdioTransport`.

> **Hosting-daemon fd hygiene:** SwiftSlash does not set
> `POSIX_SPAWN_CLOEXEC_DEFAULT`, so a host's own non-CLOEXEC descriptors are
> inherited into the spawned tool child (fd-table pollution). The child's
> framing is unaffected — it only ever duplicates fd 0/1 — but hosts that
> spawn plugin children while holding sockets or pipes should `FD_CLOEXEC`
> those themselves.

## Session-end resource release

A session ends either through `close()` (the shutdown ladder) or when the
child exits on its own (server EOF or crash). Both paths release the
transport's resources exactly once:

- `stop()` closes the retained pipe ends and the channel in its snapshot
  (orderly path); the ladder then reaps the child.
- When the child exits without a `stop()`, the reaper observes the exit and
  releases the same fds, drops the process handle (so SwiftSlash frees its
  stderr pipe), and tears the NIO channel down. Whichever path clears the
  state first is the only one that closes.

Per-session fd growth is regression-tested at zero.

## Timeouts

Per-request deadlines and the ladder's grace are two unstructured `Task`s
resolving a continuation exactly once through a Mutex gate (`ResumeOnce`).
Both paths win-or-lose through the actor's in-flight table (`removeValue` is
exclusive), so a late reply after a timeout is quietly dropped — never a
double-resume or a leaked continuation. Task-group racing is deliberately
avoided for this: group-child scheduling is unreliable in strict-concurrency
builds on this toolchain, while plain unstructured tasks are consistent.

## Verification discipline

Never trust self-round-trip tests alone.

- **Server role**: drive the built server binary over stdio with an
  independent client (e.g. the official mcp Python SDK) — `initialize` →
  `list_tools` → `call_tool` under a bounded deadline. Run the SDK's own
  server as the control first; if the control fails, the harness is broken,
  not the server.
- **Client role**: drive an independent stdio server with ``MCPClient`` over
  `SubprocessClientTransport`, and verify the ladder against a
  signal-resistant child — one that ignores both stdin EOF and SIGTERM (e.g.
  `trap '' TERM; while true; do sleep 1; done`) — so the SIGKILL rung is
  exercised and the process is reaped with no hang.

## Related Articles

- <doc:MCPClientRole> — the actor that consumes the carrier
- <doc:TransportDesign> — framing and the unified NIO pipeline
