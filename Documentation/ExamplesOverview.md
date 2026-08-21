# Examples Overview

This family of articles provides extensive, working examples of every way to
use the swift-mcp framework. Each example is self-contained and can be copied
directly into your project.

## Article Index

| Article | Covers |
|---|---|
| [Basic Tools](Examples/BasicTools.md) | Simple tools, sync vs async, return types, error handling |
| [Server Configuration](Examples/ServerConfiguration.md) | All server setup patterns: stdio, TCP, IPv4, IPv6, dual-stack, Unix sockets, ServiceGroup |
| [Advanced Tools](Examples/AdvancedTools.md) | Option groups, access control, complex types, multi-content results |
| [Integration Patterns](Examples/IntegrationPatterns.md) | Embedding, client patterns, testing, Hummingbird integration |
| [Real-World Scenarios](Examples/RealWorldScenarios.md) | Complete applications: file server, database proxy, AI assistant, build system |

## Quick Reference

### Server Launch Patterns

```swift
// Stdio (default) — for CLI subprocess mode
let server = MCPServer(name: "demo", version: "1.0.0") { ... }
try await server.runService()

// TCP — bind to explicit address
let server = MCPServer(name: "demo", version: "1.0.0",
    address: .localhostIPv4(port: 8080)) { ... }
try await server.runService()

// Custom ServiceGroup
let group = ServiceGroup(configuration: .init(
    services: [server],
    gracefulShutdownSignals: [.sigterm, .sigint, .sighup]
))
try await group.run()
```

### Tool Definition Patterns

```swift
// @MCPCommand macro — dual CLI + MCP
@MCPCommand(description: "...")
struct MyTool {
    @Argument(description: "...") var name: String = ""
    func run() async throws -> String { ... }
}

// Direct MCPTool conformance
struct MyTool: MCPTool {
    static let configuration = MCPToolConfiguration(description: "...")
    @Argument(description: "...") var name: String = ""
    func invoke(context: MCPContext) async throws -> MCPToolResult { ... }
}
```

### Transport Address Patterns

```swift
// IPv4
.hostname("127.0.0.1", port: 8080)       // localhost only
.hostname("0.0.0.0", port: 8080)          // all interfaces
.hostname("10.0.1.5", port: 8080)         // specific interface

// IPv6
.hostname("::1", port: 8080)              // localhost only
.hostname("::", port: 8080)               // all interfaces (dual-stack on macOS)

// Unix domain socket
.unixDomainSocket(path: "/tmp/mcp.sock")

// Convenience
.localhostIPv4(port: 8080)
.localhostIPv6(port: 8080)
.allInterfacesIPv4(port: 8080)
.allInterfacesIPv6(port: 8080)
```
