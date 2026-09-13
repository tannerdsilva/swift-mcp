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
@testable import MCP

/// Tests for the harness-adapter surface: schema `default` emission and the
/// result flattener that string-consuming adapters use, plus the wire-value
/// round trips they depend on (`JSONRPCID`, `AnyCodable` equality).
@Suite(.serialized)
struct AdapterSurfaceTests {

    @Test("JSONSchemaBuilder emits the static default for optional params")
    func schemaEmitsDefault() throws {
        let param = MCPParameterInfo(
            name: "count",
            description: nil,
            required: false,
            kind: .option,
            typeName: "Int",
            hasDefault: true,
            defaultValue: AnyCodable(1)
        )
        let schema = JSONSchemaBuilder.buildPropertySchema(for: param)
        #expect(schema["default"] as? Int == 1)
    }

    @Test("JSONSchemaBuilder emits no default when the macro could not evaluate it")
    func schemaOmitsUneevaluableDefault() throws {
        let param = MCPParameterInfo(
            name: "mode",
            description: nil,
            required: false,
            kind: .option,
            typeName: "String",
            hasDefault: true,
            defaultValue: nil
        )
        let schema = JSONSchemaBuilder.buildPropertySchema(for: param)
        #expect(schema["default"] == nil)
    }

    @Test("MCPToolResult.flattenedText joins text blocks and marks errors")
    func flattenedTextJoinsAndMarks() {
        #expect(MCPToolResult.text("hi").flattenedText == "hi")
        #expect(MCPToolResult.error("boom").flattenedText == "error: boom")
        #expect(MCPToolResult(content: [.text("a"), .text("b")]).flattenedText == "a\nb")
        #expect(MCPToolResult(content: [.text("a"), .resource(uri: "r1", mimeType: nil, text: nil)]).flattenedText == "a\n[resource: r1]")
    }

    @Test("JSONRPCID maps to and from decoded wire values")
    func jsonRPCIDWireMapping() {
        #expect(JSONRPCID(0) == .int(0))
        #expect(JSONRPCID("abc") == .string("abc"))
        #expect(JSONRPCID(1.5) == .number(1.5))
        #expect(JSONRPCID(JSONNull()) == .null)
        #expect(JSONRPCID([1, 2]) == nil)
        #expect(JSONRPCID.int(7).wireValue as? Int == 7)
    }

    @Test("AnyCodable equality is structural")
    func anyCodableEquality() {
        #expect(AnyCodable(1) == AnyCodable(1))
        #expect(AnyCodable("a") != AnyCodable("b"))
        #expect(AnyCodable(["k": 1]) == AnyCodable(["k": 1]))
        #expect(AnyCodable(["k": 1]) != AnyCodable(["k": 2]))
        #expect(AnyCodable([1, 2]) == AnyCodable([1, 2]))
        #expect(AnyCodable([1, 2]) != AnyCodable([1, 3]))
        #expect(AnyCodable(JSONNull()) == AnyCodable(JSONNull()))
    }
}
