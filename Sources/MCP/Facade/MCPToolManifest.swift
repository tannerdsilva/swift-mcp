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

import QuickJSON

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A harness manifest format: the binary's catalog rendered as the data some
/// agent harness consumes.
///
/// Formats are data, not hardwired protocol: the host picks one by name
/// (`--mcp-manifest <name>`) from the ones it is given, and a consumer with
/// its own harness adds a conformance instead of patching the framework.
public protocol MCPToolManifestFormat: Sendable {
    /// The format's lookup name (the `--mcp-manifest <name>` argument).
    static var formatName: String { get }

    /// Encodes a catalog into this format's bytes.
    ///
    /// - Parameters:
    ///   - catalog: The binary's discovered tool catalog.
    ///   - context: Ambient facts the format needs (binary path, invocation
    ///     prefix) that the catalog itself does not carry.
    /// - Returns: The manifest document. No trailing newline — the host frames
    ///   output the same way it frames responses.
    func encode(_ catalog: MCPToolCatalog, context: MCPManifestContext) throws -> [UInt8]
}

/// Ambient facts a manifest format needs beyond the catalog.
public struct MCPManifestContext: Sendable {
    /// The absolute path of the running binary — what a harness must execute.
    public let binaryPath: String

    /// The argv a harness appends after `binaryPath` when invoking a tool
    /// (e.g. `["plugin"]` for a binary that kept a plugin subcommand). May be
    /// empty for a pure one-shot binary.
    public let invocationArguments: [String]

    /// Creates a manifest context.
    public init(binaryPath: String, invocationArguments: [String]) {
        self.binaryPath = binaryPath
        self.invocationArguments = invocationArguments
    }

    /// Resolves the running binary's executable path, Foundation-free.
    ///
    /// The ladder mirrors what established consumers do (and what the plugin
    /// harness expects in a manifest's `command` field):
    /// - absolute `argv[0]` is kept exactly as invoked;
    /// - a relative path with a directory component resolves against the
    ///   current working directory;
    /// - a bare name is searched along `PATH` (default `/usr/bin:/bin`).
    ///
    /// - Parameters:
    ///   - arguments: The process arguments; `argv[0]` is inspected. Defaults
    ///     to `CommandLine.arguments`.
    ///   - searchPath: The `PATH` value to search for bare names. Defaults to
    ///     the process environment's `PATH`.
    /// - Returns: The resolved path, or `nil` when nothing matches.
    public static func resolveExecutablePath(
        arguments: [String] = CommandLine.arguments,
        searchPath: String? = nil
    ) -> String? {
        guard let argv0 = arguments.first, !argv0.isEmpty else { return nil }
        if argv0.hasPrefix("/") { return argv0 }
        if argv0.contains("/") {
            // a relative path with a directory component: resolve against cwd.
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(argv0, &buffer) != nil else { return nil }
            return String(cString: buffer)
        }
        let path = searchPath ?? StdioTransport.environmentString("PATH") ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(argv0)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }
}

/// The arc harness plugin manifest — the format `~/.arc/plugins/<name>/manifest.json`
/// carries.
///
/// Shape (the contract arc's `PluginManifest` decoder accepts):
/// - top level: `name`, `version`, `description` (omitted when absent),
///   `tools`;
/// - per tool: `name`, `description` (always present — arc requires the
///   field, so an absent description encodes as `""`), `command` (absolute
///   binary path), `args` (the invocation prefix), `toolset`, and `schema` —
///   the **bare parameters object** (`type`/`properties`/`required`), not the
///   wrapped `{"type":"function",…}` envelope some harnesses accept.
///
/// Output is canonical: pretty-printed, two-space indented, object keys
/// sorted at every depth — so regenerating the same manifest yields the same
/// bytes and diffs stay meaningful.
public struct ArcPluginManifest: MCPToolManifestFormat {
    public static let formatName = "arc"

    /// The toolset every tool in this manifest belongs to (the arc grouping;
    /// a one-shot binary serves exactly one toolset).
    public let toolset: String

    /// Creates the arc manifest format for a toolset.
    public init(toolset: String) {
        self.toolset = toolset
    }

    public func encode(_ catalog: MCPToolCatalog, context: MCPManifestContext) throws -> [UInt8] {
        var topLevel: [(key: String, value: CanonicalJSON)] = []
        if let description = catalog.description {
            topLevel.append(("description", .scalar(AnyCodable(description))))
        }
        topLevel.append(("name", .scalar(AnyCodable(catalog.name))))
        topLevel.append((
            "tools",
            .array(catalog.tools.map { tool in
                .object([
                    ("args", .array(context.invocationArguments.map { .scalar(AnyCodable($0)) })),
                    ("command", .scalar(AnyCodable(context.binaryPath))),
                    ("description", .scalar(AnyCodable(tool.description ?? ""))),
                    ("name", .scalar(AnyCodable(tool.name))),
                    ("schema", CanonicalJSON(tool.inputSchema)),
                    ("toolset", .scalar(AnyCodable(toolset))),
                ])
            })
        ))
        topLevel.append(("version", .scalar(AnyCodable(catalog.version))))

        return try QuickJSON.encode(CanonicalJSON.object(topLevel), flags: [.prettyTwoSpaces])
    }
}