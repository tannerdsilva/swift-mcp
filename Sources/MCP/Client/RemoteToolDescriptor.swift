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

/// A tool catalog entry as advertised by a remote server over `tools/list`.
///
/// The wire descriptor for a remote tool: name, optional description, and the
/// JSON Schema the server generated for its input. Unlike a compile-time
/// ``MCPTool``, a remote tool has no Swift type — callers invoke it through
/// ``MCPClient/callTool(_:arguments:)`` with a `[String: Any]` argument map.
public struct RemoteToolDescriptor: Sendable {
    /// The registered tool name (the key used by `tools/call`).
    public let name: String
    /// The tool's human-readable description, if the server advertised one.
    public let description: String?
    /// The tool's JSON Schema (the server's `inputSchema`).
    ///
    /// Carried as ``AnyCodable`` — the framework's JSON value type — so the
    /// descriptor remains `Sendable` without an existential `Any` payload.
    public let inputSchema: [String: AnyCodable]

    /// Creates a remote tool descriptor.
    ///
    /// - Parameters:
    ///   - name: The registered tool name.
    ///   - description: The server's tool description, if any.
    ///   - inputSchema: The tool's JSON Schema.
    public init(name: String, description: String?, inputSchema: [String: AnyCodable]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
