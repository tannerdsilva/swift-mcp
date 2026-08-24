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

import Foundation

// MARK: - JSON-RPC Types

/// A JSON-RPC request.
struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID
    let method: String
    let params: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    init(id: JSONRPCID, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decode(JSONRPCID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent([String: AnyCodable].self, forKey: .params)
    }
}

/// A JSON-RPC response (success).
struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result
    }

    init(id: JSONRPCID, result: Any?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result.map { AnyCodable($0) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decode(JSONRPCID.self, forKey: .id)
        result = try container.decodeIfPresent(AnyCodable.self, forKey: .result)
    }
}

/// A JSON-RPC error response.
struct JSONRPCErrorResponse: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID
    let error: JSONRPCErrorBody

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, error
    }

    init(id: JSONRPCID, code: Int, message: String, data: Any? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = JSONRPCErrorBody(code: code, message: message, data: data.map { AnyCodable($0) })
    }
}

struct JSONRPCErrorBody: Codable, Sendable {
    let code: Int
    let message: String
    let data: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A JSON-RPC notification (no ID).
struct JSONRPCNotification: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params
    }

    init(method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC request ID.
enum JSONRPCID: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC ID must be a string or integer"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

// MARK: - MCP Protocol Methods

/// The MCP protocol methods related to tools.
enum MCPMethod: String, Sendable {
    case initialize = "initialize"
    case ping = "ping"
    case toolsList = "tools/list"
    case toolsCall = "tools/call"
    case resourcesList = "resources/list"
    case resourcesRead = "resources/read"
    case promptsList = "prompts/list"
    case promptsGet = "prompts/get"
    case initialized = "notifications/initialized"
    case cancelled = "notifications/cancelled"
}

// MARK: - MCP Tool Protocol Types

/// A tool definition as returned by `tools/list`.
struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }

    init(name: String, description: String?, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema.mapValues { AnyCodable($0) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        var schemaContainer = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .inputSchema)
        for (key, value) in inputSchema {
            try schemaContainer.encode(value, forKey: DynamicCodingKey(key))
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        let schemaContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .inputSchema)
        var schema: [String: AnyCodable] = [:]
        for key in schemaContainer.allKeys {
            schema[key.stringValue] = try schemaContainer.decode(AnyCodable.self, forKey: key)
        }
        inputSchema = schema
    }
}

/// Dynamic coding key for arbitrary-keyed containers.
struct DynamicCodingKey: CodingKey, Sendable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

// MARK: - MCP Protocol Messages

/// The `initialize` request parameters.
struct InitializeParams: Codable, Sendable {
    let protocolVersion: String
    let capabilities: ClientCapabilities
    let clientInfo: ImplementationInfo

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocolVersion"
        case capabilities, clientInfo
    }
}

struct ClientCapabilities: Codable, Sendable {
    let tools: [String: AnyCodable]?
    let resources: [String: AnyCodable]?
    let prompts: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case tools, resources, prompts
    }

    init(tools: Bool = false, resources: Bool = false, prompts: Bool = false) {
        self.tools = tools ? [:] : nil
        self.resources = resources ? [:] : nil
        self.prompts = prompts ? [:] : nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(resources, forKey: .resources)
        try container.encodeIfPresent(prompts, forKey: .prompts)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decodeIfPresent([String: AnyCodable].self, forKey: .tools)
        resources = try container.decodeIfPresent([String: AnyCodable].self, forKey: .resources)
        prompts = try container.decodeIfPresent([String: AnyCodable].self, forKey: .prompts)
    }
}

struct ImplementationInfo: Codable, Sendable {
    let name: String
    let version: String
}

/// The `initialize` result.
struct InitializeResult: Codable, Sendable {
    let protocolVersion: String
    let capabilities: ServerCapabilities
    let serverInfo: ImplementationInfo
}

struct ServerCapabilities: Codable, Sendable {
    let tools: [String: AnyCodable]?
    let resources: [String: AnyCodable]?
    let prompts: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case tools, resources, prompts
    }

    init(tools: Bool = false, resources: Bool = false, prompts: Bool = false) {
        self.tools = tools ? [:] : nil
        self.resources = resources ? [:] : nil
        self.prompts = prompts ? [:] : nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(resources, forKey: .resources)
        try container.encodeIfPresent(prompts, forKey: .prompts)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decodeIfPresent([String: AnyCodable].self, forKey: .tools)
        resources = try container.decodeIfPresent([String: AnyCodable].self, forKey: .resources)
        prompts = try container.decodeIfPresent([String: AnyCodable].self, forKey: .prompts)
    }
}
