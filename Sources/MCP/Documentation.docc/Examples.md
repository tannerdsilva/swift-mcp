# Examples

This article links to a family of comprehensive, self-contained example
articles covering every aspect of the swift-mcp framework. Each example can be
copied directly into your project.

> The example articles live in this catalog under `Examples/` and are rendered
> by DocC alongside the rest of the documentation.

## Article Index

| Article | Description |
|---|---|
| @Links(visualStyle: detailedGrid) {
    - <doc:BasicTools>
    - <doc:ExampleServerConfiguration>
    - <doc:AdvancedTools>
    - <doc:IntegrationPatterns>
    - <doc:RealWorldScenarios>
}

## Basic Tools

Covers the fundamentals of defining MCP tools — sync vs async, return types,
error handling, and parameter patterns. Includes examples for:

- Minimal tool with one argument
- Sync vs async tools
- Text, `MCPToolResult`, and void return types
- Error handling with `MCPError` and error results
- All parameter types (`@Argument`, `@Option`, `@Flag`)
- Custom tool names
- Tools with no parameters or only optionals

## Server Configuration

Every way to configure and launch an MCP server:

- Stdio transport (default)
- TCP with explicit IPv4 addresses
- TCP with explicit IPv6 addresses
- Dual-stack binding
- Unix domain sockets
- Custom `ServiceGroup` configurations
- Multi-service setups
- Custom transports
- Access control configuration
- Logging configuration

## Advanced Tools

Advanced tool patterns including:

- Option groups for shared parameters
- Nested option groups
- Access control by source address
- Complex parameter types (enums, arrays, custom Codable types)
- Multi-content results
- Tool composition
- Dynamic tool registration
- Conditional tools
- Tools with state

## Integration Patterns

How to embed MCP in larger applications:

- Hummingbird integration
- Vapor integration
- Writing MCP clients
- Unit testing tools
- Integration testing with mock transports
- Docker deployment
- Process supervision (systemd, launchd)
- Environment-based configuration

## Real-World Scenarios

Complete, production-oriented application examples:

- File Server — file system operations
- Database Query Proxy — SQL query execution
- AI Assistant Backend — web search, calculator, weather
- Build System Controller — build management
- Monitoring Dashboard — system metrics
- Configuration Management — config CRUD
- Notification Hub — multi-channel notifications

Each scenario includes the full implementation, server setup, and client
interaction examples.
