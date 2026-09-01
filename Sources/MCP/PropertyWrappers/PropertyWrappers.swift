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
        if let typed = coercedValue(value, to: Value.self) {
            self.wrappedValue = typed
        } else if let decoded = decodeCodableValue(value, as: Value.self) {
            self.wrappedValue = decoded
        } else {
            throw MCPError.typeMismatch(
                expected: String(describing: Value.self),
                actual: String(describing: type(of: value))
            )
        }
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
        if let typed = coercedValue(value, to: Value.self) {
            self.wrappedValue = typed
        } else if let decoded = decodeCodableValue(value, as: Value.self) {
            self.wrappedValue = decoded
        } else {
            throw MCPError.typeMismatch(
                expected: String(describing: Value.self),
                actual: String(describing: type(of: value))
            )
        }
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

// MARK: - Numeric coercion

/// Casts a JSON-decoded value to the wrapper's target type, preserving the
/// cross-numeric behavior of NSNumber bridging.
///
/// The typed JSON-RPC decode path produces either `Int` or `Double` for JSON
/// numbers. Without this, an integer JSON value would no longer satisfy a
/// `Double` parameter (or a fixed-width one) — a silent behavioral regression
/// versus the previous JSONSerialization path, where `NSNumber` bridged to any
/// numeric type.
private func coercedValue<Value>(_ value: Any, to target: Value.Type) -> Value? {
    if let direct = value as? Value {
        return direct
    }

    switch target {
    case is Double.Type:
        if let integer = value as? Int { return Double(integer) as? Value }
        if let unsigned = value as? UInt { return Double(unsigned) as? Value }
        if let float = value as? Float { return Double(float) as? Value }
        return nil

    case is Float.Type:
        if let integer = value as? Int { return Float(integer) as? Value }
        if let unsigned = value as? UInt { return Float(unsigned) as? Value }
        if let double = value as? Double { return Float(double) as? Value }
        return nil

    case is Int.Type:
        if let unsigned = value as? UInt, unsigned <= UInt(Int.max) { return Int(unsigned) as? Value }
        if let double = value as? Double, double.isFinite, double.rounded() == double {
            return Int(exactly: double) as? Value
        }
        return nil

    case is UInt.Type:
        if let integer = value as? Int, integer >= 0 { return UInt(integer) as? Value }
        if let double = value as? Double, double.isFinite, double >= 0, double.rounded() == double {
            return UInt(exactly: double) as? Value
        }
        return nil

    case is Int8.Type:
        return (integerCoercion(value, Int8.self) ?? floatingPointWholeCoercion(value, Int8.self)) as? Value

    case is Int16.Type:
        return (integerCoercion(value, Int16.self) ?? floatingPointWholeCoercion(value, Int16.self)) as? Value

    case is Int32.Type:
        return (integerCoercion(value, Int32.self) ?? floatingPointWholeCoercion(value, Int32.self)) as? Value

    case is UInt8.Type:
        return (unsignedIntegerCoercion(value, UInt8.self) ?? floatingPointWholeCoercion(value, UInt8.self)) as? Value

    case is UInt16.Type:
        return (unsignedIntegerCoercion(value, UInt16.self) ?? floatingPointWholeCoercion(value, UInt16.self)) as? Value

    case is UInt32.Type:
        return (unsignedIntegerCoercion(value, UInt32.self) ?? floatingPointWholeCoercion(value, UInt32.self)) as? Value

    default:
        return nil
    }
}

/// Coerces an integer JSON value to a fixed-width signed integer type.
private func integerCoercion<I: BinaryInteger & FixedWidthInteger>(_ value: Any, _ type: I.Type) -> I? {
    if let integer = value as? Int {
        return I(exactly: integer)
    }
    if let unsigned = value as? UInt, unsigned <= UInt(I.max) {
        return I(exactly: unsigned)
    }
    return nil
}

/// Coerces an unsigned integer JSON value to a fixed-width unsigned integer type.
private func unsignedIntegerCoercion<U: BinaryInteger & FixedWidthInteger>(_ value: Any, _ type: U.Type) -> U? {
    if let integer = value as? Int, integer >= 0 {
        return U(exactly: integer)
    }
    if let unsigned = value as? UInt {
        return U(exactly: unsigned)
    }
    return nil
}

/// Coerces a whole floating-point JSON value to a fixed-width integer type.
private func floatingPointWholeCoercion<I: BinaryInteger & FixedWidthInteger>(_ value: Any, _ type: I.Type) -> I? {
    if let double = value as? Double, double.isFinite, double.rounded() == double {
        return I(exactly: double)
    }
    return nil
}

/// Decodes a JSON-compatible `Any` value into a concrete `Codable` type.
///
/// The typed JSON-RPC decode path materializes JSON as plain Swift values
/// (`String`/`Int`/`Double`/`Bool`/`JSONNull` and trees of them), so custom
/// `Codable & Sendable` parameter types — enums, structs, optionals — are
/// decoded by round-tripping that tree through `JSONEncoder`/`JSONDecoder`.
private func decodeCodableValue<Value: Decodable>(_ value: Any, as type: Value.Type) -> Value? {
    // The null marker cannot be serialized by JSONSerialization (only
    // Foundation's NSNull can), so route it straight to JSON `null`: decoding
    // `null` succeeds for Optional<W> parameters (setting nil) and fails for
    // non-optional ones (yielding a type mismatch).
    if value is JSONNull {
        return try? JSONDecoder().decode(type, from: Data("null".utf8))
    }
    // `.fragmentsAllowed` so bare scalars (e.g. a String for an enum-typed or
    // Optional<Scalar> parameter) serialize as fragments, not just dictionaries.
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
