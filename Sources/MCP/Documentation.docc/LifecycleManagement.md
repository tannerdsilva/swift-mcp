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

This creates a ``ServiceGroup`` with the server as the only service, configures
signal handling for SIGTERM and SIGINT, and configures the server service with
``.gracefullyShutdownGroup`` success termination — so the process exits cleanly
both when a signal is received and when the transport completes on its own
(client EOF on stdio, or listener close on TCP). ``runService()`` returns
normally in both cases.

### Custom ServiceGroup

For full control, create your own ``ServiceGroup``. When you want a standalone
process that exits when the MCP session ends, give the server the same
``.gracefullyShutdownGroup`` success behavior ``runService()`` uses; a host
that should keep running after the session ends can instead use ``.ignore``
(or the default ``.cancelGroup``, which surfaces a completed session as an
error).

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
let serviceGroup = ServiceGroup(
    configuration: ServiceGroupConfiguration(
        services: [
            ServiceGroupConfiguration.ServiceConfiguration(
                service: server,
                successTerminationBehavior: .gracefullyShutdownGroup
            )
        ],
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

A ``ServiceGroup`` shuts its services down in reverse declaration order. For
the MCP server:

- **Signal-initiated shutdown**: the graceful-shutdown handler registered in
  ``MCPServer/run()`` calls ``MCPTransport/stop()`` on the transport.
- **Transport completion**: when the transport finishes on its own — client
  EOF on the stdio pipe, or the TCP listener closing — the server's `run()`
  returns and the group applies the service's success termination behavior.

For the MCP server specifically:

- **StdioTransport**: the poll-based read loop observes the stop flag within
  one poll interval (250 ms), so shutdown is prompt even while the peer is
  silent. A clean client EOF ends the read loop gracefully — the server
  completes instead of crashing with an "unexpected finish" error.
- **TCPTransport**: the listening channel is closed; the server stops accepting
  and ``MCPServer/run()`` returns.
- **Registered tools**: no explicit cleanup needed (tools are value types).

## Transport Lifecycle

``MCPServer/run()`` drives the transport directly — it is not wrapped in a
nested ``ServiceGroup``. A graceful-shutdown handler around the transport's
``start(handler:)`` fans ``MCPTransport/stop()`` out to the transport, so any
transport can unwind promptly on shutdown. ``runService()`` owns the outermost
``ServiceGroup`` and its termination behavior; hosts embedding the server in
their own group configure that behavior themselves (see above).

## Related Articles

- <doc:ServerConfiguration>
- <doc:TransportDesign>
- <doc:Architecture>
