# Macro Guide

How the ``FuncTool``, ``MCPCommand``, ``MCPOptionGroup``, and ``MCPApplication``
macros work, and how to use them effectively.

## Overview

swift-mcp provides four Swift macros that generate boilerplate at compile time:

- ``FuncTool`` — generates an ``MCPTool``-conforming struct from a plain function
- ``MCPCommand`` — generates an ``MCPTool`` conformance for a struct with a `run()` method
- ``MCPOptionGroup`` — generates compile-time metadata for an option-group struct
- ``MCPApplication`` — generates a server entry point with exhaustive dispatch

All macros are available to consumers through the `MCP` product alone — the
macros live in the `MCPMacros` target, which the `MCP` library target depends
on.

## FuncTool

### What It Does

Applied to a function, ``FuncTool`` generates a struct named
`{FunctionName}Tool` (e.g. `greetTool`) that conforms to ``MCPTool``.

### Parameter Classification

The macro automatically classifies function parameters:

| Parameter Type | Classification | Wrapper |
|---|---|---|
| No default value | Required argument | ``@Argument`` |
| Has default value, non-Bool | Optional option | ``@Option`` |
| Bool with default `false` | Flag | ``@Flag`` |

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `description` | `String` | `""` | Human-readable description |
| `name` | `String?` | `nil` | Explicit tool name (defaults to function name) |
| `requiredAccess` | `AccessLevel` | `.public` | Minimum access level |

### Scope Constraint

``FuncTool`` is a *peer* macro that introduces a new type at its attachment
scope. Because peer macros are not allowed to introduce arbitrary names at
global scope, the annotated function must be nested inside a type:

```swift
enum MyTools {
    @FuncTool(description: "Greet someone by name")
    static func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
        let greeting = formal ? "Greetings" : "Hello"
        return "\(greeting), \(name)!"
    }
}

let server = MCPServer(name: "demo", version: "1.0.0") {
    MyTools.greetTool()
}
try await server.runService()
```

The generated `run()` returns `String`, so ``FuncTool`` is best suited to
`String`-returning functions. For anything else, use ``MCPCommand`` on a
struct.

## MCPCommand

### What It Does

Applied to a struct, ``MCPCommand`` generates an ``MCPTool`` conformance in an
extension:

1. A static ``MCPToolConfiguration``.
2. A static `discoverParameters()` returning compile-time parameter metadata.
3. `apply(arguments:)` and `invoke(context:)` that call through to the user's
   `run()`, auto-detecting sync/async.

### Parameter Wrappers

| Wrapper | MCP Behavior |
|---|---|
| `@Argument` | Required parameter |
| `@Option` | Optional parameter with default value |
| `@Flag` | Boolean flag, defaults to false |
| `@OptionGroup` | Nested parameter group, flattened at compile time |

All wrappers support the `enumValues:` parameter to constrain allowed values in
the JSON Schema:

```swift
@Argument(description: "Log level", enumValues: ["debug", "info", "warning", "error"])
var level: String = ""
```

### Async Detection

The macro detects whether your `run()` method is async or sync and generates
the appropriate `invoke`:

```swift
// Sync run()
func run() throws -> String { "Hello" }
// Generates: let output = try run()

// Async run()
func run() async throws -> String { try await fetch() }
// Generates: let output = try await run()
```

### Access Control

The macro supports a `requiredAccess` parameter:

```swift
@MCPCommand(description: "Admin operation", requiredAccess: .admin)
struct AdminOp {
    func run() throws -> String { "done" }
}
```

This generates `MCPToolConfiguration(requiredAccess: .admin)`, which the server
uses to filter and enforce access.

### Expansion Example

```swift
// Source:
@MCPCommand(description: "Greet someone")
struct Greet {
    @Argument var name: String = ""
    func run() throws -> String { "Hello, \(name)!" }
}

// Generated:
extension Greet: MCPTool {
    public static var configuration: MCPToolConfiguration {
        MCPToolConfiguration(description: "Greet someone")
    }
    public static func discoverParameters() -> [MCPParameterInfo] { ... }
    public mutating func apply(arguments: [String: Any]) throws { ... }
    public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
        let output = try run()
        return .text(String(describing: output))
    }
}
```

### Requirements

- Applied to **structs** only.
- The struct must have a `run()` method (sync or async; throwing or not).
- Properties must use ``@Argument``, ``@Option``, ``@Flag``, or
  ``@OptionGroup``.

## MCPOptionGroup

Applied to an option-group struct, ``MCPOptionGroup`` synthesizes a
``StaticMCPGroup`` conformance: static `mcpParameters` metadata and an
`mcpApply(arguments:)` method. The parent ``MCPCommand`` conformance inlines
the group's parameters at compile time.

```swift
@MCPOptionGroup
struct SharedOptions {
    @Option(description: "Verbose output") var verbose: Bool = false
    @Option(description: "Output path")    var outputPath: String = "."
}
```

Groups are shallow — nested ``@OptionGroup`` properties are rejected with a
compiler diagnostic.

## MCPApplication

### What It Does

Applied to a struct with ``@Tool`` properties, ``MCPApplication`` generates:

1. **``MCPToolID`` enum** — one case per ``@Tool`` property, providing
   compile-time unique tool names.
2. **Exhaustive dispatch** — a `callTool` method with a switch over the enum,
   each branch using the concrete tool type.
3. **`main()` entry point** — creates the server, registers every `@Tool`, and
   runs via ``MCPServer/runService()``.

### Usage

```swift
@main
@MCPApplication(name: "demo", version: "1.0.0")
struct MyApp {
    @Tool var greet = Greet()
    @Tool var calculate = Calculate()
}
```

> The generated `static func main()` is only invoked when the struct is also
> annotated with `@main`.

### Conditional Registration

Use the `available` parameter for debug-only tools:

```swift
@Tool(available: .debug) var debug = DebugTool()
```

The macro wraps registration and dispatch in `#if DEBUG`.

### Address Binding

Pass an address to bind to a specific network interface:

```swift
@MCPApplication(
    name: "demo",
    version: "1.0.0",
    address: .hostname("127.0.0.1", port: 8080)
)
```

### Custom Transport

Pass a ``MCPTransport`` value to use a custom transport instead of stdio.
Specify either `address` or `transport`, never both:

```swift
@MCPApplication(
    name: "demo",
    version: "1.0.0",
    transport: TCPTransport(address: .localhostIPv4(port: 8080))
)
```

## Macro Implementation Details

Both macros are implemented using SwiftSyntax and run as compiler plugins. The
implementation target `MCPMacros` is separate from the main `MCP` library to
avoid runtime dependencies on SwiftSyntax.

### MCPCommandMacro

- Type: `ExtensionMacro`
- Reads: `@Argument`, `@Option`, `@Flag`, `@OptionGroup` property wrappers
- Generates: ``MCPTool`` extension with `configuration`, `discoverParameters()`,
  `apply(arguments:)`, and `invoke(context:)`
- Detects: async `run()` via signature inspection

### MCPApplicationMacro

- Type: `MemberMacro`
- Reads: `@Tool` properties
- Generates: `ToolID` enum, `callTool` dispatch, `main()`
- Supports: `available` parameter, `address` parameter, `transport` parameter

## Related Articles

- <doc:ToolDefinition>
- <doc:OptionGroups>
- <doc:AccessControl>
