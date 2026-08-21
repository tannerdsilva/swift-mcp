# Getting Started with swift-mcp

This guide walks you through creating your first MCP server with swift-mcp.

## Prerequisites

- Swift 6.0 or later
- macOS or Linux

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
        dependencies: ["MCP"]
    ),
]
```

## Step 3: Define a Tool

You can define a tool in two ways. The simplest is the `@Tool` macro on a function:

```swift
import MCP

@Tool(description: "Echo a message back to the caller")
func echo(message: String, count: Int = 1, uppercase: Bool = false) -> String {
    var text = message
    if uppercase { text = text.uppercased() }
    return Array(repeating: text, count: count).joined(separator: "\n")
}
```

The `@Tool` macro automatically generates an `MCPTool`-conforming struct named `echoTool`.
Parameters without defaults become `@Argument` (required), parameters with defaults become
`@Option` (optional), and `Bool` parameters with default `false` become `@Flag`.

For CLI integration, use `@MCPCommand` on a struct instead (see the [Macro Guide](MacroGuide.md)).

## Step 4: Create and Run the Server

```swift
import MCP

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(name: "echo-server", version: "1.0.0") {
            echoTool()
        }
        // runService() wraps the server in a ServiceGroup with signal-based
        // graceful shutdown. The server will cleanly shut down on SIGTERM/SIGINT.
        try await server.runService()
    }
}
```

## Step 5: Test with an MCP Client

The server reads newline-delimited JSON from stdin and writes to stdout. Test it with `printf`:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello, MCP!","count":2,"uppercase":true}}}\n' | swift run MyMCPServer
```

Expected output:

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"echo-server","version":"1.0.0"}}}
{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object","properties":{"message":{"type":"string","description":"The message to echo"},"count":{"type":"integer","description":"Number of times to repeat"},"uppercase":{"type":"boolean","description":"Uppercase the message"}},"required":["message"]}}]}}
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"HELLO, MCP!\nHELLO, MCP!"}],"isError":false}}
```

## Next Steps

- Read the [Tool Definition Guide](ToolDefinition.md) for detailed information about property wrappers
- Learn about [Option Groups](OptionGroups.md) to share parameters across tools
- Explore the [Macro Guide](MacroGuide.md) for dual CLI/MCP usage
- See [Server Configuration](ServerConfiguration.md) for lifecycle management options
