# Option Groups

Share common parameters across multiple tools using `@OptionGroup` and `@OptionGroup`.

## Motivation

When multiple tools share common parameters (e.g., verbose mode, output path, authentication), option groups let you define them once and reuse them.

## Defining a Group

Create a struct with the shared parameters:

```swift
import MCP

struct SharedOptions {
    @Option(description: "Enable verbose output")
    var verbose: Bool = false

    @Option(description: "Output path")
    var outputPath: String = "."

    @Option(description: "Number of retries on failure")
    var retries: Int = 3
}
```

## Using a Group

### With @MCPCommand (Dual-Use)

```swift
@MCPCommand(description: "Process data")
struct ProcessData {
    @OptionGroup var options: SharedOptions

    @Argument(description: "Input file")
    var inputFile: String = ""

    func run() async throws -> String {
        if options.verbose {
            print("Processing \(inputFile) with \(options.retries) retries...")
        }
        return "Output written to \(options.outputPath)"
    }
}
```

### With Direct MCPTool Conformance

```swift
struct ProcessData: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Process data"
    )

    @OptionGroup
    var options: SharedOptions

    @Argument(description: "Input file")
    var inputFile: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text("Processing \(inputFile)...")
    }
}
```

## How It Works

### Parameter Discovery

When the `@MCPCommand`/`@Tool` macro encounters an `@MCPOptionGroup` property, it uses the group struct's generated metadata (from `@MCPOptionGroup`) to flatten the group's sub-parameters into the parent's parameter list.

For the `ProcessData` example above, `discoverParameters()` returns:
- `inputFile` (argument, required)
- `verbose` (option, optional)
- `outputPath` (option, optional)
- `retries` (option, optional)

### Argument Injection

The generated `apply(arguments:)` handles each `@MCPOptionGroup` property by calling the group struct's generated `mcpApply(arguments:)`, which the `@MCPOptionGroup` macro synthesizes at compile time to set the group's sub-parameters.

### JSON Schema

The JSON Schema for a tool with option groups includes all flattened parameters as top-level properties:

```json
{
  "type": "object",
  "properties": {
    "inputFile": { "type": "string", "description": "Input file" },
    "verbose": { "type": "boolean", "description": "Enable verbose output" },
    "outputPath": { "type": "string", "description": "Output path" },
    "retries": { "type": "integer", "description": "Number of retries on failure" }
  },
  "required": ["inputFile"]
}
```

## Nested Groups

Groups are shallow: an `@MCPOptionGroup` struct contains only `@Argument`/`@Option`/`@Flag` properties. Nested `@OptionGroup` properties are rejected with a compiler diagnostic, keeping the flattened namespace predictable.

## Best Practices

1. **Keep groups focused** — Each group should represent a coherent set of related parameters
2. **Use descriptive names** — The group property name is not included in the flattened parameter namespace
3. **Avoid name collisions** — Parameter names across all groups and the parent must be unique
4. **Document group structs** — Add doc comments to group structs and their properties for IDE support
