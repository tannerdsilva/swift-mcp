# Migration Guide

This guide covers upgrading between versions of swift-mcp.

## Upgrading to 1.0.0

### Breaking Changes

#### @Param Removed

The single `@Param` wrapper with `required:` parameter has been removed. Use the distinct wrappers instead:

```swift
// Before (removed)
@Param(description: "Name")
var name: String = ""

@Param(description: "Count", required: false)
var count: Int = 1

// After
@Argument(description: "Name")
var name: String = ""

@Option(description: "Count")
var count: Int = 1
```

**Rationale**: The 1:1 mapping between wrappers and their ArgumentParser/MCP counterparts provides clearer semantics and eliminates the mental translation of `required: false` → `@Option`.

#### Migration Steps

1. Replace `@Param` with `@Argument` (required parameters)
2. Replace `@Param(required: false)` with `@Option`
3. Replace `@Param(description: "x", required: false)` with `@Option(description: "x")`
4. No changes needed for `@Flag` — it remains the same

### New Features in 1.0.0

- **Option Groups**: `@OptionGroup` / `@OptionGroup` for sharing parameters across tools
- **GroupParamProtocol**: Protocol for container wrappers with recursive flattening
- **Full documentation**: Comprehensive doc comments on all public symbols
- **Documentation suite**: Getting started guide, tool definition guide, macro guide, architecture docs

### Deprecations

None.

## Upgrading from 0.x

If you were using an earlier version with `@MCPArgument`, `@MCPOption`, and `@MCPFlag` directly (without the macro), migrate to `@Argument`, `@Option`, and `@Flag` instead. The `MCP`-prefixed wrappers have been removed — use the unified property wrappers for both direct conformance and macro-based tools.
