# `MCP`

Build and consume MCP (Model Context Protocol) in Swift with a declarative,
macro-driven API.

## Overview

swift-mcp is a Swift framework for the MCP protocol, playing **both roles** on
the wire: it serves tools and consumes them as a client.

- **Macro-based tool definition**: use `MCPCommand` or `FuncTool` to define
  tools with `@Argument`, `@Option`, `@Flag`, and `@OptionGroup` wrappers.
- **Swift Service Lifecycle integration**: ``MCPServer`` and
  ``MCPClientService`` conform to the `Service` protocol. The only way to
  launch a long-lived process is through a `ServiceGroup`.
- **Compile-time guarantees**: parameters are discovered and argument
  injection is generated at compile time; the `MCPApplication` macro
  generates an exhaustive, type-preserving dispatch through a `ToolID` enum.
- **One NIO pipeline, many carriers**: a single frame codec and routing core
  serve server stdio, server TCP, and the client carriers — so server and
  client cannot drift. Network-free MCP (``LocalClientTransport``) drives the
  same router with zero bytes.
- **A full client role**: ``MCPClient`` consumes tools over a spawned
  subprocess (``SubprocessClientTransport`` — MCP-by-subprocess), over TCP
  (``TCPClientTransport``), or in-process, with per-call deadlines and
  protocol-version negotiation.
- **One-shot stdin tools**: `interface: .oneShot` on `@MCPApplication`
  compiles a tool binary that speaks the harness plugin envelope and JSON-RPC,
  serves its own catalog and manifests — and is as easy to declare as an argv
  CLI. One binary can expose a whole *pack* of tools. See <doc:StdinTools> and
  <doc:ToolPacks>.
- **Transport abstraction**: ``MCPTransport`` (server role) and
  ``ClientTransport`` (client role) with IPv4, IPv6, dual-stack, and Unix
  domain socket support.
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

### Core Protocols

- ``MCPTool``
- ``MCPTransport``
- ``ClientTransport``
- ``MCPToolID``
- ``MCPToolDispatcher``

### Server

- ``MCPServer``
- ``MCPToolBuilder``

### Client

- <doc:MCPClientRole>
- <doc:MCPBySubprocess>
- ``MCPClient``
- ``MCPClientService``
- ``MCPClientError``
- ``ClientFrameSequence``
- ``SubprocessClientTransport``
- ``TCPClientTransport``
- ``LocalClientTransport``
- ``RemoteToolDescriptor``

### Transports

- <doc:TransportDesign>
- ``StdioTransport``
- ``TCPTransport``
- ``ServerAddress``

### One-Shot Tools

- <doc:StdinTools>
- <doc:ToolPacks>
- ``MCPInterface``
- ``MCPStdinHost``
- ``MCPStdinDialect``
- ``MCPPluginDialect``
- ``MCPJSONRPCDialect``
- ``MCPToolCatalog``
- ``MCPToolManifestFormat``
- ``MCPManifestContext``
- ``ArcPluginManifest``

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
- ``Argument``
- ``Option``
- ``Flag``
- ``OptionGroup``
