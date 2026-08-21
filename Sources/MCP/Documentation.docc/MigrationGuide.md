# Migration Guide

How to migrate from earlier versions of swift-mcp.

## Overview

This guide covers breaking changes between versions and how to update your code.

## Migrating to 1.0.0

### @Param Replaced by @Argument, @Option, @Flag

The umbrella ``@Param`` wrapper has been replaced by three separate wrappers with clearer semantics.

**Before:**
```swift
@Param(description: "Name")
var name: String

@Param(description: "Count", required: false)
var count: Int = 1
```

**After:**
```swift
@Argument(description: "Name")
var name: String

@Option(description: "Count")
var count: Int = 1
```

### invoke() Is Now mutating

The ``MCPTool/invoke(context:)`` method is now ``mutating``. If you conform directly to ``MCPTool``, update your implementation.

**Before:**
```swift
func invoke(context: MCPContext) async throws -> MCPToolResult {
    .text("Hello")
}
```

**After:**
```swift
mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
    .text("Hello")
}
```

### MCPContext Now Has callerInfo

The ``MCPContext`` struct now includes an optional ``callerInfo`` property. If you create contexts manually, update your initializer calls.

**Before:**
```swift
let context = MCPContext(arguments: args)
```

**After:**
```swift
let context = MCPContext(arguments: args)  // callerInfo defaults to nil
let context = MCPContext(arguments: args, callerInfo: caller)  // explicit
```

### MCPToolConfiguration Now Has requiredAccess

The ``MCPToolConfiguration`` struct now includes a ``requiredAccess`` property that defaults to ``.public``. Existing code that creates configurations without this parameter continues to work.

### MCPTransport Handler Signature Changed

The ``MCPTransport/start(handler:)`` handler now receives ``MCPCallerInfo`` in addition to data.

**Before:**
```swift
func start(handler: @Sendable @escaping (Data) async throws -> Data?) async throws
```

**After:**
```swift
func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws
```

If you have a custom transport, update the handler signature and pass caller information.

### Server Now Uses Service Lifecycle

``MCPServer`` now conforms to the ``Service`` protocol and must be run via a ``ServiceGroup``.

**Before:**
```swift
try await server.run()
```

**After:**
```swift
try await server.runService()
// or
let group = ServiceGroup(configuration: .init(services: [server]))
try await group.run()
```

### AsyncMCPTool Protocol Added

A new ``AsyncMCPTool`` marker protocol is available for tools that perform async work. This is optional — the ``MCPCommand`` macro detects async automatically.

## Related Articles

- <doc:GettingStarted>
- <doc:ToolDefinition>
- <doc:ServerConfiguration>
