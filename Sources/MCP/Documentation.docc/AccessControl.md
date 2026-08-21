# Access Control

How to restrict tool access based on caller identity.

## Overview

swift-mcp provides a tiered access control system. Every tool declares its required ``AccessLevel``, and the server enforces it automatically in both ``tools/list`` (filtering) and ``tools/call`` (enforcement).

## Access Levels

The ``AccessLevel`` enum defines four tiers:

| Level | Value | Description |
|---|---|---|
| ``AccessLevel/public`` | 0 | Visible to all callers. No authentication needed. |
| ``AccessLevel/authenticated`` | 1 | Visible to authenticated or internal network callers. |
| ``AccessLevel/admin`` | 2 | Visible only to administrators. |
| ``AccessLevel/root`` | 3 | Visible only to the local process (stdio transport). |

Levels are ordered: higher levels include lower ones. A caller with ``.admin`` access can see tools requiring ``.public``, ``.authenticated``, or ``.admin``.

## Declaring Requirements

### Direct Conformance

Set ``requiredAccess`` in your tool's configuration:

```swift
struct AdminTool: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Sensitive operation",
        requiredAccess: .admin
    )
}
```

### Macro

Use the ``requiredAccess`` parameter:

```swift
@MCPCommand(description: "Admin operation", requiredAccess: .admin)
struct AdminOp {
    func run() throws -> String { "done" }
}
```

## How Enforcement Works

### tools/list

The server filters tools based on the caller's access level. A caller with ``.authenticated`` access will only see tools with ``requiredAccess ≤ .authenticated``.

### tools/call

Before invoking a tool, the server checks:

```swift
guard caller.accessLevel >= toolType.configuration.requiredAccess else {
    throw MCPError.accessDenied(toolName)
}
```

If the check fails, the server returns a JSON-RPC error with code ``-32000``.

## Transport-Level Resolution

### StdioTransport

The caller is always ``.root`` with source ``"stdio"``. All tools are visible.

### TCPTransport

The ``TCPTransport`` accepts an ``accessResolver`` closure that maps source IP addresses to access levels:

```swift
let transport = TCPTransport(
    address: .hostname("0.0.0.0", port: 8080),
    accessResolver: { address in
        if address.hasPrefix("127.0.0.1") || address.hasPrefix("::1") {
            return .admin
        }
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") {
            return .authenticated
        }
        return .public
    }
)
```

The resolver is called once per connection. The resolved level is stamped on every message from that connection.

## Accessing Caller Info in Tools

Tools can access caller information via ``MCPContext/callerInfo``:

```swift
func invoke(context: MCPContext) async throws -> MCPToolResult {
    if let caller = context.callerInfo {
        logger.info("Invoked by \(caller.sourceAddress ?? "unknown")")
    }
    // ...
}
```

## Best Practices

1. **Default to ``.public``** — Most tools should be open by default. Only restrict sensitive operations.
2. **Use IP-based resolution for network deployments** — The ``accessResolver`` closure is the simplest way to map IP ranges to access levels.
3. **Keep access levels coarse** — Four levels (public, authenticated, admin, root) cover most use cases. Avoid creating many fine-grained levels.
4. **Log access denials** — Use the server's logger to track denied requests for security auditing.

## Related Articles

- <doc:TransportDesign>
- <doc:ServerConfiguration>
- <doc:MacroGuide>
