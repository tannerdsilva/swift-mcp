# Option Groups

How to organize related parameters into reusable groups.

## Overview

Option groups allow you to define a set of related parameters once and reuse them across multiple tools. This is useful for common options like output formatting, logging verbosity, or connection settings.

## Defining an Option Group

Create a struct with parameter wrappers:

```swift
struct PrintOptions {
    @Option(description: "Number of copies to print")
    var copies: Int = 1

    @Flag(description: "Enable verbose output")
    var verbose: Bool = false

    @Option(description: "Output format (text, json)")
    var format: String = "text"
}
```

## Using an Option Group

Use ``@OptionGroup`` in your tool:

```swift
@MCPCommand(description: "Print a message")
struct Print {
    @OptionGroup
    var options: PrintOptions

    @Argument(description: "Message to print")
    var message: String

    func run() throws -> String {
        let prefix = options.verbose ? "[VERBOSE] " : ""
        let output = Array(repeating: "\(prefix)\(message)", count: options.copies)
            .joined(separator: "\n")
        return output
    }
}
```

## How It Works

When the macro encounters ``@OptionGroup``:

1. **MCP**: It discovers the group's parameters recursively and flattens them into the tool's parameter list. The JSON Schema includes all parameters from the group as if they were defined directly on the tool.

2. **CLI**: It generates an ``@OptionGroup`` in the ``AsyncParsableCommand`` struct, which ArgumentParser handles natively.

3. **Argument injection**: When ``apply(arguments:)`` is called, the framework creates an instance of the group type, applies arguments to it, and assigns it to the ``@OptionGroup`` property.

## Nested Option Groups

Option groups can contain other option groups:

```swift
struct NetworkOptions {
    @Option(description: "Hostname")
    var host: String = "localhost"

    @Option(description: "Port")
    var port: Int = 8080
}

struct LoggingOptions {
    @Option(description: "Log level")
    var level: String = "info"

    @OptionGroup
    var network: NetworkOptions
}

struct Service {
    @OptionGroup
    var logging: LoggingOptions

    @Argument(description: "Command")
    var command: String

    func run() throws -> String { ... }
}
```

## Protocol Conformance

The group struct must conform to ``GroupParamProtocol``. The ``@OptionGroup`` wrapper automatically provides this conformance.

## Best Practices

1. **Group related parameters** — Keep options that are always used together in one group.
2. **Provide sensible defaults** — Every option should have a default value so the group can be created without arguments.
3. **Document the group** — Add doc comments to the group struct and its properties.
4. **Keep groups shallow** — One level of nesting is usually enough. Deeply nested groups are harder to use.

## Related Articles

- <doc:ToolDefinition>
- <doc:MacroGuide>
