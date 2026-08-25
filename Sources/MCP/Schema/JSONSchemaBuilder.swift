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

/// A value representing a JSON Schema type.
///
/// Maps to the JSON Schema Draft 7 type system. Used by JSONSchemaBuilder
/// to produce the `inputSchema` for each tool.
enum JSONSchemaType: String, Sendable {
    case string = "string"
    case integer = "integer"
    case number = "number"
    case boolean = "boolean"
    case array = "array"
    case object = "object"
    case null = "null"
}

/// A builder that generates JSON Schema Draft 7 schemas from MCP tool parameter metadata.
///
/// ``JSONSchemaBuilder`` is used internally by the framework to produce the
/// `inputSchema` field for each tool in the `tools/list` response. It maps
/// Swift type names to JSON Schema types and builds a complete schema object
/// with required fields, descriptions, and property definitions.
///
/// The builder supports the following Swift-to-JSON-Schema type mappings:
/// - ``String`` → `"string"`
/// - ``Int``, ``Int8``–``Int64``, ``UInt``, ``UInt8``–``UInt64`` → `"integer"`
/// - ``Double``, ``Float``, ``Float16``, ``CGFloat`` → `"number"`
/// - ``Bool`` → `"boolean"`
/// - `Array<T>` → `"array"`
/// - Everything else → `"object"`
enum JSONSchemaBuilder: Sendable {

    /// Builds a JSON Schema object for the given tool type.
    ///
    /// - Parameter toolType: The ``MCPTool`` type to generate a schema for.
    /// - Returns: A dictionary representing the JSON Schema object, suitable
    ///   for inclusion in a `tools/list` response.
    ///
    /// The returned dictionary has the following structure:
    /// ```json
    /// {
    ///   "type": "object",
    ///   "properties": {
    ///     "name": { "type": "string", "description": "..." },
    ///     "count": { "type": "integer", "description": "..." }
    ///   },
    ///   "required": ["name"]
    /// }
    /// ```
    static func buildSchema<T: MCPTool>(for toolType: T.Type) -> [String: Any] {
        let params = toolType.discoverParameters()
        return buildObjectSchema(properties: params)
    }

    /// Builds a JSON Schema object schema from an array of parameter info.
    ///
    /// - Parameter properties: The parameter metadata to build the schema from.
    /// - Returns: A dictionary representing the JSON Schema object.
    static func buildObjectSchema(properties: [MCPParameterInfo]) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object"
        ]

        var propertiesSchema: [String: Any] = [:]
        var required: [String] = []

        for param in properties {
            let paramSchema = buildPropertySchema(for: param)
            propertiesSchema[param.name] = paramSchema

            if param.required {
                required.append(param.name)
            }
        }

        schema["properties"] = propertiesSchema

        if !required.isEmpty {
            schema["required"] = required
        }

        return schema
    }

    /// Builds a JSON Schema for a single parameter.
    ///
    /// - Parameter param: The parameter metadata.
    /// - Returns: A dictionary representing the JSON Schema for this parameter.
    static func buildPropertySchema(for param: MCPParameterInfo) -> [String: Any] {
        var schema: [String: Any] = [:]

        let jsonType = mapTypeName(param.typeName)
        schema["type"] = jsonType.rawValue

        if let description = param.description {
            schema["description"] = description
        }

        // Include enum constraints when available
        if let enumValues = param.enumValues, !enumValues.isEmpty {
            schema["enum"] = enumValues
        }

        // Array-typed parameters advertise their element type, so clients can
        // validate the shape of every element.
        if jsonType == .array, let elementTypeName = arrayElementTypeName(from: param.typeName) {
            schema["items"] = ["type": mapTypeName(elementTypeName).rawValue]
        }

        return schema
    }

    /// Extracts the element type name from a normalized array-typed parameter,
    /// unwrapping an optional wrapper first (`Optional<Array<String>>` → `String`).
    private static func arrayElementTypeName(from typeName: String) -> String? {
        var name = typeName
        if name.hasPrefix("Optional<"), name.hasSuffix(">") {
            name = String(name.dropFirst(9).dropLast(1))
        }
        guard name.hasPrefix("Array<"), name.hasSuffix(">") else { return nil }
        return String(name.dropFirst(6).dropLast(1))
    }

    /// Maps a Swift type name to a JSON Schema type.
    ///
    /// - Parameter typeName: The Swift type name (e.g. "String", "Int", "Bool").
    /// - Returns: The corresponding ``JSONSchemaType``.
    public static func mapTypeName(_ typeName: String) -> JSONSchemaType {
        switch typeName {
        case "String":
            return .string
        case "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return .integer
        case "Double", "Float", "Float16", "CGFloat":
            return .number
        case "Bool":
            return .boolean
        case let s where s.hasPrefix("Optional<"):
            let inner = s.dropFirst(9).dropLast(1)
            return mapTypeName(String(inner))
        case let s where s.hasPrefix("Array<"):
            return .array
        default:
            return .object
        }
    }
}
