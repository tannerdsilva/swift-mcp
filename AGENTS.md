# MCP — Model Context Protocol Server Framework for Swift

> **📖 Documentation:** This project uses [DocC](https://swift.org/documentation/docc) as its primary documentation format. The authoritative reference for all public API is the DocC catalog at `Sources/MCP/Documentation.docc/`. Build with `swift package --disable-sandbox generate-documentation`. Inline documentation in source files is the source of truth; this AGENTS.md is operational guidance for autonomous agents.

## Overview

A Swift package that provides an MCP (Model Context Protocol) server framework with a declarative, property-wrapper-based API inspired by Swift Argument Parser and Hummingbird. Includes a macro suite (`@MCPCommand`) that generates both `AsyncParsableCommand` and `MCPTool` conformances from a single struct declaration.

The server uses **Swift Service Lifecycle** as its primary runtime mechanism. `MCPServer` conforms to the `Service` protocol and must be run via a `ServiceGroup`. Use `runService()` for a convenient signal-handling wrapper, or create your own `ServiceGroup` for full control.

## Project Structure

```
Sources/
  MCP/                           — Main library (12 files, ~2,500 lines)
    Core/                        — Core protocols and types
      MCPTool.swift              — MCPTool protocol, parameter discovery, argument injection
      MCPToolConfiguration.swift — Tool metadata (description, name)
      MCPParam.swift             — MCPParamKind, MCPParameterInfo, MCPParamProtocol, GroupParamProtocol
      MCPContent.swift           — MCPToolResult, MCPContent, AnyCodable
      MCPError.swift             — MCPError enum (Error + Sendable + Equatable)
    PropertyWrappers/
      MCPPropertyWrappers.swift  — @MCPArgument, @MCPOption, @MCPFlag, @MCPOptionGroup
      DualWrappers.swift         — @Argument, @Option, @Flag, @OptionGroup (user-facing dual-use wrappers)
    Schema/
      JSONSchemaBuilder.swift    — JSON Schema Draft 7 generation from parameter metadata
    Protocol/
      MCPProtocol.swift          — JSON-RPC types, MCP protocol message types (internal)
    Server/
      MCPServer.swift            — Server class (conforms to Service from ServiceLifecycle)
      Transport.swift            — MCPTransport protocol + StdioTransport + TransportMessageHandler actor
      TCPTransport.swift         — TCP transport (IPv4, IPv6, dual-stack, Unix sockets)
      ServerAddress.swift        — ServerAddress enum (IPv4, IPv6, dual-stack, Unix socket)
    Macros.swift                 — @MCPCommand and @MCPApplication macro declarations
  MCPMacros/                     — Macro implementation target (SwiftSyntax)
    Plugin.swift                 — Compiler plugin entry point
    MCPCommandMacro.swift        — ExtensionMacro: generates MCPTool + CLI types
    MCPApplicationMacro.swift    — MemberMacro: generates ToolID enum, dispatch, main()
  MCPDemo/                       — Demo executable using @MCPCommand
    main.swift
Tests/
  MCPTests/                      — 67 framework tests (Swift Testing)
    MCPTests.swift
  MCPMacroTests/                 — 13 macro expansion tests
    MCPCommandMacroTests.swift
Documentation/                   — 7 documentation articles + 5 example articles
    GettingStarted.md
    ToolDefinition.md
    MacroGuide.md
    OptionGroups.md
    ServerConfiguration.md
    MCPProtocol.md
    Architecture.md
    MigrationGuide.md
    Examples/                     — Comprehensive working examples
      BasicTools.md               — Sync/async, return types, error handling
      ServerConfiguration.md      — All transport and lifecycle patterns
      AdvancedTools.md            — Option groups, access control, composition
      IntegrationPatterns.md      — Hummingbird, Vapor, clients, testing, Docker
      RealWorldScenarios.md       — File server, DB proxy, AI assistant, build system
```

## Dual-Use Macro: `@MCPCommand`

The `@MCPCommand` macro lets you write ONE struct and get both an `AsyncParsableCommand` (for CLI) and an `MCPTool` (for MCP server) for free.

### Wrapper Mapping

The mapping is 1:1 and transparent:

| You write | ArgumentParser generates | MCP generates |
|---|---|---|
| `@Argument` | `@Argument` | `@MCPArgument` |
| `@Option`   | `@Option`   | `@MCPOption`   |
| `@Flag`     | `@Flag`     | `@MCPFlag`     |
| `@OptionGroup` | `@OptionGroup` | `@MCPOptionGroup` |

### Usage

```swift
import MCP

@MCPCommand(description: "Greet someone by name")
struct Greet {
    @Argument(description: "The person to greet")
    var name: String = ""

    @Option(description: "Number of times")
    var count: Int = 1

    @Flag(description: "Use a formal greeting")
    var formal: Bool = false

    func run() async throws -> String {
        let greeting = formal ? "Greetings" : "Hello"
        return Array(repeating: "\(greeting), \(name)!", count: count)
            .joined(separator: "\n")
    }
}

// Start the server with signal-based graceful shutdown
let server = MCPServer(name: "demo", version: "1.0") {
    Greet()
}
try await server.runService()
```

## Lifecycle Management

`MCPServer` uses **Swift Service Lifecycle** (`swift-service-lifecycle`) as its primary runtime mechanism. There are two ways to run the server:

### `runService()` (Recommended)

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    Greet()
}
try await server.runService()
// Graceful shutdown on SIGTERM/SIGINT
```

This wraps the server in a `ServiceGroup` with signal-based graceful shutdown. The server will cleanly shut down when it receives `SIGTERM` or `SIGINT`.

### Custom ServiceGroup

```swift
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

### How It Works

1. `MCPServer` conforms to the `Service` protocol from ServiceLifecycle
2. `MCPServer.run()` creates a `ServiceGroup` with the transport wrapped as a `ClosureService`
3. The transport's `start(handler:)` method runs as a child service
4. Signal handling triggers graceful shutdown of all services
5. The transport stops reading stdin and the server exits cleanly

## Key Design Decisions

### Property Wrappers Are Classes

All property wrappers are implemented as **classes** (not structs) conforming to `@unchecked Sendable`. This is intentional: Mirror reflection on a tool instance returns mutable references to the wrapper objects, allowing the framework to inject argument values after initialization.

### Mirror-Based Parameter Discovery

`MCPTool.discoverParameters()` uses `Mirror(reflecting:)` to iterate stored properties. It looks for children whose label starts with `_` (the synthesized backing-storage name for property wrappers) and whose value conforms to `MCPParamProtocol`. Option groups conforming to `GroupParamProtocol` are recursively flattened.

### ServiceLifecycle Integration

The server uses `swift-service-lifecycle` for lifecycle management, following the same pattern as Hummingbird 2.x:
- `MCPServer` conforms to `Service`
- `run()` creates a `ServiceGroup` internally
- `runService()` adds signal handling
- The transport is wrapped as a `ClosureService` child

This ensures clean startup and shutdown, proper resource cleanup, and signal-based graceful termination.

## MCP Protocol Support

Currently implements:
- `initialize` — Server capability advertisement
- `ping` — Health check
- `tools/list` — Tool discovery with auto-generated JSON Schema
- `tools/call` — Tool invocation with argument injection
- `notifications/initialized` — Acknowledged (no-op)
- `notifications/cancelled` — Acknowledged (no-op)

Not yet implemented:
- `resources/list`, `resources/read` — Resource exposure
- `prompts/list`, `prompts/get` — Prompt templates
- HTTP+SSE transport (NIO dependency is available for this)
- Streaming responses
- Progress notifications

## Building & Testing

```bash
swift build           # Build the library, macros, and demo
swift test            # Run all tests (80 total: 67 framework + 13 macro)
swift run MCPDemo     # Run the demo server (reads from stdin, SIGTERM/SIGINT to stop)
```

## Conventions

- **Swift 6 language mode** is enforced project-wide via `.swiftLanguageMode(.v6)`.
- **StrictConcurrency** is enabled via `.enableExperimentalFeature("StrictConcurrency")`.
- **All tests use Swift Testing** (`import Testing`, `#expect(...)`, `@Test`).
- **Public API** uses `public` visibility; internal types use `package` or `internal` as appropriate.
- **Error types** conform to `Error`, `Sendable`, `Equatable`, and `LocalizedError`.
- **Sendable conformance**: Use `@unchecked Sendable` only when necessary; document why.
- **File header comments** follow the Apache 2.0 license header pattern.
