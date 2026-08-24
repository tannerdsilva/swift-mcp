# Tool Definition

How to define MCP tools using property wrappers and macros.

## Overview

Tools are the core concept in MCP. You can define them three ways:

1. **``FuncTool`` macro** — apply to a function to get an automatic
   ``MCPTool``-conforming struct
2. **``MCPCommand`` macro** — apply to a struct with a `run()` method
3. **Direct conformance** — conform your type directly to ``MCPTool`` for full
   control

## FuncTool Macro (Function-Based)

The simplest way to create a tool:

```swift
enum MyTools {
    @FuncTool(description: "Greet someone by name")
    static func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
        let greeting = formal ? "Greetings" : "Hello"
        return "\(greeting), \(name)!"
    }
}
```

This generates a struct named `MyTools.greetTool` conforming to ``MCPTool``.
Parameters without defaults become ``@Argument``, parameters with defaults
become ``@Option``, and `Bool` parameters with default `false` become
``@Flag``.

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    MyTools.greetTool()
}
try await server.runService()
```

> ``FuncTool`` is a peer macro and cannot introduce arbitrary names at global
> scope, so the annotated function must live inside a type. See the
> <doc:MacroGuide> for details.

## MCPCommand Macro (Struct-Based)

```swift
@MCPCommand(description: "Greet someone by name")
struct Greet {
    @Argument(description: "The person to greet")
    var name: String = ""

    @Option(description: "Number of times to repeat")
    var count: Int = 1

    @Flag(description: "Use a formal greeting")
    var formal: Bool = false

    func run() throws -> String {
        let greeting = formal ? "Greetings" : "Hello"
        return Array(repeating: "\(greeting), \(name)!", count: count)
            .joined(separator: "\n")
    }
}
```

## Direct Conformance

```swift
struct Greet: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Greet someone by name"
    )

    @Argument(description: "The person to greet")
    var name: String = ""

    @Option(description: "Number of times to repeat")
    var count: Int = 1

    @Flag(description: "Use a formal greeting")
    var formal: Bool = false

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        let greeting = formal ? "Greetings" : "Hello"
        let message = Array(repeating: "\(greeting), \(name)!", count: count)
            .joined(separator: "\n")
        return .text(message)
    }
}
```

The default `discoverParameters()` returns an empty list and the default
`apply(arguments:)` is a no-op. If a direct conformer needs parameter
discovery and injection, either use ``MCPCommand`` or provide your own
`discoverParameters()` / `apply(arguments:)` (for example, by reusing the
property wrappers' `_setValue(_:)` through a testable support type).

## Parameter Wrappers

### @Argument

A required parameter. The caller must provide this value.

```swift
@Argument(description: "The input file path")
var path: String = ""
```

- Default: the initial value is a placeholder and is ignored when the argument
  is provided
- JSON Schema: included in the `required` array
- Enum values: optionally constrain with `enumValues:`

```swift
@Argument(description: "Log level", enumValues: ["debug", "info", "warning", "error"])
var level: String = ""
```

### @Option

An optional named parameter with a default value.

```swift
@Option(description: "Output format")
var format: String = "json"
```

- Default: the initial value you provide
- JSON Schema: optional, not in the `required` array
- Enum values: optionally constrain with `enumValues:`

```swift
@Option(description: "Output format", enumValues: ["json", "text", "yaml"])
var format: String = "json"
```

### @Flag

A boolean flag that defaults to `false`.

```swift
@Flag(description: "Enable verbose output")
var verbose: Bool = false
```

- Default: `false`
- Accepits `Bool`, `Int` (nonzero is `true`), or `String` (`"true"`/`"yes"`/`"1"`
  are `true`)

### @OptionGroup

A nested group of parameters from another type, flattened at compile time:

```swift
@MCPOptionGroup
struct PrintOptions {
    @Option(description: "Number of copies")
    var copies: Int = 1

    @Flag(description: "Enable verbose output")
    var verbose: Bool = false
}

@MCPCommand(description: "Print a message")
struct Print {
    @OptionGroup
    var options: PrintOptions

    @Argument(description: "Message to print")
    var message: String = ""

    func run() throws -> String { ... }
}
```

## Return Types

The `run()` method of an ``MCPCommand``-based tool can return any value; the
macro wraps the return value in ``MCPToolResult/text(_:)`` via
`String(describing:)`.

| Return Type | MCP Result |
|---|---|
| `String` | `.text(value)` |
| `Int` | `.text("42")` |
| `Bool` | `.text("true")` |

For custom result types, implement ``MCPTool/invoke(context:)`` directly and
return ``MCPToolResult``.

## Async Support

Tools can be sync or async; the macro detects it automatically:

```swift
// Sync
func run() throws -> String { "Hello" }

// Async
func run() async throws -> String {
    try await fetch()
}
```

## Access Control

Set the required access level:

```swift
@MCPCommand(description: "Admin operation", requiredAccess: .admin)
struct AdminOp {
    func run() throws -> String { "done" }
}
```

See <doc:AccessControl> for the full model.

## Related Articles

- <doc:MacroGuide>
- <doc:OptionGroups>
- <doc:AccessControl>
