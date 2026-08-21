# Macro Guide

How the `@Tool`, `@MCPCommand`, and `@MCPApplication` macros work.

## `@Tool` Macro (Function-Based)

The simplest way to create an MCP tool. Apply `@Tool` to a function:

```swift
@Tool(description: "Greet someone by name")
func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
    let greeting = formal ? "Greetings" : "Hello"
    return "\(greeting), \(name)!"
}
```

The macro generates a struct named `{FunctionName}Tool` (e.g., `greetTool`) conforming to `MCPTool`.

### Parameter Classification

| Parameter Type | Classification | Wrapper |
|---|---|---|
| No default value | Required argument | `@Argument` |
| Has default value, non-Bool | Optional option | `@Option` |
| Bool with default `false` | Flag | `@Flag` |

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `description` | `String` | `""` | Human-readable description |
| `name` | `String?` | `nil` | Explicit tool name (defaults to function name) |
| `requiredAccess` | `AccessLevel` | `.public` | Minimum access level |

### Registration

```swift
let server = MCPServer(name: "demo", version: "1.0.0") {
    greetTool()
}
try await server.runService()
```

---

## `@MCPCommand` Macro (Struct-Based)

All wrappers support the `enumValues:` parameter to constrain allowed values:

```swift
@MCPCommand(description: "Set log level")
struct SetLogLevel {
    @Argument(description: "Log level", enumValues: ["debug", "info", "warning", "error"])
    var level: String = ""

    func run() async throws -> String { "Log level set to \(level)" }
}
```

## What the Macro Generates

For a struct like:

```swift
@MCPCommand(description: "Test")
struct Test {
    @Argument(description: "Input")
    var input: String = ""

    func run() async throws -> String { input }
}
```

The macro generates:

```swift
extension Test: MCPTool {
    public static var configuration: MCPToolConfiguration {
        MCPToolConfiguration(description: "Test")
    }

    public func invoke(context: MCPContext) async throws -> MCPToolResult {
        let output = try await run()
        return .text(String(describing: output))
    }

    #if canImport(ArgumentParser)
    struct CLI: AsyncParsableCommand {
        @Argument(description: "Input") var input: String = ""

        mutating func run() async throws {
            let command = Test(input: input)
            let result = try await command.run()
            print(result)
        }
    }
    #endif
}
```

## Requirements

- The macro can only be applied to **structs**
- The struct must have a `run()` method (async throws, returning any type)
- Properties must use `@Argument`, `@Option`, `@Flag`, or `@OptionGroup`
- For CLI generation, `import ArgumentParser` must be present in the file
- The struct must use `Swift 6` language mode

## Limitations

- The macro does not support classes or actors
- The generated `CLI` struct requires ArgumentParser to be a dependency
- Option group properties are passed through verbatim (ArgumentParser handles flattening at runtime)
