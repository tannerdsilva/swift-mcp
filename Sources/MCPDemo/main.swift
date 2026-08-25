//===----------------------------------------------------------------------===//
//
// This source file is part of the MCPDemo target
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import MCP

// MARK: - Greet Tool

@MCPCommand(description: "Greet someone by name")
struct Greet {
    @Argument(description: "The person to greet")
    var name: String = ""

    @Option(description: "Number of times to repeat")
    var count: Int = 1

    @Flag(description: "Use a formal greeting")
    var formal: Bool = false

    func run() async throws -> String {
        let greeting = formal ? "Greetings" : "Hello"
        return Array(repeating: "\(greeting), \(name)!", count: count)
            .joined(separator: "\n")
    }
}

// MARK: - Calculate Tool

@MCPCommand(description: "Perform basic arithmetic")
struct Calculate {
    @Argument(description: "First operand")
    var a: Double = 0

    @Argument(description: "Second operand")
    var b: Double = 0

    @Option(description: "Operation: add, subtract, multiply, divide")
    var operation: String = "add"

    func run() async throws -> String {
        let result: Double
        switch operation.lowercased() {
        case "add", "+":
            result = a + b
        case "subtract", "-":
            result = a - b
        case "multiply", "*":
            result = a * b
        case "divide", "/":
            guard b != 0 else { throw MCPError.internalError("Division by zero") }
            result = a / b
        default:
            throw MCPError.internalError("Unknown operation: \(operation)")
        }
        return "\(a) \(operation) \(b) = \(result)"
    }
}

// MARK: - Main

@main
struct Main {
    static func main() async throws {
        let server = MCPServer(name: "MCPDemo", version: "1.0.0") {
            Greet()
            Calculate()
        }
        try await server.runService()
    }
}
