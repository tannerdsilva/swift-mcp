# MCP — Model Context Protocol Server Framework for Swift

> **📖 Documentation:** This project uses [DocC](https://swift.org/documentation/docc) as its primary documentation format. The authoritative reference for all public API is the DocC catalog at `Sources/MCP/Documentation.docc/`. Build with `swift package --disable-sandbox generate-documentation`. Inline documentation in source files is the source of truth; this AGENTS.md is operational guidance for autonomous agents.

## Overview

A Swift package that provides an MCP (Model Context Protocol) server framework with a declarative, property-wrapper-based API. Includes a macro suite (`@MCPCommand`, `@FuncTool`, `@MCPApplication`, `@MCPOptionGroup`) that generates `MCPTool` conformances and server entry points at compile time — no runtime reflection.

The server uses **Swift Service Lifecycle** as its primary runtime mechanism. `MCPServer` conforms to the `Service` protocol and must be run via a `ServiceGroup`. Use `runService()` for a convenient signal-handling wrapper, or create your own `ServiceGroup` for full control.

## Project Structure

```
Sources/
  MCP/                           — Main library (14 files)
    Core/                        — Core protocols and types
      MCPTool.swift              — MCPTool protocol, MCPContext; default discovery/apply
      MCPToolConfiguration.swift — Tool metadata (description, name, access)
      MCPParam.swift             — MCPParameterInfo, MCPToolID, AccessLevel, MCPCallerInfo, StaticMCPGroup
      MCPContent.swift           — MCPToolResult, MCPContent, AnyCodable
      MCPError.swift             — MCPError enum (Error + Sendable + Equatable)
    PropertyWrappers/
      PropertyWrappers.swift     — @Argument, @Option, @Flag, @OptionGroup (value-type wrappers)
      Tool.swift                 — @Tool property wrapper + ToolAvailability
    Schema/
      JSONSchemaBuilder.swift    — JSON Schema Draft 7 generation from parameter metadata
    Protocol/
      MCPProtocol.swift          — typed JSON-RPC/MCP message layer (request/response/id, results)
    Server/
      MCPServer.swift            — Server class (conforms to Service from ServiceLifecycle)
      Transport.swift            — MCPTransport protocol + StdioTransport + TransportMessageHandler actor
      TCPTransport.swift         — TCP transport (IPv4, IPv6, dual-stack, Unix sockets)
      ServerAddress.swift        — ServerAddress enum (hostname, Unix socket)
    Macros.swift                 — @MCPCommand, @FuncTool, @MCPApplication, @MCPOptionGroup macro declarations
  MCPMacros/                     — Macro implementation target (SwiftSyntax)
    Plugin.swift                 — Compiler plugin entry point
    SharedGenerator.swift        — Shared apply/discovery codegen helpers
    MCPCommandMacro.swift        — ExtensionMacro: generates the MCPTool conformance
    MCPOptionGroupMacro.swift    — ExtensionMacro: generates StaticMCPGroup metadata
    ToolMacro.swift              — PeerMacro: generates tool structs from functions
    MCPApplicationMacro.swift    — MemberMacro: generates ToolID enum, dispatch, main
Tests/
  MCPTests/                      — Framework + integration tests (Swift Testing)
    MCPTests.swift               — unit, server routing, registry, transport end-to-end tests
  MCPMacroTests/                 — Macro expansion + diagnostic tests
    MCPCommandMacroTests.swift   — strict expansion asserts with re-parse gate
Sources/MCP/Documentation.docc/ — DocC catalog (primary documentation)
    GettingStarted.md, ToolDefinition.md, MacroGuide.md, OptionGroups.md,
    ServerConfiguration.md, MCPProtocol.md, TransportDesign.md,
    LifecycleManagement.md, AccessControl.md, Architecture.md,
    MigrationGuide.md, MCP.md, Examples.md
    Examples/                    — Comprehensive working examples
      BasicTools.md               — Sync/async, return types, error handling
      ExampleServerConfiguration.md — Transports, addresses, lifecycle, access control
      AdvancedTools.md            — Option groups, complex types, composition
      IntegrationPatterns.md      — Hummingbird, Vapor, clients, testing, Docker
      RealWorldScenarios.md       — File server, DB proxy, AI assistant, build system
      /LICENSE.txt
```

## Macro Suite

swift-mcp ships four macros that eliminate boilerplate at compile time:

- `@MCPCommand` — generates an `MCPTool` conformance in an extension from a struct with a `run()` method. The struct must declare exactly one `run()`; its `async`/`throws`/`Void` shape is detected at compile time and the generated code carries only the matching `try`/`await` prefix. Property wrappers map transparently: `@Argument` (required), `@Option` (optional with default), `@Flag` (Bool, defaults false), `@OptionGroup` (flattened at compile time).
- `@FuncTool` — generates an `MCPTool`-conforming struct from a `static` function nested in a type. Any return type is supported and rendered via `String(describing:)`; `Void` yields an empty text block. `_`-labeled, `inout`, and variadic parameters are rejected with diagnostics.
- `@MCPApplication` — generates a server entry point: a `ToolID` enum, exhaustive `callTool(_:arguments:)` dispatch, and a `main()` that registers each `@Tool` property (used with `@main`).
- `@MCPOptionGroup` — generates `StaticMCPGroup` metadata so option groups flatten at compile time.

## Parameter Wrappers

The property wrappers are **value types** (`struct`). Each tool instance follows a create → apply → invoke → discard discipline, so per-invocation mutation stays value semantics and never crosses tasks. Parameter metadata and argument injection are macro-generated at compile time — there is no `Mirror` reflection in the framework.

Wrapper values are constrained to `Codable & Sendable`. JSON-native scalars and fixed-width numerics inject directly (with cross-numeric coercion); any custom `Codable & Sendable` type (enums, structs, optionals) decodes from its JSON representation.

## Lifecycle Management

`MCPServer` uses **Swift Service Lifecycle** (`swift-service-lifecycle`) as its primary runtime mechanism. There are two ways to run the server:

### `runService()` (Recommended)

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
try await server.runService()
// Graceful shutdown on SIGTERM/SIGINT; clean exit on client EOF (stdio)
```

This wraps the server in a `ServiceGroup` with signal-based graceful shutdown and `.gracefullyShutdownGroup` success termination.

### Custom ServiceGroup

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
let serviceGroup = ServiceGroup(
    configuration: .init(
        services: [
            ServiceGroupConfiguration.ServiceConfiguration(
                service: server,
                successTerminationBehavior: .gracefullyShutdownGroup
            )
        ],
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: server.logger
    )
)
try await serviceGroup.run()
```

### How It Works

1. `MCPServer` conforms to the `Service` protocol from ServiceLifecycle
2. `MCPServer.run()` drives the transport directly and returns when the transport completes — client EOF on stdio, listener close on TCP — or after graceful shutdown stops it
3. A graceful-shutdown handler registered in `run()` fans `MCPTransport/stop()` out to the transport, so signal-initiated shutdown wakes the poll-based stdio read loop promptly
4. `runService()` configures the server service with `.gracefullyShutdownGroup` success termination behavior, so a completed session (EOF) ends the process cleanly instead of crashing with `serviceFinishedUnexpectedly`
5. Hosts embedding `MCPServer` in their own `ServiceGroup` choose their own success termination behavior (`cancelGroup`, `gracefullyShutdownGroup`, or `ignore`)

## MCP Protocol Support

Currently implements:
- `initialize` — Server capability advertisement
- `ping` — Health check
- `tools/list` — Tool discovery with auto-generated JSON Schema
- `tools/call` — Tool invocation with argument injection
- `notifications/initialized` — Acknowledged (no-op)
- `notifications/cancelled` — Acknowledged (no-op)

Error codes: `-32700` parse error, `-32000` access denied, `-32601` method not found, `-32602` invalid params, `-32603` internal error/type mismatch.

Not yet implemented:
- `resources/list`, `resources/read` — Resource exposure
- `prompts/list`, `prompts/get` — Prompt templates
- HTTP+SSE transport (implementable via the `MCPTransport` protocol)
- Streaming responses
- Progress notifications

## Building & Testing

```bash
swift build           # Build the library and macros
swift test            # Run all tests (framework + macro expansion)
swift package --disable-sandbox generate-documentation   # Build the DocC catalog
```

## Conventions

- **Swift 6 language mode** is enforced target-wide via `.swiftLanguageMode(.v6)`.
- **All tests use Swift Testing** (`import Testing`, `#expect(...)`, `@Test`).
- **StrictConcurrency** is implied by Swift 6 language mode; `@unchecked Sendable` is used only where documented (server registries guarded by a lock, transport flags).
- **Public API** uses `public` visibility; internal types use `internal` as appropriate.
- **Error types** conform to `Error`, `Sendable`, `Equatable`, and `CustomStringConvertible` (Foundation-free descriptions; no `LocalizedError`).
- **File header comments** follow the MIT license header pattern used across Sources.
