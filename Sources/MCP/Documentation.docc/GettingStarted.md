# Getting Started with swift-mcp

Create your first MCP server in minutes.

## Prerequisites

- Swift 6.0 or later
- macOS 14 or Linux

## Step 1: Create a Package

```bash
mkdir MyMCPServer && cd MyMCPServer
swift package init --type executable
```

## Step 2: Add the Dependency

Edit `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-mcp.git", from: "1.0.0"),
],
targets: [
    .executableTarget(
        name: "MyMCPServer",
        dependencies: [
            .product(name: "MCP", package: "swift-mcp"),
        ]
    ),
]
```

The macro implementation ships inside the `MCP` product — no extra dependency
is required to use ``MCPCommand`` and friends.

## Step 3: Define a Tool

The simplest way is the ``FuncTool`` macro on a function:

```swift
import MCP

enum MyTools {
    @FuncTool(description: "Echo a message back to the caller")
    static func echo(message: String, count: Int = 1, uppercase: Bool = false) -> String {
        var text = message
        if uppercase { text = text.uppercased() }
        return Array(repeating: text, count: count).joined(separator: "\n")
    }
}
```

The macro generates an `MCPTool`-conforming struct named `MyTools.echoTool`.
Parameters without defaults become `@Argument` (required), parameters with
defaults become `@Option` (optional), and `Bool` parameters with default
`false` become `@Flag`.

For struct-based tools with a `run()` method, use `@MCPCommand` instead — see
the <doc:MacroGuide>.

## Step 4: Create and Run the Server

```swift
import MCP

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(name: "echo-server", version: "1.0.0") {
            MyTools.echoTool()
        }
        // runService() wraps the server in a ServiceGroup with signal-based
        // graceful shutdown on SIGTERM/SIGINT.
        try await server.runService()
    }
}
```

## Step 5: Test with an MCP Client

The server reads newline-delimited JSON from stdin and writes to stdout. Test
it with `printf`:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echoTool","arguments":{"message":"Hello, MCP!","count":2,"uppercase":true}}}' \
  | swift run MyMCPServer
```

The `tools/list` response includes an auto-generated JSON Schema for each tool,
and `tools/call` returns the tool's result.

## Next Steps

- <doc:ToolDefinition> — learn about all parameter wrapper types
- <doc:OptionGroups> — share parameters across tools
- <doc:MacroGuide> — deep dive into the macro system
- <doc:ServerConfiguration> — transports, addresses, and lifecycle
