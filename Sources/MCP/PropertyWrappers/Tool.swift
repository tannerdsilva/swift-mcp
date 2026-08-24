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

/// Marks a property as an MCP tool for the ``MCPApplication`` macro.
///
/// Use this property wrapper on stored properties of a struct annotated with
/// ``MCPApplication``. The macro discovers all `@Tool` properties and
/// generates a `main()` function that registers each tool with the server.
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
/// Use the `available` parameter to conditionally include tools:
/// - ``ToolAvailability/always``: Always register (default).
/// - ``ToolAvailability/debug``: Only register in debug builds.
@propertyWrapper
public struct Tool<T: MCPTool> {
    /// The underlying tool value.
    public var wrappedValue: T

    /// When this tool is available for registration.
    public let available: ToolAvailability

    /// Creates a new tool wrapper that is always available.
    ///
    /// - Parameter wrappedValue: The tool instance.
    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
        self.available = .always
    }

    /// Creates a new tool wrapper with the given availability.
    ///
    /// - Parameters:
    ///   - wrappedValue: The tool instance.
    ///   - available: When the tool should be available.
    public init(wrappedValue: T, available: ToolAvailability) {
        self.wrappedValue = wrappedValue
        self.available = available
    }
}
