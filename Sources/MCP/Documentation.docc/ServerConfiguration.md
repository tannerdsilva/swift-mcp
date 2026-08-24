# Server Configuration

How to configure the MCP server, including transports, addresses, tool
registration, and running it.

## Overview

The ``MCPServer`` class is the main entry point for creating an MCP server. It
handles tool registration, JSON-RPC message routing, transport I/O, and
lifecycle management via Swift Service Lifecycle.

## Creating a Server

```swift
// Uses StdioTransport by default
let server = MCPServer(name: "my-server", version: "1.0.0")

// With tools registered via the result builder
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
    Calculate()
}
```

## Transport Configuration

### Stdio Transport (Default)

Stdio requires no configuration:

```swift
let server = MCPServer(name: "demo", version: "1.0.0")
```

### TCP Transport with Address

```swift
let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    address: .hostname("127.0.0.1", port: 8080)
)
```

`ServerAddress` supports IPv4, IPv6, dual-stack, and Unix domain sockets — see
<doc:TransportDesign>.

### TCP Transport with Custom Access Resolver

```swift
let transport = TCPTransport(
    address: .hostname("0.0.0.0", port: 8080),
    accessResolver: { address in
        if address.hasPrefix("[IPv4]127.0.0.1") { return .admin }
        return .public
    }
)
let server = MCPServer(name: "demo", version: "1.0.0", transport: transport)
```

The server also offers a convenience initializer that builds the
``TCPTransport`` for you:

```swift
let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    address: .hostname("0.0.0.0", port: 8080),
    accessResolver: { address in address.hasPrefix("[IPv4]127.0.0.1") ? .admin : .public }
)
```

### Custom Transport

Any ``MCPTransport`` implementation can be injected:

```swift
let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    transport: MyHTTPTransport()
)
```

## Tool Registration

### Imperative

```swift
let server = MCPServer(name: "demo", version: "1.0.0")
server.register(Greet())
server.register(Calculate())
```

### Result Builder

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
    Calculate()
    if isDebug {
        DebugTool()
    }
}
```

### Dynamic Registration and Unregistration

```swift
server.register(GetWeather())
server.unregister("getWeather")  // Remove a tool at runtime
```

If a tool with the same name is already registered, a warning is logged and
the existing tool is overwritten. Instance-registered tools use
``MCPServer/registerInstance(_:instance:)``; note that instance-registered
tools are not filtered by access level (only type-registered tools are).

### Macro Application

```swift
@main
@MCPApplication(name: "demo", version: "1.0.0")
struct MyApp {
    @Tool var greet = Greet()
    @Tool var calculate = Calculate()
}
```

## Running the Server

The server conforms to the `Service` protocol and must be run via a
``ServiceGroup``.

```swift
// Simple (recommended): signal-based graceful shutdown on SIGTERM/SIGINT
try await server.runService()

// Custom ServiceGroup
let serviceGroup = ServiceGroup(
    configuration: ServiceGroupConfiguration(
        services: [server],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: server.logger
    )
)
try await serviceGroup.run()
```

See <doc:LifecycleManagement> for combining the server with other services.

## Logging

The server uses `Logging` from swift-log with a fixed label (`mcp.server`).
Control verbosity through the server's ``MCPServer/logLevel`` property:

```swift
let server = MCPServer(name: "demo", version: "1.0.0")
server.logLevel = .debug
```

## Related Articles

- <doc:GettingStarted>
- <doc:TransportDesign>
- <doc:LifecycleManagement>
- <doc:AccessControl>
