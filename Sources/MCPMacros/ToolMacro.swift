import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - ToolMacro

/// Generates an ``MCPTool``-conforming struct from a function declaration.
///
/// Apply this macro to a function to automatically generate an MCP tool
/// that wraps the function. The function's parameters become tool parameters:
///
/// - Parameters **without** default values → ``Argument`` (required)
/// - Parameters **with** default values → ``Option`` (optional)
/// - ``Bool`` parameters with default `false` → ``Flag``
///
/// ```swift
/// @FuncTool(description: "Greet someone by name")
/// func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
///     let greeting = formal ? "Greetings" : "Hello"
///     return "\(greeting), \(name)!"
/// }
/// ```
///
/// The generated struct is named `{FunctionName}Tool` (e.g., `greetTool`)
/// and conforms to ``MCPTool``. It can be registered with an ``MCPServer``:
///
/// ```swift
/// let server = MCPServer(name: "demo", version: "1.0.0") {
///     greetTool()
/// }
/// ```
public struct ToolMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError.message("@FuncTool can only be applied to functions")
        }

        let funcName = funcDecl.name.text
        let description = extractStringArgument(from: node, name: "description") ?? ""
        let toolName = extractStringArgument(from: node, name: "name")
        let requiredAccess = extractAccessArgument(from: node)

        let params = extractParameters(from: funcDecl)
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrowing = funcDecl.signature.effectSpecifiers?.throwsClause?.throwsSpecifier != nil

        let structDecl = generateStruct(
            funcName: funcName,
            description: description,
            toolName: toolName,
            params: params,
            isAsync: isAsync,
            isThrowing: isThrowing,
            requiredAccess: requiredAccess
        )

        return [structDecl]
    }

    // MARK: - Parameter Extraction

    struct ParamInfo {
        let name: String
        let type: String
        let hasDefault: Bool
        let isBool: Bool
        let defaultExpr: String?
    }

    static func extractParameters(from funcDecl: FunctionDeclSyntax) -> [ParamInfo] {
        var params: [ParamInfo] = []

        for param in funcDecl.signature.parameterClause.parameters {
            let paramName = param.firstName.text
            guard paramName != "_" else { continue }

            let typeText = trimmed(param.type.description)
            let isBool = typeText == "Bool"
            let hasDefault = param.defaultValue != nil
            let defaultExpr = param.defaultValue?.value.description

            params.append(ParamInfo(
                name: paramName,
                type: typeText,
                hasDefault: hasDefault,
                isBool: isBool,
                defaultExpr: defaultExpr
            ))
        }

        return params
    }

    // MARK: - Struct Generation

    static func generateStruct(
        funcName: String,
        description: String,
        toolName: String?,
        params: [ParamInfo],
        isAsync: Bool,
        isThrowing: Bool,
        requiredAccess: String?
    ) -> DeclSyntax {
        let structName = "\(funcName)Tool"
        let nameArg = toolName.map { ", name: \"\($0)\"" } ?? ""
        let accessArg = requiredAccess.map { ", requiredAccess: \($0)" } ?? ""

        // Generate property declarations
        var properties: [String] = []
        var initArgs: [String] = []
        var callArgs: [String] = []

        for param in params {
            let wrapperKind: String
            let defaultValue: String

            if !param.hasDefault {
                wrapperKind = "@Argument"
                defaultValue = " = \(defaultValueForType(param.type))"
            } else if param.isBool {
                wrapperKind = "@Flag"
                defaultValue = " = \(param.defaultExpr ?? "false")"
            } else {
                wrapperKind = "@Option"
                defaultValue = " = \(param.defaultExpr ?? defaultValueForType(param.type))"
            }

            properties.append("    \(wrapperKind) var \(param.name): \(param.type)\(defaultValue)")
            initArgs.append("\(param.name): \(param.name)")
            callArgs.append("\(param.name): \(param.name)")
        }

        let _ = params.isEmpty
            ? "\(structName)()"
            : "\(structName)(\(initArgs.joined(separator: ", ")))"

        let callExpr = "\(funcName)(\(callArgs.joined(separator: ", ")))"

        let propertyInfos = params.map { param in
            let kind: WrapperKind = !param.hasDefault ? .argument : (param.isBool ? .flag : .option)
            return PropertyInfo(
                name: param.name,
                type: param.type,
                wrapperKind: kind,
                description: nil,
                hasInitializer: param.hasDefault,
                enumValues: nil,
                initializerExpr: nil
            )
        }
        let discoveryExpression = generateDiscoveryExpression(properties: propertyInfos)
        let applyBody = generateApplyBody(properties: propertyInfos)

        let asyncModifier = isAsync ? "async " : ""
        let throwModifier = isThrowing ? "throws " : ""
        let tryPrefix = isThrowing ? "try " : ""
        let awaitPrefix = isAsync ? "await " : ""

        let invokeBody: String
        if isAsync || isThrowing {
            invokeBody = """
                    let output = \(tryPrefix)\(awaitPrefix)run()
                    return .text(String(describing: output))
            """
        } else {
            invokeBody = """
                    let output = run()
                    return .text(String(describing: output))
            """
        }

        let propertiesBlock = properties.joined(separator: "\n")

        let source = """
        /// Auto-generated MCP tool for `\(funcName)`.
        public struct \(structName): MCPTool {
        \(propertiesBlock)

            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "\(description)"\(nameArg)\(accessArg))
            }

            public static func discoverParameters() -> [MCPParameterInfo] {
                \(discoveryExpression)
            }

            public mutating func apply(arguments: [String: Any]) throws {
                \(applyBody)
            }

            public func run() \(asyncModifier)\(throwModifier)-> String {
                return \(callExpr)
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
        \(invokeBody)
            }
        }
        """

        return DeclSyntax(stringLiteral: source)
    }
}
