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

import Testing
import Logging
import QuickJSON
@testable import MCP

/// Discovery of a binary's self-description from its compiled surface: the
/// public catalog is built by the same router catalog `tools/list` serves, so
/// the live wire and the introspection output cannot drift.
@Suite("Tool catalog — discovery from the compiled surface")
struct ToolCatalogTests {

    @Test("discovery over the fixture app yields name, version, description, and tools")
    func discoveryMetadataAndTools() {
        let catalog = MCPToolCatalog.discover(
            name: "app-server",
            version: "1.0.0",
            description: "fixture catalog",
            dispatcher: AppServer()
        )
        #expect(catalog.name == "app-server")
        #expect(catalog.version == "1.0.0")
        #expect(catalog.description == "fixture catalog")
        #expect(catalog.tools.map(\.name) == ["greet", "calculate"])
    }

    @Test("an empty description stays nil")
    func emptyDescriptionIsNil() {
        let catalog = MCPToolCatalog.discover(name: "app-server", version: "1.0.0", dispatcher: AppServer())
        #expect(catalog.description == nil)
    }

    @Test("additional tools append to the discovered catalog")
    func discoveryWithAdditionalTools() {
        let catalog = MCPToolCatalog.discover(
            name: "app-server",
            version: "1.0.0",
            dispatcher: AppServer(),
            additionalTools: [PrintTool()]
        )
        #expect(catalog.tools.map(\.name) == ["greet", "calculate", "print"])
    }

    @Test("discovered tools equal the router's tools/list output (semantic compare)")
    func discoveryMatchesRouterWireOutput() async throws {
        let catalog = MCPToolCatalog.discover(name: "app-server", version: "1.0.0", dispatcher: AppServer())

        let router = MCPMessageRouter(
            name: "app-server",
            version: "1.0.0",
            logger: Logger(label: "test.catalog"),
            dispatcher: AppServer()
        )
        let wire = try await router.route(
            encodeFrame(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]),
            caller: MCPCallerInfo(sourceAddress: "test", accessLevel: .root)
        )
        let wireTools = ((decodeFrame(wire ?? []) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(wireTools?.count == catalog.tools.count)

        for (index, tool) in catalog.tools.enumerated() {
            let wireTool = wireTools?[index] as? [String: Any] ?? [:]
            #expect(wireTool["name"] as? String == tool.name)
            #expect(wireTool["description"] as? String == tool.description)

            // semantic comparison — JSON object key order is not significant.
            let encodedSchema = try QuickJSON.encode(tool.inputSchema)
            let decodedSchema = try QuickJSON.decode(AnyCodable.self, from: encodedSchema)
            let catalogSchema = decodedSchema.value as? [String: Any] ?? [:]
            let wireSchema = wireTool["inputSchema"] as? [String: Any] ?? [:]
            #expect(AnyCodable(wireSchema) == AnyCodable(catalogSchema))
        }
    }

    @Test("catalog encoding is canonical: keys sorted at every level, bytes stable")
    func catalogEncodingIsCanonical() throws {
        let catalog = MCPToolCatalog.discover(
            name: "app-server",
            version: "1.0.0",
            description: "fixture catalog",
            dispatcher: AppServer()
        )
        let first = try QuickJSON.encode(catalog)
        let second = try QuickJSON.encode(catalog)
        #expect(first == second)

        // top-level keys are emitted in sorted order:
        // description < name < tools < version.
        let text = String(decoding: first, as: UTF8.self)
        let descriptionIndex = try #require(text.range(of: "\"description\""))
        let nameIndex = try #require(text.range(of: "\"name\""))
        let toolsIndex = try #require(text.range(of: "\"tools\""))
        let versionIndex = try #require(text.range(of: "\"version\""))
        #expect(descriptionIndex.lowerBound < nameIndex.lowerBound)
        #expect(nameIndex.lowerBound < toolsIndex.lowerBound)
        #expect(toolsIndex.lowerBound < versionIndex.lowerBound)

        // per-tool entries are sorted too: description < inputSchema < name,
        // and each schema's own keys are sorted (properties < required < type).
        let toolsArray = try #require(text.range(of: "\"tools\":["))
        let entry = text[toolsArray.upperBound...]
        #expect(entry.hasPrefix("{\"description\""))

        let schemaIndex = try #require(entry.range(of: "\"inputSchema\""))
        let toolNameIndex = try #require(entry.range(of: "\"name\""))
        #expect(schemaIndex.lowerBound < toolNameIndex.lowerBound)

        let propertiesIndex = try #require(entry.range(of: "\"properties\""))
        let requiredIndex = try #require(entry.range(of: "\"required\""))
        let objectTypeIndex = try #require(entry.range(of: "\"type\":\"object\""))
        #expect(propertiesIndex.lowerBound < requiredIndex.lowerBound)
        #expect(requiredIndex.lowerBound < objectTypeIndex.lowerBound)
    }
}

/// Harness manifest formats as data — the arc plugin manifest first.
///
/// The acceptance shape is the manifest arc consumes today
/// (`~/.arc/plugins/<name>/manifest.json`): top-level
/// `name`/`version`/`description`/`tools`, and per tool
/// `name`/`description`/`command`/`args`/`toolset`/`schema` — where `schema`
/// is the bare parameters object (`type`/`properties`/`required`), not the
/// wrapped function-call envelope.
@Suite("Tool manifests — arc plugin format")
struct ToolManifestTests {

    private func catalogFixture() -> MCPToolCatalog {
        MCPToolCatalog.discover(
            name: "app-server",
            version: "1.0.0",
            description: "fixture catalog",
            dispatcher: AppServer()
        )
    }

    private func contextFixture() -> MCPManifestContext {
        MCPManifestContext(binaryPath: "/usr/local/bin/app-server", invocationArguments: ["plugin"])
    }

    @Test("arc manifest top level: name/version/description/tools")
    func arcManifestTopLevel() throws {
        let bytes = try ArcPluginManifest(toolset: "fixture-toolset").encode(catalogFixture(), context: contextFixture())
        let decoded = try #require(decodeFrame(bytes) as? [String: Any])
        #expect(decoded["name"] as? String == "app-server")
        #expect(decoded["version"] as? String == "1.0.0")
        #expect(decoded["description"] as? String == "fixture catalog")
        let tools = try #require(decoded["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools.compactMap { $0["name"] as? String } == ["greet", "calculate"])
    }

    @Test("arc manifest per tool: name/description/command/args/toolset/schema")
    func arcManifestPerTool() throws {
        let catalog = catalogFixture()
        let bytes = try ArcPluginManifest(toolset: "fixture-toolset").encode(catalog, context: contextFixture())
        let decoded = try #require(decodeFrame(bytes) as? [String: Any])
        let tool = try #require((decoded["tools"] as? [[String: Any]])?.first)

        #expect(tool["name"] as? String == "greet")
        #expect(tool["description"] as? String == "Greet someone by name")
        #expect(tool["command"] as? String == "/usr/local/bin/app-server")
        #expect(tool["args"] as? [String] == ["plugin"])
        #expect(tool["toolset"] as? String == "fixture-toolset")

        // schema is the bare parameters object — no function-call envelope.
        let schema = try #require(tool["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["function"] == nil)
        #expect((schema["properties"] as? [String: Any])?.isEmpty == false)

        // and it is semantically the catalog tool's schema.
        let catalogSchema = try QuickJSON.decode(AnyCodable.self, from: try QuickJSON.encode(catalog.tools[0].inputSchema))
        #expect(AnyCodable(schema) == AnyCodable(catalogSchema.value))
    }

    @Test("arc manifest is deterministic and compact, with sorted keys")
    func arcManifestDeterminism() throws {
        let manifest = ArcPluginManifest(toolset: "fixture-toolset")
        let catalog = catalogFixture()
        let first = try manifest.encode(catalog, context: contextFixture())
        let second = try manifest.encode(catalog, context: contextFixture())
        #expect(first == second)

        let text = String(decoding: first, as: UTF8.self)
        // compact: a harness reads these bytes, so there is no insignificant
        // whitespace — one line, no padded separators.
        #expect(!text.contains("\n"))
        #expect(!text.contains("\" : \""))
        // sorted keys: description < name < tools < version.
        let descriptionIndex = try #require(text.range(of: "\"description\""))
        let nameIndex = try #require(text.range(of: "\"name\""))
        let toolsIndex = try #require(text.range(of: "\"tools\""))
        let versionIndex = try #require(text.range(of: "\"version\""))
        #expect(descriptionIndex.lowerBound < nameIndex.lowerBound)
        #expect(nameIndex.lowerBound < toolsIndex.lowerBound)
        #expect(toolsIndex.lowerBound < versionIndex.lowerBound)

        // the reviewable form is a separate format name, differing in
        // whitespace only.
        let pretty = try ArcPluginManifest.Pretty(toolset: "fixture-toolset")
            .encode(catalog, context: contextFixture())
        let prettyText = String(decoding: pretty, as: UTF8.self)
        #expect(prettyText.contains("\n  \"description\""))
        let compactDoc = try QuickJSON.decode(AnyCodable.self, from: first)
        let prettyDoc = try QuickJSON.decode(AnyCodable.self, from: pretty)
        #expect(compactDoc == prettyDoc)
    }

    @Test("missing tool descriptions encode as empty strings; an absent top-level description is omitted")
    func arcManifestMissingDescriptions() throws {
        let catalog = MCPToolCatalog(
            name: "t",
            version: "1",
            description: nil,
            tools: [MCPToolCatalog.Tool(name: "x", description: nil, inputSchema: ["type": AnyCodable("object")])]
        )
        let bytes = try ArcPluginManifest(toolset: "ts").encode(
            catalog,
            context: MCPManifestContext(binaryPath: "/bin/t", invocationArguments: [])
        )
        let decoded = try #require(decodeFrame(bytes) as? [String: Any])
        #expect(decoded["description"] == nil)
        let tool = try #require((decoded["tools"] as? [[String: Any]])?.first)
        #expect(tool["description"] as? String == "")
        #expect(tool["args"] as? [String] == [])
    }

    @Test("format identity: the arc format answers to its name")
    func formatName() {
        #expect(ArcPluginManifest.formatName == "arc")
    }

    @Test("executable path resolution: absolute argv0 kept, bare names search PATH, empty fails")
    func executablePathResolution() {
        #expect(
            MCPManifestContext.resolveExecutablePath(arguments: ["/usr/local/bin/tool"], searchPath: "/nowhere")
                == "/usr/local/bin/tool"
        )
        #expect(
            MCPManifestContext.resolveExecutablePath(arguments: ["ls"], searchPath: "/bin")
                == "/bin/ls"
        )
        #expect(
            MCPManifestContext.resolveExecutablePath(arguments: ["definitely-not-a-real-binary-xyz"], searchPath: "/bin:/usr/bin")
                == nil
        )
        #expect(MCPManifestContext.resolveExecutablePath(arguments: [], searchPath: "/bin") == nil)
        #expect(MCPManifestContext.resolveExecutablePath(arguments: [""], searchPath: "/bin") == nil)
    }
}