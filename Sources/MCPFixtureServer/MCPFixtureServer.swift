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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A test fixture server: a macro-built standalone MCP server over stdio.
///
/// Spawned by the real-client integration verification (the official mcp
/// Python SDK driving initialize → list → call over stdio) and by the
/// subprocess-client tests. Kept deliberately small — two representative tools
/// (one string, one numeric) exercising the `@MCPCommand` macro path, plus
/// hooks the integration tests need (cancellation observation, oversized
/// results, child-environment inspection).

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
        do {
            try await Task.sleep(for: .seconds(seconds))
            return "done"
        } catch is CancellationError {
            // observable cancellation marker for the client suite: when a
            // timed-out call's `notifications/cancelled` reaches this tool,
            // the sleep throws and this line lands on the retained stderr tail.
            _ = fputs("fixture slow-cancelled\n", stderr)
            throw CancellationError()
        }
    }
}

@MCPCommand(description: "Return a string of the given length", name: "big")
struct Big {
    @Argument(description: "How many characters to return")
    var count: Int = 5000

    func run() async throws -> String {
        String(repeating: "x", count: count)
    }
}

@MCPCommand(description: "Return a child environment variable's value", name: "envget")
struct EnvGet {
    @Argument(description: "Environment variable name")
    var key: String = ""

    func run() async throws -> String {
        guard let value = getenv(key) else { return "(unset)" }
        return String(cString: value)
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
@MCPApplication(name: "mcp-fixture", version: "1.0.0")
struct MCPFixtureServer {
    @Tool var echo = Echo()
    @Tool var add = Add()
    @Tool var slow = Slow()
    @Tool var big = Big()
    @Tool var envget = EnvGet()
    @Tool var admin = AdminEcho()
}
