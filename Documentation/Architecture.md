# Architecture

This document describes the architecture and design decisions of swift-mcp.

## Overview

swift-mcp is organized into several layers:

```
┌─────────────────────────────────────────────┐
│                 MCPServer                    │
│  (Request routing, tool dispatch, JSON-RPC)  │
├─────────────────────────────────────────────┤
│               MCPTool Protocol               │
│  (Tool definition, parameter discovery)      │
├─────────────────────────────────────────────┤
│          Property Wrappers Layer             │
│  (@Argument, @Option, @Flag, etc.) │
├─────────────────────────────────────────────┤
│          JSONSchemaBuilder                   │
│  (Swift types → JSON Schema Draft 7)         │
├─────────────────────────────────────────────┤
│          Transport Layer                     │
│  (MCPTransport protocol, StdioTransport)     │
├─────────────────────────────────────────────┤
│          Protocol Layer                      │
│  (JSON-RPC types, MCP protocol messages)     │
└─────────────────────────────────────────────┘
```

## Core Design Decisions

### Property Wrappers Are Classes

All property wrappers (`@Argument`, `@Option`, `@Flag`, `@OptionGroup`, `@Argument`, `@Option`, `@Flag`, `@OptionGroup`) are implemented as **classes** (not structs) conforming to `@unchecked Sendable`.

**Why**: Mirror reflection on a tool instance returns mutable references to the wrapper objects, allowing the framework to inject argument values into the wrappers after initialization. A struct-based wrapper would be copied by Mirror, making mutation impossible.

### Mirror-Based Parameter Discovery

The framework uses `Mirror(reflecting:)` to discover parameters at runtime, avoiding the need for manual registration or compile-time code generation (beyond the optional macro).

**How it works**:
1. `MCPTool.discoverParameters()` creates an instance and reflects on it
2. It looks for children whose label starts with `_` (the synthesized backing-storage name for property wrappers)
3. Children conforming to `MCPParamProtocol` are added to the parameter list
4. Children conforming to `GroupParamProtocol` are recursively flattened

### Free Function for Discovery

The `_discoverParameters(from:)` function is a free function rather than a protocol extension method.

**Why**: Swift protocol dispatch has limitations with static methods in protocol extensions when called from instance context. A free function avoids these issues entirely.

### Dual-Use Wrappers vs Framework Wrappers

There are two sets of property wrappers:

- **Framework wrappers** (`@Argument`, `@Option`, `@Flag`, `@OptionGroup`): Used with direct `MCPTool` conformance
- **Dual-use wrappers** (`@Argument`, `@Option`, `@Flag`, `@OptionGroup`): Used with the `@MCPCommand` macro

Both sets conform to the same internal protocols (`MCPParamProtocol`, `GroupParamProtocol`), so the framework treats them identically.

### Macro Architecture

The `@MCPCommand` macro is an `@attached(extension, conformances: MCPTool)` macro. It:

1. Parses the struct's member declarations using SwiftSyntax
2. Identifies `@Argument`, `@Option`, `@Flag`, and `@OptionGroup` wrapped properties
3. Generates an extension with `MCPTool` conformance and a nested `CLI` struct

The CLI struct is wrapped in `#if canImport(ArgumentParser)` so it compiles away when ArgumentParser is not available.

### Transport Abstraction

The `MCPTransport` protocol abstracts the communication channel. The default `StdioTransport` reads newline-delimited JSON from stdin and writes to stdout. Custom transports (HTTP+SSE, WebSocket, etc.) can be implemented by conforming to the protocol.

### ServiceLifecycle Integration

`MCPServer` conforms to the `Service` protocol from `swift-service-lifecycle`. The `run()` method creates a `ServiceGroup` with the transport wrapped as a `ClosureService`. The `runService()` convenience method adds signal-based graceful shutdown (SIGTERM/SIGINT).

This follows the same pattern as Hummingbird 2.x, ensuring:
- Clean startup and shutdown sequences
- Proper resource cleanup on termination
- Signal-based graceful shutdown
- Composability with other services in the same ServiceGroup

## Data Flow

### Tool Invocation

```
Client                    Server                    Tool
  │                         │                        │
  │── tools/call ──────────>│                        │
  │                         │── tool.init() ────────>│
  │                         │── tool.apply(args) ───>│
  │                         │── tool.invoke(ctx) ───>│
  │                         │<── MCPToolResult ──────│
  │<── JSON-RPC response ───│                        │
```

### Parameter Discovery

```
discoverParameters()
  │
  ├── Mirror(reflecting: instance)
  │     │
  │     ├── _name: MCPParamProtocol  →  MCPParameterInfo
  │     ├── _count: MCPParamProtocol →  MCPParameterInfo
  │     └── _options: GroupParamProtocol
  │           │
  │           └── Mirror(reflecting: options)
  │                 ├── _verbose: MCPParamProtocol → MCPParameterInfo
  │                 └── _path: MCPParamProtocol    → MCPParameterInfo
  │
  └── [MCPParameterInfo, MCPParameterInfo, ...]
```
