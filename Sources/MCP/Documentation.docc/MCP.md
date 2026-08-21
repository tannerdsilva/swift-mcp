# ``MCP``

Build MCP (Model Context Protocol) servers in Swift with a declarative, macro-driven API.

## Overview

swift-mcp is a Swift framework for building MCP servers. It provides:

- **Macro-based tool definition**: Use `@MCPCommand` to define tools with `@Argument`, `@Option`, `@Flag`, and `@OptionGroup` wrappers — one struct generates both an MCP tool and a CLI command.
- **Swift Service Lifecycle integration**: `MCPServer` conforms to the `Service` protocol. The only way to launch a server is through a `ServiceGroup`.
- **Compile-time guarantees**: Tool names are unique, types are preserved, and the `@MCPApplication` macro generates exhaustive dispatch.
- **Transport abstraction**: Built-in `StdioTransport` and `TCPTransport` with IPv4, IPv6, dual-stack, and Unix domain socket support.
- **Access control**: Per-tool access levels with IP-based resolution for TCP transports.
- **Async and sync tools**: Support both synchronous and asynchronous tool implementations.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ToolDefinition>
- <doc:ServerConfiguration>

### Macros

- <doc:MacroGuide>
- ``MCPCommand``
- ``MCPApplication``
- ``Argument``
- ``Option``
- ``Flag``
- ``OptionGroup``

### Core Protocols

- ``MCPTool``
- ``AsyncMCPTool``
- ``MCPTransport``
- ``MCPToolID``

### Server

- ``MCPServer``
- ``MCPToolBuilder``
- ``MCPRouter``

### Transports

- <doc:TransportDesign>
- ``StdioTransport``
- ``TCPTransport``
- ``ServerAddress``

### Access Control

- <doc:AccessControl>
- ``AccessLevel``
- ``MCPCallerInfo``

### Lifecycle

- <doc:LifecycleManagement>

### Architecture

- <doc:Architecture>
- <doc:MigrationGuide>

### Examples

- <doc:Examples>

### Supporting Types

- ``MCPContext``
- ``MCPToolConfiguration``
- ``MCPToolResult``
- ``MCPContent``
- ``MCPError``
- ``MCPParamKind``
- ``MCPParameterInfo``
- ``MCPParamProtocol``
- ``GroupParamProtocol``
- ``ToolAvailability``
- ``Tool``

### JSON Schema

- ``JSONSchemaBuilder``
