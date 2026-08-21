# Basic Tools

This article covers the fundamentals of defining MCP tools — sync vs async,
return types, error handling, and parameter patterns.

## Table of Contents

- [Minimal Tool](#minimal-tool)
- [Sync vs Async](#sync-vs-async)
- [Return Types](#return-types)
- [Error Handling](#error-handling)
- [All Parameter Types](#all-parameter-types)
- [Custom Tool Names](#custom-tool-names)
- [Tools with No Parameters](#tools-with-no-parameters)
- [Tools with Only Optionals](#tools-with-only-optionals)

---

## Minimal Tool

The simplest possible MCP tool — one argument, one text response:

```swift
import MCP

@MCPCommand(description: "Echo back the input")
struct Echo {
    @Argument(description: "Text to echo")
    var text: String = ""

    func run() async throws -> String {
        return text
    }
}
```

**Server:**

```swift
let server = MCPServer(name: "echo", version: "1.0.0") {
    Echo()
}
try await server.runService()
```

**Client call:**

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"Hello, world!"}}}
```

**Response:**

```json
{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Hello, world!"}],"isError":false}}
```

---

## Sync vs Async

The `@MCPCommand` macro automatically detects whether your `run()` method is
sync or async and generates the appropriate `invoke(context:)` implementation.

### Sync Tool

```swift
@MCPCommand(description: "Add two numbers")
struct Add {
    @Argument(description: "First number") var a: Double = 0
    @Argument(description: "Second number") var b: Double = 0

    func run() throws -> String {
        let result = a + b
        return "\(a) + \(b) = \(result)"
    }
}
```

### Async Tool

```swift
@MCPCommand(description: "Fetch a web page")
struct Fetch {
    @Argument(description: "URL to fetch") var url: String = ""

    func run() async throws -> String {
        let (data, _) = try await URLSession.shared.data(
            from: URL(string: url)!
        )
        return String(decoding: data, as: UTF8.self)
    }
}
```

### Direct Conformance — Sync

```swift
struct Greet: MCPTool {
    static let configuration = MCPToolConfiguration(description: "Greet someone")

    @Argument(description: "Name") var name: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        // Even for sync work, invoke is async throws by protocol
        return .text("Hello, \(name)!")
    }
}
```

### Direct Conformance — Async with Network Call

```swift
struct GetWeather: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Get current weather for a city"
    )

    @Argument(description: "City name") var city: String = ""
    @Option(description: "Units: metric or imperial") var units: String = "metric"

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        let url = URL(string: "https://api.weather.com/current?city=\(city)&units=\(units)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return .text(String(decoding: data, as: UTF8.self))
    }
}
```

---

## Return Types

### Text (String)

The most common return type. The `@MCPCommand` macro accepts any `String`-returning
`run()` method and wraps it in `.text(...)` automatically.

```swift
@MCPCommand(description: "Return a greeting")
struct Greet {
    @Argument(description: "Name") var name: String = ""
    func run() async throws -> String { "Hello, \(name)!" }
}
```

### MCPToolResult (Direct Conformance)

For full control over the response — multiple content blocks, error flags:

```swift
struct MultiContent: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Return multiple content blocks"
    )

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        MCPToolResult(content: [
            .text("Here is the result:"),
            .text("Line two of the result"),
            .image(data: base64String, mimeType: "image/png")
        ])
    }
}
```

### Void / No Return

For tools that perform side effects without returning data:

```swift
@MCPCommand(description: "Log a message")
struct LogMessage {
    @Argument(description: "Message to log") var message: String = ""

    func run() async throws {
        print("LOG: \(message)")
        // No return value — client receives empty content
    }
}
```

### Multiple Content Blocks

```swift
struct Report: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Generate a report with text and an image"
    )

    @Argument(description: "Data to chart") var dataPoints: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        let chartImage = generateChart(from: dataPoints)
        return MCPToolResult(content: [
            .text("Report generated successfully"),
            .text("Data points: \(dataPoints)"),
            .image(data: chartImage, mimeType: "image/png")
        ])
    }
}

func generateChart(from data: String) -> String {
    // Returns base64-encoded PNG
    ""
}
```

---

## Error Handling

### Throwing Errors

Throw `MCPError` for structured error responses:

```swift
@MCPCommand(description: "Divide two numbers")
struct Divide {
    @Argument(description: "Dividend") var a: Double = 0
    @Argument(description: "Divisor") var b: Double = 0

    func run() async throws -> String {
        guard b != 0 else {
            throw MCPError.internalError("Division by zero")
        }
        return "\(a) / \(b) = \(a / b)"
    }
}
```

**Error response:**

```json
{
    "jsonrpc": "2.0",
    "id": 1,
    "error": {
        "code": -32603,
        "message": "Division by zero"
    }
}
```

### Error Result (Non-Throwing)

For error results that are part of normal operation (not framework errors):

```swift
struct Validate: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Validate an email address"
    )

    @Argument(description: "Email to validate") var email: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        if email.contains("@") && email.contains(".") {
            return .text("Valid email: \(email)")
        } else {
            return .error("Invalid email format: \(email)")
        }
    }
}
```

### Type Mismatch Errors

The framework automatically returns type mismatch errors when argument types
don't match. No special handling needed:

```swift
@MCPCommand(description: "Set a timeout")
struct SetTimeout {
    @Argument(description: "Timeout in seconds") var seconds: Int = 0
    func run() async throws -> String {
        "Timeout set to \(seconds)s"
    }
}
```

If a client sends `{"seconds": "not-a-number"}`, the framework returns:

```json
{
    "jsonrpc": "2.0",
    "id": 1,
    "error": {
        "code": -32603,
        "message": "Type mismatch: expected Int, got String"
    }
}
```

---

## All Parameter Types

A tool demonstrating every parameter type together:

```swift
@MCPCommand(description: "Demonstrate all parameter types")
struct AllParams {
    // Required positional argument
    @Argument(description: "A required value")
    var required: String = ""

    // Optional named parameter with default
    @Option(description: "An optional value")
    var optional: Int = 42

    // Boolean flag
    @Flag(description: "Enable verbose output")
    var verbose: Bool = false

    // Optional named parameter with String default
    @Option(description: "Output format")
    var format: String = "json"

    func run() async throws -> String {
        """
        Required: \(required)
        Optional: \(optional)
        Verbose: \(verbose)
        Format: \(format)
        """
    }
}
```

**Client call:**

```json
{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
        "name": "allParams",
        "arguments": {
            "required": "hello",
            "verbose": true
        }
    }
}
```

**Response:**

```json
{
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "content": [{"type": "text", "text": "Required: hello\nOptional: 42\nVerbose: true\nFormat: json"}],
        "isError": false
    }
}
```

---

## Custom Tool Names

By default, the tool name is derived from the type name (first letter lowercased).
Override with `configuration.name`:

```swift
@MCPCommand(
    description: "Search for items",
    name: "search-items"  // explicit kebab-case name
)
struct SearchItems {
    @Argument(description: "Query string") var query: String = ""

    func run() async throws -> String {
        "Searching for: \(query)"
    }
}
```

With direct conformance:

```swift
struct SearchItems: MCPTool {
    static let configuration = MCPToolConfiguration(
        name: "search-items",
        description: "Search for items"
    )

    @Argument(description: "Query string") var query: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text("Searching for: \(query)")
    }
}
```

---

## Tools with No Parameters

```swift
@MCPCommand(description: "Return server health status")
struct Health {
    func run() async throws -> String {
        "{\"status\": \"healthy\", \"uptime\": 3600}"
    }
}
```

---

## Tools with Only Optionals

All parameters are optional with defaults:

```swift
@MCPCommand(description: "Configure the system")
struct Configure {
    @Option(description: "Hostname") var host: String = "localhost"
    @Option(description: "Port number") var port: Int = 8080
    @Flag(description: "Use TLS") var tls: Bool = false

    func run() async throws -> String {
        "Configured: \(host):\(port) tls=\(tls)"
    }
}
```

The client can call with no arguments and all defaults apply:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"configure","arguments":{}}}
```
