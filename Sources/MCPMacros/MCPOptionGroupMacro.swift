import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - MCPOptionGroupMacro

public struct MCPOptionGroupMacro: ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroError.message("@MCPOptionGroup can only be applied to structs")
        }

        let structName = structDecl.name.text
        let properties = MCPCommandMacro.extractProperties(from: declaration)

        for prop in properties where prop.wrapperKind == .optionGroup {
            throw MacroError.message("nested option groups are not supported: \(prop.name)")
        }

        let discoveryExpression = generateDiscoveryExpression(properties: properties)
        let applyBody = generateApplyBody(properties: properties, includeRequiredCheck: false)

        let members = """
            public static var mcpParameters: [MCPParameterInfo] {
                \(discoveryExpression)
            }

            public mutating func mcpApply(arguments: [String: Any]) throws {
                \(applyBody)
            }
        """

        let source: DeclSyntax = """
        extension \(raw: structName): StaticMCPGroup {
        \(raw: members)
        }
        """

        return [source.cast(ExtensionDeclSyntax.self)]
    }
}
