# Example: Server Configuration

This article covers every way to configure and launch an MCP server — stdio,
TCP with explicit IP bindings, Unix domain sockets, dual-stack, custom
ServiceGroup setups, and multi-service configurations.

## Table of Contents

- [Stdio Transport (Default)](#stdio-transport-default)
- [TCP with IPv4](#tcp-with-ipv4)
- [TCP with IPv6](#tcp-with-ipv6)
- [Dual-Stack Binding](#dual-stack-binding)
- [Unix Domain Socket](#unix-domain-socket)
- [Custom ServiceGroup](#custom-servicegroup)
- [Multi-Service Configuration](#multi-service-configuration)
- [Custom Transport](#custom-transport)
- [Access Control Configuration](#access-control-configuration)
- [Logging Configuration](#logging-configuration)
- [Complete Configuration Example](#complete-configuration-example)

---

## Stdio Transport (Default)

The simplest setup — reads JSON-RPC from stdin, writes to stdout. Ideal for
CLI subprocess mode where an MCP client (like an AI assistant) spawns the
server as a child process.

```swift
import MCP

@MCPCommand(description: "Greet someone")
struct Greet {
    @Argument(description: "Name") var name: String = ""
    func run() async throws -> String { "Hello, \(name)!" }
}

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(name: "MyServer", version: "1.0.0") {
            Greet()
        }
        try await server.runService()
    }
}
```

**Run it:**

```bash
swift run
# In another terminal, send JSON-RPC:
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"greet","arguments":{"name":"World"}}}' | nc localhost 8080
```

Wait — that's stdio, not TCP. For stdio, pipe the message directly:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"greet","arguments":{"name":"World"}}}' | swift run
```

---

## TCP with IPv4

Bind to a specific IPv4 address and port using the `address:` parameter:

```swift
import MCP

let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    address: .hostname("127.0.0.1", port: 8080)  // localhost only
) {
    Greet()
    Calculate()
}
try await server.runService()
```

### Convenience Methods

```swift
// Localhost only (127.0.0.1:8080)
let server = MCPServer(name: "s", version: "1.0",
    address: .localhostIPv4(port: 8080)) { ... }

// All IPv4 interfaces (0.0.0.0:8080)
let server = MCPServer(name: "s", version: "1.0",
    address: .allInterfacesIPv4(port: 8080)) { ... }

// Specific interface
let server = MCPServer(name: "s", version: "1.0",
    address: .hostname("10.0.1.50", port: 9090)) { ... }
```

### Testing IPv4 Binding

```bash
# Start the server (it will block)
swift run

# In another terminal:
curl -X POST http://127.0.0.1:8080 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# Or use nc:
echo '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' | nc 127.0.0.1 8080
```

---

## TCP with IPv6

Bind to IPv6 addresses. On macOS, binding to `::1` gives you IPv6-localhost
only. On Linux, you may need to configure `IPV6_V6ONLY` behavior.

```swift
// IPv6 localhost only
let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    address: .hostname("::1", port: 8080)
) { ... }

// All IPv6 interfaces
let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    address: .hostname("::", port: 8080)
) { ... }

// Convenience
let server = MCPServer(name: "s", version: "1.0",
    address: .localhostIPv6(port: 8080)) { ... }
```

### Testing IPv6

```bash
# Using curl with IPv6
curl -g -X POST http://[::1]:8080 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}'

# Using nc with IPv6
echo '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' | nc -6 ::1 8080
```

---

## Dual-Stack Binding

On macOS (Darwin), binding to `::` (all IPv6 interfaces) automatically enables
dual-stack mode — the server accepts both IPv4 and IPv6 connections. On Linux,
you need to explicitly disable `IPV6_V6ONLY` by passing `allowIPv4MappedIPv6: true`.

```swift
// macOS — dual-stack is automatic
let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    address: .allInterfacesIPv6(port: 8080)
) { ... }

// Linux — explicit dual-stack opt-in
let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    address: .hostname("::", port: 8080),
    allowIPv4MappedIPv6: true  // disables IPV6_V6ONLY
) { ... }
```

### Dual-Stack Test

```bash
# Both of these reach the same server:
curl http://127.0.0.1:8080 ...
curl -g http://[::1]:8080 ...
```

### Platform Behavior

| Platform | `::` binding | `allowIPv4MappedIPv6: true` |
|---|---|---|
| macOS | Dual-stack by default | No effect (already dual-stack) |
| Linux | IPv6 only | Disables `IPV6_V6ONLY`, enables dual-stack |
| Other Unix | IPv6 only | Disables `IPV6_V6ONLY`, enables dual-stack |

---

## Unix Domain Socket

For local IPC with higher throughput and no port conflicts:

```swift
let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    address: .unixDomainSocket(path: "/tmp/mcp-server.sock")
) { ... }
```

### Testing Unix Domain Socket

```bash
# Using nc:
echo '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' \
  | nc -U /tmp/mcp-server.sock

# Using curl (macOS):
curl --unix-socket /tmp/mcp-server.sock http://localhost/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

### Socket Cleanup

The transport automatically removes the socket file on bind. If the server
crashes, you may need to clean up manually:

```bash
rm -f /tmp/mcp-server.sock
```

---

## Custom ServiceGroup

For full control over lifecycle — custom signals, multiple services, custom
grace period:

```swift
import MCP
import ServiceLifecycle
import UnixSignals

let server = MCPServer(name: "MyServer", version: "1.0.0") {
    Greet()
    Calculate()
}

let serviceGroup = ServiceGroup(
    configuration: ServiceGroupConfiguration(
        services: [server],
        gracefulShutdownSignals: [
            .sigterm,
            .sigint,
            .sighup    // also reload on SIGHUP
        ],
        logger: server.logger
    )
)
try await serviceGroup.run()
```

### Custom Grace Period

```swift
let serviceGroup = ServiceGroup(
    configuration: ServiceGroupConfiguration(
        services: [server],
        gracefulShutdownSignals: [.sigterm, .sigint],
        gracefulShutdownDuration: .seconds(30),  // 30s grace period
        logger: server.logger
    )
)
```

---

## Multi-Service Configuration

Run multiple MCP servers (or an MCP server alongside other services) in the
same process:

```swift
import MCP
import ServiceLifecycle

let server1 = MCPServer(name: "API", version: "1.0.0",
    address: .localhostIPv4(port: 8080)) {
    Greet()
    Calculate()
}

let server2 = MCPServer(name: "Admin", version: "1.0.0",
    address: .localhostIPv4(port: 9090)) {
    Health()
    Metrics()
}

let serviceGroup = ServiceGroup(
    configuration: ServiceGroupConfiguration(
        services: [server1, server2],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: Logger(label: "mcp.multi")
    )
)
try await serviceGroup.run()
```

### MCP Server + Health HTTP Server

```swift
import MCP
import ServiceLifecycle
import NIOHTTP1

let mcpServer = MCPServer(name: "App", version: "1.0.0",
    address: .localhostIPv4(port: 8080)) {
    Query()
    Command()
}

// A lightweight health-check HTTP server
let healthService = ClosureService {
    let channel = try await ServerBootstrap(group: .singleton)
        .bind(host: "127.0.0.1", port: 9090).get()
    // ... handle HTTP health checks ...
    try await channel.closeFuture.get()
}

let group = ServiceGroup(configuration: .init(
    services: [mcpServer, healthService],
    gracefulShutdownSignals: [.sigterm, .sigint]
))
try await group.run()
```

---

## Custom Transport

Implement the `MCPTransport` protocol for custom communication channels:

```swift
import MCP
import Foundation

/// A transport that communicates over WebSockets
struct WebSocketTransport: MCPTransport {
    let url: URL

    func start(
        handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?
    ) async throws {
        // WebSocket connection logic
        // On message: call handler(data, callerInfo)
        // On response: send response data back through WebSocket
    }

    func stop() async throws {
        // Clean up WebSocket connection
    }
}

// Usage
let transport = WebSocketTransport(url: URL(string: "ws://example.com/mcp")!)
let server = MCPServer(name: "Remote", version: "1.0.0",
    transport: transport) {
    Greet()
}
```

---

## Access Control Configuration

The TCP transport resolves caller IP addresses to access levels. Configure
custom resolution logic:

```swift
import MCP

// Allow only localhost for admin tools
let transport = TCPTransport(
    address: .hostname("0.0.0.0", port: 8080),
    accessResolver: { address in
        if address == "127.0.0.1" || address == "::1" {
            return .admin
        } else if address.hasPrefix("10.0.") || address.hasPrefix("192.168.") {
            return .user
        } else {
            return .public
        }
    }
)

let server = MCPServer(
    name: "SecureServer",
    version: "1.0.0",
    transport: transport
) {
    PublicTool()
    AdminTool()  // requires .admin access
}
```

### Access Levels

```swift
public enum AccessLevel: Int, Sendable, Comparable {
    case `public` = 0
    case user = 10
    case admin = 20
}
```

Tools declare their required access level:

```swift
@MCPCommand(
    description: "Shutdown the server",
    requiredAccess: .admin
)
struct Shutdown {
    func run() async throws -> String {
        // Only callers with .admin access can invoke this
        "Shutting down..."
    }
}
```

---

## Logging Configuration

```swift
import Logging

// Custom logger
var logger = Logger(label: "mcp.my-server")
logger.logLevel = .debug

let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    logger: logger
) {
    Greet()
}
```

### Logging Levels

| Level | When it fires |
|---|---|
| `trace` | Every JSON-RPC message received/sent |
| `debug` | Tool registration with type info |
| `info` | Server start/stop, tool registration/unregistration |
| `warning` | Unknown methods, tool name collision, unregistering unknown tool |
| `error` | Errors are returned as JSON-RPC error responses (use `logLevel = .warning` to see them) |

---

## Complete Configuration Example

A production-ready server with all options:

```swift
import MCP
import Logging
import ServiceLifecycle
import UnixSignals

// MARK: - Tools

@MCPCommand(description: "Query the database")
struct Query {
    @Argument(description: "SQL query") var sql: String = ""
    func run() async throws -> String { "Executing: \(sql)" }
}

@MCPCommand(
    description: "Admin: reload configuration",
    requiredAccess: .admin
)
struct Reload {
    func run() async throws -> String { "Configuration reloaded" }
}

// MARK: - Server

@main
struct Main {
    static func main() async throws {
        let logger: Logger = {
            var l = Logger(label: "mcp.production")
            l.logLevel = .info
            return l
        }()

        let server = MCPServer(
            name: "ProductionServer",
            version: "2.1.0",
            address: .hostname("::", port: 8080),
            allowIPv4MappedIPv6: true,
            logger: logger
        ) {
            Query()
            Reload()
        }

        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [server],
                gracefulShutdownSignals: [.sigterm, .sigint],
                gracefulShutdownDuration: .seconds(60),
                logger: logger
            )
        )

        logger.info("Starting ProductionServer v2.1.0 on port 8080")
        try await serviceGroup.run()
    }
}
```
