# swift-mcp

**A Swift framework for building MCP (Model Context Protocol) servers with a declarative, property-wrapper-based API inspired by Swift Argument Parser and Hummingbird.**

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![MCP](https://img.shields.io/badge/MCP-2025--06--18-purple.svg)](https://modelcontextprotocol.io)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blueviolet.svg)](https://swift.org/documentation/docc)

---

> **📖 Documentation:** This project uses [DocC](https://swift.org/documentation/docc) as its primary documentation format. Build the documentation with `swift package --disable-sandbox generate-documentation` or read the articles inline in `Sources/MCP/Documentation.docc/`.

## Overview

`swift-mcp` lets you define MCP tools using the same familiar syntax as Swift Argument Parser. Write your tool once, and optionally get both an MCP server tool and a CLI command from a single struct declaration.

### Quick Start

```swift
import MCP

@Tool(description: "Greet someone by name")
func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
    let greeting = formal ? "Greetings" : "Hello"
    return Array(repeating: "\(greeting), \(name)!", count: count)
        .joined(separator: "\n")
}

// Start the server
let server = MCPServer(name: "demo", version: "1.0.0") {
    greetTool()
}
try await server.runService()
```

### Features

- **`@Tool` macro** — Generate MCP tools from plain functions with automatic parameter discovery
- **`@MCPCommand` macro** — Dual-use CLI/MCP tools with Swift Argument Parser integration
- **`@MCPApplication` macro** — Full server application generation with `@Tool` property wrapper
- **Property wrappers** — `@Argument`, `@Option`, `@Flag`, `@OptionGroup` for parameter declaration
- **Automatic JSON Schema** — Tool parameters are automatically described in JSON Schema Draft 7
- **Compile-time discovery** — Parameters are discovered via macro-generated code, no runtime reflection
- **Option groups** — Share common parameters across tools with `@OptionGroup`
- **Stdio transport** — Standard MCP transport for subprocess-based clients
- **TCP transport** — IPv4, IPv6, dual-stack, and Unix domain socket support
- **Access control** — Per-tool access levels with IP-based resolution
- **Enum constraints** — Optional `enumValues` parameter for JSON Schema enum constraints
- **Dynamic registration** — Register and unregister tools at runtime with `register(_:)` and `unregister(_:)`
- **Structured logging** — `trace`, `debug`, `info`, `warning`, `error` levels via Swift Logging API
- **Actor-based concurrency** — `TransportMessageHandler` actor for serialized, cancellable message processing

---

## Table of Contents

- [Installation](#installation)
- [Usage Guide](#usage-guide)
  - [Direct MCPTool Conformance](#direct-mcptool-conformance)
  - [Macro-Based Tools](#macro-based-tools)
  - [Option Groups](#option-groups)
  - [Server Setup](#server-setup)
- [API Reference](#api-reference)
- [Documentation](#documentation)
- [Testing](#testing)
- [License](#license)

---

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-mcp.git", from: "1.0.0")
]
```

Then add `MCP` as a dependency to your target:

```swift
.target(
    name: "MyTool",
    dependencies: ["MCP"]
)
```

If you want to use the `@MCPCommand` macro with ArgumentParser CLI generation, also add `ArgumentParser`:

```swift
.target(
    name: "MyTool",
    dependencies: [
        "MCP",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
    ]
)
```

---

## Usage Guide

### Direct MCPTool Conformance

For full control, conform your types directly to `MCPTool`:

```swift
import MCP

struct GetWeather: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Get the current weather for a location"
    )

    @MCPArgument(description: "The city name")
    var city: String = ""

    @MCPOption(description: "Temperature unit (celsius/fahrenheit)")
    var unit: String = "celsius"

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text("The weather in \(city) is sunny and 22°\(unit == "celsius" ? "C" : "F")")
    }
}
```

### `@Tool` Macro (Function-Based)

The simplest way to create an MCP tool: apply `@Tool` to a plain function.

```swift
@Tool(description: "Calculate the sum of two numbers")
func add(a: Double, b: Double) -> String {
    return "\(a + b)"
}

// Parameters without defaults → @Argument (required)
// Parameters with defaults → @Option (optional)
// Bool parameters with default false → @Flag

let server = MCPServer(name: "calc", version: "1.0.0") {
    addTool()
}
try await server.runService()
```

The generated struct is named `{FunctionName}Tool` (e.g., `addTool`). It conforms to `MCPTool` automatically.

### Macro-Based Tools (Struct-Based)

Use `@MCPCommand` to generate both MCP and CLI conformances from a single struct:

```swift
import ArgumentParser  // Required for CLI generation
import MCP

@MCPCommand(description: "Calculate")
struct Calculate {
    @Argument(description: "First number")
    var a: Double = 0

    @Argument(description: "Second number")
    var b: Double = 0

    @Option(description: "Operation: add, subtract, multiply, divide")
    var operation: String = "add"

    func run() async throws -> String {
        switch operation {
        case "add":      return "\(a + b)"
        case "subtract": return "\(a - b)"
        case "multiply": return "\(a * b)"
        case "divide":
            guard b != 0 else { throw MCPError.internalError("Division by zero") }
            return "\(a / b)"
        default:
            throw MCPError.internalError("Unknown operation: \(operation)")
        }
    }
}

// As an MCP tool:
let server = MCPServer(name: "calc", version: "1.0.0") { Calculate() }

// As a CLI command:
// Calculate.CLI.main()
```

### Option Groups

Share common parameters across tools:

```swift
struct SharedOptions {
    @Option(description: "Enable verbose output")
    var verbose: Bool = false

    @Option(description: "Output path")
    var outputPath: String = "."
}

@MCPCommand(description: "Process data")
struct ProcessData {
    @OptionGroup var options: SharedOptions

    @Argument(description: "Input file")
    var inputFile: String = ""

    func run() async throws -> String {
        // options.verbose, options.outputPath available
        return "Processing \(inputFile)..."
    }
}
```

### Server Setup

```swift
import MCP

// Imperative registration
let server = MCPServer(name: "myserver", version: "1.0.0")
server.register(GetWeather())
server.register(Greet())
try await server.run()

// Declarative registration with result builder
let server = MCPServer(name: "myserver", version: "1.0.0") {
    GetWeather()
    Greet()
    Calculate()
}
try await server.run()

// Dynamic registration and unregistration
server.register(GetWeather())
server.unregister("get_weather")  // Remove a tool at runtime
```

---

## API Reference

### Core Protocols

| Protocol | Description |
|---|---|
| `MCPTool` | The main protocol for defining MCP tools |
| `MCPParamProtocol` | Protocol for parameter property wrappers |
| `StaticMCPGroup` | Macro-generated metadata protocol for option-group structs |
| `MCPTransport` | Protocol for transport layer abstraction |

### Property Wrappers (Framework-Level)

| Wrapper | Maps To | Required | Has Default | Enum Support |
|---|---|---|---|---|
| `@MCPArgument` | `@Argument` | Yes | No | `enumValues:` |
| `@MCPOption` | `@Option` | No | Yes | `enumValues:` |
| `@MCPFlag` | `@Flag` | No | Yes (false) | — |
| `@MCPOptionGroup` | `@OptionGroup` | — | — | — |

### Property Wrappers (Dual-Use, with `@MCPCommand`)

| Wrapper | ArgumentParser | MCP |
|---|---|---|
| `@Argument` | `@Argument` | `@MCPArgument` |
| `@Option` | `@Option` | `@MCPOption` |
| `@Flag` | `@Flag` | `@MCPFlag` |
| `@OptionGroup` | `@OptionGroup` | `@MCPOptionGroup` |

### Key Types

| Type | Description |
|---|---|
| `MCPServer` | Main server class for hosting tools |
| `MCPToolConfiguration` | Tool metadata (description, name) |
| `MCPToolResult` | Result of a tool invocation |
| `MCPContent` | Content block (text, image, resource) |
| `MCPParameterInfo` | Metadata for a single parameter |
| `MCPContext` | Contextual information for tool invocation |
| `MCPError` | Error type for the framework |
| `AnyCodable` | Type-erased Codable wrapper |
| `JSONSchemaBuilder` | JSON Schema generation from parameter metadata |
| `StdioTransport` | Standard I/O transport for MCP |
| `TCPTransport` | TCP transport with IPv4/IPv6/Unix socket support |
| `ServerAddress` | Address configuration (IPv4, IPv6, dual-stack, Unix socket) |
| `TransportMessageHandler` | Actor for serialized, cancellable message processing |
| `MCPToolBuilder` | Result builder for declarative tool registration |

---

## Documentation

Comprehensive documentation is available in the `Documentation/` directory:

- **[Getting Started](Documentation/GettingStarted.md)** — First steps with swift-mcp
- **[Tool Definition Guide](Documentation/ToolDefinition.md)** — Defining tools with property wrappers
- **[Macro Guide](Documentation/MacroGuide.md)** — Using `@MCPCommand` for dual-use tools
- **[Option Groups](Documentation/OptionGroups.md)** — Sharing parameters across tools
- **[Server Configuration](Documentation/ServerConfiguration.md)** — Server setup and transport options
- **[MCP Protocol](Documentation/MCPProtocol.md)** — Supported protocol methods and message flow
- **[Architecture](Documentation/Architecture.md)** — Framework architecture and design decisions
- **[Migration Guide](Documentation/MigrationGuide.md)** — Upgrading from earlier versions

### Examples

A family of comprehensive, working examples is available in `Documentation/Examples/`:

| Article | Covers |
|---|---|
| [BasicTools](Documentation/Examples/BasicTools.md) | Sync/async, return types, error handling, all parameter types |
| [ServerConfiguration](Documentation/Examples/ServerConfiguration.md) | Stdio, TCP (IPv4/IPv6/dual-stack), Unix sockets, ServiceGroup |
| [AdvancedTools](Documentation/Examples/AdvancedTools.md) | Option groups, access control, complex types, composition |
| [IntegrationPatterns](Documentation/Examples/IntegrationPatterns.md) | Hummingbird, Vapor, clients, testing, Docker, systemd |
| [RealWorldScenarios](Documentation/Examples/RealWorldScenarios.md) | File server, DB proxy, AI assistant, build system, monitor, config, notifications |

Each example is self-contained and ready to copy into your project.

---

## Testing

```bash
swift test
```

The test suite covers:
- Tool parameter discovery and argument injection
- JSON Schema generation
- Error handling (missing arguments, type mismatches)
- Option group flattening and argument application
- Macro expansion for all wrapper types
- Server message handling (initialize, tools/list, tools/call, ping, notifications)
- Transport message actor (ordering, cancellation)
- MCPApplication macro (ToolID enum, debug-only tools, address binding)
- Dynamic tool registration and unregistration
- Enum value constraints in JSON Schema

---

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE.txt](LICENSE.txt) for details.
