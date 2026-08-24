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

import Foundation

// MARK: - @Argument

/// A required parameter for an MCP tool.
///
/// Use with the ``MCPCommand`` macro or in a type that conforms directly
/// to ``MCPTool``.
///
/// Parameters marked with `@Argument` are required and must be provided by
/// the caller. The initial value is a placeholder and is ignored when the
/// argument is provided.
///
/// ```swift
/// @MCPCommand(description: "Greet someone")
/// struct Greet {
///     @Argument(description: "The person to greet")
///     var name: String = ""
/// }
/// ```
///
/// - Warning: This wrapper is a value type whose mutable state is a normal
///   stored property; mutating methods follow value semantics. Each tool
///   instance is used in a create → apply → invoke → discard pattern.
@propertyWrapper
public struct Argument<Value: Codable & Sendable>: MCPParamProtocol {

    /// The underlying wrapped value.
    public var wrappedValue: Value

    /// Creates a new required argument wrapper.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default/placeholder value. Ignored when the
    ///     argument is provided by the caller.
    ///   - description: A human-readable description of the parameter
    ///     (consumed at compile time by the macro for schema generation).
    ///   - enumValues: Allowed values for enum-typed parameters (e.g. `["debug", "info"]`),
    ///     consumed at compile time by the macro.
    public init(wrappedValue: Value, description: String? = nil, enumValues: [String]? = nil) {
        self.wrappedValue = wrappedValue
    }

    /// Sets the wrapped value from an untyped JSON-decoded value.
    ///
    /// - Parameter value: The value to set.
    /// - Throws: ``MCPError/typeMismatch(expected:actual:)`` if the value
    ///   cannot be cast to the expected type.
    public mutating func _setValue(_ value: Any) throws {
        guard let typed = value as? Value else {
            throw MCPError.typeMismatch(
                expected: String(describing: Value.self),
                actual: String(describing: type(of: value))
            )
        }
        self.wrappedValue = typed
    }
}

// MARK: - @Option

/// An optional parameter with a default value for an MCP tool.
///
/// Use with the ``MCPCommand`` macro or in a type that conforms directly
/// to ``MCPTool``.
///
/// Parameters marked with `@Option` are optional. The initial value is used
/// as the default when the caller does not provide a value.
///
/// ```swift
/// @MCPCommand(description: "Greet someone")
/// struct Greet {
///     @Option(description: "Number of times")
///     var count: Int = 1
/// }
/// ```
///
/// - Warning: This wrapper is a value type whose mutable state is a normal
///   stored property; mutating methods follow value semantics. Each tool
///   instance is used in a create → apply → invoke → discard pattern.
@propertyWrapper
public struct Option<Value: Codable & Sendable>: MCPParamProtocol {

    /// The underlying wrapped value.
    public var wrappedValue: Value

    /// Creates a new optional argument wrapper with a default value.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default value when the parameter is not provided.
    ///   - description: A human-readable description of the parameter
    ///     (consumed at compile time by the macro for schema generation).
    ///   - enumValues: Allowed values for enum-typed parameters (e.g. `["debug", "info"]`),
    ///     consumed at compile time by the macro.
    public init(wrappedValue: Value, description: String? = nil, enumValues: [String]? = nil) {
        self.wrappedValue = wrappedValue
    }

    /// Sets the wrapped value from an untyped JSON-decoded value.
    ///
    /// - Parameter value: The value to set.
    /// - Throws: ``MCPError/typeMismatch(expected:actual:)`` if the value
    ///   cannot be cast to the expected type.
    public mutating func _setValue(_ value: Any) throws {
        guard let typed = value as? Value else {
            throw MCPError.typeMismatch(
                expected: String(describing: Value.self),
                actual: String(describing: type(of: value))
            )
        }
        self.wrappedValue = typed
    }
}

// MARK: - @Flag

/// A boolean flag for an MCP tool.
///
/// Use with the ``MCPCommand`` macro or in a type that conforms directly
/// to ``MCPTool``.
///
/// Flags are boolean parameters that default to `false`. They are set to
/// `true` when the flag is present in the caller's arguments.
///
/// ```swift
/// @MCPCommand(description: "Greet someone")
/// struct Greet {
///     @Flag(description: "Use a formal greeting")
///     var formal: Bool = false
/// }
/// ```
///
/// - Warning: This wrapper is a value type whose mutable state is a normal
///   stored property; mutating methods follow value semantics. Each tool
///   instance is used in a create → apply → invoke → discard pattern.
@propertyWrapper
public struct Flag: MCPParamProtocol {

    /// The underlying wrapped boolean value.
    public var wrappedValue: Bool

    /// Creates a new flag wrapper.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default value (typically `false`).
    ///   - description: A human-readable description of the flag
    ///     (consumed at compile time by the macro for schema generation).
    ///   - enumValues: Allowed values for enum-typed parameters (e.g. `["debug", "info"]`),
    ///     consumed at compile time by the macro.
    public init(wrappedValue: Bool = false, description: String? = nil, enumValues: [String]? = nil) {
        self.wrappedValue = wrappedValue
    }

    /// Sets the wrapped value from an untyped value.
    ///
    /// Accepts `Bool`, `Int` (nonzero is `true`), or `String`
    /// ("true"/"yes"/"1" are `true`, "false"/"no"/"0" are `false`).
    ///
    /// - Parameter value: The value to set.
    /// - Throws: ``MCPError/typeMismatch(expected:actual:)`` if the value
    ///   cannot be converted to a boolean.
    public mutating func _setValue(_ value: Any) throws {
        if let bool = value as? Bool {
            self.wrappedValue = bool
        } else if let int = value as? Int {
            self.wrappedValue = int != 0
        } else if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": self.wrappedValue = true
            case "false", "no", "0": self.wrappedValue = false
            default:
                throw MCPError.typeMismatch(
                    expected: "Bool",
                    actual: String(describing: type(of: value))
                )
            }
        } else {
            throw MCPError.typeMismatch(
                expected: "Bool",
                actual: String(describing: type(of: value))
            )
        }
    }
}

// MARK: - @OptionGroup

/// A container that flattens a group of parameters into the parent tool.
///
/// Use with the ``MCPCommand`` macro or in a type that conforms directly
/// to ``MCPTool``. The group struct should use ``Argument``, ``Option``, and
/// ``Flag`` wrappers for its properties; they are flattened into the parent's
/// parameter namespace.
///
/// ```swift
/// struct SharedOptions {
///     @Option(description: "Verbose output")
///     var verbose: Bool = false
///
///     @Option(description: "Output path")
///     var outputPath: String = "."
/// }
///
/// @MCPCommand(description: "My command")
/// struct MyCommand {
///     @OptionGroup var shared: SharedOptions
///
///     func run() async throws -> String { ... }
/// }
/// ```
///
/// The group's parameters (`verbose`, `outputPath`) are flattened into the
/// parent's parameter namespace at compile time by the ``MCPCommand`` macro.
///
/// - Warning: This wrapper is a value type whose mutable state is a normal
///   stored property; mutating methods follow value semantics. Each tool
///   instance is used in a create → apply → invoke → discard pattern.
@propertyWrapper
public struct OptionGroup<Value: StaticMCPGroup>: Sendable {

    /// The underlying wrapped group struct.
    public var wrappedValue: Value

    /// Creates a new option group wrapper.
    ///
    /// - Parameter wrappedValue: The group struct instance.
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    /// Applies arguments to the group's sub-parameters.
    ///
    /// Forwards to the macro-generated ``StaticMCPGroup/mcpApply(arguments:)``
    /// implementation synthesized by ``MCPOptionGroup``.
    ///
    /// - Parameter arguments: A dictionary of argument names to values.
    public mutating func mcpApply(arguments: [String: Any]) throws {
        try wrappedValue.mcpApply(arguments: arguments)
    }
}
