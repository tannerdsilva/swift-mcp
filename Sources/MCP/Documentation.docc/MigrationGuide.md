# Migration Guide

How to migrate from earlier versions of swift-mcp.

## Overview

This guide covers breaking changes between versions and how to update your code.

## Upgrading to 1.2.0

### Tool-Creation and Codegen Changes

- ``MCPCommand`` now rejects **multiple** member `run()` overloads with a
  diagnostic. Non-throwing `run()` methods no longer generate an unconditional
  `try`, a `Void` `run()` produces an empty text block instead of `"()"` —
  both macros now agree — and a `run()` provided by an **extension** of the
  struct still works (the macro falls back to a plain call).
- ``FuncTool`` supports **any return type** (rendered via `String(describing:)`),
  `Void` returns produce an empty text block, and `_`-labeled, `inout`, and
  variadic parameters are rejected with diagnostics. The wrapped function must
  be `static` and nested in a type (the global-scope case was never compilable).
- Property wrappers decode **custom `Codable & Sendable` parameter types**
  (enums, structs, optionals), so a JSON object now injects into a `Codable`
  struct parameter instead of failing with a type mismatch.

### Server Behavior Changes

- ``MCPServer/runService()`` returns normally when the transport completes
  (client EOF on stdio). Previously the process crashed with
  `ServiceGroupError: A service has finished unexpectedly`. Hosts embedding
  ``MCPServer`` in their own ``ServiceGroup`` now choose the
  `successTerminationBehavior` (`cancelGroup`, `gracefullyShutdownGroup`, or
  `ignore`).
- ``MCPServer/unregister(_:)`` also removes instance-registered tools, and
  instance-registered tools are access-filtered and enforced exactly like
  type-registered ones.
- `MCPContent.resource` encodes the spec's nested `EmbeddedResource` shape
  (`{"type":"resource","resource":{...}}`) instead of the old flat shape.
- ``TCPTransport/defaultAccessResolver(_:)`` (the default resolver) matches the
  NIO address format including the scheme prefix, so IPv4 and IPv6 loopback
  callers resolve to ``AccessLevel/admin``.

## Upgrading to 1.1.0

### Dual-Use CLI Code Generation Removed

Earlier versions of ``MCPCommand`` generated a nested `CLI` struct conforming
to `AsyncParsableCommand` behind an `#if canImport(ArgumentParser)` guard.
That path was dropped because the generated code could never compile: the MCP
wrapper names collide with ArgumentParser's, and the MCP library does not
depend on ArgumentParser.

**What changed**: ``MCPCommand`` now generates only the ``MCPTool``
conformance. Remove any `import ArgumentParser` and references to
`YourType.CLI`.

**If you need a CLI**: declare the command's argument surface as its own
`AsyncParsableCommand` struct and share the underlying logic with your
``MCPTool`` implementation — the MCP wrappers and ArgumentParser wrappers are
independent types and are not interchangeable.

### Everything Else Unchanged

All other APIs from 1.0.0 are unchanged in 1.1.0.

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

### AsyncMCPTool Removed

The ``AsyncMCPTool`` marker protocol (introduced in an earlier release) has
been removed — it carried no requirements and had no framework consumer, and
``MCPCommand`` detects `async` from `run()`. Tools that previously conformed
to it should conform to ``MCPTool`` directly.

## Related Articles

- <doc:GettingStarted>
- <doc:ToolDefinition>
- <doc:ServerConfiguration>
