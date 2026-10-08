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

// the tools file. `import MCP` lives here and nowhere else in this target —
// see PackEntry.swift for why the entry file must not import the whole library.

import MCP

@MCPCommand(description: "Greet a caller by name", name: "greet")
struct Greet {
    @Argument(description: "Who to greet")
    var name: String = "world"

    func run() async throws -> String {
        "hello, \(name)"
    }
}

@MCPCommand(description: "Reverse a string", name: "reverse")
struct Reverse {
    @Argument(description: "The text to reverse")
    var text: String = ""

    func run() async throws -> String {
        String(text.reversed())
    }
}

/// The dispatcher surface `PackEntry` hands to the host.
///
/// Deliberately carries no `@main`: this binary's entry point is the CLI in
/// `PackEntry.swift`, which is what routes a harness through `<bin> plugin`.
/// The macro still generates the whole typed dispatch surface (tool ids,
/// exhaustive switch, catalog, access gate) — only the generated `main()` goes
/// unused here.
@MCPApplication(
    name: "mcp-two-file-pack",
    version: "1.0.0",
    description: "A two-file shimless pack: MCP tools in one file, the CLI entry in another"
)
struct PackTools {
    @Tool var greet = Greet()
    @Tool var reverse = Reverse()
}