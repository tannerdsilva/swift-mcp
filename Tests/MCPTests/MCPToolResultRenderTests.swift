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
import Foundation
import MCP

private struct Coordinates: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

private struct Opaque {
    let label: String
}

/// An `Encodable` whose encoding fails, to prove the render path degrades
/// instead of propagating.
private struct Unencodable: Encodable {
    struct Boom: Error {}
    func encode(to encoder: Encoder) throws { throw Boom() }
}

/// The rendering contract: what a tool's return *value* becomes on the wire.
///
/// Three overloads and three outcomes — a `String` verbatim, any `Encodable`
/// value as compact JSON, anything else as its description. The compiler picks
/// between them, so a tool author never chooses a rendering mode.
@Suite
struct MCPToolResultRenderTests {

    @Test("a String is the result verbatim, never re-quoted")
    func stringIsVerbatim() {
        #expect(MCPToolResult.render("hello").flattenedText == "hello")
        // the load-bearing case: a tool that returns a JSON document returns
        // that document, not a quoted string containing one.
        #expect(MCPToolResult.render(#"{"a":1}"#).flattenedText == #"{"a":1}"#)
        // an empty return stays empty rather than becoming `""`.
        #expect(MCPToolResult.render("").flattenedText == "")
    }

    @Test("an integer renders as its decimal text")
    func integerRenders() {
        #expect(MCPToolResult.render(3).flattenedText == "3")
        #expect(MCPToolResult.render(-17).flattenedText == "-17")
    }

    @Test("an Encodable value renders as compact, deterministic JSON")
    func encodableRendersAsJSON() throws {
        let value = Coordinates(latitude: 1.5, longitude: -2.25)
        let text = MCPToolResult.render(value).flattenedText

        #expect(!text.contains("\n"))   // compact, not pretty-printed
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        #expect(decoded["latitude"] as? Double == 1.5)
        #expect(decoded["longitude"] as? Double == -2.25)

        // same value, same bytes: a consumer may compare renders.
        #expect(MCPToolResult.render(value).flattenedText == text)
    }

    @Test("a non-Encodable value falls back to its description")
    func opaqueFallsBack() {
        let text = MCPToolResult.render(Opaque(label: "x")).flattenedText
        #expect(text.contains("Opaque"))
        #expect(text.contains("x"))
    }

    @Test("a failed encoding degrades to the description rather than throwing")
    func encodingFailureDegrades() {
        let text = MCPToolResult.render(Unencodable()).flattenedText
        #expect(!text.isEmpty)
        #expect(text.contains("Unencodable"))
    }

    @Test("the rendered result is a text result, not an error")
    func renderedResultsAreNotErrors() {
        #expect(MCPToolResult.render("hello").isError == false)
        #expect(MCPToolResult.render(3).isError == false)
        #expect(MCPToolResult.render(Coordinates(latitude: 0, longitude: 0)).isError == false)
    }
}