import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Tool Property Info

/// Information about a `@Tool` property extracted from the struct declaration.
struct ToolPropertyInfo {
    let name: String
    let isDebugOnly: Bool
}

// MARK: - MCPApplicationMacro

/// Generates a `main()` entry point, a `ToolID` enum, and exhaustive dispatch.
///
/// This macro is an attached member macro. It reads the struct's `@Tool`
/// properties and generates:
///
/// 1. A ``MCPToolID``-conforming enum with one case per tool
/// 2. A `callTool(_:arguments:)` method with exhaustive switch dispatch
/// 3. A `static func main()` that creates the server, registers tools, and runs
///
/// Tools marked with `@Tool(available: .debug)` are wrapped in `#if DEBUG`.
/// An `address` parameter generates a ``TCPTransport`` bound to that address.
public struct MCPApplicationMacro: MemberMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroError.message("@MCPApplication can only be applied to structs")
        }

        let structName = structDecl.name.text

        // Extract macro arguments
        let serverName = extractStringArgument(from: node, name: "name") ?? ""
        let serverVersion = extractStringArgument(from: node, name: "version") ?? ""
        let addressArg = extractExpressionArgument(from: node, name: "address")
        let transportArg = extractExpressionArgument(from: node, name: "transport")

        if addressArg != nil && transportArg != nil {
            throw MacroError.message(
                "@MCPApplication: specify either 'address' or 'transport', not both"
            )
        }

        // Find all @Tool properties with their types and availability
        let toolProperties = extractToolProperties(from: declaration)

        // Build the ToolID enum name
        let enumName = "\(structName)_ToolID"

        // Generate all members
        let toolIDEnum = generateToolIDEnum(
            enumName: enumName,
            toolProperties: toolProperties
        )

        let callToolFunc = generateCallTool(
            enumName: enumName,
            toolProperties: toolProperties
        )

        let mainFunc = generateMain(
            structName: structName,
            serverName: serverName,
            serverVersion: serverVersion,
            addressArg: addressArg,
            transportArg: transportArg,
            toolProperties: toolProperties
        )

        return [
            DeclSyntax(stringLiteral: toolIDEnum),
            DeclSyntax(stringLiteral: callToolFunc),
            DeclSyntax(stringLiteral: mainFunc),
        ]
    }

    // MARK: - Address Argument Extraction

    /// Extracts an expression-valued parameter (e.g. `address`, `transport`)
    /// from the macro attribute. Returns the full expression string, or nil.
    static func extractExpressionArgument(from node: AttributeSyntax, name: String) -> String? {
        guard let argList = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for arg in argList {
            guard let label = arg.label, label.text == name else { continue }
            return trimmed(arg.expression.description)
        }
        return nil
    }

    // MARK: - Tool Property Extraction

    /// Extracts property info from `@Tool` properties, including type and availability.
    static func extractToolProperties(from declaration: some DeclGroupSyntax) -> [ToolPropertyInfo] {
        var properties: [ToolPropertyInfo] = []

        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            // Check for @Tool attribute (may be qualified as MCP.Tool)
            let toolAttr = varDecl.attributes.first { attr in
                guard let attrSyntax = attr.as(AttributeSyntax.self) else { return false }
                let name = trimmed(attrSyntax.attributeName.description)
                return name == "Tool" || name.hasSuffix(".Tool")
            }?.as(AttributeSyntax.self)

            guard let attr = toolAttr else { continue }

            for binding in varDecl.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }

                // Check for available: .debug parameter
                let isDebugOnly = extractDebugAvailability(from: attr)

                properties.append(ToolPropertyInfo(
                    name: name,
                    isDebugOnly: isDebugOnly
                ))
            }
        }

        return properties
    }

    /// Checks if the @Tool attribute has `available: .debug`.
    static func extractDebugAvailability(from attribute: AttributeSyntax) -> Bool {
        guard let argList = attribute.arguments?.as(LabeledExprListSyntax.self) else { return false }
        for arg in argList {
            guard let label = arg.label, label.text == "available" else { continue }
            let exprDesc = trimmed(arg.expression.description)
            // Check for ".debug" or "ToolAvailability.debug"
            if exprDesc == ".debug" || exprDesc.hasSuffix(".debug") {
                return true
            }
        }
        return false
    }

    // MARK: - ToolID Enum Generation

    /// Generates a MCPToolID-conforming enum with one case per tool.
    static func generateToolIDEnum(
        enumName: String,
        toolProperties: [ToolPropertyInfo]
    ) -> String {
        let cases = toolProperties.map { prop in
            prop.isDebugOnly ? "    #if DEBUG\n    case \(prop.name)\n    #endif" : "    case \(prop.name)"
        }.joined(separator: "\n")

        return """
        /// Compile-time unique tool identifiers generated by @MCPApplication.
        enum \(enumName): String, MCPToolID {
        \(cases)
        }
        """
    }

    // MARK: - Exhaustive Dispatch Generation

    /// Generates a `callTool` method with exhaustive switch dispatch.
    /// Each branch creates the concrete tool type, applies arguments, and invokes.
    static func generateCallTool(
        enumName: String,
        toolProperties: [ToolPropertyInfo]
    ) -> String {
        let cases = toolProperties.map { prop in
            let open = prop.isDebugOnly ? "#if DEBUG\n        " : ""
            let close = prop.isDebugOnly ? "\n        #endif" : ""
            return """
            \(open)case .\(prop.name):
                    var tool = self.\(prop.name)
                    try tool.apply(arguments: arguments)
                    return try await tool.invoke(context: MCPContext(arguments: arguments))\(close)
            """
        }.joined(separator: "\n")

        return """
        /// Exhaustive dispatch for all registered tools.
        /// Each tool's concrete type is known in its branch — no type erasure.
        func callTool(_ id: \(enumName), arguments: [String: Any]) async throws -> MCPToolResult {
            switch id {
        \(cases)
            }
        }
        """
    }

    // MARK: - Main Function Generation

    /// Generates the `static func main()` body.
    static func generateMain(
        structName: String,
        serverName: String,
        serverVersion: String,
        addressArg: String?,
        transportArg: String?,
        toolProperties: [ToolPropertyInfo]
    ) -> String {
        // Build the server initialization with the requested transport.
        // Debug-only tools are guarded so their registration is compiled out of
        // release builds — the registry, tools/list, and tools/call all feed
        // from this registration list, so an unguarded entry would expose
        // debug tools in production.
        let toolList = toolProperties.map { prop in
            if prop.isDebugOnly {
                return "            #if DEBUG\n            app.\(prop.name)\n            #endif"
            }
            return "            app.\(prop.name)"
        }.joined(separator: "\n")
        let serverInit: String
        if let transport = transportArg {
            serverInit = "let server = MCPServer(name: \"\(serverName)\", version: \"\(serverVersion)\", transport: \(transport)) {\n\(toolList)\n        }"
        } else if let address = addressArg {
            serverInit = "let server = MCPServer(name: \"\(serverName)\", version: \"\(serverVersion)\", address: \(address)) {\n\(toolList)\n        }"
        } else {
            serverInit = "let server = MCPServer(name: \"\(serverName)\", version: \"\(serverVersion)\") {\n\(toolList)\n        }"
        }

        return """
        /// Generated entry point for the MCP server application.
        static func main() async throws {
            let app = \(structName)()
            \(serverInit)
            try await server.runService()
        }
        """
    }
}
