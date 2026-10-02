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