import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Tool Property Info

/// Information about a `@Tool` property extracted from the struct declaration.
struct ToolPropertyInfo {
    let name: String
    /// The concrete tool type name (e.g. `Greet`) used for static access to
    /// `toolName`, `configuration`, and `discoverParameters()` in the
    /// generated dispatcher surface.
    let typeName: String
    let isDebugOnly: Bool
}

// MARK: - MCPApplicationMacro

/// Generates the `MCPToolDispatcher` surface, a `ToolID` enum, and `main()`.
///
/// This macro is declared as both an attached member macro and an attached
/// extension macro. The member expansion reads the struct's `@Tool`
/// properties and generates, inside the type:
///
/// 1. A ``MCPToolID``-conforming enum with one case per tool
/// 2. A typed `callTool(_:arguments:context:)` method with exhaustive switch
///    dispatch over each tool's **concrete** type
/// 3. The ``MCPToolDispatcher`` requirements — `toolID(named:)`,
///    `requiredAccess(named:)`, `callTool(named:arguments:context:)`, and
///    `toolCatalog(for:)` — all built from static per-tool metadata, so the
///    server routes `tools/list`/`tools/call` with no runtime type erasure
/// 4. A `static func main()` that creates the server with `dispatcher: app`
///
/// The extension expansion adds `: MCPToolDispatcher` conformance; the
/// requirements are satisfied by the member expansion above.
///
/// Tools marked with `@Tool(available: .debug)` are wrapped in `#if DEBUG` in
/// every generated artifact (enum case, dispatch, catalog, access gate), so a
/// release build neither lists nor serves them.
public struct MCPApplicationMacro: MemberMacro, ExtensionMacro {

    // MARK: - Member Expansion

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

        let invokeSwitch = generateInvokeSwitch(
            enumName: enumName,
            toolProperties: toolProperties
        )

        let typedCallTool = generateTypedCallTool(enumName: enumName)

        let toolIDLookup = generateToolIDLookup(
            enumName: enumName,
            toolProperties: toolProperties
        )

        let requiredAccess = generateRequiredAccess(
            enumName: enumName,
            toolProperties: toolProperties
        )

        let stringCallTool = generateStringCallTool(enumName: enumName)

        let toolCatalog = generateToolCatalog(toolProperties: toolProperties)

        let mainFunc = generateMain(
            structName: structName,
            serverName: serverName,
            serverVersion: serverVersion,
            addressArg: addressArg,
            transportArg: transportArg
        )

        return [
            DeclSyntax(stringLiteral: toolIDEnum),
            DeclSyntax(stringLiteral: invokeSwitch),
            DeclSyntax(stringLiteral: typedCallTool),
            DeclSyntax(stringLiteral: toolIDLookup),
            DeclSyntax(stringLiteral: requiredAccess),
            DeclSyntax(stringLiteral: stringCallTool),
            DeclSyntax(stringLiteral: toolCatalog),
            DeclSyntax(stringLiteral: mainFunc),
        ]
    }

    // MARK: - Extension Expansion

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let typeName = trimmed(type.description)
        return [
            try ExtensionDeclSyntax("extension \(raw: typeName): MCPToolDispatcher {}")
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

                // Extract the concrete tool type name from the type annotation
                // or the initializer expression (e.g. "Greet()" -> "Greet").
                let typeName: String
                if let type = binding.typeAnnotation?.type {
                    typeName = trimmed(type.description)
                } else if let initExpr = binding.initializer?.value {
                    typeName = extractTypeFromInitializer(initExpr)
                } else {
                    typeName = "Never"
                }

                // Check for available: .debug parameter
                let isDebugOnly = extractDebugAvailability(from: attr)

                properties.append(ToolPropertyInfo(
                    name: name,
                    typeName: typeName,
                    isDebugOnly: isDebugOnly
                ))
            }
        }

        return properties
    }

    /// Extracts the type name from an initializer expression.
    /// e.g., "Greet()" -> "Greet", "MyModule.Greet()" -> "MyModule.Greet"
    static func extractTypeFromInitializer(_ expr: ExprSyntax) -> String {
        let desc = trimmed(expr.description)
        // Remove trailing parentheses and arguments
        if let parenIndex = desc.firstIndex(of: "(") {
            return String(desc[..<parenIndex])
        }
        return desc
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

    // MARK: - Exhaustive Typed Dispatch

    /// Generates the private, exhaustive `_invokeTool` switch — the single
    /// place every entry point (typed, string-keyed) reaches the tools. Each
    /// branch operates on the tool's concrete configured instance.
    static func generateInvokeSwitch(
        enumName: String,
        toolProperties: [ToolPropertyInfo]
    ) -> String {
        let cases = toolProperties.map { prop -> String in
            let branch =
                "        case .\(prop.name):\n" +
                "            var tool = self.\(prop.name)\n" +
                "            try tool.apply(arguments: arguments)\n" +
                "            return try await tool.invoke(context: context)"
            if prop.isDebugOnly {
                return "#if DEBUG\n" + branch + "\n        #endif"
            }
            return branch
        }.joined(separator: "\n")

        return """
        /// Compile-time-known exhaustive dispatch generated by @MCPApplication.
        /// Selected by every entry point so the tools are reached through
        /// concrete types — no type erasure.
        private func _invokeTool(_ id: \(enumName), arguments: [String: Any], context: MCPContext) async throws -> MCPToolResult {
            switch id {
        \(cases)
            }
        }
        """
    }

    /// Generates the typed, id-keyed entry point (no caller context).
    static func generateTypedCallTool(enumName: String) -> String {
        """
        /// Invokes a tool by its compile-time identifier.
        func callTool(_ id: \(enumName), arguments: [String: Any]) async throws -> MCPToolResult {
            try await _invokeTool(id, arguments: arguments, context: MCPContext(arguments: arguments))
        }
        """
    }

    // MARK: - Dispatcher Surface

    /// Generates the registered-name → ToolID mapping (if-chains over each
    /// tool's static `toolName`, since a tool's registered name comes from its
    /// configuration, not from the property name).
    static func generateToolIDLookup(
        enumName: String,
        toolProperties: [ToolPropertyInfo]
    ) -> String {
        let checks = toolProperties.map { prop -> String in
            let check = "    if name == \(prop.typeName).toolName { return .\(prop.name) }"
            if prop.isDebugOnly {
                return "#if DEBUG\n" + check + "\n    #endif"
            }
            return check
        }.joined(separator: "\n")

        return """
        /// Maps a registered tool name to its compile-time identifier.
        func toolID(named name: String) -> \(enumName)? {
        \(checks)
            return nil
        }
        """
    }

    /// Generates the per-tool access gate backed by each tool's static
    /// configuration, so the server enforces authorization before dispatch.
    static func generateRequiredAccess(
        enumName: String,
        toolProperties: [ToolPropertyInfo]
    ) -> String {
        let cases = toolProperties.map { prop -> String in
            let branch =
                "        case .\(prop.name):\n" +
                "            return \(prop.typeName).configuration.requiredAccess"
            if prop.isDebugOnly {
                return "#if DEBUG\n" + branch + "\n        #endif"
            }
            return branch
        }.joined(separator: "\n")

        return """
        /// The access level a caller must satisfy to invoke the named tool.
        func requiredAccess(named name: String) -> AccessLevel? {
            guard let id = toolID(named: name) else { return nil }
            switch id {
        \(cases)
            }
        }
        """
    }

    /// Generates the string-keyed entry point into the typed dispatch.
    static func generateStringCallTool(enumName: String) -> String {
        """
        /// Invokes the named tool through the exhaustive typed dispatch.
        func callTool(named name: String, arguments: [String: Any], context: MCPContext) async throws -> MCPToolResult? {
            guard let id = toolID(named: name) else { return nil }
            return try await _invokeTool(id, arguments: arguments, context: context)
        }
        """
    }

    /// Generates the `tools/list` catalog, filtered by the caller's access
    /// level, using each tool's static configuration and parameter metadata.
    static func generateToolCatalog(toolProperties: [ToolPropertyInfo]) -> String {
        let entries = toolProperties.map { prop -> String in
            let branch =
                "    if callerAccessLevel >= \(prop.typeName).configuration.requiredAccess {\n" +
                "        catalog.append(MCPToolDescriptor(\n" +
                "            name: \(prop.typeName).toolName,\n" +
                "            description: \(prop.typeName).configuration.description,\n" +
                "            parameters: \(prop.typeName).discoverParameters()\n" +
                "        ))\n" +
                "    }"
            if prop.isDebugOnly {
                return "#if DEBUG\n" + branch + "\n    #endif"
            }
            return branch
        }.joined(separator: "\n")

        return """
        /// The `tools/list` catalog for a caller of the given access level.
        func toolCatalog(for callerAccessLevel: AccessLevel) -> [MCPToolDescriptor] {
            var catalog: [MCPToolDescriptor] = []
        \(entries)
            return catalog
        }
        """
    }

    // MARK: - Main Function Generation

    /// Generates the `static func main()` body.
    ///
    /// The server is constructed with the app as its ``MCPToolDispatcher`` —
    /// no registration loop, no existential tool array. The dispatcher feeds
    /// both `tools/list` and `tools/call`.
    static func generateMain(
        structName: String,
        serverName: String,
        serverVersion: String,
        addressArg: String?,
        transportArg: String?
    ) -> String {
        let serverInit: String
        if let transport = transportArg {
            serverInit = "let server = MCPServer(name: \"\(serverName)\", version: \"\(serverVersion)\", transport: \(transport), dispatcher: app)"
        } else if let address = addressArg {
            serverInit = "let server = MCPServer(name: \"\(serverName)\", version: \"\(serverVersion)\", address: \(address), dispatcher: app)"
        } else {
            serverInit = "let server = MCPServer(name: \"\(serverName)\", version: \"\(serverVersion)\", dispatcher: app)"
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
