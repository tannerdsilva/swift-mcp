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

### Property Wrappers Are Value Types

All property wrappers (`@Argument`, `@Option`, `@Flag`, `@OptionGroup` — the same types work for both direct `MCPTool` conformance and the `@MCPCommand` macro) are implemented as **structs** (value types) conforming to `MCPParamProtocol` (and `StaticMCPGroup` is synthesized onto option-group structs by `@MCPOptionGroup`). No `AnyObject` constraint and no `@unchecked Sendable` are needed.

**Why**: Parameter discovery and argument injection are generated at compile time by the macros, so the framework never reflects on wrapper instances at runtime. Value types keep the wrappers simple and give `Sendable` conformance for free.

### Compile-Time Parameter Discovery

Parameter discovery is generated at compile time by the `@MCPCommand`/`@Tool` macros — no reflection, no manual registration.

**How it works**:
1. The macro parses the struct's member declarations with SwiftSyntax
2. Each property wrapped in `@Argument`/`@Option`/`@Flag` becomes an `MCPParameterInfo` entry in a statically-typed `discoverParameters()`
3. Each `@MCPOptionGroup` property is flattened into the parent's parameter list using the group's generated metadata
4. `apply(arguments:)` is generated with direct `_setValue(_:)` calls

### Option-Group Macro

`@MCPOptionGroup` attaches to an option-group struct and generates its flattened parameter metadata plus an `mcpApply(arguments:)` method on the group type itself:

```swift
@MCPOptionGroup
struct SharedOptions {
    @Option(description: "Verbose output") var verbose: Bool = false
    @Option(description: "Output path")    var outputPath: String = "."
}
```

**Why**: Generating the group's metadata and apply logic at compile time lets the parent `@MCPCommand` macro inline the group's parameters without runtime reflection, and the group stays a plain value type.

### One Wrapper Set

The project has a **single set** of property wrappers — `@Argument`, `@Option`, `@Flag`, `@OptionGroup` — used both with direct `MCPTool` conformance and with the `@MCPCommand` macro. They are value-type structs conforming to `MCPParamProtocol`; option-group structs gain a `StaticMCPGroup` conformance from `@MCPOptionGroup`, so the macros generate identical code for either usage.

### Macro Architecture

The `@MCPCommand` macro is an `@attached(extension, conformances: MCPTool)` macro. It:

1. Parses the struct's member declarations using SwiftSyntax
2. Identifies `@Argument`, `@Option`, `@Flag`, and `@OptionGroup` wrapped properties
3. Generates an extension with `MCPTool` conformance — including `discoverParameters()` and `apply(arguments:)` — and a nested `CLI` struct

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

### Parameter Discovery (Compile Time)

```
             source struct (read by SwiftSyntax)
@MCPCommand struct Greet
         │
         ├── parser reads member declarations
         │      ├── @Argument _name
         │      ├── @Option   _count
         │      └── @OptionGroup _shared: SharedOptions
         │              └── @MCPOptionGroup flattens group metadata
         │                    ├── _verbose → MCPParameterInfo
         │                    └── _path    → MCPParameterInfo
         │
         ├── generates discoverParameters() → [MCPParameterInfo]
         │      ├── name, count
         │      └── verbose, path (flattened from SharedOptions metadata)
         │
         └── generates apply(arguments:)
                ├── arguments["name"]  → _name._setValue(...)
                ├── arguments["count"] → _count._setValue(...)
                └── arguments["verbose"] → SharedOptions.mcpApply(arguments)
```
