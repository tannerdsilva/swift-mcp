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

// the entry file: ArgumentParser, plus a SELECTIVE MCP import.
//
// a whole-library `import MCP` here would collide with ArgumentParser's own
// `@Argument`, `@Option`, `@Flag` and `@OptionGroup` — same names in both
// frameworks — and fail this entire file with `'Argument' is ambiguous for
// type lookup in this context`, cascading into `does not conform to protocol
// 'ParsableCommand'` on every `@Option`-bearing command. name only the type the
// entry actually needs; the whole-library import stays in the tools file.
//
// this target exists to compile-check that layout, not to be a large tool.

import ArgumentParser
import struct MCP.MCPStdinHost

/// The binary's root.
///
/// `AsyncParsableCommand` is load-bearing rather than stylistic: a subcommand
/// with an `async run()` under a synchronous root is refused at runtime
/// ("Asynchronous subcommand of a synchronous root") and its `run()` is
/// silently never called.
@main
struct PackCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-two-file-pack",
        abstract: "A shimless MCP tool pack with a CLI entry point",
        subcommands: [Plugin.self]
    )
}

/// The one-shot host entry: `<bin> plugin`.
///
/// The tools file advertises `["plugin"]` as the manifest invocation argv, so
/// this is exactly what a harness spawns.
struct Plugin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Serve one harness frame on stdin, then exit"
    )

    /// Everything after `plugin` belongs to the host, not to the CLI: its
    /// introspection flags (`--mcp-list`, `--mcp-manifest <fmt>`) have to reach
    /// `MCPStdinHost` rather than be rejected as unknown options.
    ///
    /// `@Argument` here is ArgumentParser's — the reason this file does not
    /// `import MCP`.
    @Argument(parsing: .captureForPassthrough)
    var hostArguments: [String] = []

    func run() async throws {
        // `argv[0]` must be the REAL executable path: the manifest resolves its
        // `command` field from it (an absolute path is kept verbatim; a bare
        // name is searched along PATH and would not be found). The captured
        // tokens are exactly the ones `MCPStdinHost` introspects.
        let arguments = [CommandLine.arguments.first ?? "mcp-two-file-pack"] + hostArguments

        await MCPStdinHost(
            name: "mcp-two-file-pack",
            version: "1.0.0",
            description: "A two-file shimless pack: MCP tools in one file, the CLI entry in another",
            dispatcher: PackTools(),
            configuration: .init(
                arguments: arguments,
                manifestInvocationArguments: ["plugin"]
            )
        ).runMain()
    }
}