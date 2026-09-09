# MCP — Model Context Protocol Server Framework for Swift

> **📖 Documentation:** This project uses [DocC](https://swift.org/documentation/docc) as its primary documentation format. The authoritative reference for all public API is the DocC catalog at `Sources/MCP/Documentation.docc/`. Build with `swift package --disable-sandbox generate-documentation`. Inline documentation in source files is the source of truth; this AGENTS.md is operational guidance for autonomous agents.

## Overview

A Swift package that provides an MCP (Model Context Protocol) framework with a declarative, property-wrapper-based API. It serves tools (`@MCPCommand`, `@FuncTool`, `@MCPApplication`, `@MCPOptionGroup` generate `MCPTool` conformances and server entry points at compile time — no runtime reflection) and, since Sep 2026, consumes them as a client: `MCPClient` speaks MCP-by-subprocess over SwiftSlash-spawned tool-server binaries, or over TCP, with the same framing core in both roles.

The **unified NIO transport pipeline** is the load-bearing architecture: one `MCPFrameCodec` (newline-delimited JSON-RPC framing + per-frame size cap) and one `MCPMessageRouter` (the JSON-RPC routing core) serve every deployment — server TCP, server stdio, and the client carriers. Server and client cannot drift.

The server uses **Swift Service Lifecycle** as its primary runtime mechanism. `MCPServer` conforms to the `Service` protocol and must be run via a `ServiceGroup`. Use `runService()` for a convenient signal-handling wrapper, or create your own `ServiceGroup` for full control. The client side wraps the same way (`MCPClientService`).

## Project Structure

```
Sources/
  MCP/                           — Main library
    Core/                        — Core protocols and types
      MCPTool.swift              — MCPTool protocol, MCPContext; default discovery/apply
      MCPToolConfiguration.swift — Tool metadata (description, name, access)
      MCPParam.swift             — MCPParameterInfo, MCPToolID, AccessLevel, MCPCallerInfo, StaticMCPGroup
      MCPContent.swift           — MCPToolResult, MCPContent, AnyCodable
      MCPError.swift             — MCPError enum (Error + Sendable + Equatable)
      MCPToolDispatcher.swift    — MCPToolDispatcher protocol + MCPToolDescriptor
    PropertyWrappers/
      PropertyWrappers.swift     — @Argument, @Option, @Flag, @OptionGroup (value-type wrappers)
      Tool.swift                 — @Tool property wrapper + ToolAvailability
    Schema/
      JSONSchemaBuilder.swift    — JSON Schema Draft 7 generation from parameter metadata
    Protocol/
      MCPProtocol.swift          — typed JSON-RPC/MCP message layer (request/response/id, results)
    Transport/                   — the shared NIO transport core (server + client)
      MCPFrameCodec.swift        — newline-delimited JSON-RPC framing + per-frame size cap (one impl, every carrier)
      MCPMessageRouter.swift     — the byte-level JSON-RPC routing core; owns tool registries
      MCPMessageHandler.swift    — NIO frame→actor dispatch glue (TCP connections + stdio channel)
      TransportMessageHandler.swift — per-channel ordering/backpressure actor
    Server/
      MCPServer.swift            — Server class (conforms to Service from ServiceLifecycle)
      Transport.swift            — MCPTransport protocol + StdioTransport (NIO pipe channel over dup'd std streams)
      TCPTransport.swift         — TCP transport (IPv4, IPv6, dual-stack, Unix sockets)
      ServerAddress.swift        — ServerAddress enum (hostname, Unix socket)
    Client/                      — the client role (MCP-by-subprocess and network carriers)
      MCPClient.swift            — actor state machine: spawn/handshake/in-flight table/catalog/timeouts
      ClientTransport.swift      — ClientTransport protocol, MCPClientError, ResumeOnce
      SubprocessClientTransport.swift — SwiftSlash v5 BYO + NIO pipe channel; shutdown ladder
      TCPClientTransport.swift     — NIO socket client carrier (hostname + Unix sockets)
      LocalClientTransport.swift — network-free carrier over MCPMessageRouter
      MCPClientService.swift     — Service wrapper for harness ServiceGroups
      RemoteToolDescriptor.swift — wire catalog entry
    Macros.swift                 — @MCPCommand, @FuncTool, @MCPApplication, @MCPOptionGroup macro declarations
  MCPMacros/                     — Macro implementation target (SwiftSyntax)
    Plugin.swift                 — Compiler plugin entry point
    SharedGenerator.swift        — Shared apply/discovery codegen helpers
    MCPCommandMacro.swift        — ExtensionMacro: generates the MCPTool conformance
    MCPOptionGroupMacro.swift    — ExtensionMacro: generates StaticMCPGroup metadata
    ToolMacro.swift              — PeerMacro: generates tool structs from functions
    MCPApplicationMacro.swift    — MemberMacro: generates ToolID enum, dispatch, main
  MCPFixtureServer/              — test fixture: @MCPApplication stdio server (echo/add/slow) spawned by client tests
Tests/
  MCPTests/                      — Framework + integration tests (Swift Testing)
    MCPTests.swift               — unit, server routing, registry, transport end-to-end tests
    MCPClientTests.swift         — client over subprocess: round-trip, timeouts, mid-call kill, oversize, ladder, stderr tail
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

## Unified NIO Transport Pipeline

Framing and routing are single-sourced so no deployment can drift:

- **`MCPFrameCodec`** — one `ChannelDuplexHandler` doing newline-delimited JSON-RPC framing with a per-frame size cap (`maxMessageSize`, 10 MiB default). An oversized frame — complete line or partial remainder — is rejected with a `-32700 Message too large` frame and the channel closes. Used by: server TCP, server stdio, client subprocess, client TCP.
- **`MCPMessageRouter`** — the byte-level JSON-RPC routing core (batches, id-routing, initialize negotiation, tools/list, tools/call, access gates, error mapping). Owns the tool registries; `MCPServer` is a thin facade over it. The in-process `LocalClientTransport` drives it with zero bytes.
- **Server glue** — `MCPMessageHandler` (NIO frame → `TransportMessageHandler` actor, with the stdio drain-then-close contract on half-close) + `TransportMessageHandler` (per-channel ordering/backpressure).
- **`StdioTransport`** runs on a NIO pipe channel over `dup(0)`/`dup(1)` (the raw `poll` loop is gone, Sep 2026); NIO owns the duplicates, never the real std streams.

## Macro Suite

swift-mcp ships four macros that eliminate boilerplate at compile time:

- `@MCPCommand` — generates an `MCPTool` conformance in an extension from a struct with a `run()` method. The struct must declare exactly one `run()`; its `async`/`throws`/`Void` shape is detected at compile time and the generated code carries only the matching `try`/`await` prefix. Property wrappers map transparently: `@Argument` (required), `@Option` (optional with default), `@Flag` (Bool, defaults false), `@OptionGroup` (flattened at compile time).
- `@FuncTool` — generates an `MCPTool`-conforming struct from a `static` function nested in a type. Any return type is supported and rendered via `String(describing:)`; `Void` yields an empty text block. `_`-labeled, `inout`, and variadic parameters are rejected with diagnostics.
- `@MCPApplication` — generates a `<Name>_ToolID` enum, an exhaustive typed dispatch switch (`_invokeTool`), a `MCPToolDispatcher` conformance (catalog, access gate, string dispatch), and a `main()` that runs the server with the app as its dispatcher (used with `@main`). Debug-only `@Tool(available: .debug)` entries are `#if DEBUG`-guarded in every generated artifact (enum case, switch, catalog, access gate). The dispatcher is the only existential in the macro path; servers may also hold dynamically registered tools via `register`/`registerInstance` (dispatcher is consulted first).
- `@MCPOptionGroup` — generates `StaticMCPGroup` metadata so option groups flatten at compile time.
- `MCPToolBuilder` — pack-based result builder; each tool expression keeps its concrete type through the generic server initializers (no `[any MCPTool]` array; flat lists only — hand-written servers needing dynamic selection use `register`/`registerInstance`).

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
3. A graceful-shutdown handler registered in `run()` fans `MCPTransport/stop()` out to the transport, so signal-initiated shutdown closes the transport's channel/read loop promptly
4. `runService()` configures the server service with `.gracefullyShutdownGroup` success termination behavior, so a completed session (EOF) ends the process cleanly instead of crashing with `serviceFinishedUnexpectedly`
5. Hosts embedding `MCPServer` in their own `ServiceGroup` choose their own success termination behavior (`cancelGroup`, `gracefullyShutdownGroup`, or `ignore`)

### Client role — MCP by subprocess

`MCPClient` is an actor (state: idle → spawning → handshake → ready → shuttingDown → disconnected) over a `ClientTransport` carrier. Three carriers are implemented: `SubprocessClientTransport` (SwiftSlash 5.0 BYO data channels + NIO pipe channel), `TCPClientTransport` (NIO socket channel, hostname + Unix sockets), and the network-free `LocalClientTransport`, which drives the shared `MCPMessageRouter` with zero bytes and zero processes — the same actor, timeouts, and catalog logic on top. `MCPClientService` wraps one plugin as a `Service` for host `ServiceGroup`s.

- **Framing:** newline-delimited JSON-RPC both ways; the child-facing pipe ends go to SwiftSlash via `.byo(fd:)`; the parent ends become a NIO duplex channel (input = stdout read end, output = stdin write end). stderr stays on SwiftSlash's built-in line stream → logger + retained tail.
- **The CLOEXEC trap:** every parent pipe end (and every NIO dup) MUST be marked `FD_CLOEXEC`. posix_spawn inherits non-CLOEXEC fds, and an inherited copy of the stdin *write* end keeps the pipe open forever — the child never sees stdin EOF and the clean-shutdown ladder always escalates.
- **Shutdown ladder** (the only shutdown signal is EOF on stdin): close the transport's stdin write end + the channel (rung 1) → grace (2s default) → SIGTERM → SIGKILL to the process group (`kill(-pid)`); SwiftSlash guarantees the reap on every rung.
- **Timeout machinery:** per-request deadlines and the ladder's grace are two unstructured `Task`s resolving a continuation exactly once through a Mutex gate (`ResumeOnce`). Do NOT convert these to `withTaskGroup` racing — group-child scheduling is unreliable in strict-concurrency builds on this toolchain (siblings can silently never run, hanging the group).

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
swift build           # Build the library, macros, and the MCPFixtureServer executable
swift test            # Run all tests (framework + macro expansion + client subprocess suite)
                      #   note: client tests spawn .build/debug/MCPFixtureServer — run `swift build` first
swift package --disable-sandbox generate-documentation   # Build the DocC catalog
```

**Verification discipline** — never trust self-round-trip tests alone:
1. Server role: drive the built `MCPFixtureServer` over stdio with the official mcp Python SDK (`initialize` → `list_tools` → `call_tool` under a 30s bound). Run the SDK's own `MCPServer` as the control first; if the control fails, the harness is broken, not the server.
2. Client role: drive a third-party stdio server (e.g. the SDK's `MCPServer`) with `MCPClient` over `SubprocessClientTransport`. Recipe + venv setup live in the `swift-mcp-server-authoring` skill.
3. The in-repo client suite covers round-trip, timeouts, mid-call kill, oversize frames, clean EOF exit, TERM→KILL escalation, and stderr-tail retention against the spawned fixture.

**Verification matrix** (the transport unification's cross-checks; `✓` cells are regression-tested or control-verified in this repo):

| client \ server | swift-mcp stdio | swift-mcp TCP | third-party |
|---|---|---|---|
| `SubprocessClientTransport` | ✓ in-repo suite | — | ✓ manual control (mcp SDK `MCPServer`) |
| `TCPClientTransport` | — | ✓ in-repo suite (IPv4 + Unix socket) | — (no third-party raw-TCP MCP server in the wild; shares the codec/actor verified over stdio) |
| `LocalClientTransport` | — | ✓ in-repo (semantic catalog parity vs TCP) | — |
| official mcp SDK (as client) | ✓ control experiment | — | ✓ control |

Every meaningful cell is green; the `—` cells are structural (a stdio-only client cannot reach a TCP server and vice versa) or have no third-party peer to test against.

## Conventions

- **Swift 6 language mode** is enforced target-wide via `.swiftLanguageMode(.v6)`.
- **All tests use Swift Testing** (`import Testing`, `#expect(...)`, `@Test`).
- **StrictConcurrency** is implied by Swift 6 language mode; `@unchecked Sendable` is used only where documented (server registries guarded by a lock, transport flags).
- **Public API** uses `public` visibility; internal types use `internal` as appropriate.
- **Error types** conform to `Error`, `Sendable`, `Equatable`, and `CustomStringConvertible` (Foundation-free descriptions; no `LocalizedError`).
- **File header comments** follow the MIT license header pattern used across Sources.
