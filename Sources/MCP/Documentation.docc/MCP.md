# ``MCP``

Build MCP (Model Context Protocol) servers in Swift with a declarative,
macro-driven API.

## Overview

swift-mcp is a Swift framework for building MCP servers. It provides:

- **Macro-based tool definition**: use ``MCPCommand`` or ``FuncTool`` to define
  tools with `@Argument`, `@Option`, `@Flag`, and `@OptionGroup` wrappers.
- **Swift Service Lifecycle integration**: ``MCPServer`` conforms to the
  `Service` protocol. The only way to launch a server is through a
  ``ServiceGroup``.
- **Compile-time guarantees**: parameters are discovered and argument
  injection is generated at compile time; the ``MCPApplication`` macro
  generates an exhaustive, type-preserving dispatch through a `ToolID` enum.
- **Transport abstraction**: built-in ``StdioTransport`` and ``TCPTransport``
  with IPv4, IPv6, dual-stack, and Unix domain socket support.
- **Access control**: per-tool access levels with IP-based resolution for TCP
  transports.
- **Async and sync tools**: support both synchronous and asynchronous tool
  implementations.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ToolDefinition>
- <doc:ServerConfiguration>
- <doc:OptionGroups>

### Macros

- <doc:MacroGuide>
- ``MCPCommand``
- ``MCPApplication``
- ``FuncTool``
- ``MCPOptionGroup``
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

### Protocol

- <doc:MCPProtocol>

### Architecture

- <doc:Architecture>
- <doc:MigrationGuide>

### Examples

- <doc:Examples>
- <doc:BasicTools>
- <doc:AdvancedTools>
- <doc:IntegrationPatterns>
- <doc:RealWorldScenarios>
- <doc:ExampleServerConfiguration>

### Supporting Types

- ``MCPContext``
- ``MCPToolConfiguration``
- ``MCPToolResult``
- ``MCPContent``
- ``MCPError``
- ``MCPParamKind``
- ``MCPParameterInfo``
- ``StaticMCPGroup``
- ``ToolAvailability``
- ``Tool``

### JSON Schema

- ``JSONSchemaBuilder``
