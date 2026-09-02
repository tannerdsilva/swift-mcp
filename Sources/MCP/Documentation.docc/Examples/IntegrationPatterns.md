# Integration Patterns

This article covers how to embed the MCP server in larger applications,
write clients, test tools, and integrate with other frameworks like
Hummingbird and Vapor.

## Table of Contents

- [Embedding in a Hummingbird Application](#embedding-in-a-hummingbird-application)
- [Embedding in a Vapor Application](#embedding-in-a-vapor-application)
- [Writing an MCP Client](#writing-an-mcp-client)
- [Testing Tools](#testing-tools)
- [Testing the Server](#testing-the-server)
- [Docker Deployment](#docker-deployment)
- [Process Supervision](#process-supervision)
- [Environment-Based Configuration](#environment-based-configuration)

---

## Embedding in a Hummingbird Application

Run an MCP server alongside a Hummingbird HTTP server in the same process,
sharing state and services:

```swift
import Hummingbird
import MCP
import ServiceLifecycle

// MARK: - Shared State

actor AppState {
    var requestCount = 0
    var items: [String] = []

    func addItem(_ item: String) {
        items.append(item)
        requestCount += 1
    }

    func getStats() -> (count: Int, items: [String]) {
        (requestCount, items)
    }
}

// MARK: - MCP Tools

struct AppStateMCP {
    let state: AppState
}

extension AppStateMCP {
    @MCPCommand(description: "Add an item to the shared store")
    struct AddItem {
        @Argument(description: "Item to add") var item: String = ""
        func run() async throws -> String { "Added: \(item)" }
    }

    @MCPCommand(description: "Get store statistics")
    struct GetStats {
        func run() async throws -> String { "Stats" }
    }
}

// MARK: - Hummingbird Application

func buildApplication(state: AppState) -> some ApplicationProtocol {
    let router = Router()
    router.get("/health") { _, _ in
        HTTPResponse(status: .ok, body: ByteBuffer(string: "OK"))
    }
    router.get("/items") { _, _ in
        HTTPResponse(status: .ok, body: ByteBuffer(string: "items"))
    }
    var app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 3000)))
    app.addServices()
    return app
}

// MARK: - Main

@main
struct Main {
    static func main() async throws {
        let state = AppState()

        // MCP server
        let mcpServer = MCPServer(
            name: "HummingbirdMCP",
            version: "1.0.0",
            address: .localhostIPv4(port: 9090)
        ) {
            AppStateMCP.AddItem()
            AppStateMCP.GetStats()
        }

        // Hummingbird server
        let app = buildApplication(state: state)

        // Run both in the same ServiceGroup
        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [mcpServer, app],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: Logger(label: "composite")
            )
        )
        try await serviceGroup.run()
    }
}
```

---

## Embedding in a Vapor Application

```swift
import Vapor
import MCP
import ServiceLifecycle

// MARK: - Vapor + MCP

@main
struct Main {
    static func main() async throws {
        let app = try await Vapor.Application.make()

        // Configure Vapor
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 8080

        app.get("health") { _ in "OK" }

        // MCP server
        let mcpServer = MCPServer(
            name: "VaporMCP",
            version: "1.0.0",
            address: .localhostIPv4(port: 9090)
        ) {
            VaporTools.QueryDatabase()
            VaporTools.SendEmail()
        }

        // Run both
        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [mcpServer],
                gracefulShutdownSignals: [.sigterm, .sigint]
            )
        )

        // Start Vapor in a task, run MCP in another
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.run() }
            group.addTask { try await serviceGroup.run() }
            try await group.next()
        }
    }
}
```

---

## Writing an MCP Client

### Minimal Client

```swift
import Foundation

/// A minimal MCP client for testing
final class MCPClient {
    let host: String
    let port: Int
    private var nextId = 1
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(host: String = "127.0.0.1", port: Int = 8080) {
        self.host = host
        self.port = port
    }

    /// Send a JSON-RPC request and receive the response
    func send(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1

        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if !params.isEmpty {
            request["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: request)
        let responseData = try await sendData(data)
        return try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
    }

    /// Initialize the connection
    func initialize() async throws -> [String: Any] {
        try await send(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "clientInfo": ["name": "swift-mcp-client", "version": "1.0.0"]
        ])
    }

    /// List available tools
    func listTools() async throws -> [[String: Any]] {
        let response = try await send(method: "tools/list")
        return (response["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    }

    /// Call a tool
    func callTool(_ name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let response = try await send(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])
        return response["result"] as? [String: Any] ?? [:]
    }

    /// Send raw data over TCP
    private func sendData(_ data: Data) async throws -> Data {
        let socket = try await SocketConnection(host: host, port: port)
        try await socket.send(data + "\n".data(using: .utf8)!)
        return try await socket.receive()
    }
}
```

### Using the Client

```swift
let client = MCPClient(host: "127.0.0.1", port: 8080)

// Initialize
let initResult = try await client.initialize()
print("Server info: \(initResult)")

// List tools
let tools = try await client.listTools()
for tool in tools {
    print(" - \(tool["name"] ?? ""): \(tool["description"] ?? "")")
}

// Call a tool
let result = try await client.callTool("greet", arguments: ["name": "World"])
print("Result: \(result)")
```

---

## Testing Tools

### Unit Testing a Tool

```swift
import Testing
import MCP

@MCPCommand(description: "Add two numbers")
struct Add {
    @Argument(description: "First") var a: Double = 0
    @Argument(description: "Second") var b: Double = 0
    func run() throws -> String { "\(a + b)" }
}

@Test("Add tool returns correct sum")
func testAddTool() async throws {
    var tool = Add()
    tool.a = 2
    tool.b = 3
    let result = try tool.run()
    #expect(result == "5.0")
}

@Test("Add tool with negative numbers")
func testAddNegative() async throws {
    var tool = Add()
    tool.a = -5
    tool.b = 10
    let result = try tool.run()
    #expect(result == "5.0")
}
```

### Testing MCPTool Protocol Conformance

```swift
import Testing
import MCP

struct Greet: MCPTool {
    static let configuration = MCPToolConfiguration(description: "Greet someone")
    @Argument(description: "Name") var name: String = ""

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text("Hello, \(name)!")
    }
}

@Test("Greet tool returns correct text")
func testGreetTool() async throws {
    var tool = Greet()
    try tool.apply(arguments: ["name": "World"])
    let result = try await tool.invoke(context: MCPContext(arguments: ["name": "World"]))
    #expect(result.content.count == 1)

    if case .text(let text) = result.content[0] {
        #expect(text == "Hello, World!")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("Greet tool requires name argument")
func testGreetMissingArgument() async throws {
    var tool = Greet()
    #expect(throws: MCPError.self) {
        try tool.apply(arguments: [:])
    }
}

@Test("Greet tool parameter discovery")
func testGreetParameters() async throws {
    let params = Greet.discoverParameters()
    #expect(params.count == 1)
    #expect(params[0].name == "name")
    #expect(params[0].required == true)
    #expect(params[0].kind == .argument)
}
```

### Testing with Mock Transport

```swift
import Testing
import MCP

/// A mock transport for testing
final class MockTransport: MCPTransport, @unchecked Sendable {
    var messages: [Data] = []
    var responses: [Data] = []
    var onStart: (@Sendable () async throws -> Void)?

    func start(
        handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?
    ) async throws {
        try await onStart?()
        for message in messages {
            if let response = try await handler(message, MCPCallerInfo(
                sourceAddress: "127.0.0.1",
                accessLevel: .admin
            )) {
                responses.append(response)
            }
        }
    }

    func stop() async throws {}
}

@Test("Server handles tools/list request")
func testServerToolsList() async throws {
    let transport = MockTransport()
    transport.messages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]
        ])
    ]

    let server = MCPServer(name: "TestServer", version: "1.0.0", transport: transport) {
        Greet()
    }

    try await server.run()

    #expect(transport.responses.count == 2)
    let listResponse = try JSONSerialization.jsonObject(with: transport.responses[1]) as? [String: Any]
    let result = listResponse?["result"] as? [String: Any]
    let tools = result?["tools"] as? [[String: Any]]
    #expect(tools?.count == 1)
    #expect(tools?.first?["name"] as? String == "greet")
}
```

---

## Testing the Server

### Integration Test with TCP Transport

```swift
import Testing
import MCP

@Test("Server accepts TCP connections and responds to ping")
func testTCPServerPing() async throws {
    // Start server on random port
    let server = MCPServer(
        name: "TestServer",
        version: "1.0.0",
        address: .localhostIPv4(port: 0)  // port 0 = OS-assigned
    ) {
        Greet()
    }

    // Run in background task
    Task {
        try await server.runService()
    }

    // Give it a moment to start
    try await Task.sleep(nanoseconds: 500_000_000)

    // Send ping
    let client = MCPClient(host: "127.0.0.1", port: 8080)
    let response = try await client.send(method: "ping")
    #expect(response["result"] != nil)
}
```

---

## Docker Deployment

### Multi-stage Dockerfile

```dockerfile
# ============================================================
# Build stage
# ============================================================
FROM swift:6.0 AS build

WORKDIR /app
COPY Package.swift .
COPY Sources ./Sources
COPY Tests ./Tests

RUN swift build -c release --static-swift-stdlib

# ============================================================
# Runtime stage
# ============================================================
FROM ubuntu:24.04 AS runtime

# Install ca-certificates for HTTPS calls
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/.build/release/MyServer /app/server  # replace with your executable target

EXPOSE 8080

ENTRYPOINT ["/app/server"]
```

### Docker Compose

```yaml
version: "3.9"
services:
  mcp-server:
    build: .
    ports:
      - "127.0.0.1:8080:8080"  # localhost only
    environment:
      - LOG_LEVEL=info
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{}}' | nc 127.0.0.1 8080"]
      interval: 30s
      timeout: 5s
      retries: 3
```

### Docker Run

```bash
# Build
docker build -t mcp-server .

# Run with IPv4 binding
docker run -p 127.0.0.1:8080:8080 mcp-server

# Run with IPv6 binding
docker run -p [::1]:8080:8080 mcp-server

# Run with Unix socket mount
docker run -v /tmp/mcp.sock:/tmp/mcp.sock mcp-server
```

---

## Process Supervision

### systemd Service

```ini
[Unit]
Description=MCP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mcp-server
Restart=always
RestartSec=5
User=mcp
Group=mcp
Environment=LOG_LEVEL=info

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

### Launchd (macOS)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.mcp-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/mcp-server</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>/var/mcp</string>
    <key>StandardOutPath</key>
    <string>/var/log/mcp-server.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/mcp-server.error.log</string>
</dict>
</plist>
```

---

## Environment-Based Configuration

```swift
import MCP

struct ServerConfig {
    let name: String
    let version: String
    let address: ServerAddress
    let logLevel: Logger.Level

    static func fromEnvironment() -> ServerConfig {
        let host = ProcessInfo.processInfo.environment["MCP_HOST"] ?? "127.0.0.1"
        let port = Int(ProcessInfo.processInfo.environment["MCP_PORT"] ?? "") ?? 8080
        let useIPv6 = ProcessInfo.processInfo.environment["MCP_IPV6"] != nil

        let address: ServerAddress
        if let socketPath = ProcessInfo.processInfo.environment["MCP_SOCKET"] {
            address = .unixDomainSocket(path: socketPath)
        } else if useIPv6 {
            address = .hostname(host, port: port)
        } else {
            address = .hostname(host, port: port)
        }

        return ServerConfig(
            name: ProcessInfo.processInfo.environment["MCP_NAME"] ?? "MCP Server",
            version: ProcessInfo.processInfo.environment["MCP_VERSION"] ?? "1.0.0",
            address: address,
            logLevel: Logger.Level(rawValue: ProcessInfo.processInfo.environment["LOG_LEVEL"] ?? "info") ?? .info
        )
    }
}

@main
struct Main {
    static func main() async throws {
        let config = ServerConfig.fromEnvironment()

        var logger = Logger(label: "mcp.server")
        logger.logLevel = config.logLevel

        let server = MCPServer(
            name: config.name,
            version: config.version,
            address: config.address,
            logger: logger
        ) {
            Greet()
            Calculate()
        }

        try await server.runService()
    }
}
```
