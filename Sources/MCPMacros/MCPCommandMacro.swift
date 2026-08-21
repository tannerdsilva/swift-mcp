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
        let isAsyncRun = detectAsyncRun(in: declaration)

        let extensionDecl = generateExtension(
            structName: structName,
            description: description,
            toolName: toolName,
            properties: properties,
            isAsyncRun: isAsyncRun,
            requiredAccess: requiredAccess
        )

        return [extensionDecl]
    }

    // MARK: - Async Run Detection

    /// Detects whether the user's `run()` method is async or sync.
    ///
    /// Looks for a `func run(...)` declaration in the struct's member block
    /// and checks if it has the `async` keyword in its signature.
    static func detectAsyncRun(in declaration: some DeclGroupSyntax) -> Bool {
        for member in declaration.memberBlock.members {
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self) else { continue }
            guard funcDecl.name.text == "run" else { continue }
            // Check for async specifier in the signature
            if let effectSpecifiers = funcDecl.signature.effectSpecifiers {
                return effectSpecifiers.asyncSpecifier != nil
            }
            return false
        }
        return false
    }

    // MARK: - Property Extraction

    static func extractProperties(from declaration: some DeclGroupSyntax) -> [PropertyInfo] {
        var properties: [PropertyInfo] = []

        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            let wrapperKind: WrapperKind? = varDecl.attributes.first { attr in
                guard let name = attr.as(AttributeSyntax.self)?.attributeName.description else { return false }
                return name == "Argument" || name == "Option" || name == "Flag" || name == "OptionGroup"
            }.flatMap { attr in
                guard let name = attr.as(AttributeSyntax.self)?.attributeName.description else { return nil }
                return WrapperKind(rawValue: name)
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

                let attr = varDecl.attributes.first { attr in
                    guard let name = attr.as(AttributeSyntax.self)?.attributeName.description else { return false }
                    return name == "Argument" || name == "Option" || name == "Flag" || name == "OptionGroup"
                }?.as(AttributeSyntax.self)

                let description = attr.flatMap { extractDescription(from: $0) }

                properties.append(PropertyInfo(
                    name: name,
                    type: typeAnnotation,
                    wrapperKind: kind,
                    description: description,
                    hasInitializer: hasInitializer
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
        isAsyncRun: Bool,
        requiredAccess: String? = nil
    ) -> ExtensionDeclSyntax {
        let nameArg = toolName.map { ", name: \"\($0)\"" } ?? ""
        let accessArg = requiredAccess.map { ", requiredAccess: \($0)" } ?? ""

        // Generate the invoke method — calls run() with or without await
        // Note: the outer `try` is already in the template below
        let invokeCall = isAsyncRun ? "await run()" : "run()"

        let mcpMembers = """
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "\(description)"\(nameArg)\(accessArg))
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try \(invokeCall)
                return .text(String(describing: output))
            }
            """

        let cliStruct = buildCLIStruct(structName: structName, properties: properties, isAsyncRun: isAsyncRun)

        let source: DeclSyntax = """
        extension \(raw: structName): MCPTool {
        \(raw: mcpMembers)
        \(raw: cliStruct)
        }
        """

        return source.cast(ExtensionDeclSyntax.self)
    }

    // MARK: - CLI Struct

    static func buildCLIStruct(structName: String, properties: [PropertyInfo], isAsyncRun: Bool) -> String {
        var memberDeclarations: [String] = []
        var initArgs: [String] = []

        for prop in properties {
            switch prop.wrapperKind {
            case .argument:
                let descAttr = prop.description.map { "description: \"\($0)\"" } ?? ""
                let wrapperAttr = descAttr.isEmpty ? "@Argument" : "@Argument(\(descAttr))"
                let defaultValue = prop.hasInitializer ? "" : " = \(defaultValueForType(prop.type))"
                memberDeclarations.append("\(wrapperAttr) var \(prop.name): \(prop.type)\(defaultValue)")
                initArgs.append("\(prop.name): \(prop.name)")

            case .option:
                let descAttr = prop.description.map { "description: \"\($0)\"" } ?? ""
                let wrapperAttr = descAttr.isEmpty ? "@Option" : "@Option(\(descAttr))"
                let defaultValue = prop.hasInitializer ? "" : " = \(defaultValueForType(prop.type))"
                memberDeclarations.append("\(wrapperAttr) var \(prop.name): \(prop.type)\(defaultValue)")
                initArgs.append("\(prop.name): \(prop.name)")

            case .flag:
                let descAttr = prop.description.map { "description: \"\($0)\"" } ?? ""
                let wrapperAttr = descAttr.isEmpty ? "@Flag" : "@Flag(\(descAttr))"
                let defaultValue = prop.hasInitializer ? "" : " = false"
                memberDeclarations.append("\(wrapperAttr) var \(prop.name): \(prop.type)\(defaultValue)")
                initArgs.append("\(prop.name): \(prop.name)")

            case .optionGroup:
                memberDeclarations.append("@OptionGroup var \(prop.name): \(prop.type)")
                initArgs.append("\(prop.name): \(prop.name)")
            }
        }

        let paramArgs = initArgs.joined(separator: ", ")
        let parentInit = properties.isEmpty
            ? "\(structName)()"
            : "\(structName)(\(paramArgs))"

        let members = memberDeclarations.joined(separator: "\n            ")

        // CLI run() mirrors the user's sync/async choice
        // Note: the outer `try` is already in the template below
        let cliRunCall = isAsyncRun ? "await command.run()" : "command.run()"
        let cliRunModifier = isAsyncRun ? "async " : ""

        return """
            #if canImport(ArgumentParser)
            struct CLI: AsyncParsableCommand {
                \(members)

                mutating func run() \(cliRunModifier)throws {
                    let command = \(parentInit)
                    let result = try \(cliRunCall)
                    print(result)
                }
            }
            #endif
            """
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
