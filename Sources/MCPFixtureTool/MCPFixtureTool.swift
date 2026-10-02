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

import MCP

/// A test fixture: a compiled `interface: .oneShot` stdin tool binary.
///
/// Spawned by the end-to-end suite, which drives every face of the facade the
/// way a harness does — the plugin envelope with stdin held open, JSON-RPC
/// frames at EOF, introspection without stdin, the exit contract, and the
/// `MCP_ACCESS_LEVEL` caller seam. Kept deliberately small: one string tool,
/// one numeric tool, one failing tool, and one access-gated tool.

@MCPCommand(description: "Echo a message back verbatim", name: "echo")
struct Echo {
    @Argument(description: "The message to echo")
    var message: String = ""

    func run() async throws -> String {
        message
    }
}

@MCPCommand(description: "Add two integers", name: "add")
struct Add {
    @Argument(description: "First operand")
    var a: Int = 0

    @Argument(description: "Second operand")
    var b: Int = 0

    func run() async throws -> Int {
        a + b
    }
}

/// A tool that always fails, so the harness error-text mapping
/// (`{"result":"Error: …"}`) is exercised end to end.
struct FixtureFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MCPCommand(description: "Always fails, for error-text mapping", name: "fail")
struct Fail {
    @Argument(description: "Failure message")
    var message: String = ""

    func run() async throws -> String {
        throw FixtureFailure(message: message.isEmpty ? "boom" : message)
    }
}

@MCPCommand(description: "Admin-gated echo, used to exercise plugin trust levels", name: "admin", requiredAccess: .admin)
struct AdminEcho {
    @Argument(description: "Message to echo")
    var message: String = ""

    func run() async throws -> String {
        "admin:\(message)"
    }
}

@main
@MCPApplication(
    name: "mcp-fixture-tool",
    version: "1.0.0",
    description: "MCP stdin tool fixture: plugin envelope, JSON-RPC, and introspection",
    interface: .oneShot
)
struct MCPFixtureTool {
    @Tool var echo = Echo()
    @Tool var add = Add()
    @Tool var fail = Fail()
    @Tool var admin = AdminEcho()
}