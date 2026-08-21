# Transport Design

How MCP communication channels work, and how to build custom transports.

## Overview

The ``MCPTransport`` protocol abstracts the communication channel between the MCP server and its clients. The framework provides two built-in implementations, and you can create custom transports for any communication medium.

## The Protocol

```swift
public protocol MCPTransport: Sendable {
    func start(
        handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?
    ) async throws

    func stop() async throws
}
```

- **start**: Begins processing messages. The handler receives raw JSON-RPC data and caller information, and returns optional response data. Return ``nil`` for notifications.
- **stop**: Causes ``start`` to return. After calling ``stop``, the transport should no longer invoke the handler.

## Built-in Transports

### StdioTransport

Reads newline-delimited JSON from stdin and writes to stdout. The caller is always ``.root`` with source address ``"stdio"``. This is the default transport and is suitable for CLI-based MCP servers launched as subprocesses.

```swift
let transport = StdioTransport()
```

### TCPTransport

Listens for TCP connections and communicates using newline-delimited JSON. Supports IPv4, IPv6, dual-stack, and Unix domain sockets.

```swift
let transport = TCPTransport(
    address: .hostname("127.0.0.1", port: 8080),
    accessResolver: { address in
        address.hasPrefix("127.0.0.1") ? .admin : .public
    }
)
```

The ``TCPTransport`` accepts an ``accessResolver`` closure that maps source IP addresses to ``AccessLevel`` values. This is resolved once per connection and stamped on every message from that connection.

#### Address Types

- ``ServerAddress/hostname(_:port:)`` — TCP hostname and port (IPv4 or IPv6)
- ``ServerAddress/unixDomainSocket(path:)`` — Unix domain socket

#### Dual-Stack Support

On Darwin (macOS), binding to ``::`` automatically accepts IPv4 connections via IPv4-mapped IPv6 addresses. On Linux, set ``allowIPv4MappedIPv6: true`` to disable ``IPV6_V6ONLY``.

## Caller Information

Every message includes ``MCPCallerInfo`` with the source address and resolved access level. This enables:

- **tools/list filtering**: Only show tools the caller has access to
- **tools/call enforcement**: Reject calls to tools above the caller's access level
- **Audit logging**: Tools can log who invoked them

## Custom Transports

Implement ``MCPTransport`` for any communication channel:

```swift
struct WebSocketTransport: MCPTransport {
    func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws {
        // Connect to WebSocket, read messages, call handler, write responses
    }

    func stop() async throws {
        // Close WebSocket connection
    }
}
```

## Message Format

All transports use newline-delimited JSON. Each message is a complete JSON-RPC 2.0 object on a single line, terminated by ``0x0A`` (newline).

```json
{"jsonrpc":"2.0","id":1,"method":"tools/list"}
{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
```

## Related Articles

- <doc:ServerConfiguration>
- <doc:AccessControl>
- <doc:LifecycleManagement>
