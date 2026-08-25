import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Argument Extraction Helpers

func extractStringArgument(from attribute: AttributeSyntax, name: String) -> String? {
    guard let argList = attribute.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for arg in argList {
        guard let label = arg.label, label.text == name else { continue }
        if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
           let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            return segment.content.text
        }
    }
    return nil
}

func extractDescription(from attribute: AttributeSyntax) -> String? {
    if let desc = extractStringArgument(from: attribute, name: "description") {
        return desc
    }
    if let argList = attribute.arguments?.as(LabeledExprListSyntax.self),
       let first = argList.first,
       first.label == nil {
        if let stringLiteral = first.expression.as(StringLiteralExprSyntax.self),
           let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            return segment.content.text
        }
    }
    return nil
}

/// Extracts the `requiredAccess` argument from a macro attribute.
/// The access level is an enum member expression (e.g. `.admin`, `.public`).
func extractAccessArgument(from attribute: AttributeSyntax) -> String? {
    guard let argList = attribute.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for arg in argList {
        guard let label = arg.label, label.text == "requiredAccess" else { continue }
        return trimmed(arg.expression.description)
    }
    return nil
}

// MARK: - Property Info

enum WrapperKind: String {
    case argument = "Argument"
    case option = "Option"
    case flag = "Flag"
    case optionGroup = "OptionGroup"
}

struct PropertyInfo {
    let name: String
    let type: String
    let wrapperKind: WrapperKind
    let description: String?
    let hasInitializer: Bool
    let enumValues: [String]?
    let initializerExpr: String?
}

// MARK: - MCPCommandMacro

public struct MCPCommandMacro: ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroError.message("@MCPCommand can only be applied to structs")
        }

        let structName = structDecl.name.text
        let description = extractStringArgument(from: node, name: "description") ?? ""
        let toolName = extractStringArgument(from: node, name: "name")
        let requiredAccess = extractAccessArgument(from: node)
        let properties = extractProperties(from: declaration)
        let runSignature = try detectRun(in: declaration)

        let extensionDecl = generateExtension(
            structName: structName,
            description: description,
            toolName: toolName,
            properties: properties,
            runSignature: runSignature,
            requiredAccess: requiredAccess
        )

        return [extensionDecl]
    }

    // MARK: - Run Signature Detection

    /// The async/throws shape of the annotated struct's `run()` method.
    struct RunSignature {
        let isAsync: Bool
        let isThrowing: Bool
        /// Whether `run()` returns `Void` (or has no return clause).
        let isVoid: Bool
    }

    /// Detects the signature of the user's `run()` method.
    ///
    /// Requires exactly one `run()` declaration; zero or multiple overloads are
    /// ambiguous and fail loudly instead of mis-detecting the first one found.
    static func detectRun(in declaration: some DeclGroupSyntax) throws -> RunSignature {
        let runFunctions = declaration.memberBlock.members.compactMap { member -> FunctionDeclSyntax? in
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self), funcDecl.name.text == "run" else { return nil }
            return funcDecl
        }

        guard !runFunctions.isEmpty else {
            throw MacroError.message("@MCPCommand requires a run() method on the annotated struct")
        }
        guard runFunctions.count == 1 else {
            throw MacroError.message("@MCPCommand requires exactly one run() method (found \(runFunctions.count))")
        }

        let signature = runFunctions[0].signature
        let isAsync = signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrowing = signature.effectSpecifiers?.throwsClause?.throwsSpecifier != nil
        let isVoid: Bool
        if let returnClause = signature.returnClause {
            let typeName = trimmed(returnClause.type.description)
            isVoid = typeName == "Void" || typeName == "()"
        } else {
            isVoid = true
        }
        return RunSignature(isAsync: isAsync, isThrowing: isThrowing, isVoid: isVoid)
    }

    // MARK: - Property Extraction

    static func extractProperties(from declaration: some DeclGroupSyntax) -> [PropertyInfo] {
        var properties: [PropertyInfo] = []

        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            let wrapperKind: WrapperKind? = varDecl.attributes.first { attr in
                guard let attrSyntax = attr.as(AttributeSyntax.self) else { return false }
                let name = trimmed(attrSyntax.attributeName.description)
                return name == "Argument" || name == "Option" || name == "Flag" || name == "OptionGroup"
            }.flatMap { attr in
                guard let attrSyntax = attr.as(AttributeSyntax.self) else { return nil }
                return WrapperKind(rawValue: trimmed(attrSyntax.attributeName.description))
            }

            guard let kind = wrapperKind else { continue }

            for binding in varDecl.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }

                let typeAnnotation: String
                if let type = binding.typeAnnotation?.type {
                    typeAnnotation = trimmed(type.description)
                } else {
                    typeAnnotation = "String"
                }

                let hasInitializer = binding.initializer != nil
                let initializerExpr = binding.initializer?.value.description

                let attr = varDecl.attributes.first { attr in
                    guard let name = attr.as(AttributeSyntax.self)?.attributeName.description else { return false }
                    return name == "Argument" || name == "Option" || name == "Flag" || name == "OptionGroup"
                }?.as(AttributeSyntax.self)

                let description = attr.flatMap { extractDescription(from: $0) }
                let enumValues = attr.flatMap { extractEnumValues(from: $0) }

                properties.append(PropertyInfo(
                    name: name,
                    type: typeAnnotation,
                    wrapperKind: kind,
                    description: description,
                    hasInitializer: hasInitializer,
                    enumValues: enumValues,
                    initializerExpr: initializerExpr
                ))
            }
        }

        return properties
    }

    // MARK: - Extension Generation

    static func generateExtension(
        structName: String,
        description: String,
        toolName: String?,
        properties: [PropertyInfo],
        runSignature: RunSignature,
        requiredAccess: String? = nil
    ) -> ExtensionDeclSyntax {
        let nameArg = toolName.map { ", name: \"\($0)\"" } ?? ""
        let accessArg = requiredAccess.map { ", requiredAccess: \($0)" } ?? ""

        // Only emit `try`/`await` when the user's run() is actually throwing or
        // async — an unconditional prefix generates warnings for every
        // non-throwing run() (the sync and async non-throwing cases).
        let tryPrefix = runSignature.isThrowing ? "try " : ""
        let awaitPrefix = runSignature.isAsync ? "await " : ""
        let invokeCall = "\(tryPrefix)\(awaitPrefix)run()"

        // A Void return mimics ``FuncTool``: an empty text block instead of
        // String(describing:)'s "()".
        let invokeBody: String
        if runSignature.isVoid {
            invokeBody = """
                        \(invokeCall)
                        return .text("")
            """
        } else {
            invokeBody = """
                        let output = \(invokeCall)
                        return .text(String(describing: output))
            """
        }

        let discoveryExpression = generateDiscoveryExpression(properties: properties)
        let applyBody = generateApplyBody(properties: properties)

        let mcpMembers = """
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "\(description)"\(nameArg)\(accessArg))
            }

            public static func discoverParameters() -> [MCPParameterInfo] {
                \(discoveryExpression)
            }

            public mutating func apply(arguments: [String: Any]) throws {
                \(applyBody)
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
            \(invokeBody)
            }
            """

        let source: DeclSyntax = """
        extension \(raw: structName): MCPTool {
        \(raw: mcpMembers)
        }
        """

        return source.cast(ExtensionDeclSyntax.self)
    }
}

// MARK: - Helpers

func defaultValueForType(_ type: String) -> String {
    switch type {
    case "String": return "\"\""
    case "Int", "Int8", "Int16", "Int32", "Int64": return "0"
    case "UInt", "UInt8", "UInt16", "UInt32", "UInt64": return "0"
    case "Double", "Float", "Float16": return "0.0"
    case "Bool": return "false"
    default: return "\(type)()"
    }
}

// MARK: - Macro Error

enum MacroError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let msg): return msg
        }
    }
}
