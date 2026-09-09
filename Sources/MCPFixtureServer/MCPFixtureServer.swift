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

/// A test fixture server: a macro-built standalone MCP server over stdio.
///
/// Spawned by the real-client integration verification (the official mcp
/// Python SDK driving initialize → list → call over stdio) and by the
/// subprocess-client tests. Kept deliberately small — two representative tools
/// (one string, one numeric) exercising the `@MCPCommand` macro path.

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

@MCPCommand(description: "Sleep for the given number of seconds", name: "slow")
struct Slow {
    @Argument(description: "How many seconds to sleep")
    var seconds: Double = 5.0

    func run() async throws -> String {
        try await Task.sleep(for: .seconds(seconds))
        return "done"
    }
}

@main
@MCPApplication(name: "mcp-fixture", version: "1.0.0")
struct MCPFixtureServer {
    @Tool var echo = Echo()
    @Tool var add = Add()
    @Tool var slow = Slow()
}
