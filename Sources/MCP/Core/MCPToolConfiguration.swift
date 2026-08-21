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

/// Configuration metadata for an MCP tool.
///
/// This is the MCP analogue of `CommandConfiguration` from Swift Argument Parser.
/// Provide a configuration as the `configuration` property of your `MCPTool` type.
///
/// ```swift
/// struct Greet: MCPTool {
///     static let configuration = MCPToolConfiguration(
///         description: "Greet someone by name"
///     )
/// }
/// ```
public struct MCPToolConfiguration: Sendable, Codable {
    /// A human-readable description of what the tool does.
    public let description: String

    /// An explicit name for the tool. If `nil`, the name is derived from
    /// the type name converted to camelCase.
    public let name: String?

    /// The minimum access level required to invoke this tool.
    ///
    /// The server checks the caller's access level against this value
    /// in both `tools/list` (filtering) and `tools/call` (enforcement).
    /// Defaults to ``AccessLevel/public``, which allows all callers.
    public let requiredAccess: AccessLevel

    /// Creates a new tool configuration.
    ///
    /// - Parameters:
    ///   - description: A human-readable description of the tool.
    ///   - name: An explicit tool name. If `nil`, the type name is used.
    ///   - requiredAccess: The minimum access level required. Defaults to ``AccessLevel/public``.
    public init(
        description: String,
        name: String? = nil,
        requiredAccess: AccessLevel = .public
    ) {
        self.description = description
        self.name = name
        self.requiredAccess = requiredAccess
    }
}
