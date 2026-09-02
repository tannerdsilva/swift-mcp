# swift-mcp

**A Swift framework for building MCP (Model Context Protocol) servers with a declarative, property-wrapper-based API.**

![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg) ![License](https://img.shields.io/badge/License-MIT-green.svg) ![MCP](https://img.shields.io/badge/MCP-2025--11--25-purple.svg)

---

> **📖 Documentation:** This project uses [DocC](https://swift.org/documentation/docc) as its primary documentation format. The authoritative catalog lives in `Sources/MCP/Documentation.docc/`. Build it with `swift package --disable-sandbox generate-documentation`.

## Overview

`swift-mcp` lets you define MCP tools using property wrappers (`@Argument`, `@Option`, `@Flag`, `@OptionGroup`) and macros (`@MCPCommand`, `@FuncTool`, `@MCPApplication`, `@MCPOptionGroup`), then host them with an `MCPServer` run through Swift Service Lifecycle.

### Quick Start

```swift
import MCP

enum MyTools {
    @FuncTool(description: "Greet someone by name")
    static func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
        let greeting = formal ? "Greetings" : "Hello"
        return Array(repeating: "\(greeting), \(name)!", count: count)
            .joined(separator: "\n")
    }
}

let server = MCPServer(name: "demo", version: "1.0.0") {
    MyTools.greetTool()
}
try await server.runService()
```

### Features

- **`@MCPCommand` macro** — generate an `MCPTool` conformance from a struct with a `run()` method
- **`@FuncTool` macro** — generate MCP tools from plain functions
- **`@MCPApplication` macro** — full server entry point generation with exhaustive, type-preserving dispatch
- **Property wrappers** — `@Argument`, `@Option`, `@Flag`, `@OptionGroup`
- **Automatic JSON Schema** — tool parameters are described in JSON Schema Draft 7
- **Compile-time discovery** — parameters are discovered via macro-generated code, no runtime reflection
- **Codable parameter types** — custom enums, structs, and optionals decode from their JSON representation
- **Option groups** — share common parameters across tools with `@OptionGroup` + `@MCPOptionGroup`
- **Stdio transport** — standard MCP transport for subprocess-based clients
- **TCP transport** — IPv4, IPv6, dual-stack, and Unix domain socket support
- **Access control** — per-tool access levels with IP-based resolution
- **Enum constraints** — optional `enumValues` parameter for JSON Schema enum constraints
- **Dynamic registration** — register and unregister tools at runtime with `register(_:)` and `unregister(_:)`
- **Structured logging** — `trace`/`debug`/`info`/`warning`/`error` via Swift Logging
- **Actor-based concurrency** — `TransportMessageHandler` for serialized, cancellable message processing

---

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Testing](#testing)
- [License](#license)

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tannerdsilva/swift-mcp.git", from: "1.0.0")
],
targets: [
    .target(
        name: "MyTool",
        dependencies: [
            .product(name: "MCP", package: "swift-mcp"),
        ]
    ),
]
```

The macro implementation ships with the `MCP` product — no separate macro
dependency is required.

## Usage

### Direct MCPTool conformance

```swift
import MCP

struct GetWeather: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Get the current weather for a location"
    )

    @Argument(description: "The city name")
    var city: String = ""

    @Option(description: "Temperature unit (celsius/fahrenheit)")
    var unit: String = "celsius"

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text("The weather in \(city) is sunny and 22°\(unit == "celsius" ? "C" : "F")")
    }
}
```

### `@FuncTool` (function-based)

Apply `@FuncTool` to a function to get an `MCPTool`-conforming struct:

```swift
enum MyTools {
    @FuncTool(description: "Calculate the sum of two numbers")
    static func add(a: Double, b: Double) -> String {
        "\(a + b)"
    }
}

// Parameters without defaults → @Argument (required)
// Parameters with defaults → @Option (optional)
// Bool parameters with default false → @Flag

let server = MCPServer(name: "calc", version: "1.0.0") {
    MyTools.addTool()
}
try await server.runService()
```

The generated struct is named `{FunctionName}Tool` (e.g. `addTool`). Because
`@FuncTool` is a peer macro, the annotated function must be a `static` member
of a type — the compiler forbids arbitrary-name peer macros at file scope, and
the generated tool calls the function unqualified. Any return type is
supported (rendered via `String(describing:)`); `Void`-returning functions
produce an empty text block. See the
[Macro Guide](Sources/MCP/Documentation.docc/MacroGuide.md) for the parameter
constraints.

### `@MCPCommand` (struct-based)

Use `@MCPCommand` to generate an `MCPTool` conformance from a struct:

```swift
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

let server = MCPServer(name: "calc", version: "1.0.0") { Calculate() }
```

### Option groups

Share common parameters across tools:

```swift
@MCPOptionGroup
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

### Server setup

```swift
// Imperative registration
let server = MCPServer(name: "myserver", version: "1.0.0")
server.register(GetWeather())
server.register(Greet())
try await server.runService()

// Declarative registration with result builder
let server = MCPServer(name: "myserver", version: "1.0.0") {
    GetWeather()
    Greet()
    Calculate()
}
try await server.runService()

// Dynamic registration and unregistration
server.register(GetWeather())
server.unregister("getWeather")  // Remove a tool at runtime

// TCP binding
let server = MCPServer(name: "myserver", version: "1.0.0",
    address: .localhostIPv4(port: 8080)) {
    GetWeather()
}
```

### Full application entry point

```swift
@main
@MCPApplication(name: "myserver", version: "1.0.0", address: .localhostIPv4(port: 8080))
struct MyApp {
    @Tool var weather = GetWeather()
    @Tool var greet = Greet()
}
```

## Documentation

The [DocC catalog](Sources/MCP/Documentation.docc/) contains the full guide set:

- **Getting Started** — first steps with swift-mcp
- **Tool Definition** — defining tools with property wrappers and macros
- **Macro Guide** — `@MCPCommand`, `@FuncTool`, `@MCPOptionGroup`, `@MCPApplication`
- **Option Groups** — sharing parameters across tools
- **Server Configuration** — transports, addresses, lifecycle, logging
- **MCP Protocol** — supported protocol methods and message flow
- **Transport Design** — stdio/TCP transports and custom transports
- **Access Control** — the access-level model and IP-based resolution
- **Lifecycle Management** — Swift Service Lifecycle integration
- **Architecture** — framework architecture and design decisions
- **Migration Guide** — upgrading between versions

### Examples

A family of comprehensive, working examples lives in
[`Sources/MCP/Documentation.docc/Examples/`](Sources/MCP/Documentation.docc/Examples/):

| Article | Covers |
|---|---|
| [BasicTools](Sources/MCP/Documentation.docc/Examples/BasicTools.md) | Sync/async, return types, error handling, all parameter types |
| [Example: Server Configuration](Sources/MCP/Documentation.docc/Examples/ExampleServerConfiguration.md) | Stdio, TCP (IPv4/IPv6/dual-stack), Unix sockets, ServiceGroup |
| [AdvancedTools](Sources/MCP/Documentation.docc/Examples/AdvancedTools.md) | Option groups, access control, complex types, composition |
| [IntegrationPatterns](Sources/MCP/Documentation.docc/Examples/IntegrationPatterns.md) | Hummingbird, Vapor, clients, testing, Docker, systemd |
| [RealWorldScenarios](Sources/MCP/Documentation.docc/Examples/RealWorldScenarios.md) | File server, DB proxy, AI assistant, build system, monitor, config |

## Testing

```bash
swift test
```

The suite covers:

- Tool parameter discovery and argument injection (including custom `Codable` types)
- JSON Schema generation
- Error handling (missing arguments, type mismatches, parse errors, access denied)
- Option group flattening and argument application
- Macro expansion and diagnostics for all macros
- Server message handling (initialize, tools/list, tools/call, ping, notifications)
- Stdio and TCP transports end-to-end (EOF, shutdown, real-socket round trips)
- Default access-resolver behavior (IPv4/IPv6 loopback)
- `@MCPApplication` macro (ToolID enum, debug-only tools, address and transport binding)
- Dynamic tool registration, unregistration, and concurrent-registry safety
- Enum value constraints, spec-compliant resource content shapes

## License

This project is licensed under the MIT License. See [LICENSE.txt](LICENSE.txt) for details.
