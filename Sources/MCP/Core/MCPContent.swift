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

/// Content blocks that can be returned from an MCP tool invocation.
///
/// MCP tools return an array of content blocks. The supported types mirror
/// the MCP specification's `ContentBlock` union. Each case represents a
/// different kind of content that can be included in a tool response.
///
/// Usage:
/// ```swift
/// // Return text content
/// return .text("Hello, world!")
///
/// // Return an image
/// return .image(data: base64String, mimeType: "image/png")
///
/// // Return a resource reference
/// return .resource(uri: "file:///path", mimeType: "text/plain", text: "content")
/// ```
public enum MCPContent: Sendable, Codable {
    /// A plain text content block.
    ///
    /// The associated value is the text string to return. This is the most
    /// common content type for tool responses.
    case text(String)

    /// An image content block with base64-encoded data.
    ///
    /// - Parameters:
    ///   - data: The base64-encoded image data.
    ///   - mimeType: The MIME type of the image (e.g. "image/png", "image/jpeg").
    case image(data: String, mimeType: String)

    /// A resource content block (embedded resource reference).
    ///
    /// - Parameters:
    ///   - uri: The URI identifying the resource.
    ///   - mimeType: Optional MIME type of the resource.
    ///   - text: Optional text content of the resource.
    case resource(uri: String, mimeType: String?, text: String?)

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, uri, resource
    }

    /// Encodes this content block to a JSON-RPC compatible format.
    ///
    /// The `resource` case encodes the spec's `EmbeddedResource` shape —
    /// `{ "type": "resource", "resource": { "uri", "mimeType?", "text?" } }`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .resource(let uri, let mimeType, let text):
            try container.encode("resource", forKey: .type)
            var resource = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .resource)
            try resource.encode(uri, forKey: .uri)
            try resource.encodeIfPresent(mimeType, forKey: .mimeType)
            try resource.encodeIfPresent(text, forKey: .text)
        }
    }

    /// Decodes a content block from a JSON-RPC compatible format.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        case "resource":
            let resource = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .resource)
            let uri = try resource.decode(String.self, forKey: .uri)
            let mimeType = try resource.decodeIfPresent(String.self, forKey: .mimeType)
            let text = try resource.decodeIfPresent(String.self, forKey: .text)
            self = .resource(uri: uri, mimeType: mimeType, text: text)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown content type: \(type)"
                )
            )
        }
    }
}

/// The result of a tool invocation.
///
/// ``MCPToolResult`` encapsulates the output of an MCP tool call. It contains
/// an array of ``MCPContent`` blocks and an error flag. Use the static factory
/// methods `text(_:)` and `error(_:)` for common cases.
///
/// ```swift
/// // Return a successful text result
/// return .text("Operation completed")
///
/// // Return an error result
/// return .error("Something went wrong")
/// ```
public struct MCPToolResult: Sendable, Codable {
    /// The content blocks produced by the tool.
    ///
    /// Each block is an ``MCPContent`` value. Tools typically return a single
    /// text block, but can return multiple blocks of different types.
    public var content: [MCPContent]

    /// Whether the tool invocation ended in an error.
    ///
    /// When `true`, the client should treat the result as an error even if
    /// the content contains text. Set this flag for error results.
    public var isError: Bool

    /// Creates a new tool result with the given content.
    ///
    /// - Parameters:
    ///   - content: The content blocks to include in the result.
    ///   - isError: Whether the result represents an error. Defaults to `false`.
    public init(
        content: [MCPContent],
        isError: Bool = false
    ) {
        self.content = content
        self.isError = isError
    }

    /// Creates a successful result with a single text content block.
    ///
    /// - Parameter text: The text to return as the result.
    /// - Returns: An ``MCPToolResult`` with a single `.text` content block.
    ///
    /// This is the most common way to return a result from a tool:
    /// ```swift
    /// return .text("Hello, world!")
    /// ```
    public static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)])
    }

    /// Creates a result from a tool's return value.
    ///
    /// This is what a `@MCPCommand` tool's `run()` return becomes on the wire,
    /// and the compiler picks the overload — a tool author never chooses a
    /// rendering mode:
    ///
    /// - a `String` is the result **verbatim**, never re-quoted, so a tool that
    ///   returns a JSON document returns that document;
    /// - any `Encodable` value becomes **compact canonical JSON**, so a
    ///   structured return is machine-readable instead of a debug description;
    /// - anything else falls back to `String(describing:)`, so a return type
    ///   that cannot encode still answers rather than failing to compile.
    ///
    /// ```swift
    /// return .render("hello")                    // hello
    /// return .render(3)                          // 3
    /// return .render(Stats(lines: 2, words: 3))  // {"lines":2,"words":3}
    /// ```
    public static func render(_ text: String) -> MCPToolResult {
        .text(text)
    }

    /// Renders an `Encodable` return value as compact canonical JSON.
    ///
    /// Canonical rather than merely compact: the encoder is position-based and
    /// a dictionary-shaped value iterates in per-process hash order, so
    /// encoding straight to bytes would give the same value different renders
    /// on different runs. Round-tripping through the canonical wrapper makes
    /// the render a function of the value alone, so a consumer may compare or
    /// hash renders.
    ///
    /// Both steps degrade instead of throwing: a value that cannot encode, or
    /// whose canonical form cannot be produced, renders as its description.
    public static func render<T: Encodable>(_ value: T) -> MCPToolResult {
        guard let bytes = try? QuickJSON.encode(value) else {
            return .text(String(describing: value))
        }
        if let decoded = try? QuickJSON.decode(AnyCodable.self, from: bytes),
           let canonical = try? QuickJSON.encode(CanonicalJSON(decoded.value)) {
            return .text(String(decoding: canonical, as: UTF8.self))
        }
        return .text(String(decoding: bytes, as: UTF8.self))
    }

    /// Renders a return value that is not `Encodable` as its description.
    ///
    /// The least specific overload, so it is chosen only when nothing better
    /// applies.
    public static func render<T>(_ value: T) -> MCPToolResult {
        .text(String(describing: value))
    }

    /// Creates an error result with a message.
    ///
    /// - Parameter message: The error message.
    /// - Returns: An ``MCPToolResult`` with `isError` set to `true`.
    ///
    /// ```swift
    /// return .error("Division by zero")
    /// ```
    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], isError: true)
    }

    /// A single text rendering of the result, for string-consuming adapters
    /// (e.g. a harness `ToolEntry` whose handler returns `String`).
    ///
    /// Concatenates every `.text` block newline-separated; non-text blocks
    /// (images, resources) are summarized by their kind so nothing is silently
    /// dropped. When ``isError`` is `true` the text is prefixed with `error: `
    /// so the consumer can distinguish a failed invocation from success text.
    public var flattenedText: String {
        var parts: [String] = []
        for block in content {
            switch block {
            case .text(let text):
                parts.append(text)
            case .image:
                parts.append("[image content]")
            case .resource(let uri, _, _):
                parts.append("[resource: \(uri)]")
            }
        }
        let text = parts.joined(separator: "\n")
        return isError ? "error: \(text)" : text
    }
}

/// The JSON `null` marker carried by ``AnyCodable``.
///
/// Swift-native replacement for Foundation's `NSNull`: a `null` JSON value is
/// represented as an instance of this value type, so JSON null round-trips
/// without any Foundation symbol in the encoding core. Values that reach
/// ``AnyCodable`` as `null` (e.g. `{"key": null}`) decode to a `JSONNull` and
/// encode back as JSON `null`.
struct JSONNull: Sendable, Hashable {}

/// A type-erased `Codable` value for use in structured content.
///
/// ``AnyCodable`` wraps an arbitrary `Any` value and provides `Codable`
/// conformance by attempting to encode/decode known types (`String`, `Int`,
/// `Double`, `Bool`, arrays, and dictionaries). Unknown types are encoded
/// as their string description. JSON `null` is represented by the internal
/// `JSONNull` marker type.
///
/// This is used internally by the framework for JSON-RPC message serialization
/// where the exact types are not known at compile time.
public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    /// The wrapped value.
    public let value: Any

    /// Creates a new type-erased codable wrapper.
    ///
    /// - Parameter value: Any value to wrap. Must be one of the supported types
    ///   for proper round-trip encoding/decoding.
    public init(_ value: Any) {
        self.value = value
    }

    /// Value equality over the wrapped payloads (dictionaries and arrays
    /// compare structurally; two `JSONNull`s are equal).
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l, r) as (Int, Int): return l == r
        case let (l, r) as (Double, Double): return l == r
        case let (l, r) as (String, String): return l == r
        case let (l, r) as (Bool, Bool): return l == r
        case (_, _) as (JSONNull, JSONNull): return true
        case let (l, r) as ([String: Any], [String: Any]):
            guard l.count == r.count else { return false }
            for (key, lhsValue) in l {
                guard let rhsValue = r[key] else { return false }
                if AnyCodable(lhsValue) != AnyCodable(rhsValue) { return false }
            }
            return true
        case let (l, r) as ([Any], [Any]):
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { AnyCodable($0) == AnyCodable($1) }
        default: return false
        }
    }

    /// Encodes the wrapped value to the given encoder.
    ///
    /// Attempts to encode known types in order: `String`, `Int`, `Double`,
    /// `Bool`, `[String: Any]`, `[Any]`. Falls back to `String(describing:)`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is JSONNull: try container.encodeNil()
        case let v as String: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as [String: Any]: try container.encode(v.mapValues(AnyCodable.init))
        case let v as [Any]: try container.encode(v.map(AnyCodable.init))
        default:
            try container.encode(String(describing: value))
        }
    }

    /// Decodes a value from the given decoder.
    ///
    /// Attempts to decode known types in order: `String`, `Int`, `Double`,
    /// `Bool`, `[String: AnyCodable]`, `[AnyCodable]`. JSON `null` decodes to
    /// a `JSONNull` marker. Falls back to encoding the raw description as a
    /// string to avoid silent data loss.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = JSONNull() }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v.mapValues(\.value) }
        else if let v = try? container.decode([AnyCodable].self) { value = v.map(\.value) }
        else {
            // Preserve the raw data as a description string rather than silently
            // returning an empty dictionary. This ensures no data is lost even
            // when the type is unknown.
            let raw = try container.decode(String.self)
            value = raw
        }
    }
}
