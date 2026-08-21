# Lifecycle Management

How swift-mcp integrates with Swift Service Lifecycle for process lifecycle management.

## Overview

``MCPServer`` conforms to the ``Service`` protocol from Swift Service Lifecycle. This means the server is managed by a ``ServiceGroup``, which provides signal-based graceful shutdown, service dependency ordering, and structured concurrency.

## Why Service Lifecycle?

Swift Service Lifecycle is the standard way to manage long-running server processes in the Swift ecosystem. It provides:

- **Graceful shutdown**: Services receive shutdown signals and clean up resources in order
- **Dependency ordering**: Services start in declaration order and shut down in reverse order
- **Structured concurrency**: Services run as child tasks of the service group
- **Signal handling**: Built-in support for SIGTERM, SIGINT, and other signals

## Running the Server

### Recommended: ``runService()``

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
try await server.runService()
// SIGTERM or SIGINT triggers graceful shutdown
```

This creates a ``ServiceGroup`` with the server as the only service, configures signal handling for SIGTERM and SIGINT, and runs until a signal is received.

### Custom ServiceGroup

For full control, create your own ``ServiceGroup``:

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
let serviceGroup = ServiceGroup(
    configuration: ServiceGroupConfiguration(
        services: [server],
        gracefulShutdownSignals: [.sigterm, .sigint, .sighup],
        logger: server.logger
    )
)
try await serviceGroup.run()
```

### Multiple Services

The MCP server can run alongside other services in the same ``ServiceGroup``:

```swift
let serviceGroup = ServiceGroup(
    configuration: ServiceGroupConfiguration(
        services: [
            firewallService,     // starts first
            mcpServer,           // starts second
            handshakeChecker,    // starts third
        ],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: logger
    )
)
try await serviceGroup.run()
// Shutdown order: handshakeChecker → mcpServer → firewallService
```

## Shutdown Behavior

When a signal is received:

1. ``ServiceGroup`` sends a shutdown signal to all services
2. Services stop in reverse declaration order
3. Each service's ``run()`` method returns
4. Resources are cleaned up

For the MCP server specifically:

- **StdioTransport**: The read loop exits on the next iteration
- **TCPTransport**: The listening channel is closed, active connections are drained
- **Registered tools**: No explicit cleanup needed (tools are value types)

## Transport as a Child Service

Internally, ``MCPServer.run()`` wraps the transport in a ``ClosureService`` and runs it as a child of an internal ``ServiceGroup``. This ensures the transport's lifecycle is managed alongside the server's.

## Related Articles

- <doc:ServerConfiguration>
- <doc:TransportDesign>
- <doc:Architecture>
