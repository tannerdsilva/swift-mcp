# Macro Guide

How the ``@Tool``, ``MCPCommand``, and ``MCPApplication`` macros work, and how to use them effectively.

## Overview

swift-mcp provides three Swift macros that generate boilerplate code at compile time:

- ``Tool`` — Generates an ``MCPTool``-conforming struct from a plain function
- ``MCPCommand`` — Generates ``MCPTool`` conformance and optional ``AsyncParsableCommand`` CLI struct
- ``MCPApplication`` — Generates a complete server entry point with exhaustive dispatch

## @Tool

### What It Does

Applied to a function, ``Tool`` generates a struct named ``{FunctionName}Tool`` that conforms to ``MCPTool``.

### Parameter Classification

The macro automatically classifies function parameters:

| Parameter Type | Classification | Wrapper |
|---|---|---|
| No default value | Required argument | ``@Argument`` |
| Has default value, non-Bool | Optional option | ``@Option`` |
| Bool with default ``false`` | Flag | ``@Flag`` |

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| ``description`` | ``String`` | ``\"\"`` | Human-readable description |
| ``name`` | ``String?`` | ``nil`` | Explicit tool name (defaults to function name) |
| ``requiredAccess`` | ``AccessLevel`` | ``.public`` | Minimum access level |

### Example

```swift
@Tool(description: "Greet someone by name")
func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
    let greeting = formal ? "Greetings" : "Hello"
    return "\(greeting), \(name)!"
}

let server = MCPServer(name: "demo", version: "1.0.0") {
    greetTool()
}
try await server.runService()
```

### Generated Code

For the function above, the macro generates:

```swift
public struct greetTool: MCPTool {
    @Argument var name: String = ""
    @Option var count: Int = 1
    @Flag var formal: Bool = false

    public static var configuration: MCPToolConfiguration {
        MCPToolConfiguration(description: "Greet someone by name")
    }

    public func run() -> String {
        return greet(name: name, count: count, formal: formal)
    }

    public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
        let output = run()
        return .text(String(describing: output))
    }
}
```

## @MCPCommand

### What It Does

Applied to a struct, ``MCPCommand`` generates:

1. **``MCPTool`` conformance** — ``configuration`` property and ``invoke(context:)`` method that calls the user's ``run()``
2. **``AsyncParsableCommand`` conformance** — A nested ``CLI`` struct with the same properties, enabling command-line invocation

### Parameter Wrappers

| Wrapper | MCP Behavior | CLI Behavior |
|---|---|---|
| ``@Argument`` | Required positional parameter | Required positional argument |
| ``@Option`` | Optional named parameter with default | Optional named option with default |
| ``@Flag`` | Boolean flag, defaults to false | Boolean flag, defaults to false |
| ``@OptionGroup`` | Nested parameter group | Nested option group |

All wrappers support the ``enumValues:`` parameter to constrain allowed values in the JSON Schema:

```swift
@Argument(description: "Log level", enumValues: ["debug", "info", "warning", "error"])
var level: String = ""
```

### Async Detection

The macro detects whether your ``run()`` method is async or sync and generates the appropriate ``invoke``:

```swift
// Sync run()
func run() throws -> String { "Hello" }
// Generates: let output = try run()

// Async run()
func run() async throws -> String { try await fetch() }
// Generates: let output = try await run()
```

### Access Control

The macro supports a ``requiredAccess`` parameter:

```swift
@MCPCommand(description: "Admin operation", requiredAccess: .admin)
struct AdminOp {
    func run() throws -> String { "done" }
}
```

This generates ``MCPToolConfiguration(requiredAccess: .admin)``, which the server uses to filter and enforce access.

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
    public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
        let output = try run()
        return .text(String(describing: output))
    }
}
// Plus CLI struct for ArgumentParser...
```

## @MCPApplication

### What It Does

Applied to a struct with ``@Tool`` properties, ``MCPApplication`` generates:

1. **``MCPToolID`` enum** — One case per ``@Tool`` property, providing compile-time unique tool names
2. **Exhaustive dispatch** — A ``callTool`` method with a switch over the enum, each branch using the concrete tool type
3. **``main()`` entry point** — Creates the server, registers tools, and runs via ``ServiceGroup``

### Usage

```swift
@MCPApplication(name: "demo", version: "1.0.0")
struct MyApp {
    @Tool var greet = Greet()
    @Tool var calculate = Calculate()
}
```

### Conditional Registration

Use the ``available`` parameter for debug-only tools:

```swift
@Tool(available: .debug) var debug = DebugTool()
```

The macro wraps registration and dispatch in ``#if DEBUG``.

### Address Binding

Pass an address to bind to a specific network interface:

```swift
@MCPApplication(
    name: "demo",
    version: "1.0.0",
    address: .hostname("127.0.0.1", port: 8080)
)
```

## Macro Implementation Details

Both macros are implemented using SwiftSyntax and run as compiler plugins. The implementation target is ``MCPMacros``, which is separate from the main ``MCP`` library to avoid runtime dependencies on SwiftSyntax.

### MCPCommandMacro

- Type: ``ExtensionMacro``
- Reads: ``@Argument``, ``@Option``, ``@Flag``, ``@OptionGroup`` property wrappers
- Generates: ``MCPTool`` extension with ``configuration`` and ``invoke``
- Detects: Async ``run()`` via signature inspection

### MCPApplicationMacro

- Type: ``MemberMacro``
- Reads: ``@Tool`` properties
- Generates: ``ToolID`` enum, ``callTool`` dispatch, ``main()``
- Supports: ``available`` parameter, ``address`` parameter

## Related Articles

- <doc:ToolDefinition>
- <doc:OptionGroups>
- <doc:AccessControl>
