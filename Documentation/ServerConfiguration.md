# Server Configuration

This guide covers MCP server setup, lifecycle management, transport options, and logging.

## Server Setup

```swift
import MCP

let server = MCPServer(name: "my-server", version: "1.0.0")
try await server.runService()
```

## Lifecycle Management

The server uses **Swift Service Lifecycle** (`swift-service-lifecycle`) as its primary runtime mechanism. `MCPServer` conforms to the `Service` protocol and must be run via a `ServiceGroup`.

### `runService()` (Recommended)

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
try await server.runService()
```

This wraps the server in a `ServiceGroup` with signal-based graceful shutdown. The server will cleanly shut down when it receives `SIGTERM` or `SIGINT`.

### Custom ServiceGroup

For full control over the lifecycle configuration:

```swift
import ServiceLifecycle
import UnixSignals

let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
let serviceGroup = ServiceGroup(
    configuration: .init(
        services: [server],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: server.logger
    )
)
try await serviceGroup.run()
```

### Combining with Other Services

You can run the MCP server alongside other services in the same `ServiceGroup`:

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
let healthCheck = ClosureService {
    // Periodic health check logic
}
let serviceGroup = ServiceGroup(
    configuration: .init(
        services: [server, healthCheck],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: server.logger
    )
)
try await serviceGroup.run()
```

## Transport Options

### Stdio Transport (Default)

The stdio transport reads newline-delimited JSON from stdin and writes responses to stdout. This is the standard transport for MCP servers launched as subprocesses.

```swift
// Default (stdio)
let server = MCPServer(name: "demo", version: "1.0.0")

// Explicit
let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    transport: StdioTransport()
)
```

### Custom Transport

Implement the `MCPTransport` protocol for custom transports:

```swift
import MCP

struct HTTPTransport: MCPTransport {
    func start(handler: @Sendable @escaping (Data) async throws -> Data?) async throws {
        // Start HTTP server, call handler for each request
    }

    func stop() async throws {
        // Shut down the server
    }
}
```

## Logging

The server uses Swift Logging (`swift-log`) for structured logging:

```swift
import Logging
import MCP

var logger = Logger(label: "com.example.mcp")
logger.logLevel = .debug

let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    logger: logger
)
```

## Tool Registration

### Imperative

```swift
let server = MCPServer(name: "demo", version: "1.0.0")
server.register(GetWeather())
server.register(Greet())
```

### Declarative (Result Builder)

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    GetWeather()
    Greet()
    if isDebug {
        DebugTool()
    }
}
```

### Dynamic Registration and Unregistration

Tools can be registered and unregistered at runtime:

```swift
server.register(GetWeather())
server.unregister("get_weather")  // Remove a tool by name
```

If a tool with the same name is already registered, a warning is logged and the existing tool is overwritten.

## Logging Levels

The server emits structured log messages at the following levels:

| Level | When it fires |
|---|---|
| `trace` | Every JSON-RPC message received/sent |
| `debug` | Tool registration with type info |
| `info` | Server start/stop, tool registration/unregistration |
| `warning` | Unknown methods, tool name collision, unregistering unknown tool |
| `error` | Errors are returned as JSON-RPC error responses |

Configure the log level via the logger:

```swift
var logger = Logger(label: "com.example.mcp")
logger.logLevel = .info  // Only info and above
```

## Supported Protocol Methods

| Method | Description |
|---|---|
| `initialize` | Server capability advertisement |
| `ping` | Health check |
| `tools/list` | List available tools with JSON Schema |
| `tools/call` | Invoke a tool with arguments |
| `notifications/initialized` | Acknowledged (no-op) |
| `notifications/cancelled` | Acknowledged (no-op) |
