# Server Configuration

How to configure the MCP server, including transports, addresses, and tool registration.

## Overview

The ``MCPServer`` class is the main entry point for creating an MCP server. It handles tool registration, JSON-RPC message routing, transport I/O, and lifecycle management.

## Basic Configuration

```swift
let server = MCPServer(
    name: "my-server",
    version: "1.0.0",
    transport: StdioTransport(),  // default
    logger: Logger(label: "my-server")
)
```

## Transport Configuration

### Stdio Transport (Default)

```swift
let server = MCPServer(name: "demo", version: "1.0.0")
// Uses StdioTransport by default
```

### TCP Transport with Address

```swift
let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    address: .hostname("127.0.0.1", port: 8080)
)
```

### TCP Transport with Custom Access Resolver

```swift
let transport = TCPTransport(
    address: .hostname("0.0.0.0", port: 8080),
    allowIPv4MappedIPv6: true,
    accessResolver: { address in
        if address.hasPrefix("127.0.0.1") { return .admin }
        if address.hasPrefix("10.") { return .authenticated }
        return .public
    }
)
let server = MCPServer(name: "demo", version: "1.0.0", transport: transport)
```

### Unix Domain Socket

```swift
let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    address: .unixDomainSocket(path: "/tmp/mcp.sock")
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
}
```

### Dynamic Registration and Unregistration

```swift
server.register(GetWeather())
server.unregister("get_weather")  // Remove a tool at runtime
```

If a tool with the same name is already registered, a warning is logged and the existing tool is overwritten.

### Macro Application

```swift
@MCPApplication(name: "demo", version: "1.0.0")
struct MyApp {
    @Tool var greet = Greet()
    @Tool var calculate = Calculate()
}
```

## Running the Server

```swift
// Simple (recommended)
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

## Logging

The server uses ``Logging`` from swift-log. Configure the logger to control verbosity:

```swift
var logger = Logger(label: "mcp.server")
logger.logLevel = .debug

let server = MCPServer(
    name: "demo",
    version: "1.0.0",
    logger: logger
)
```

## Related Articles

- <doc:GettingStarted>
- <doc:TransportDesign>
- <doc:LifecycleManagement>
- <doc:AccessControl>
