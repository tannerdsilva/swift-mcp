# Architecture

The design philosophy, layering, and key architectural decisions behind swift-mcp.

## Overview

swift-mcp follows a layered architecture inspired by Swift Argument Parser and Hummingbird. Each layer builds on the one below it, with clear separation of concerns.

## Layers

### Layer 0: Core Protocols

The foundation of the framework. ``MCPTool`` defines the interface every tool must conform to. ``MCPTransport`` abstracts the communication channel. ``MCPError`` provides structured error handling.

```
MCPTool          — Tool interface (invoke, apply, configuration)
MCPTransport     — Communication channel (start, stop)
MCPError         — Structured errors
MCPContext       — Invocation context (arguments, caller info)
```

### Layer 1: Property Wrappers

Dual-use property wrappers that work with both Swift Argument Parser and the MCP framework. Each wrapper stores its metadata and provides it to both systems.

```
@Argument  → @Argument  (required positional parameter)
@Option    → @Option    (optional named parameter with default)
@Flag      → @Flag      (boolean flag, defaults to false)
@OptionGroup → @OptionGroup (nested parameter group)
```

### Layer 2: Macro System

The ``MCPCommand`` macro reads property wrapper annotations and generates:

- ``MCPTool`` conformance with ``invoke(context:)`` that calls the user's ``run()``
- An optional ``AsyncParsableCommand``-conforming CLI struct
- ``MCPToolConfiguration`` with metadata and access level

The ``MCPApplication`` macro generates:

- A ``MCPToolID`` enum for compile-time unique tool names
- Exhaustive switch dispatch preserving concrete tool types
- A ``main()`` entry point with ``ServiceGroup``

### Layer 3: Server

``MCPServer`` ties everything together:

- Accepts tool registrations
- Manages transport I/O
- Routes JSON-RPC messages
- Filters tools by access level
- Conforms to the ``Service`` protocol for lifecycle management

### Layer 4: Application

The user's application code. Uses macros to define tools, creates a server, and runs it via ``ServiceGroup``.

## Data Flow

```
JSON-RPC Request
  → Transport (reads bytes, resolves caller info)
    → Server.handleMessage (routes by method)
      → tools/list: filter by access level, build schema
      → tools/call: check access, create tool, apply args, invoke
        → MCPTool.invoke(context:)
          → User's run() method
    ← Response (or error)
  ← Transport (writes bytes)
```

## Key Design Decisions

### Why Service Lifecycle?

Swift Service Lifecycle provides signal-based graceful shutdown, service dependency ordering, and structured concurrency. By making ``MCPServer`` conform to ``Service``, we get all of this for free. There is no other way to launch the server.

### Why Separate Argument/Option/Flag?

Separate wrappers provide clearer semantics than a single ``@Param`` wrapper. Each wrapper has a distinct behavior:

- ``@Argument`` — required, positional, must be provided by the caller
- ``@Option`` — optional, named, has a default value
- ``@Flag`` — boolean, toggles a feature on/off

This 1:1 mapping with ArgumentParser makes the dual-use design transparent.

### Why Access Levels on Tools?

Access control is a first-class concern for MCP servers that operate on a network. By making ``requiredAccess`` a property of ``MCPToolConfiguration``, every tool declares its security requirements at the point of definition. The server enforces them automatically.

### Why No Dynamic Tool Loading?

Compile-time guarantees are prioritized over runtime flexibility. The ``MCPApplication`` macro generates exhaustive dispatch with concrete types — no ``any MCPTool`` erasure. Dynamic loading is possible via ``DynamicMCPServer`` for the rare cases that need it.

## Related Articles

- <doc:TransportDesign>
- <doc:MacroGuide>
- <doc:LifecycleManagement>
- <doc:AccessControl>
