# Transport Design

How MCP communication works, and how to build custom transports for either role.

## Overview

swift-mcp has **one NIO pipeline and many carriers**. Framing and routing are
single-sourced so no deployment can drift:

- **Framing** — `MCPFrameCodec` is the one `ChannelDuplexHandler` doing
  newline-delimited JSON-RPC framing with a per-frame size cap. Every carrier —
  server TCP, server stdio, and the client carriers — runs it, so the wire
  format (and the limit) cannot differ by medium.
- **Routing** — the byte-level JSON-RPC routing core (`MCPMessageRouter`)
  handles batches, id-routing, `initialize` negotiation, `tools/list`,
  `tools/call`, access gates, and error mapping. It owns the tool registries;
  ``MCPServer`` is a thin facade over it, and the network-free client carrier
  drives it with zero bytes.
- **Two roles** — the server role exposes the ``MCPTransport`` protocol; the
  client role exposes ``ClientTransport``. Both consume the shared pipeline.

## Framing & size limits

All transports speak **newline-delimited JSON**: one complete JSON-RPC 2.0
object per line, terminated by `0x0A`. JSON string literals escape newlines, so
a literal `0x0A` byte can only be a frame boundary — a partially-received
buffer is never mistaken for a frame.

```json
{"jsonrpc":"2.0","id":1,"method":"tools/list"}
{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
```

Every carrier enforces a per-frame size cap (`maxMessageSize`, 10 MiB by
default): a frame larger than the cap — whether it arrives as one complete
line or as a partial accumulate — is answered with a `-32700 Message too large`
frame and the connection closes. Memory stays bounded regardless of peer
behavior.

## The server role — `MCPTransport`

```swift
public protocol MCPTransport: Sendable {
    func start(
        handler: @Sendable @escaping ([UInt8], MCPCallerInfo) async throws -> [UInt8]?
    ) async throws
    func stop() async throws
}
```

- **start** begins processing messages. The handler receives raw JSON-RPC data
  and caller information, and returns optional response bytes. Return `nil` for
  notifications.
- **stop** causes `start` to return, after which the handler is no longer
  invoked.

### StdioTransport

The default transport for CLI-based MCP servers launched as subprocesses (Claude
Desktop, VS Code extensions, and this package's own subprocess client). Reads
newline-delimited JSON from stdin and writes to stdout; the caller is always
`.root` with source address `"stdio"`.

`StdioTransport` runs on a **NIO pipe channel**: the standard streams are
duplicated and bound to the channel, so framing, the size cap, EOF, and
shutdown are the same machinery as every other carrier — event-driven, no
polling. NIO owns the duplicates; the real fd 0/1 are never touched. Client
EOF on stdin (the session's only shutdown signal in stdio mode) ends the
session after pending responses flush.

```swift
let transport = StdioTransport(logger: logger)
```

### TCPTransport

Listens for TCP connections using newline-delimited JSON over
IPv4/IPv6/dual-stack and Unix domain sockets.

```swift
let transport = TCPTransport(
    address: .hostname("127.0.0.1", port: 8080),
    accessResolver: { address in
        address.hasPrefix("[IPv4]127.0.0.1") ? .admin : .public
    }
)
```

The ``TCPTransport`` accepts an `accessResolver` closure that maps source
addresses to ``AccessLevel`` values. This is resolved once per connection and
stamped on every message from that connection.

> The resolver receives NIO's socket description string, which includes a
> scheme prefix and the port — for example `[IPv4]127.0.0.1:54321` for IPv4
> and `[IPv6]::1:54321` for IPv6 (IPv4-mapped IPv6 renders as
> `[IPv6]::ffff:127.0.0.1:54321`). Match against the prefix form shown above
> rather than the bare address.
>
> The default resolver is ``TCPTransport/defaultAccessResolver(_:)``: it grants
> ``AccessLevel/admin`` to loopback callers (IPv4, IPv6, and IPv4-mapped IPv6,
> in both the canonical and bare spellings) and ``AccessLevel/public`` to
> everyone else.

#### Address Types

- ``ServerAddress/hostname(_:port:)`` — TCP hostname and port (IPv4 or IPv6)
- ``ServerAddress/unixDomainSocket(path:)`` — Unix domain socket

#### Dual-Stack Support

On Darwin (macOS), binding to `::` automatically accepts IPv4 connections via
IPv4-mapped IPv6 addresses. On Linux, set `allowIPv4MappedIPv6: true` to
disable `IPV6_V6ONLY`.

## The client role — `ClientTransport`

The framework also *consumes* tools as an MCP client. ``MCPClient`` runs the
full client state machine over a carrier that implements
``ClientTransport``:

```swift
public protocol ClientTransport: Sendable {
    func start() async throws
    func sendFrame(_ bytes: [UInt8]) async throws
    nonisolated func frames() -> AsyncStream<[UInt8]>
    func stop() async throws
}
```

Three carriers are built in:

- ``SubprocessClientTransport`` — spawns a standalone tool-server binary and
  speaks MCP over its stdio (MCP-by-subprocess). See
  <doc:MCPBySubprocess> for the process, fd, and shutdown machinery.
- ``TCPClientTransport`` — connects to a networked server over
  ``ServerAddress`` (hostname + port or Unix domain socket).
- ``LocalClientTransport`` — **network-free MCP**: drives the shared routing
  core directly with zero bytes and zero processes, so the same client state
  machine runs over a compile-time dispatcher with no medium at all.

The actor, in-flight table, per-call deadlines, and catalog logic are shared
across every carrier. See <doc:MCPClient> for full coverage.

## Caller Information

Every server-side message includes ``MCPCallerInfo`` with the source address
and resolved access level. This enables:

- **tools/list filtering**: only show tools the caller has access to
- **tools/call enforcement**: reject calls to tools above the caller's level
- **Audit logging**: tools can log who invoked them

Client requests carry caller identity the same way; network-free bindings run
at ``AccessLevel/root`` (a trusted, in-process caller).

## Custom Transports

Implement ``MCPTransport`` for a custom server medium:

```swift
struct WebSocketServerTransport: MCPTransport {
    func start(handler: @Sendable @escaping ([UInt8], MCPCallerInfo) async throws -> [UInt8]?) async throws {
        // Accept a WebSocket, read frames, call handler, write responses.
    }
    func stop() async throws {
        // Close connections.
    }
}
```

…and ``ClientTransport`` for a custom client medium:

```swift
struct WebSocketClientTransport: ClientTransport {
    func start() async throws { /* connect */ }
    func sendFrame(_ bytes: [UInt8]) async throws { /* frame + write */ }
    nonisolated func frames() -> AsyncStream<[UInt8]> { /* inbound frames until EOF */ }
    func stop() async throws { /* close */ }
}
```

Any custom carrier can reuse the shared framing discipline by composing the
same codec into its NIO channel pipeline.

## Related Articles

- <doc:ServerConfiguration>
- <doc:AccessControl>
- <doc:LifecycleManagement>
- <doc:MCPClientRole>
- <doc:MCPBySubprocess>
