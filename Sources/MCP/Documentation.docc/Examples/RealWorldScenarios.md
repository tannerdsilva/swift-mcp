# Real-World Scenarios

This article presents complete, production-oriented application examples
built with swift-mcp. Each scenario is a self-contained project that
demonstrates a realistic use case.

## Table of Contents

- [File Server](#file-server)
- [Database Query Proxy](#database-query-proxy)
- [AI Assistant Backend](#ai-assistant-backend)
- [Build System Controller](#build-system-controller)
- [Monitoring Dashboard](#monitoring-dashboard)
- [Configuration Management](#configuration-management)
- [Notification Hub](#notification-hub)

---

## File Server

An MCP server that provides file system operations — read, write, list, search.

### Tools

- `readFile` — Read a file's contents
- `writeFile` — Write content to a file
- `listDirectory` — List files in a directory
- `searchFiles` — Search for files by pattern
- `fileInfo` — Get file metadata

### Implementation

```swift
import MCP
import Foundation

// MARK: - File Server Tools

@MCPCommand(description: "Read the contents of a file")
struct ReadFile {
    @Argument(description: "Absolute path to the file")
    var path: String = ""

    func run() async throws -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw MCPError.internalError("File not readable: \(path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MCPCommand(description: "Write content to a file")
struct WriteFile {
    @Argument(description: "Absolute path to the file")
    var path: String = ""

    @Argument(description: "Content to write")
    var content: String = ""

    func run() async throws -> String {
        let url = URL(fileURLWithPath: path)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Written \(content.count) bytes to \(path)"
    }
}

@MCPCommand(description: "List files in a directory")
struct ListDirectory {
    @Argument(description: "Directory path")
    var path: String = ""

    @Option(description: "File extension filter (e.g. 'swift')")
    var ext: String? = nil

    func run() async throws -> String {
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: path
        )
        let filtered = ext.map { ext in
            contents.filter { $0.hasSuffix(".\(ext)") }
        } ?? contents
        return filtered.joined(separator: "\n")
    }
}

@MCPCommand(description: "Search for files matching a pattern")
struct SearchFiles {
    @Argument(description: "Directory to search in")
    var directory: String = ""

    @Argument(description: "Filename pattern (glob)")
    var pattern: String = ""

    func run() async throws -> String {
        let enumerator = FileManager.default.enumerator(atPath: directory)
        var matches: [String] = []
        while let file = enumerator?.nextObject() as? String {
            if file.contains(pattern) {
                matches.append(file)
            }
        }
        return matches.joined(separator: "\n")
    }
}

@MCPCommand(description: "Get metadata about a file")
struct FileInfo {
    @Argument(description: "File path")
    var path: String = ""

    func run() async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = attrs[.size] as? Int ?? 0
        let modDate = attrs[.modificationDate] as? Date ?? Date()
        let type = attrs[.type] as? FileAttributeType ?? .typeUnknown

        return """
        Path: \(path)
        Size: \(fileSize) bytes
        Modified: \(modDate)
        Type: \(type == .typeDirectory ? "directory" : "file")
        """
    }
}

// MARK: - Server

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(
            name: "FileServer",
            version: "1.0.0",
            address: .localhostIPv4(port: 8080)
        ) {
            ReadFile()
            WriteFile()
            ListDirectory()
            SearchFiles()
            FileInfo()
        }
        try await server.runService()
    }
}
```

### Example Client Session

```bash
# List files
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"listDirectory","arguments":{"path":"/tmp","ext":"txt"}}}' | nc 127.0.0.1 8080

# Read a file
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"readFile","arguments":{"path":"/tmp/notes.txt"}}}' | nc 127.0.0.1 8080

# Write a file
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"writeFile","arguments":{"path":"/tmp/hello.txt","content":"Hello, MCP!"}}}' | nc 127.0.0.1 8080
```

---

## Database Query Proxy

An MCP server that proxies SQL queries to a PostgreSQL database.

### Tools

- `query` — Execute a SQL query and return results
- `listTables` — List all tables in the database
- `describeTable` — Show table schema

### Implementation

```swift
import MCP
import PostgresNIO  // hypothetical Swift Postgres client

// MARK: - Database Configuration

struct DatabaseConfig {
    let host: String
    let port: Int
    let database: String
    let user: String
    let password: String
}

// MARK: - Shared Database Connection

actor DatabasePool {
    private let config: DatabaseConfig
    private var connection: PostgresConnection?

    init(config: DatabaseConfig) {
        self.config = config
    }

    func connect() async throws -> PostgresConnection {
        if let existing = connection {
            return existing
        }
        let conn = try await PostgresConnection.connect(
            to: .init(host: config.host, port: config.port),
            configuration: .init(
                user: config.user,
                password: config.password,
                database: config.database
            )
        )
        connection = conn
        return conn
    }

    func query(_ sql: String) async throws -> [[String: Any]] {
        let conn = try await connect()
        let rows = try await conn.query(sql)
        return rows.map { row in
            row.columns.reduce(into: [String: Any]()) { dict, col in
                dict[col.name] = col.value
            }
        }
    }
}

// MARK: - Tools

@MCPCommand(description: "Execute a SQL query")
struct Query {
    @Argument(description: "SQL query to execute")
    var sql: String = ""

    func run() async throws -> String {
        let results = try await dbPool.query(sql)
        let jsonData = try JSONSerialization.data(
            withJSONObject: results, options: .prettyPrinted
        )
        return String(decoding: jsonData, as: UTF8.self)
    }
}

@MCPCommand(description: "List all tables in the database")
struct ListTables {
    func run() async throws -> String {
        let results = try await dbPool.query("""
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'public'
            ORDER BY table_name
        """)
        return results.map { $0["table_name"] as? String ?? "" }
            .joined(separator: "\n")
    }
}

@MCPCommand(description: "Describe a table's schema")
struct DescribeTable {
    @Argument(description: "Table name")
    var table: String = ""

    func run() async throws -> String {
        let results = try await dbPool.query("""
            SELECT column_name, data_type, is_nullable
            FROM information_schema.columns
            WHERE table_name = '\(table)'
            ORDER BY ordinal_position
        """)
        return results.map { row in
            "\(row["column_name"] ?? "") (\(row["data_type"] ?? ""))"
        }.joined(separator: "\n")
    }
}

// MARK: - Server

let dbPool = DatabasePool(config: .init(
    host: ProcessInfo.processInfo.environment["DB_HOST"] ?? "localhost",
    port: Int(ProcessInfo.processInfo.environment["DB_PORT"] ?? "") ?? 5432,
    database: ProcessInfo.processInfo.environment["DB_NAME"] ?? "mydb",
    user: ProcessInfo.processInfo.environment["DB_USER"] ?? "user",
    password: ProcessInfo.processInfo.environment["DB_PASS"] ?? ""
))

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(
            name: "DBProxy",
            version: "1.0.0",
            address: .localhostIPv4(port: 8080)
        ) {
            Query()
            ListTables()
            DescribeTable()
        }
        try await server.runService()
    }
}
```

### Security Considerations

- Run on localhost only (`127.0.0.1` or Unix socket)
- Use read-only database credentials for query tools
- Validate and sanitize SQL input
- Consider using parameterized queries
- Set query timeouts to prevent runaway queries

---

## AI Assistant Backend

An MCP server that provides tools for an AI assistant — web search, calculator,
file operations, and system information.

### Tools

- `webSearch` — Search the web
- `calculate` — Evaluate mathematical expressions
- `readFile` — Read a file
- `systemInfo` — Get system information
- `currentTime` — Get the current date and time
- `weather` — Get weather for a location (mock)

### Implementation

```swift
import MCP
import Foundation

// MARK: - Web Search Tool

@MCPCommand(description: "Search the web for information")
struct WebSearch {
    @Argument(description: "Search query")
    var query: String = ""

    @Option(description: "Number of results (1-10)")
    var count: Int = 5

    func run() async throws -> String {
        // In production, use URLSession to call a search API
        return """
        Search results for '\(query)':
        1. https://example.com/result1
        2. https://example.com/result2
        3. https://example.com/result3
        """
    }
}

// MARK: - Calculator Tool

@MCPCommand(description: "Evaluate a mathematical expression")
struct Calculate {
    @Argument(description: "Expression to evaluate")
    var expression: String = ""

    func run() async throws -> String {
        // Use NSExpression for safe evaluation
        let expr = NSExpression(format: expression)
        guard let result = expr.expressionValue(with: nil, context: nil) else {
            throw MCPError.internalError("Could not evaluate expression")
        }
        return "\(expression) = \(result)"
    }
}

// MARK: - System Info Tool

@MCPCommand(description: "Get system information")
struct SystemInfo {
    func run() async throws -> String {
        let processInfo = ProcessInfo.processInfo
        return """
        Hostname: \(processInfo.hostName)
        OS: \(processInfo.operatingSystemVersionString)
        CPUs: \(processInfo.processorCount)
        Memory: \(processInfo.physicalMemory / 1024 / 1024 / 1024) GB
        Swift: \(processInfo.swiftVersion)
        """
    }
}

// MARK: - Time Tool

@MCPCommand(description: "Get the current date and time")
struct CurrentTime {
    @Option(description: "Timezone (e.g. 'America/New_York')")
    var timezone: String = "UTC"

    func run() async throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(abbreviation: "UTC")
        return formatter.string(from: Date())
    }
}

// MARK: - Weather Tool (Mock)

@MCPCommand(description: "Get the current weather for a location")
struct Weather {
    @Argument(description: "City name")
    var city: String = ""

    @Option(description: "Units: metric or imperial")
    var units: String = "metric"

    func run() async throws -> String {
        let temp = units == "metric" ? 22 : 72
        let unit = units == "metric" ? "°C" : "°F"
        return "Weather in \(city): \(temp)\(unit), partly cloudy"
    }
}

// MARK: - Server

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(
            name: "AIAssistant",
            version: "1.0.0",
            address: .hostname("127.0.0.1", port: 8080)
        ) {
            WebSearch()
            Calculate()
            SystemInfo()
            CurrentTime()
            Weather()
        }
        try await server.runService()
    }
}
```

### Client Integration (Python)

```python
import json
import socket

class MCPClient:
    def __init__(self, host="127.0.0.1", port=8080):
        self.host = host
        self.port = port
        self.id = 0

    def send(self, method, params=None):
        self.id += 1
        request = {
            "jsonrpc": "2.0",
            "id": self.id,
            "method": method,
        }
        if params:
            request["params"] = params

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.connect((self.host, self.port))
            sock.sendall((json.dumps(request) + "\n").encode())

            response = b""
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response += chunk
                if b"\n" in chunk:
                    break

        return json.loads(response)

    def initialize(self):
        return self.send("initialize", {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "python-client", "version": "1.0"}
        })

    def list_tools(self):
        return self.send("tools/list")

    def call_tool(self, name, arguments=None):
        return self.send("tools/call", {
            "name": name,
            "arguments": arguments or {}
        })

# Usage
client = MCPClient()
client.initialize()
tools = client.list_tools()
result = client.call_tool("weather", {"city": "London", "units": "metric"})
print(result)
```

---

## Build System Controller

An MCP server that controls a build system — trigger builds, check status,
view logs, and manage build artifacts.

### Tools

- `build` — Trigger a build for a project
- `buildStatus` — Check the status of a build
- `buildLogs` — Get build logs
- `listArtifacts` — List build artifacts
- `cleanBuild` — Clean and rebuild

### Implementation

```swift
import MCP
import Foundation

// MARK: - Build State

actor BuildManager {
    enum BuildStatus: String {
        case idle, building, succeeded, failed
    }

    struct Build {
        let id: String
        let project: String
        let startTime: Date
        var status: BuildStatus
        var logs: [String]
        var artifacts: [String]
    }

    private var builds: [String: Build] = [:]
    private var nextId = 1

    func startBuild(project: String) -> String {
        let id = "build-\(nextId)"
        nextId += 1
        builds[id] = Build(
            id: id,
            project: project,
            startTime: Date(),
            status: .building,
            logs: ["Starting build for \(project)..."],
            artifacts: []
        )
        return id
    }

    func getStatus(id: String) -> Build? {
        builds[id]
    }

    func addLog(id: String, message: String) {
        builds[id]?.logs.append(message)
    }

    func completeBuild(id: String, success: Bool) {
        builds[id]?.status = success ? .succeeded : .failed
        builds[id]?.logs.append(success ? "Build succeeded" : "Build failed")
    }
}

let buildManager = BuildManager()

// MARK: - Tools

@MCPCommand(description: "Trigger a build for a project")
struct Build {
    @Argument(description: "Project name or path")
    var project: String = ""

    @Option(description: "Build configuration (debug/release)")
    var configuration: String = "release"

    func run() async throws -> String {
        let buildId = await buildManager.startBuild(project: project)

        // Start build in background
        Task {
            await buildManager.addLog(id: buildId, message: "Configuration: \(configuration)")
            // Simulate build
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await buildManager.addLog(id: buildId, message: "Compiling...")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            await buildManager.completeBuild(id: buildId, success: true)
        }

        return "Build started: \(buildId) for \(project)"
    }
}

@MCPCommand(description: "Check the status of a build")
struct BuildStatus {
    @Argument(description: "Build ID")
    var buildId: String = ""

    func run() async throws -> String {
        guard let build = await buildManager.getStatus(id: buildId) else {
            throw MCPError.internalError("Build not found: \(buildId)")
        }
        return """
        Build: \(build.id)
        Project: \(build.project)
        Status: \(build.status.rawValue)
        Started: \(build.startTime)
        """
    }
}

@MCPCommand(description: "Get build logs")
struct BuildLogs {
    @Argument(description: "Build ID")
    var buildId: String = ""

    func run() async throws -> String {
        guard let build = await buildManager.getStatus(id: buildId) else {
            throw MCPError.internalError("Build not found: \(buildId)")
        }
        return build.logs.joined(separator: "\n")
    }
}

@MCPCommand(description: "List build artifacts")
struct ListArtifacts {
    @Argument(description: "Build ID")
    var buildId: String = ""

    func run() async throws -> String {
        guard let build = await buildManager.getStatus(id: buildId) else {
            throw MCPError.internalError("Build not found: \(buildId)")
        }
        let artifacts = build.artifacts
        return artifacts.isEmpty ? "No artifacts" : artifacts.joined(separator: "\n")
    }
}

@MCPCommand(description: "Clean and rebuild a project")
struct CleanBuild {
    @Argument(description: "Project name or path")
    var project: String = ""

    func run() async throws -> String {
        // Clean step
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // Build step
        let buildId = await buildManager.startBuild(project: project)
        await buildManager.completeBuild(id: buildId, success: true)
        return "Clean build completed: \(buildId)"
    }
}

// MARK: - Server

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(
            name: "BuildSystem",
            version: "1.0.0",
            address: .localhostIPv4(port: 8080)
        ) {
            Build()
            BuildStatus()
            BuildLogs()
            ListArtifacts()
            CleanBuild()
        }
        try await server.runService()
    }
}
```

---

## Monitoring Dashboard

An MCP server that provides system monitoring data — CPU, memory, disk,
network, and running processes.

### Tools

- `cpuInfo` — Get CPU usage information
- `memoryInfo` — Get memory usage
- `diskInfo` — Get disk usage
- `networkInfo` — Get network statistics
- `processList` — List running processes
- `uptime` — Get system uptime

### Implementation

```swift
import MCP
import Foundation

@MCPCommand(description: "Get CPU usage information")
struct CPUInfo {
    func run() async throws -> String {
        // On macOS, use sysctl or host_info
        return """
        CPU: Apple M3 Ultra
        Cores: 32 (24 performance + 8 efficiency)
        Usage: 12.5%
        Temperature: 52°C
        """
    }
}

@MCPCommand(description: "Get memory usage information")
struct MemoryInfo {
    func run() async throws -> String {
        let processInfo = ProcessInfo.processInfo
        let physical = processInfo.physicalMemory
        // Note: actual usage requires host_statistics or similar
        return """
        Total: \(physical / 1024 / 1024 / 1024) GB
        Used: 32 GB
        Available: 224 GB
        """
    }
}

@MCPCommand(description: "Get disk usage information")
struct DiskInfo {
    @Option(description: "Mount point (default: /)")
    var path: String = "/"

    func run() async throws -> String {
        let attrs = try FileManager.default.attributesOfFileSystem(
            forPath: path
        )
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used = total - free

        return """
        Mount: \(path)
        Total: \(total / 1024 / 1024 / 1024) GB
        Used: \(used / 1024 / 1024 / 1024) GB
        Free: \(free / 1024 / 1024 / 1024) GB
        """
    }
}

@MCPCommand(description: "Get network statistics")
struct NetworkInfo {
    func run() async throws -> String {
        // Would use ifaddrs or similar system call
        return """
        Interface: en0
        IP: 192.168.1.100
        RX: 1.2 GB
        TX: 0.8 GB
        Connections: 42
        """
    }
}

@MCPCommand(description: "List running processes")
struct ProcessList {
    @Option(description: "Filter by process name")
    var filter: String? = nil

    @Option(description: "Maximum results")
    var limit: Int = 20

    func run() async throws -> String {
        // Would use proc_listallpids or similar
        return """
        PID  NAME          CPU%  MEM%
        1    launchd       0.0   0.1
        123  mcp-server    0.5   0.3
        456  safari        2.1   1.5
        """
    }
}

@MCPCommand(description: "Get system uptime")
struct Uptime {
    func run() async throws -> String {
        var uptime = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &uptime)
        let seconds = uptime.tv_sec
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        return "Uptime: \(days)d \(hours)h \(minutes)m"
    }
}

// MARK: - Server

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(
            name: "Monitor",
            version: "1.0.0",
            address: .localhostIPv4(port: 8080)
        ) {
            CPUInfo()
            MemoryInfo()
            DiskInfo()
            NetworkInfo()
            ProcessList()
            Uptime()
        }
        try await server.runService()
    }
}
```

---

## Configuration Management

An MCP server that manages application configuration — get, set, list, and
validate configuration values.

### Tools

- `configGet` — Get a configuration value
- `configSet` — Set a configuration value
- `configList` — List all configuration keys
- `configValidate` — Validate the configuration
- `configReload` — Reload configuration from file
- `configExport` — Export configuration as JSON

### Implementation

```swift
import MCP
import Foundation

// MARK: - Configuration Store

actor ConfigStore {
    private var config: [String: Any] = [:]
    private let filePath: String

    init(filePath: String) {
        self.filePath = filePath
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            config = [:]
            return
        }
        config = json
    }

    func save() throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        try data.write(to: URL(fileURLWithPath: filePath))
    }

    func get(_ key: String) -> Any? { config[key] }
    func set(_ key: String, value: Any) { config[key] = value }
    func all() -> [String: Any] { config }
    func reload() { load() }
}

let configStore = ConfigStore(filePath: "/etc/myapp/config.json")

// MARK: - Tools

@MCPCommand(description: "Get a configuration value")
struct ConfigGet {
    @Argument(description: "Configuration key")
    var key: String = ""

    func run() async throws -> String {
        guard let value = await configStore.get(key) else {
            throw MCPError.internalError("Key not found: \(key)")
        }
        return "\(key) = \(value)"
    }
}

@MCPCommand(description: "Set a configuration value")
struct ConfigSet {
    @Argument(description: "Configuration key")
    var key: String = ""

    @Argument(description: "Value (JSON-encoded)")
    var value: String = ""

    func run() async throws -> String {
        let parsedValue = try JSONSerialization.jsonObject(
            with: value.data(using: .utf8)!
        )
        await configStore.set(key, value: parsedValue)
        try await configStore.save()
        return "Set \(key) = \(value)"
    }
}

@MCPCommand(description: "List all configuration keys")
struct ConfigList {
    @Option(description: "Filter by prefix")
    var prefix: String? = nil

    func run() async throws -> String {
        let all = await configStore.all()
        let filtered = prefix.map { p in
            all.filter { $0.key.hasPrefix(p) }
        } ?? all
        return filtered.map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }
}

@MCPCommand(description: "Validate the current configuration")
struct ConfigValidate {
    func run() async throws -> String {
        let all = await configStore.all()
        var errors: [String] = []

        for (key, value) in all {
            if value is NSNull {
                errors.append("\(key) is null")
            }
        }

        if errors.isEmpty {
            return "Configuration is valid (\(all.count) keys)"
        }
        return "Validation errors:\n" + errors.joined(separator: "\n")
    }
}

@MCPCommand(description: "Reload configuration from file")
struct ConfigReload {
    func run() async throws -> String {
        await configStore.reload()
        let count = await configStore.all().count
        return "Configuration reloaded (\(count) keys)"
    }
}

@MCPCommand(description: "Export configuration as JSON")
struct ConfigExport {
    func run() async throws -> String {
        let all = await configStore.all()
        let data = try JSONSerialization.data(withJSONObject: all, options: .prettyPrinted)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Server

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(
            name: "ConfigManager",
            version: "1.0.0",
            address: .unixDomainSocket(path: "/tmp/config-mcp.sock")
        ) {
            ConfigGet()
            ConfigSet()
            ConfigList()
            ConfigValidate()
            ConfigReload()
            ConfigExport()
        }
        try await server.runService()
    }
}
```

---

## Notification Hub

An MCP server that sends notifications through multiple channels — email,
Slack, SMS, and push notifications.

### Tools

- `sendEmail` — Send an email notification
- `sendSlack` — Send a Slack message
- `sendSMS` — Send an SMS notification
- `sendPush` — Send a push notification
- `notificationStatus` — Check delivery status

### Implementation

```swift
import MCP
import Foundation

// MARK: - Notification Service

actor NotificationService {
    struct Notification: Sendable {
        let id: String
        let channel: String
        let recipient: String
        let subject: String
        let body: String
        let status: String
    }

    private var notifications: [String: Notification] = [:]
    private var nextId = 1

    func send(channel: String, recipient: String, subject: String, body: String) -> String {
        let id = "notif-\(nextId)"
        nextId += 1
        notifications[id] = Notification(
            id: id, channel: channel, recipient: recipient,
            subject: subject, body: body, status: "sent"
        )
        return id
    }

    func getStatus(id: String) -> Notification? {
        notifications[id]
    }
}

let notifier = NotificationService()

// MARK: - Tools

@MCPCommand(description: "Send an email notification")
struct SendEmail {
    @Argument(description: "Recipient email address")
    var to: String = ""

    @Argument(description: "Email subject")
    var subject: String = ""

    @Argument(description: "Email body")
    var body: String = ""

    func run() async throws -> String {
        let id = await notifier.send(
            channel: "email", recipient: to,
            subject: subject, body: body
        )
        return "Email sent: \(id) to \(to)"
    }
}

@MCPCommand(description: "Send a Slack message")
struct SendSlack {
    @Argument(description: "Slack channel (e.g. #general)")
    var channel: String = ""

    @Argument(description: "Message text")
    var message: String = ""

    func run() async throws -> String {
        let id = await notifier.send(
            channel: "slack", recipient: channel,
            subject: "", body: message
        )
        return "Slack message sent: \(id) to \(channel)"
    }
}

@MCPCommand(description: "Send an SMS notification")
struct SendSMS {
    @Argument(description: "Phone number")
    var phone: String = ""

    @Argument(description: "Message text")
    var message: String = ""

    func run() async throws -> String {
        let id = await notifier.send(
            channel: "sms", recipient: phone,
            subject: "", body: message
        )
        return "SMS sent: \(id) to \(phone)"
    }
}

@MCPCommand(description: "Send a push notification")
struct SendPush {
    @Argument(description: "Device token")
    var deviceToken: String = ""

    @Argument(description: "Title")
    var title: String = ""

    @Argument(description: "Body")
    var body: String = ""

    func run() async throws -> String {
        let id = await notifier.send(
            channel: "push", recipient: deviceToken,
            subject: title, body: body
        )
        return "Push notification sent: \(id)"
    }
}

@MCPCommand(description: "Check notification delivery status")
struct NotificationStatus {
    @Argument(description: "Notification ID")
    var notificationId: String = ""

    func run() async throws -> String {
        guard let notif = await notifier.getStatus(id: notificationId) else {
            throw MCPError.internalError("Notification not found: \(notificationId)")
        }
        return """
        ID: \(notif.id)
        Channel: \(notif.channel)
        Recipient: \(notif.recipient)
        Subject: \(notif.subject)
        Status: \(notif.status)
        """
    }
}

// MARK: - Server

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(
            name: "Notifier",
            version: "1.0.0",
            address: .localhostIPv4(port: 8080)
        ) {
            SendEmail()
            SendSlack()
            SendSMS()
            SendPush()
            NotificationStatus()
        }
        try await server.runService()
    }
}
```
