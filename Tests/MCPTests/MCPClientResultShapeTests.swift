import Testing
import Foundation
@testable import MCP
import QuickJSON

/// The `tools/call` result envelope's wire contract.
///
/// `isError` is optional in MCP (absent means success) and the current official
/// servers omit it on success — `@modelcontextprotocol/server-filesystem`
/// answers `{"content":[…],"structuredContent":{…}}`. Requiring it failed the
/// whole reply to decode (`MCP invalid response: notFound`), so every
/// `callTool` against a real server threw.
///
/// Decode-level on purpose: the framework's client tests drive the in-repo
/// `MCPFixtureServer`, which always encodes `isError`, so a wire test against
/// our own server cannot express this case.
@Suite("MCP tools/call result shape")
struct MCPClientResultShapeTests {

    @Test("a result without isError decodes as a success")
    func missingIsErrorIsSuccess() throws {
        let frame = Array(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8)
        let envelope = try QuickJSON.decode(ToolCallEnvelope.self, from: frame)
        #expect(envelope.isError == false)
        #expect(envelope.content.count == 1)
    }

    @Test("a result with extra server fields still decodes")
    func extraFieldsAreIgnored() throws {
        // the real filesystem server also sends structuredContent
        let frame = Array(
            #"{"content":[{"type":"text","text":"ok"}],"structuredContent":{"files":[]},"isError":false}"#.utf8
        )
        let envelope = try QuickJSON.decode(ToolCallEnvelope.self, from: frame)
        #expect(envelope.isError == false)
    }

    @Test("isError is honoured when the server does send it")
    func isErrorIsHonoured() throws {
        let failed = Array(#"{"content":[{"type":"text","text":"nope"}],"isError":true}"#.utf8)
        #expect(try QuickJSON.decode(ToolCallEnvelope.self, from: failed).isError == true)

        let ok = Array(#"{"content":[{"type":"text","text":"ok"}],"isError":false}"#.utf8)
        #expect(try QuickJSON.decode(ToolCallEnvelope.self, from: ok).isError == false)
    }

    @Test("a result with no content still fails loudly")
    func missingContentThrows() throws {
        let frame = Array(#"{"isError":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try QuickJSON.decode(ToolCallEnvelope.self, from: frame)
        }
    }
}