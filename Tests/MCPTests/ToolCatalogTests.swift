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