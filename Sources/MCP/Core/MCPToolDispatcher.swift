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

/// Static metadata for a single compile-time-known tool.
///
/// Produced by an ``MCPToolDispatcher`` for the `tools/list` catalog. The
/// server converts a descriptor into a wire `MCPToolDefinition` by building
/// the JSON Schema from ``parameters`` — keeping schema generation, which
/// depends on internal JSONSchemaBuilder, on the framework side.
public struct MCPToolDescriptor: Sendable, Equatable {
    /// The registered tool name (the key used by `tools/call`).
    public let name: String
    /// The human-readable tool description.
    public let description: String
    /// The tool's compile-time-discovered parameter metadata.
    public let parameters: [MCPParameterInfo]

    /// Creates a new tool descriptor.
    ///
    /// - Parameters:
    ///   - name: The registered tool name.
    ///   - description: The human-readable tool description.
    ///   - parameters: The parameter metadata for the tool's JSON Schema.
    public init(name: String, description: String, parameters: [MCPParameterInfo]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A compile-time-known, exhaustive dispatch surface for a fixed set of tools.
///
/// ``MCPApplication`` generates a conformance on the application struct:
/// every method is an exhaustive switch over the generated ``MCPToolID``
/// enum or an if-chain over each tool's *static* ``MCPTool/toolName``, so the
/// server routes `tools/list` and `tools/call` through **concrete** types —
/// no runtime type erasure in the registry. The only existential is the
/// single ``dispatcher`` the server holds to reach this surface.
///
/// A server may hold both a dispatcher (macro-generated tools) and a
/// dynamically-registered tool set (via ``MCPServer/register(_:)`` and
/// ``MCPServer/registerInstance(_:instance:)``). The dispatcher is consulted
/// first for both listing and invocation; dynamic tools remain available
/// through the registry path.
///
/// The three requirements are the entire runtime contract this framework
/// places on a tool set:
/// - ``toolCatalog(for:)`` answers the accessible `tools/list` subset.
/// - ``requiredAccess(named:)`` answers the access gate so the server enforces
///   authorization uniformly before any invocation.
/// - ``callTool(named:arguments:context:)`` performs the typed dispatch.
public protocol MCPToolDispatcher: Sendable {
    /// The `tools/list` catalog, filtered to what this caller may see.
    ///
    /// - Parameter callerAccessLevel: The caller's resolved access level.
    /// - Returns: One descriptor per accessible tool.
    func toolCatalog(for callerAccessLevel: AccessLevel) -> [MCPToolDescriptor]

    /// The access level a caller must satisfy to invoke the named tool.
    ///
    /// - Parameter name: The registered tool name.
    /// - Returns: The tool's `requiredAccess`, or `nil` if the name is unknown.
    func requiredAccess(named name: String) -> AccessLevel?

    /// Invokes the named tool with typed, exhaustive dispatch.
    ///
    /// The server has already enforced ``requiredAccess(named:)`` before
    /// calling this method, so the generated implementation applies arguments
    /// and invokes the tool's concrete type directly.
    ///
    /// - Parameters:
    ///   - name: The registered tool name.
    ///   - arguments: The caller-provided arguments.
    ///   - context: Per-call context, including caller identity.
    /// - Returns: The tool result, or `nil` if the name is not handled.
    func callTool(named name: String, arguments: [String: Any], context: MCPContext) async throws -> MCPToolResult?
}
