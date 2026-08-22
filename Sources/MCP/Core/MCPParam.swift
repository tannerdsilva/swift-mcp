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

/// The kind of an MCP tool parameter.
///
/// This enum classifies parameters into three categories that mirror the
/// Swift Argument Parser's parameter types:
///
/// - ``argument``: A required positional or named parameter. The caller must
///   provide a value. Maps to `@Argument`.
/// - ``option``: An optional parameter with a default value. The caller can
///   omit it. Maps to `@Option`.
/// - ``flag``: A boolean flag that defaults to `false`. Maps to `@Flag`.
public enum MCPParamKind: String, Sendable, Equatable, Codable {
    /// A required positional/named parameter.
    case argument
    /// An optional parameter with a default value.
    case option
    /// A boolean flag parameter.
    case flag
}

/// Metadata describing a single parameter of an MCP tool.
///
/// ``MCPParameterInfo`` is produced by ``MCPTool/discoverParameters()`` and
/// describes each parameter that a tool expects. It includes the parameter's
/// name, type, whether it is required, and its kind (argument, option, or flag).
///
/// This information is used by JSONSchemaBuilder to generate JSON Schema
/// for the `tools/list` response, and by ``MCPTool/apply(arguments:)`` to
/// validate required arguments.
public struct MCPParameterInfo: Sendable, Equatable, Codable {
    /// The parameter name (e.g. "city", "count").
    ///
    /// This is derived from the property name by stripping the leading `_`
    /// from the property wrapper's backing storage name.
    public let name: String

    /// A human-readable description of the parameter.
    ///
    /// This value comes from the `description` parameter of the property wrapper.
    /// It is included in the JSON Schema for the tool.
    public let description: String?

    /// Whether this parameter is required.
    ///
    /// Required parameters must be provided by the caller. The framework throws
    /// ``MCPError/missingArgument(_:)`` if a required parameter is absent.
    public let required: Bool

    /// The kind of parameter.
    ///
    /// Determines how the parameter is presented in the JSON Schema and how
    /// it is handled during argument injection.
    public let kind: MCPParamKind

    /// The Swift type name (e.g. "String", "Int").
    ///
    /// This is used by ``JSONSchemaBuilder`` to map Swift types to JSON Schema
    /// types for the `inputSchema` field.
    public let typeName: String

    /// Whether the parameter has a default value.
    ///
    /// Parameters with defaults are optional. The default is used when the
    /// caller does not provide a value.
    public let hasDefault: Bool

    /// The allowed values for enum-typed parameters, or `nil` if the parameter
    /// is not constrained to specific values.
    ///
    /// When present, these values are included in the JSON Schema as an `enum`
    /// constraint, telling clients which values are accepted.
    public let enumValues: [String]?

    /// Creates a new parameter info value.
    ///
    /// - Parameters:
    ///   - name: The parameter name.
    ///   - description: A human-readable description.
    ///   - required: Whether the parameter is required.
    ///   - kind: The kind of parameter.
    ///   - typeName: The Swift type name.
    ///   - hasDefault: Whether the parameter has a default value.
    ///   - enumValues: Allowed values for enum-typed parameters, or `nil`.
    public init(
        name: String,
        description: String?,
        required: Bool,
        kind: MCPParamKind,
        typeName: String,
        hasDefault: Bool,
        enumValues: [String]? = nil
    ) {
        self.name = name
        self.description = description
        self.required = required
        self.kind = kind
        self.typeName = typeName
        self.hasDefault = hasDefault
        self.enumValues = enumValues
    }
}

// MARK: - MCPParamProtocol

/// Protocol that individual parameter property wrappers conform to.
///
/// ``MCPParamProtocol`` defines the interface the framework uses to interact
/// with tool parameters at runtime. All property wrappers (`@Argument`,
/// `@Option`, `@Flag`) conform to this protocol as value types.
///
/// Parameter metadata is emitted at compile time by the ``MCPCommand`` and
/// ``MCPOptionGroup`` macros via ``MCPTool/discoverParameters()``, so this
/// protocol only carries the runtime accessors for argument injection.
protocol MCPParamProtocol: Sendable {
    /// A human-readable description of this parameter.
    var _paramDescription: String? { get }

    /// The Swift type name as a string (e.g. "String", "Int").
    var _paramTypeName: String { get }

    /// Whether this parameter is required.
    var _paramRequired: Bool { get }

    /// The kind of parameter (argument, option, flag).
    var _paramKind: MCPParamKind { get }

    /// Whether this parameter has a default value.
    var _paramHasDefault: Bool { get }

    /// The allowed values for enum-typed parameters, or `nil` if unconstrained.
    var _paramEnumValues: [String]? { get }

    /// Set the wrapped value from an untyped JSON-decoded value.
    ///
    /// - Parameter value: The value to set, as decoded from JSON.
    /// - Throws: ``MCPError/typeMismatch(expected:actual:)`` if the value
    ///   cannot be converted to the expected type.
    mutating func _setValue(_ value: Any) throws

    /// Get the current wrapped value as an `Any` for JSON encoding.
    ///
    /// - Returns: The current value of the wrapped property.
    func _getValue() throws -> Any
}

// MARK: - MCPToolID

/// A protocol for compile-time unique tool identifiers.
///
/// Conforming types must be `String`-backed enums. The ``MCPApplication``
/// macro generates a ``MCPToolID``-conforming enum with one case per
/// ``Tool`` property, providing compile-time unique tool names and
/// exhaustive dispatch.
///
/// ```swift
/// enum MyToolID: String, MCPToolID {
///     case greet
///     case calculate
/// }
/// ```
public protocol MCPToolID: RawRepresentable<String>, Hashable, Sendable, CaseIterable {}

// MARK: - ToolAvailability

/// Controls when a tool is available for registration.
///
/// Used with the ``Tool`` property wrapper's `available` parameter to
/// conditionally include tools in the server.
///
/// ```swift
/// @Tool(available: .debug) var debug = DebugTool()
/// ```
public enum ToolAvailability: Sendable {
    /// The tool is always available (default).
    case always
    /// The tool is only available in debug builds.
    case debug
}

// MARK: - AccessLevel

/// The access level required to invoke a tool.
///
/// Access levels are ordered: higher levels include lower ones.
/// The server compares the caller's access level against the tool's
/// required access level to determine if the caller may invoke the tool.
///
/// ```swift
/// struct AdminTool: MCPTool {
///     static let configuration = MCPToolConfiguration(
///         description: "Sensitive operation",
///         requiredAccess: .admin
///     )
/// }
/// ```
public enum AccessLevel: Int, Sendable, Comparable, Codable {
    /// Visible to all callers. No authentication needed.
    case `public` = 0
    /// Visible to authenticated or internal network callers.
    case authenticated = 1
    /// Visible only to administrators.
    case admin = 2
    /// Visible only to the local process (stdio transport).
    case root = 3

    public static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - MCPCallerInfo

/// Information about the caller invoking a tool.
///
/// The transport provides caller information when processing requests.
/// The server uses this information to filter tools in `tools/list`
/// and enforce access control in `tools/call`.
///
/// For stdio transport, the caller is always `.root` with source "stdio".
/// For TCP transport, the caller's access level is resolved from the
/// source IP address.
public struct MCPCallerInfo: Sendable {
    /// The source address (e.g. "127.0.0.1:54321" for TCP, "stdio" for stdio).
    public let sourceAddress: String?

    /// The resolved access level for this caller.
    public let accessLevel: AccessLevel

    /// Creates new caller info.
    ///
    /// - Parameters:
    ///   - sourceAddress: The source address of the caller.
    ///   - accessLevel: The resolved access level.
    public init(sourceAddress: String?, accessLevel: AccessLevel) {
        self.sourceAddress = sourceAddress
        self.accessLevel = accessLevel
    }
}

// MARK: - StaticMCPGroup

/// Protocol for macro-generated option-group metadata.
///
/// Conforming types are option-group structs annotated with ``MCPOptionGroup``.
/// The macro synthesizes static parameter metadata and an argument-apply
/// method so the parent ``MCPTool`` conformance can flatten groups at compile
/// time without reflection.
public protocol StaticMCPGroup: Sendable {
    /// The flattened parameter metadata for this group.
    static var mcpParameters: [MCPParameterInfo] { get }

    /// Apply a set of arguments to the group's parameters.
    ///
    /// - Parameter arguments: A dictionary of argument names to values.
    /// - Throws: ``MCPError/typeMismatch(expected:actual:)`` if a value cannot
    ///   be converted to the expected type.
    mutating func mcpApply(arguments: [String: Any]) throws
}
