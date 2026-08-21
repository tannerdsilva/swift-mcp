# Getting Started with swift-mcp

Create your first MCP server in minutes.

## Overview

This guide walks you through creating a simple MCP server that exposes a "greet" tool.

## Create a Package

```bash
mkdir MyMCPServer && cd MyMCPServer
swift package init --type executable
```

## Add the Dependency

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

## Define a Tool

```swift
import MCP

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

## Create and Run the Server

```swift
// main.swift
import MCP

let server = MCPServer(name: "greeter", version: "1.0.0") {
    Greet()
}
try await server.runService()
```

## Test with an MCP Client

The server listens on stdin/stdout by default. You can test it with any MCP client:

```bash
# Using the MCP CLI tool
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | swift run MyMCPServer
```

## Next Steps

- <doc:ToolDefinition> — Learn about all parameter wrapper types
- <doc:ServerConfiguration> — Configure transports, addresses, and access control
- <doc:MacroGuide> — Deep dive into the macro system
