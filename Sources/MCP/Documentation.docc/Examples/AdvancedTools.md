# Advanced Tools

This article covers advanced tool patterns — option groups, access control,
complex parameter types, multi-content results, and tool composition.

## Table of Contents

- [Option Groups (Shared Parameters)](#option-groups-shared-parameters)
- [Nested Option Groups](#nested-option-groups)
- [Access Control by Source Address](#access-control-by-source-address)
- [Complex Parameter Types](#complex-parameter-types)
- [Multi-Content Results](#multi-content-results)
- [Tool Composition](#tool-composition)
- [Dynamic Tool Registration](#dynamic-tool-registration)
- [Conditional Tools](#conditional-tools)
- [Tools with State](#tools-with-state)

---

## Option Groups (Shared Parameters)

Option groups let you share common parameters across multiple tools without
duplication. Define a struct with the shared parameters and use `@OptionGroup`
to include it.

### Defining a Shared Parameter Group

```swift
import MCP

/// Shared parameters for all database tools
struct DatabaseOptions {
    @Option(description: "Database hostname")
    var host: String = "localhost"

    @Option(description: "Database port")
    var port: Int = 5432

    @Option(description: "Database name")
    var database: String = "mydb"

    @Option(description: "Connection timeout in seconds")
    var timeout: Int = 30

    @Flag(description: "Use TLS for the connection")
    var tls: Bool = false
}
```

### Using the Group in Multiple Tools

```swift
@MCPCommand(description: "Query the database")
struct Query {
    @OptionGroup
    var db: DatabaseOptions

    @Argument(description: "SQL query")
    var sql: String = ""

    func run() async throws -> String {
        let tls = db.tls ? " (TLS)" : ""
        return "Querying \(db.host):\(db.port)/\(db.database)\(tls): \(sql)"
    }
}

@MCPCommand(description: "Migrate the database schema")
struct Migrate {
    @OptionGroup
    var db: DatabaseOptions

    @Argument(description: "Migration file path")
    var migrationFile: String = ""

    func run() async throws -> String {
        return "Running migration \(migrationFile) on \(db.database)"
    }
}
```

### Server Setup

```swift
let server = MCPServer(name: "DBTools", version: "1.0.0") {
    Query()
    Migrate()
}
try await server.runService()
```

### Client Call

The group's parameters are flattened into the parent's namespace:

```json
{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
        "name": "query",
        "arguments": {
            "host": "db.example.com",
            "port": 5432,
            "database": "analytics",
            "tls": true,
            "sql": "SELECT * FROM users"
        }
    }
}
```

---

## Nested Option Groups

Option groups can contain other option groups:

```swift
struct Credentials {
    @Option(description: "Username")
    var username: String = "admin"

    @Option(description: "Password")
    var password: String = ""
}

struct ConnectionOptions {
    @OptionGroup
    var credentials: Credentials

    @Option(description: "API endpoint URL")
    var endpoint: String = "https://api.example.com"

    @Option(description: "Request timeout")
    var timeout: Int = 10
}

@MCPCommand(description: "Call an API endpoint")
struct ApiCall {
    @OptionGroup
    var connection: ConnectionOptions

    @Argument(description: "API path")
    var path: String = ""

    func run() async throws -> String {
        return "Calling \(connection.endpoint)/\(path) as \(connection.credentials.username)"
    }
}
```

**Flattened parameters:** `username`, `password`, `endpoint`, `timeout`, `path`

---

## Access Control by Source Address

Control which callers can invoke which tools based on their IP address.

### Defining Tools with Access Levels

```swift
// Public tool — anyone can use
@MCPCommand(description: "Search public records")
struct Search {
    @Argument(description: "Query") var query: String = ""
    func run() async throws -> String { "Searching for: \(query)" }
}

// User-level tool — authenticated users
@MCPCommand(
    description: "Access user profile",
    requiredAccess: .user
)
struct GetProfile {
    @Argument(description: "User ID") var userId: String = ""
    func run() async throws -> String { "Profile for: \(userId)" }
}

// Admin-only tool
@MCPCommand(
    description: "Server administration",
    requiredAccess: .admin
)
struct AdminPanel {
    @Argument(description: "Command") var command: String = ""
    func run() async throws -> String { "Admin: \(command)" }
}
```

### Configuring the Access Resolver

```swift
let transport = TCPTransport(
    address: .hostname("0.0.0.0", port: 8080),
    accessResolver: { address in
        // Extract IP (strip port if present)
        let ip = address.split(separator: ":").first.map(String.init) ?? address

        switch ip {
        case "127.0.0.1", "::1", "::ffff:127.0.0.1":
            return .admin       // localhost gets full access
        case let s where s.hasPrefix("10.0."):
            return .user        // internal network
        case let s where s.hasPrefix("192.168."):
            return .user        // internal network
        default:
            return .public      // external gets public tools only
        }
    }
)

let server = MCPServer(
    name: "SecureServer",
    version: "1.0.0",
    transport: transport
) {
    Search()
    GetProfile()
    AdminPanel()
}
```

### Access Denied Response

When a caller without sufficient access tries to invoke a protected tool:

```json
{
    "jsonrpc": "2.0",
    "id": 1,
    "error": {
        "code": -32000,
        "message": "Access denied: adminPanel"
    }
}
```

---

## Complex Parameter Types

While the framework supports basic types (String, Int, Double, Bool) out of
the box, you can use any `Codable & Sendable` type with the property wrappers.

### Enum Parameters

```swift
enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

@MCPCommand(description: "Set the log level")
struct SetLogLevel {
    @Option(description: "Log level")
    var level: LogLevel = .info

    func run() async throws -> String {
        return "Log level set to \(level.rawValue)"
    }
}
```

### Array Parameters

```swift
@MCPCommand(description: "Process a list of items")
struct BatchProcess {
    @Argument(description: "Items to process (comma-separated)")
    var items: [String] = []

    @Option(description: "Batch size")
    var batchSize: Int = 10

    func run() async throws -> String {
        return "Processing \(items.count) items in batches of \(batchSize)"
    }
}
```

### Optional Parameters

```swift
@MCPCommand(description: "Find a user")
struct FindUser {
    @Option(description: "Filter by email")
    var email: String? = nil

    @Option(description: "Filter by department")
    var department: String? = nil

    func run() async throws -> String {
        if let email {
            return "Searching by email: \(email)"
        } else if let department {
            return "Searching by department: \(department)"
        }
        return "No filters provided"
    }
}
```

### Custom Codable Types

```swift
struct Coordinates: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct BoundingBox: Codable, Sendable {
    let northEast: Coordinates
    let southWest: Coordinates
}

@MCPCommand(description: "Search within a geographic area")
struct GeoSearch {
    @Argument(description: "Query") var query: String = ""
    @Argument(description: "Bounding box") var bounds: BoundingBox

    func run() async throws -> String {
        return "Searching '\(query)' within bounds"
    }
}
```

---

## Multi-Content Results

Tools can return multiple content blocks of different types.

### Text + Image

```swift
struct Screenshot: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Take a screenshot of a web page"
    )

    @Argument(description: "URL to capture") var url: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        let imageData = try await captureWebPage(url)
        return MCPToolResult(content: [
            .text("Screenshot of \(url):"),
            .image(data: imageData, mimeType: "image/png")
        ])
    }
}
```

### Text + Resource

```swift
struct ReadFile: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Read a file and return its contents"
    )

    @Argument(description: "File path") var path: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return MCPToolResult(content: [
            .text("File: \(path)"),
            .resource(uri: "file://\(path)", mimeType: "text/plain", text: content)
        ])
    }
}
```

### Structured Data

```swift
struct AnalyzeData: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Analyze a dataset and return results"
    )

    @Argument(description: "CSV data") var csv: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        let summary = computeSummary(from: csv)
        let chartBase64 = generateChart(from: csv)
        return MCPToolResult(content: [
            .text("Analysis complete"),
            .text(summary),
            .image(data: chartBase64, mimeType: "image/svg+xml")
        ])
    }
}
```

---

## Tool Composition

Call one tool from another by creating a new context:

```swift
@MCPCommand(description: "Format a greeting")
struct FormatGreeting {
    @Argument(description: "Name") var name: String = ""
    @Flag(description: "Formal") var formal: Bool = false

    func run() async throws -> String {
        formal ? "Greetings, \(name)!" : "Hey \(name)!"
    }
}

@MCPCommand(description: "Greet multiple people")
struct GreetAll {
    @Argument(description: "Names (comma-separated)")
    var names: String = ""

    func run() async throws -> String {
        let nameList = names.split(separator: ",").map(String.init)
        var greeting = FormatGreeting()
        var results: [String] = []

        for name in nameList {
            greeting.name = name
            greeting.formal = false
            // Note: direct invocation requires MCPTool protocol
            // This is a simplified example
            results.append("Hello, \(name)!")
        }

        return results.joined(separator: "\n")
    }
}
```

---

## Dynamic Tool Registration

Register tools programmatically at runtime:

```swift
let server = MCPServer(name: "Dynamic", version: "1.0.0")

// Register tools one at a time
server.register(Greet())
server.register(Calculate())

// Register based on configuration
if config.enableAdminTools {
    server.register(AdminPanel())
    server.register(Metrics())
}

// Register from a plugin system
for plugin in loadedPlugins {
    server.register(plugin.tool)
}

try await server.runService()
```

---

## Conditional Tools

Use the result builder's conditional support to include tools based on
compile-time or runtime conditions:

```swift
let server = MCPServer(name: "MyServer", version: "1.0.0") {
    Greet()
    Calculate()

    if ProcessInfo.processInfo.environment["ENABLE_DEBUG"] != nil {
        DebugTool()
        Metrics()
    }

    #if DEBUG
    TestTool()
    #endif
}
```

---

## Tools with State

Tools are instantiated fresh for each invocation, but you can use the server's
context for shared state:

```swift
actor SharedState {
    var counter: Int = 0

    func increment() -> Int {
        counter += 1
        return counter
    }
}

let state = SharedState()

@MCPCommand(description: "Get the current request count")
struct GetCount {
    func run() async throws -> String {
        let count = await state.increment()
        return "Request count: \(count)"
    }
}

let server = MCPServer(name: "Stateful", version: "1.0.0") {
    GetCount()
}
```
