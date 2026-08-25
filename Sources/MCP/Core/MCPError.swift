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

/// Errors that can occur in the MCP framework.
///
/// This enum provides a comprehensive set of error cases for the MCP protocol
/// and framework operations. Each case includes contextual information to help
/// diagnose and handle failures.
///
/// The framework uses these errors throughout the stack:
/// - **Argument validation**: ``missingArgument(_:)``, ``typeMismatch(expected:actual:)``
/// - **Tool routing**: ``toolNotFound(_:)``
/// - **Protocol errors**: ``jsonRPCError(code:message:)``
/// - **Transport failures**: ``transportError(_:)``
/// - **Internal errors**: ``internalError(_:)``
///
/// ```swift
/// throw MCPError.missingArgument("name")
/// throw MCPError.typeMismatch(expected: "String", actual: "Int")
/// ```
public enum MCPError: Error, Sendable, Equatable {
    /// A required argument was not provided by the caller.
    ///
    /// The associated value is the name of the missing parameter.
    /// This error is thrown by ``MCPTool/apply(arguments:)`` when a required
    /// parameter is absent from the arguments dictionary.
    case missingArgument(String)

    /// An argument value could not be converted to the expected type.
    ///
    /// - Parameters:
    ///   - expected: The Swift type name the framework expected.
    ///   - actual: The type name of the value that was provided.
    case typeMismatch(expected: String, actual: String)

    /// The requested tool was not found on this server.
    ///
    /// The associated value is the name of the tool that was requested.
    /// This error is returned by the server when a `tools/call` request
    /// references a tool that has not been registered.
    case toolNotFound(String)

    /// A JSON-RPC protocol error occurred.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code.
    ///   - message: A human-readable error message.
    case jsonRPCError(code: Int, message: String)

    /// A transport-level error occurred.
    ///
    /// The associated value describes the transport failure. This can include
    /// I/O errors, connection failures, or unexpected EOF on stdin.
    case transportError(String)

    /// An internal framework error occurred.
    ///
    /// The associated value describes the internal inconsistency. These errors
    /// indicate bugs in the framework or unexpected state.
    case internalError(String)

    /// The caller does not have sufficient access to invoke a tool.
    ///
    /// The associated value is the name of the tool that was denied.
    /// This error is returned by the server when a `tools/call` request
    /// references a tool whose required access level exceeds the caller's
    /// access level.
    case accessDenied(String)
}

extension MCPError: LocalizedError {
    /// A localized description of the error, suitable for display to the user.
    public var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .typeMismatch(let expected, let actual):
            return "Type mismatch: expected \(expected), got \(actual)"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .jsonRPCError(let code, let message):
            return "JSON-RPC error \(code): \(message)"
        case .transportError(let message):
            return "Transport error: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        case .accessDenied(let name):
            return "Access denied: \(name)"
        }
    }
}
