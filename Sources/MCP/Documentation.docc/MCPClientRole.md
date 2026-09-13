# MCP Client Role

Using swift-mcp to *consume* tools — as an MCP client over any carrier.

## Overview

The framework plays both roles on the MCP wire. The server role serves tools;
the client role discovers and invokes tools offered by a peer — a spawned
tool-server binary (MCP-by-subprocess), a networked server, or an in-process
compile-time dispatcher (network-free MCP). ``MCPClient`` is the actor that
owns the connection, and a ``ClientTransport`` is the medium it speaks over.

```swift
import MCP

// (1) spawn a tool-server binary and speak MCP over its stdio
let transport = SubprocessClientTransport(configuration: .init(
    executable: "/usr/local/bin/tool-server"
))

// (2) or connect to a networked server
// let transport = TCPClientTransport(configuration: .init(
//     address: .hostname("127.0.0.1", port: 8080)
// ))

// (3) or run network-free over a compile-time dispatcher
// let transport = LocalClientTransport(dispatcher: MyApp())

let client = MCPClient(transport: transport)

try await client.connect()                       // spawn/connect + initialize
let tools = try await client.listTools()         // remote catalog
let result = try await client.callTool("greet", arguments: ["name": "Ada"])
await client.close()                             // graceful shutdown ladder
```

## The client state machine

``MCPClient`` is an `actor` with a strict state progression:

```
idle → spawning → handshake → ready → shuttingDown → disconnected
```

- **`connect()`** brings the carrier up (spawns the child, connects the
  socket, or prepares the in-process surface), starts a single read-loop task
  over the carrier's `frames()`, and completes the `initialize` handshake.
  Protocol-version negotiation mirrors the server's supported set: the client
  requests the newest version and accepts the server's answer when it is
  supported; a disjoint set fails the handshake.
- **`listTools()`** fetches the remote catalog and caches it. A
  `notifications/tools/list_changed` notification invalidates the cache —
  catalogs are rebuilt, never trusted from memory.
- **`callTool(_:arguments:)`** invokes a remote tool. A tool-level failure
  (the server reports `isError`) returns an ``MCPToolResult`` with `isError`
  set; a JSON-RPC-level error throws
  ``MCPClientError/remoteError(code:message:)``.
- **`close()`** asks an EOF-exit peer to wind down cooperatively (the
  best-effort `shutdown` extension — unsupported peers fall back to EOF and
  the signal ladder), then runs the carrier's termination and moves to
  `disconnected`.

## Lifecycle philosophy: one shot, by design

`MCPClient` is deliberately **not** reconnecting. With no network layer there
is no transient failure to retry: a subprocess plugin either works or it
doesn't, and after EOF/close the client is `disconnected` for good. A host
that wants a crashed plugin back builds a fresh client; the in-process test
suite treats respawn as a new connection, not a recovery. (The client itself
is cheap — the connection, not the process, is the disposable unit.)

Every request is correlated by JSON-RPC id through an actor-owned in-flight
table (out-of-order replies are safe) and carries a deadline
(``MCPClient/ClientConfiguration``): a stuck peer can never hang the caller.
When a per-call deadline expires, the client emits `notifications/cancelled`
for that request id, so a server-side in-flight tool is interrupted at its next
cooperative suspend point instead of running on with the caller's identity.
Caller task cancellation is wired to the same mechanism: cancelling the `Task`
awaiting any request (`callTool`, `listTools`, `ping`) surfaces
`CancellationError` promptly and emits the same `notifications/cancelled`, so
the remote invocation stops at its next cooperative suspend point instead of
outliving the caller. Late replies, deadline reapers, and concurrent cancels
race through the in-flight table and resolve exactly once. On
plain EOF, every in-flight request fails with ``MCPClientError/connectionClosed``
— unless the carrier recorded a size-cap teardown, in which case calls fail
with ``MCPClientError/messageTooLarge(_:)``.

## The carriers

A ``ClientTransport`` implements `start()`, `sendFrame(_:)` (write-to-
completion with real backpressure), `frames()` (an `AsyncStream` of complete
frames until EOF), and `stop()`.

| Carrier | Medium | Use when |
|---|---|---|
| ``SubprocessClientTransport`` | a spawned tool-server binary over its stdio (SwiftSlash v5 BYO + NIO pipe channel) | adopt an external Swift tool package without a rebuild — the `.dylib` alternative that actually ships |
| ``TCPClientTransport`` | a NIO socket channel (hostname + port or Unix domain socket) | talk to a networked MCP server |
| ``LocalClientTransport`` | **no bytes at all** — drives the shared routing core directly | compile-time (embedded) binding to a macro-generated ``MCPToolDispatcher`` |

The actor is deliberately carrier-agnostic: the same state machine, timeouts,
and catalog logic run identically over all three, so network-free MCP is a
configuration, not a fork.

## Environment & trust boundary (subprocess)

By default the child inherits the **full parent environment**, with
``SubprocessClientTransport/Configuration/environment`` merged over it (values
here win), followed by the framework's own plumbing
(`MCP_ACCESS_LEVEL`, optional `MCP_CALLER_IDENT`). SwiftSlash passes the dict
to `posix_spawn` as the child's **complete** envp, so inheritance is done
explicitly by this transport rather than by the OS.

That has a real consequence for hosts holding secrets: a spawned plugin can
read every host environment variable and shares the host uid. `trustLevel` is
policy signaling from the harness to its own first-party child — it is **not**
a security boundary. Treat spawned plugins as extensions of the harness
process, not contained parties. To scrub, set
`inheritParentEnvironment: false` and pass exactly the variables the plugin
needs; the resulting dict (plus the MCP plumbing) is the child's entire
environment.

`ClientTransport.frames()` returns a backpressured ``ClientFrameSequence``:
the carrier pauses reads at a high watermark and resumes below a low one, so a
slow consumer backpressures the peer instead of buffering without bound, and
frames are never dropped.

## Serving a plugin from a host `ServiceGroup`

For a host that owns a `ServiceGroup` (a daemon, an agent harness),
``MCPClientService`` wraps one subprocess plugin as a `Service`: it spawns the
child, negotiates, fetches the catalog, then idles until the connection drops
or the group shuts down — the shutdown ladder runs inside `run()`, per the
Second Law.

```swift
let plugin = MCPClientService(transport: SubprocessClientTransport(
    configuration: .init(executable: "/usr/local/bin/tool-server")
))
let group = ServiceGroup(configuration: .init(
    services: [
        ServiceGroupConfiguration.ServiceConfiguration(
            service: plugin,
            successTerminationBehavior: .gracefullyShutdownGroup
        )
    ],
    gracefulShutdownSignals: [.sigterm, .sigint]
))
try await group.run()
```

## Errors

All client faults throw ``MCPClientError`` (Foundation-free, `Equatable`,
`CustomStringConvertible`): `notConnected`, `connectionClosed`, `callTimeout`,
`negotiationTimeout`, `unsupportedProtocolVersion`, `remoteError`,
`invalidResponse`, and the bring-up failures `spawnFailed` / `connectionFailed`.

## Related Articles

- <doc:MCPBySubprocess> — the subprocess carrier's process and shutdown machinery
- <doc:TransportDesign> — framing and the unified NIO pipeline
- <doc:IntegrationPatterns> — embedding MCP in a host
