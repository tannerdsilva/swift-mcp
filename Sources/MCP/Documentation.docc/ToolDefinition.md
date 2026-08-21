# Tool Definition

How to define MCP tools using property wrappers and macros.

## Overview

Tools are the core concept in MCP. You can define tools in three ways:

1. **``@Tool`` macro** — Apply to a function, get an automatic ``MCPTool``-conforming struct
2. **``@MCPCommand`` macro** — Apply to a struct for dual MCP + CLI support
3. **Direct conformance** — Conform your type directly to ``MCPTool`` for full control

## ``@Tool`` Macro (Function-Based)

The simplest way to create a tool:

```swift
@Tool(description: "Greet someone by name")
func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
    let greeting = formal ? "Greetings" : "Hello"
    return "\(greeting), \(name)!"
}
```

The macro generates a struct named ``greetTool`` conforming to ``MCPTool``.
Parameters without defaults become ``@Argument``, parameters with defaults become ``@Option``,
and ``Bool`` parameters with default ``false`` become ``@Flag``.

Register with a server:

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    greetTool()
}
try await server.runService()
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

## Macro-Based Definition

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

## Parameter Wrappers

### @Argument

A required positional parameter. The caller must provide this value.

```swift
@Argument(description: "The input file path")
var path: String
```

- MCP: Required parameter in the JSON Schema
- CLI: Positional argument
- Default: No default — the caller must provide a value
- Enum values: Optionally constrain with `enumValues:`

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

- MCP: Optional parameter with default in the JSON Schema
- CLI: Named option (e.g., ``--format json``)
- Default: The initial value you provide
- Enum values: Optionally constrain with `enumValues:`

```swift
@Option(description: "Output format", enumValues: ["json", "text", "yaml"])
var format: String = "json"
```

### @Flag

A boolean flag that defaults to ``false``.

```swift
@Flag(description: "Enable verbose output")
var verbose: Bool = false
```

- MCP: Optional boolean parameter with default ``false``
- CLI: Boolean flag (e.g., ``--verbose``)
- Default: ``false``

### @OptionGroup

A nested group of parameters from another type.

```swift
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
    var message: String

    func run() throws -> String { ... }
}
```

## Return Types

The ``run()`` method can return any type that conforms to ``CustomStringConvertible``. The macro wraps the return value in ``MCPToolResult/text(_:)``.

| Return Type | MCP Result |
|---|---|
| ``String`` | ``.text(value)`` |
| ``Int`` | ``.text("42")`` |
| ``Bool`` | ``.text("true")`` |
| ``CustomStringConvertible`` | ``.text(value.description)`` |

For custom result types, implement ``invoke`` directly and return ``MCPToolResult``.

## Async Support

Tools can be sync or async:

```swift
// Sync
func run() throws -> String { "Hello" }

// Async
func run() async throws -> String {
    let data = try await URLSession.shared.data(from: url)
    return String(decoding: data, as: UTF8.self)
}
```

The macro detects async automatically and generates the appropriate ``invoke``.

## Access Control

Set the required access level:

```swift
@MCPCommand(description: "Admin operation", requiredAccess: .admin)
struct AdminOp {
    func run() throws -> String { "done" }
}
```

## Related Articles

- <doc:MacroGuide>
- <doc:OptionGroups>
- <doc:AccessControl>
