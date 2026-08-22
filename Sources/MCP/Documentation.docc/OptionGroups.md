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

Option groups are flattened at **compile time**. Annotate the group struct with ``@MCPOptionGroup``:

```swift
@MCPOptionGroup
struct PrintOptions {
    @Option(description: "Number of copies to print")
    var copies: Int = 1

    @Flag(description: "Enable verbose output")
    var verbose: Bool = false
}
```

Then, when the ``MCPCommand`` macro processes a tool with an ``@OptionGroup`` property:

1. **MCP**: The macro inlines the group's static metadata (`StaticMCPGroup/mcpParameters`) into the tool's `discoverParameters()`, so the JSON Schema includes all group parameters as if they were declared on the tool.

2. **CLI**: It generates an ``@OptionGroup`` in the ``AsyncParsableCommand`` struct, which ArgumentParser handles natively.

3. **Argument injection**: The generated `apply(arguments:)` forwards to the group's macro-generated `mcpApply(arguments:)`, which sets each present parameter through its property wrapper.

## Nested Option Groups

Option groups are shallow: an ``@MCPOptionGroup`` struct should contain only `@Argument`/`@Option`/`@Flag` properties. Nested `@OptionGroup` properties are rejected with a compiler diagnostic.

## Protocol Conformance

The group struct must be annotated with ``@MCPOptionGroup``, which synthesizes a ``StaticMCPGroup`` conformance (static `mcpParameters` metadata plus `mcpApply(arguments:)`). The ``@OptionGroup`` wrapper then flattens it into the parent at compile time.

## Best Practices

1. **Group related parameters** — Keep options that are always used together in one group.
2. **Provide sensible defaults** — Every option should have a default value so the group can be created without arguments.
3. **Document the group** — Add doc comments to the group struct and its properties.
4. **Keep groups shallow** — One level of nesting is usually enough. Deeply nested groups are harder to use.

## Related Articles

- <doc:ToolDefinition>
- <doc:MacroGuide>
