//===----------------------------------------------------------------------===//
//
// This source file is part of the MCP open source project
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - @Argument

/// A required parameter for a dual CLI/MCP command.
///
/// Use with the ``MCPCommand`` macro. Maps to `@Argument` in ArgumentParser.
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

    /// A human-readable description of this parameter.
    public let _paramDescription: String?

    /// The Swift type name as a string.
    public let _paramTypeName: String

    /// Whether this parameter is required. Always `true` for `@Argument`.
    public let _paramRequired: Bool = true

    /// The kind of parameter. Always `.argument`.
    let _paramKind: MCPParamKind = .argument

    /// Whether this parameter has a default value. Always `false` for `@Argument`.
    public let _paramHasDefault: Bool = false

    /// The allowed values for enum-typed parameters, or `nil` if unconstrained.
    public let _paramEnumValues: [String]?

    /// Creates a new required argument wrapper.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default/placeholder value. Ignored when the
    ///     argument is provided by the caller.
    ///   - description: A human-readable description of the parameter.
    ///   - enumValues: Allowed values for enum-typed parameters (e.g. `["debug", "info"]`).
    public init(wrappedValue: Value, description: String? = nil, enumValues: [String]? = nil) {
        self.wrappedValue = wrappedValue
        self._paramDescription = description
        self._paramTypeName = String(describing: Value.self)
        self._paramEnumValues = enumValues
    }

    /// Sets the wrapped value from an untyped JSON-decoded value.
    ///
    /// - Parameter value: The value to set.
    /// - Throws: ``MCPError/typeMismatch(expected:actual:)`` if the value
    ///   cannot be cast to the expected type.
    public mutating func _setValue(_ value: Any) throws {
        guard let typed = value as? Value else {
            throw MCPError.typeMismatch(
                expected: _paramTypeName,
                actual: String(describing: type(of: value))
            )
        }
        self.wrappedValue = typed
    }

    /// Returns the current wrapped value.
    public func _getValue() throws -> Any {
        self.wrappedValue
    }
}

// MARK: - @Option

/// An optional parameter with a default value for a dual CLI/MCP command.
///
/// Use with the ``MCPCommand`` macro. Maps to `@Option` in ArgumentParser.
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

    /// A human-readable description of this parameter.
    public let _paramDescription: String?

    /// The Swift type name as a string.
    public let _paramTypeName: String

    /// Whether this parameter is required. Always `false` for `@Option`.
    public let _paramRequired: Bool = false

    /// The kind of parameter. Always `.option`.
    let _paramKind: MCPParamKind = .option

    /// Whether this parameter has a default value. Always `true` for `@Option`.
    public let _paramHasDefault: Bool = true

    /// The allowed values for enum-typed parameters, or `nil` if unconstrained.
    public let _paramEnumValues: [String]?

    /// Creates a new optional argument wrapper with a default value.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default value when the parameter is not provided.
    ///   - description: A human-readable description of the parameter.
    ///   - enumValues: Allowed values for enum-typed parameters (e.g. `["debug", "info"]`).
    public init(wrappedValue: Value, description: String? = nil, enumValues: [String]? = nil) {
        self.wrappedValue = wrappedValue
        self._paramDescription = description
        self._paramTypeName = String(describing: Value.self)
        self._paramEnumValues = enumValues
    }

    /// Sets the wrapped value from an untyped JSON-decoded value.
    ///
    /// - Parameter value: The value to set.
    /// - Throws: ``MCPError/typeMismatch(expected:actual:)`` if the value
    ///   cannot be cast to the expected type.
    public mutating func _setValue(_ value: Any) throws {
        guard let typed = value as? Value else {
            throw MCPError.typeMismatch(
                expected: _paramTypeName,
                actual: String(describing: type(of: value))
            )
        }
        self.wrappedValue = typed
    }

    /// Returns the current wrapped value.
    public func _getValue() throws -> Any {
        self.wrappedValue
    }
}

// MARK: - @Flag

/// A boolean flag for a dual CLI/MCP command.
///
/// Use with the ``MCPCommand`` macro. Maps to `@Flag` in ArgumentParser.
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

    /// A human-readable description of this flag.
    public let _paramDescription: String?

    /// The Swift type name. Always `"Bool"`.
    public let _paramTypeName: String = "Bool"

    /// Whether this parameter is required. Always `false` for `@Flag`.
    public let _paramRequired: Bool = false

    /// The kind of parameter. Always `.flag`.
    let _paramKind: MCPParamKind = .flag

    /// Whether this parameter has a default value. Always `true` for `@Flag`.
    public let _paramHasDefault: Bool = true

    /// The allowed values for enum-typed parameters, or `nil` if unconstrained.
    public let _paramEnumValues: [String]?

    /// Creates a new flag wrapper.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default value (typically `false`).
    ///   - description: A human-readable description of the flag.
    ///   - enumValues: Allowed values for enum-typed parameters (e.g. `["debug", "info"]`).
    public init(wrappedValue: Bool = false, description: String? = nil, enumValues: [String]? = nil) {
        self.wrappedValue = wrappedValue
        self._paramDescription = description
        self._paramEnumValues = enumValues
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

    /// Returns the current wrapped value.
    public func _getValue() throws -> Any {
        self.wrappedValue
    }
}

// MARK: - @OptionGroup

/// A container that flattens a group of parameters into the parent command.
///
/// Use with the ``MCPCommand`` macro. Maps to `@OptionGroup` in ArgumentParser.
/// The group struct should use ``Argument``, ``Option``, and ``Flag`` wrappers
/// for its properties; they are flattened into the parent's parameter namespace.
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
/// parent's parameter namespace at runtime by both ArgumentParser and the
/// MCP framework.
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
