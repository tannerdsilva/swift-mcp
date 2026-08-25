# Option Groups

How to organize related parameters into reusable groups.

## Overview

Option groups let you define a set of related parameters once and reuse them
across multiple tools. This is useful for common options like output
formatting, logging verbosity, or connection settings.

## Defining an Option Group

Annotate a struct with ``@MCPOptionGroup`` and give it parameter wrappers:

```swift
@MCPOptionGroup
struct PrintOptions {
    @Option(description: "Number of copies to print")
    var copies: Int = 1

    @Flag(description: "Enable verbose output")
    var verbose: Bool = false

    @Option(description: "Output format (text, json)")
    var format: String = "text"
}
```

``@MCPOptionGroup`` synthesizes a ``StaticMCPGroup`` conformance — static
`mcpParameters` metadata plus `mcpApply(arguments:)` — so the group's
parameters can be flattened into a parent tool at compile time.

## Using an Option Group

Use ``@OptionGroup`` in your tool:

```swift
@MCPCommand(description: "Print a message")
struct Print {
    @OptionGroup
    var options: PrintOptions

    @Argument(description: "Message to print")
    var message: String = ""

    func run() throws -> String {
        let prefix = options.verbose ? "[VERBOSE] " : ""
        let output = Array(repeating: "\(prefix)\(message)", count: options.copies)
            .joined(separator: "\n")
        return output
    }
}
```

Groups also work in directly conformed tools:

```swift
struct Print: MCPTool {
    static let configuration = MCPToolConfiguration(description: "Print a message")

    @OptionGroup
    var options: PrintOptions

    @Argument(description: "Message to print")
    var message: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text(message)
    }
}
```

## How It Works

When ``MCPCommand`` processes a tool with an ``@OptionGroup`` property:

1. **Discovery**: the macro inlines the group's static metadata
   (`StaticMCPGroup/mcpParameters`) into the tool's `discoverParameters()`, so
   the JSON Schema includes all group parameters as if they were declared on
   the tool.
2. **Argument injection**: the generated `apply(arguments:)` forwards to the
   group's macro-generated `mcpApply(arguments:)`, which sets each present
   parameter through its property wrapper.

## Nested Option Groups

Groups are shallow: an ``@MCPOptionGroup`` struct should contain only
`@Argument` / `@Option` / `@Flag` properties. Nested `@OptionGroup` properties
are rejected with a compiler diagnostic.

## Best Practices

1. **Group related parameters** — keep options that are always used together
   in one group.
2. **Provide sensible defaults** — every option should have a default value so
   the group can be created without arguments.
3. **Keep groups shallow** — one level of nesting is usually enough.
4. **Avoid name collisions** — parameter names across all groups and the parent
   must be unique, since the flattened namespace is flat.

## Related Articles

- <doc:ToolDefinition>
- <doc:MacroGuide>
