# Architecture

This document describes the architecture and key design decisions of swift-mcp.

## Overview

swift-mcp is organized into layers:

```
┌─────────────────────────────────────────────┐
│                 MCPServer                    │
│  (request routing, tool dispatch, JSON-RPC)  │
├─────────────────────────────────────────────┤
│               MCPTool Protocol               │
│  (tool definition, parameter discovery)      │
├─────────────────────────────────────────────┤
│          Property Wrappers Layer             │
│  (@Argument, @Option, @Flag, @OptionGroup)   │
├─────────────────────────────────────────────┤
│          JSONSchemaBuilder                   │
│  (Swift types → JSON Schema Draft 7)         │
├─────────────────────────────────────────────┤
│          Transport Layer                     │
│  (MCPTransport, StdioTransport, TCPTransport)│
├─────────────────────────────────────────────┤
│          Protocol Layer                      │
│  (JSON-RPC types, MCP protocol messages)     │
└─────────────────────────────────────────────┘
```

## Core Design Decisions

### Property wrappers are value types

All property wrappers (`@Argument`, `@Option`, `@Flag`, `@OptionGroup`) are
implemented as **structs** (value types) conforming to ``MCPParamProtocol``.
Option-group structs gain a ``StaticMCPGroup`` conformance synthesized by
``MCPOptionGroup``. No `AnyObject` constraint and no `@unchecked Sendable`
are needed.

**Why**: parameter discovery and argument injection are generated at compile
time by the macros, so the framework never reflects on wrapper instances at
runtime. Value types keep the wrappers simple and give `Sendable` conformance
for free.

### Compile-time parameter discovery

Parameter discovery is generated at compile time by the ``MCPCommand`` /
``FuncTool`` macros — no reflection, no manual registration.

**How it works**:

1. The macro parses the struct's member declarations with SwiftSyntax.
2. Each property wrapped in `@Argument` / `@Option` / `@Flag` becomes an
   ``MCPParameterInfo`` entry in a statically-typed `discoverParameters()`.
3. Each `@OptionGroup` property is flattened into the parent's parameter list
   using the group's generated metadata.
4. `apply(arguments:)` is generated with direct `_setValue(_:)` calls.

### Option-group macro

``MCPOptionGroup`` attaches to an option-group struct and generates its
flattened parameter metadata plus an `mcpApply(arguments:)` method on the
group type itself:

```swift
@MCPOptionGroup
struct SharedOptions {
    @Option(description: "Verbose output") var verbose: Bool = false
    @Option(description: "Output path")    var outputPath: String = "."
}
```

**Why**: generating the group's metadata and apply logic at compile time lets
the parent ``MCPCommand`` macro inline the group's parameters without runtime
reflection, and the group stays a plain value type.

### One wrapper set

The project has a **single set** of property wrappers — `@Argument`, `@Option`,
`@Flag`, `@OptionGroup` — used both with direct ``MCPTool`` conformance and
with the ``MCPCommand`` macro. Option-group structs gain a ``StaticMCPGroup``
conformance from ``MCPOptionGroup``, so the macros generate identical code for
either usage.

### Macro architecture

``MCPCommand`` is an ``@attached(extension, conformances: MCPTool)`` macro. It:

1. Parses the struct's member declarations using SwiftSyntax.
2. Identifies `@Argument`, `@Option`, `@Flag`, and `@OptionGroup` wrapped
   properties.
3. Generates an extension with ``MCPTool`` conformance — including static
   `discoverParameters()` and `apply(arguments:)`.

``MCPApplication`` is a ``@attached(member)`` + ``@attached(extension)``
macro. It:

1. Reads all `@Tool` property values.
2. Generates a ``MCPToolID``-conforming enum with one case per tool.
3. Generates a private, exhaustive `_invokeTool` switch that preserves each
   tool's concrete type — the single spot every entry point reaches.
4. Generates a ``MCPToolDispatcher`` conformance so the server serves
   `tools/list` and `tools/call` through that typed switch.
5. Generates a `static func main()` that builds an ``MCPServer`` with the
   app as its dispatcher and runs it via ``MCPServer/runService()``.

The macro implementation lives in the separate `MCPMacros` target, which the
`MCP` library target depends on. This keeps SwiftSyntax out of the runtime
dependency graph while letting consumers use the macros through the `MCP`
product alone.

### Transport abstraction

The ``MCPTransport`` protocol abstracts the communication channel. The default
``StdioTransport`` reads newline-delimited JSON from stdin and writes to
stdout. ``TCPTransport`` binds to IPv4, IPv6, dual-stack, or Unix domain socket
addresses. Custom transports (HTTP+SSE, WebSocket, etc.) can be implemented by
conforming to the protocol and injecting them via
``MCPServer/init(name:version:transport:dispatcher:tools:)``.

### Compile-time dispatch, end to end

A macro-generated server is served entirely through typed dispatch. The
``MCPToolDispatcher`` surface that ``MCPApplication`` synthesizes builds
`tools/list` and `tools/call` from each tool's **static** configuration and
parameter metadata — the `_invokeTool` switch selects the concrete type per
branch, so no `any MCPTool` exists in the macro path. The only existential a
macro-generated server holds is the single `dispatcher` reference itself
(plus the intrinsic JSON/transport/`Codable` boundaries below). Debug-only
tools are guarded by `#if DEBUG` in every generated artifact (enum case,
switch branch, catalog entry, access gate), so a release build neither lists
nor invokes them.

### Accepted type erasure

The strict core deliberately keeps a small, documented set of exclusions —
removing any of them would cost ergonomics without buying hot-path
performance:

- **The JSON boundary.** `tools/call` arguments and `tools/list` schemas are
  heterogeneous JSON: `[String: Any]` at the wire, `AnyCodable` in the
  protocol layer. The macro-generated `apply` extracts each parameter onto
  concrete wrapper types, so `Any` never crosses into a tool.
- **`MCPTransport`.** One value held per server; dispatch is a single
  interface call on `start`/`stop` per lifetime — zero per-message cost.
- **`any Encoder` / `any Decoder`.** Part of the `Codable` contract itself.
- **The dynamic registry.** ``MCPServer/register(_:)`` and
  ``MCPServer/registerInstance(_:instance:)`` remain for hand-wired and hybrid
  servers. A server may hold both a dispatcher (macro-generated tools) and
  registered tools; the dispatcher is consulted first for both listing and
  invocation. Builder-based registration
  (``MCPServer/init(name:version:dispatcher:tools:)``) preserves concrete
  types all the way to registration via a pack-based ``MCPToolBuilder``.

### ServiceLifecycle integration

``MCPServer`` conforms to the `Service` protocol from `swift-service-lifecycle`.
``MCPServer/run()`` drives the transport directly: when the transport completes —
client EOF on stdio, or listener close on TCP — the service returns, and the
enclosing ``ServiceGroup`` applies the service's configured success termination
behavior. A graceful-shutdown handler registered in `run()` fans
``MCPTransport/stop()`` out to the transport, so signal-initiated shutdown wakes
the poll-based stdio read loop promptly.

``MCPServer/runService(gracefulShutdownSignals:)`` configures the outer group
with `.gracefullyShutdownGroup` success termination, so a completed session ends
the process cleanly. Hosts embedding ``MCPServer`` in their own ``ServiceGroup``
choose that behavior themselves (``cancelGroup``, ``gracefullyShutdownGroup``,
or ``ignore``). This keeps the server composable with other services in the
same group while giving every host control over session-end semantics.

## Data Flow

### Tool invocation

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

### Parameter discovery (compile time)

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

## Related Articles

- <doc:MacroGuide>
- <doc:ToolDefinition>
- <doc:MCPProtocol>
- <doc:TransportDesign>
- <doc:LifecycleManagement>
