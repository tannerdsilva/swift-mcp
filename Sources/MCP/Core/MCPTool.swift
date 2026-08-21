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
import Logging

private let paramDiscoveryLogger = Logger(label: "MCP.ParameterDiscovery")

// MARK: - MCPTool

/// A type that represents an MCP tool.
///
/// Conform your tool type to ``MCPTool`` and declare its parameters using the
/// ``Argument``, ``Option``, and ``Flag`` property wrappers, or use the
/// ``MCPCommand`` macro for automatic conformance generation.
///
/// ## Direct Conformance
///
/// ```swift
/// struct GetWeather: MCPTool {
///     static let configuration = MCPToolConfiguration(
///         description: "Get the current weather for a location"
///     )
///
///     @Argument(description: "The city name")
///     var city: String = ""
///
///     func invoke(context: MCPContext) async throws -> MCPToolResult {
///         .text("The weather in \(city) is sunny and 22°C")
///     }
/// }
/// ```
///
/// ## Macro-Based Conformance
///
/// ```swift
/// @MCPCommand(description: "Get the current weather")
/// struct GetWeather {
///     @Argument(description: "The city name")
///     var city: String = ""
///
///     // Can be sync or async — the macro detects which
///     func run() throws -> String {
///         "The weather in \(city) is sunny"
///     }
/// }
/// ```
public protocol MCPTool: Sendable {
    /// Configuration metadata for this tool.
    static var configuration: MCPToolConfiguration { get }

    /// Creates a new instance of the tool with default parameter values.
    init()

    /// Applies the given arguments to the tool's parameters.
    mutating func apply(arguments: [String: Any]) throws

    /// Invoke the tool's logic.
    ///
    /// Before this method is called, the framework sets the tool's property
    /// wrapper values to those provided by the caller via ``apply(arguments:)``.
    /// Access them directly within your implementation.
    ///
    /// - Parameter context: Contextual information about the invocation.
    /// - Returns: The result of the tool invocation.
    mutating func invoke(context: MCPContext) async throws -> MCPToolResult
}

// MARK: - AsyncMCPTool

/// A marker protocol for tools that perform asynchronous work.
///
/// Conform to this protocol to indicate that your tool performs async
/// operations. The framework can use this information for scheduling
/// and resource management.
///
/// When using the ``MCPCommand`` macro, the macro automatically detects
/// whether your ``run()`` method is async or sync and generates the
/// appropriate ``MCPTool/invoke(context:)`` implementation. You do not
/// need to conform to ``AsyncMCPTool`` explicitly when using the macro.
///
/// ```swift
/// struct FetchWeather: AsyncMCPTool {
///     static let configuration = MCPToolConfiguration(...)
///
///     @Argument(description: "The city name")
///     var city: String = ""
///
///     func invoke(context: MCPContext) async throws -> MCPToolResult {
///         let data = try await URLSession.shared.data(from: url)
///         return .text(String(decoding: data, as: UTF8.self))
///     }
/// }
/// ```
public protocol AsyncMCPTool: MCPTool {}

// MARK: - Default configuration

extension MCPTool {
    /// The default tool configuration.
    public static var configuration: MCPToolConfiguration {
        MCPToolConfiguration(description: "")
    }
}

// MARK: - Tool name derivation

extension MCPTool {
    /// The name of this tool, derived from the configuration or the type name.
    public static var toolName: String {
        if let explicitName = configuration.name {
            return explicitName
        }
        return Self._deriveName(from: String(describing: Self.self))
    }

    /// Converts a PascalCase type name to camelCase.
    private static func _deriveName(from typeName: String) -> String {
        guard let first = typeName.first else { return typeName.lowercased() }
        return first.lowercased() + typeName.dropFirst()
    }
}

// MARK: - Parameter discovery

extension MCPTool {
    /// Discovers the parameters of this tool by reflecting on an instance.
    static func discoverParameters() -> [MCPParameterInfo] {
        let instance = Self()
        return _discoverParameters(from: instance)
    }

    /// Applies the given arguments to the tool's parameters.
    public mutating func apply(arguments: [String: Any]) throws {
        let mirror = Mirror(reflecting: self)
        let params = Self.discoverParameters()
        var setParams = Set<String>()

        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            let propertyName = String(label.dropFirst())

            if let param = child.value as? MCPParamProtocol {
                if let value = arguments[propertyName] {
                    try param._setValue(value)
                    setParams.insert(propertyName)
                }
            } else if let group = child.value as? GroupParamProtocol {
                try group._groupApply(arguments: arguments)
                let groupParams = _discoverParameters(from: group._groupWrappedValue)
                for gp in groupParams {
                    if arguments[gp.name] != nil {
                        setParams.insert(gp.name)
                    }
                }
            }
        }

        // Check for missing required arguments
        for param in params where param.required {
            if !setParams.contains(param.name) {
                throw MCPError.missingArgument(param.name)
            }
        }
    }
}

// MARK: - Internal discovery helper (free function to avoid protocol dispatch issues)

/// Recursively discovers parameters from an arbitrary value via Mirror.
internal func _discoverParameters(from value: Any) -> [MCPParameterInfo] {
    let mirror = Mirror(reflecting: value)
    var params: [MCPParameterInfo] = []

    for child in mirror.children {
        guard let label = child.label, label.hasPrefix("_") else { continue }
        let propertyName = String(label.dropFirst())

        if let param = child.value as? MCPParamProtocol {
            params.append(MCPParameterInfo(
                name: propertyName,
                description: param._paramDescription,
                required: param._paramRequired,
                kind: param._paramKind,
                typeName: param._paramTypeName,
                hasDefault: param._paramHasDefault,
                enumValues: param._paramEnumValues
            ))
        } else if let group = child.value as? GroupParamProtocol {
            let groupParams = _discoverParameters(from: group._groupWrappedValue)
            params.append(contentsOf: groupParams)
        }
    }

    // Warn if no parameters were found — this could indicate the type
    // uses struct-based property wrappers that Mirror cannot inspect.
    if params.isEmpty {
        let typeName = "\(type(of: value))"
        if typeName != "()" {
            // Only warn for non-empty types
            paramDiscoveryLogger.warning("No parameters discovered for \(typeName). Ensure all parameter wrappers are classes (not structs) so Mirror can find them.")
        }
    }

    return params
}

// MARK: - MCPContext

/// Contextual information provided to a tool during invocation.
///
/// The framework creates an ``MCPContext`` and passes it to
/// ``MCPTool/invoke(context:)``. The context provides access to the
/// raw arguments dictionary and information about the caller.
///
/// - ``arguments``: The raw arguments dictionary passed to the tool.
/// - ``callerInfo``: Information about the caller, including access level.
public struct MCPContext: @unchecked Sendable {
    /// The raw arguments dictionary passed to the tool.
    public let arguments: [String: Any]

    /// Information about the caller.
    ///
    /// For stdio transport, this is always a root-level caller.
    /// For TCP transport, the access level is resolved from the source IP.
    /// If the transport does not provide caller info, this is `nil`.
    public let callerInfo: MCPCallerInfo?

    /// Creates a new context with the given arguments and caller info.
    ///
    /// - Parameters:
    ///   - arguments: The raw arguments dictionary.
    ///   - callerInfo: Information about the caller. Defaults to `nil`.
    public init(arguments: [String: Any], callerInfo: MCPCallerInfo? = nil) {
        self.arguments = arguments
        self.callerInfo = callerInfo
    }
}
