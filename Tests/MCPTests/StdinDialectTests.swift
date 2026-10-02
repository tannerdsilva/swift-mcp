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
import QuickJSON
@testable import MCP

/// The stdin dialect protocol and its JSON-RPC identity conformance.
///
/// a dialect is a pure byte transcoder: it recognizes a harness frame,
/// rewrites it to a JSON-RPC frame for the one shared router, and rewrites the
/// router's response back to the harness envelope. it never interprets call
/// semantics — that stays in `MCPMessageRouter`, so the facade and the server
/// cannot drift.
@Suite("Stdin dialects — protocol and JSON-RPC identity")
struct StdinDialectTests {

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    private let requestFrame = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
    private let batchFrame = #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#
    private let pluginFrame = #"{"tool":"echo","args":{"message":"hi"}}"#

    // MARK: - recognition

    @Test("json-rpc dialect recognizes a request frame")
    func recognizesRequest() {
        #expect(MCPJSONRPCDialect.recognizes(bytes(requestFrame)))
    }

    @Test("json-rpc dialect recognizes a batch frame")
    func recognizesBatch() {
        #expect(MCPJSONRPCDialect.recognizes(bytes(batchFrame)))
    }

    @Test("json-rpc dialect rejects plugin frames")
    func rejectsPluginFrame() {
        #expect(!MCPJSONRPCDialect.recognizes(bytes(pluginFrame)))
    }

    @Test("json-rpc dialect rejects non-JSON bytes")
    func rejectsNonJSON() {
        #expect(!MCPJSONRPCDialect.recognizes(bytes("not json at all")))
        #expect(!MCPJSONRPCDialect.recognizes([]))
    }

    @Test("json-rpc dialect rejects JSON that is not an envelope")
    func rejectsBareJSON() {
        #expect(!MCPJSONRPCDialect.recognizes(bytes("42")))
        #expect(!MCPJSONRPCDialect.recognizes(bytes(#"{"foo":1}"#)))
    }

    // MARK: - route: harness → JSON-RPC (identity; the router classifies)

    @Test("json-rpc route is byte-identity for request frames")
    func routeIsIdentityForRequests() throws {
        let frame = bytes(requestFrame)
        #expect(try MCPJSONRPCDialect().route(frame) == frame)
        let batch = bytes(batchFrame)
        #expect(try MCPJSONRPCDialect().route(batch) == batch)
    }

    @Test("json-rpc route is byte-identity for malformed bytes — the router owns classification")
    func routeIsIdentityForMalformed() throws {
        // deliberately a transcoder, not a classifier: whatever the engine
        // answers for these bytes, it answers for the facade too (no drift).
        let garbage = bytes("not json at all")
        #expect(try MCPJSONRPCDialect().route(garbage) == garbage)
    }

    // MARK: - respond: JSON-RPC → harness

    @Test("json-rpc respond passes the response through unchanged")
    func respondPassesThrough() throws {
        let response = bytes(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        let frame = bytes(requestFrame)
        #expect(try MCPJSONRPCDialect().respond(response, to: frame) == response)
    }

    @Test("json-rpc respond maps a nil response (notification) to nil")
    func respondMapsNilToNil() throws {
        #expect(try MCPJSONRPCDialect().respond(nil, to: bytes(requestFrame)) == nil)
    }

    // MARK: - metadata

    @Test("json-rpc dialect metadata")
    func metadata() {
        #expect(MCPJSONRPCDialect.dialectName == "jsonrpc")
        #expect(MCPJSONRPCDialect.completesAfterFirstRequest == false)
    }

    // MARK: - existential usage (the host stores `[any MCPStdinDialect]`)

    @Test("static recognition is reachable through the existential metatype")
    func recognitionThroughExistential() {
        let dialects: [any MCPStdinDialect] = [MCPJSONRPCDialect()]
        let matched = dialects.first { type(of: $0).recognizes(bytes(requestFrame)) }
        #expect(matched != nil)
        let missed = dialects.first { type(of: $0).recognizes(bytes(pluginFrame)) }
        #expect(missed == nil)
    }
}

/// The plugin envelope dialect: `{"tool","args"}` in, `{"result"}` out, one
/// request per process, no session.
@Suite("Stdin dialects — plugin envelope")
struct StdinPluginDialectTests {

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    private let pluginFrame = #"{"tool":"echo","args":{"message":"hi"}}"#

    // MARK: - recognition

    @Test("plugin dialect recognizes a tool frame")
    func recognizesToolFrame() {
        #expect(MCPPluginDialect.recognizes(bytes(pluginFrame)))
        #expect(MCPPluginDialect.recognizes(bytes(#"{"tool":"echo"}"#)))
    }

    @Test("plugin dialect rejects json-rpc frames and non-JSON")
    func rejectsOtherShapes() {
        #expect(!MCPPluginDialect.recognizes(bytes(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        #expect(!MCPPluginDialect.recognizes(bytes("not json")))
        #expect(!MCPPluginDialect.recognizes(bytes(#"{"args":{}}"#)))
    }

    // MARK: - route: plugin frame → tools/call request

    @Test("plugin route synthesizes a tools/call request")
    func routeSynthesizesToolsCall() throws {
        let routed = try MCPPluginDialect().route(bytes(pluginFrame))
        let frame = decodeFrame(routed) as? [String: Any]
        #expect(frame?["jsonrpc"] as? String == "2.0")
        #expect(frame?["id"] as? Int != nil)
        #expect(frame?["method"] as? String == "tools/call")
        let params = frame?["params"] as? [String: Any]
        #expect(params?["name"] as? String == "echo")
        let arguments = params?["arguments"] as? [String: Any]
        #expect(arguments?["message"] as? String == "hi")
    }

    @Test("plugin route defaults missing args to an empty object")
    func routeDefaultsArgs() throws {
        let routed = try MCPPluginDialect().route(bytes(#"{"tool":"echo"}"#))
        let frame = decodeFrame(routed) as? [String: Any]
        let params = frame?["params"] as? [String: Any]
        let arguments = params?["arguments"] as? [String: Any]
        #expect(arguments?.isEmpty == true)
    }

    @Test("plugin route throws on malformed payloads")
    func routeThrowsOnMalformed() {
        #expect(throws: MCPStdinDialectError.self) { try MCPPluginDialect().route(bytes(#"{"tool":123}"#)) }
        #expect(throws: MCPStdinDialectError.self) { try MCPPluginDialect().route(bytes(#"{"args":{}}"#)) }
        #expect(throws: MCPStdinDialectError.self) { try MCPPluginDialect().route(bytes(#"{"tool":"x","args":"nope"}"#)) }
        #expect(throws: MCPStdinDialectError.self) { try MCPPluginDialect().route(bytes("not json")) }
    }

    // MARK: - respond: response → {"result"}

    @Test("plugin respond maps success text content to {\"result\"}")
    func respondMapsText() throws {
        let response = encodeFrame(
            ["jsonrpc": "2.0", "id": 1, "result": ["content": [["type": "text", "text": "hi"]], "isError": false]] as [String: Any]
        )
        let out = try MCPPluginDialect().respond(response, to: bytes(pluginFrame))
        let harness = out.flatMap { decodeFrame($0) } as? [String: Any]
        #expect(harness?["result"] as? String == "hi")
    }

    @Test("plugin respond prefixes isError results with \"Error: \"")
    func respondMapsErrorResult() throws {
        let response = encodeFrame(
            ["jsonrpc": "2.0", "id": 1, "result": ["content": [["type": "text", "text": "boom"]], "isError": true]] as [String: Any]
        )
        let out = try MCPPluginDialect().respond(response, to: bytes(pluginFrame))
        let harness = out.flatMap { decodeFrame($0) } as? [String: Any]
        #expect(harness?["result"] as? String == "Error: boom")
    }

    @Test("plugin respond maps JSON-RPC protocol errors to Error: text")
    func respondMapsProtocolError() throws {
        let response = encodeFrame(
            ["jsonrpc": "2.0", "id": 1, "error": ["code": -32000, "message": "Access denied: admin"]] as [String: Any]
        )
        let out = try MCPPluginDialect().respond(response, to: bytes(pluginFrame))
        let harness = out.flatMap { decodeFrame($0) } as? [String: Any]
        #expect(harness?["result"] as? String == "Error: Access denied: admin")
    }

    @Test("plugin respond maps a nil response to nil and rejects undecodable responses")
    func respondNilAndGarbage() throws {
        let suppressed = try MCPPluginDialect().respond(nil, to: bytes(pluginFrame))
        #expect(suppressed == nil)
        #expect(throws: MCPStdinDialectError.self) {
            try MCPPluginDialect().respond(bytes("garbage"), to: bytes(pluginFrame))
        }
        #expect(throws: MCPStdinDialectError.self) {
            try MCPPluginDialect().respond(encodeFrame(["jsonrpc": "2.0", "id": 1] as [String: Any]), to: bytes(pluginFrame))
        }
    }

    // MARK: - metadata + coexistence

    @Test("plugin dialect metadata")
    func metadata() {
        #expect(MCPPluginDialect.dialectName == "plugin")
        #expect(MCPPluginDialect.completesAfterFirstRequest == true)
    }

    @Test("detection order: plugin claims its frames, json-rpc claims its own")
    func detectionOrder() {
        let dialects: [any MCPStdinDialect] = [MCPPluginDialect(), MCPJSONRPCDialect()]
        let pluginMatch = dialects.first { type(of: $0).recognizes(bytes(pluginFrame)) }
        #expect(pluginMatch != nil)
        #expect(type(of: pluginMatch!).dialectName == "plugin")

        let rpcFrame = bytes(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let rpcMatch = dialects.first { type(of: $0).recognizes(rpcFrame) }
        #expect(rpcMatch != nil)
        #expect(type(of: rpcMatch!).dialectName == "jsonrpc")
    }
}