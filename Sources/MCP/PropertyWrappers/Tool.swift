//===----------------------------------------------------------------------===//
//
// This source file is part of the MCP open source project
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// MARK: - Tool Property Wrapper

/// Marks a property as an MCP tool for the ``MCPApplication`` macro.
///
/// Use this property wrapper on stored properties of a struct annotated with
/// ``MCPApplication``. The macro discovers all `@Tool` properties and
/// generates the typed dispatch surface that serves them.
///
/// ```swift
/// @MCPApplication(name: "demo", version: "1.0.0")
/// struct MyApp {
///     @Tool var greet = Greet()
///     @Tool var calculate = Calculate()
///     @Tool(available: .debug) var debug = DebugTool()
/// }
/// ```
///
/// The `available` argument is **compile-time only**: ``MCPApplication``
/// matches `.debug` textually and guards that tool's enum case, dispatch
/// branch, catalog entry, and access gate with `#if DEBUG`, so a release build
/// neither lists nor invokes it. The value is not stored at runtime.
@propertyWrapper
public struct Tool<T: MCPTool> {
    /// The underlying tool value.
    public var wrappedValue: T

    /// Creates a new tool wrapper that is always available.
    ///
    /// - Parameter wrappedValue: The tool instance.
    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }

    /// Creates a new tool wrapper with the given availability.
    ///
    /// The availability is consumed at compile time by ``MCPApplication`` and
    /// is not stored at runtime.
    ///
    /// - Parameters:
    ///   - wrappedValue: The tool instance.
    ///   - available: When the tool should be available.
    public init(wrappedValue: T, available: ToolAvailability) {
        // Swift requires the argument to be accepted for `@Tool(available:)`
        // call sites; the macro reads the attribute textually and the value
        // carries no runtime state.
        _ = available
        self.wrappedValue = wrappedValue
    }
}

extension Tool: Sendable where T: MCPTool {
    // `wrappedValue` is `Sendable` (MCPTool requires it), so the wrapper is
    // unconditionally Sendable for its generic signature. This lets
    // @MCPApplication app structs (which hold @Tool properties and conform to
    // the Sendable MCPToolDispatcher) satisfy strict concurrency.
}
