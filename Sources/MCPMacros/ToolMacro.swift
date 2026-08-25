import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - ToolMacro

/// Generates an ``MCPTool``-conforming struct from a static function declaration.
///
/// Apply this macro to a `static` function on a type to automatically generate
/// an MCP tool that wraps the function. The function's parameters become tool
/// parameters:
///
/// - Parameters **without** default values → ``Argument`` (required)
/// - Parameters **with** default values → ``Option`` (optional)
/// - ``Bool`` parameters with default `false` → ``Flag``
///
/// ```swift
/// enum MyTools {
///     @FuncTool(description: "Greet someone by name")
///     static func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
///         let greeting = formal ? "Greetings" : "Hello"
///         return "\(greeting), \(name)!"
///     }
/// }
///
/// let server = MCPServer(name: "demo", version: "1.0.0") {
///     MyTools.greetTool()
/// }
/// ```
///
/// The generated struct is named `{FunctionName}Tool` (e.g., `greetTool`),
/// conforms to ``MCPTool``, and can be registered with an ``MCPServer``.
///
/// ## Scope constraint
///
/// ``FuncTool`` is a *peer* macro that introduces a new type at its attachment
/// scope. Because the compiler does not allow peer macros to introduce
/// arbitrary names at global scope, the annotated function must be a member of
/// a type — and because the generated `run()` calls it unqualified, it must be
/// `static` (instance methods cannot be wrapped).
///
/// ## Return types
///
/// Any return type is supported. The generated `run()` returns the function's
/// declared type and `invoke` renders the value to text via
/// `String(describing:)`, matching ``MCPCommand``. Functions that return
/// ``Swift/Void`` produce an empty text block. Errors thrown by the function
/// surface as JSON-RPC `-32603` errors.
///
/// ## Parameter constraints
///
/// Every parameter must carry a label (no `_`-labeled parameters), and `inout`
/// and variadic parameters are rejected with a diagnostic — these cannot be
/// addressed as JSON-valued MCP arguments.
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

        // A peer macro attaches the generated struct inside the annotated
        // function's enclosing type, and the generated `run()` calls the
        // function unqualified — both rely on the function being a static
        // member. (Global functions are already rejected by the compiler for
        // arbitrary-name peer macros.)
        let isStatic = funcDecl.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        guard isStatic else {
            throw MacroError.message(
                "@FuncTool requires a static function on a type (the generated tool calls it unqualified, so instance methods cannot be wrapped)"
            )
        }

        let returnType = extractReturnType(from: funcDecl)
        let params = try extractParameters(from: funcDecl)
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrowing = funcDecl.signature.effectSpecifiers?.throwsClause?.throwsSpecifier != nil

        let structDecl = generateStruct(
            funcName: funcName,
            returnType: returnType,
            description: description,
            toolName: toolName,
            params: params,
            isAsync: isAsync,
            isThrowing: isThrowing,
            requiredAccess: requiredAccess
        )

        return [structDecl]
    }

    // MARK: - Return Type Extraction

    /// The declared return type of the wrapped function, or `Void` when absent.
    ///
    /// The generated `run()` returns this type; `invoke` renders it to text
    /// via `String(describing:)`, so any return type is supported.
    static func extractReturnType(from funcDecl: FunctionDeclSyntax) -> String {
        guard let returnClause = funcDecl.signature.returnClause else { return "Void" }
        let type = trimmed(returnClause.type.description)
        return type.isEmpty ? "Void" : type
    }

    // MARK: - Parameter Extraction

    struct ParamInfo {
        let name: String
        let type: String
        let hasDefault: Bool
        let isBool: Bool
        let defaultExpr: String?
    }

    static func extractParameters(from funcDecl: FunctionDeclSyntax) throws -> [ParamInfo] {
        var params: [ParamInfo] = []

        for param in funcDecl.signature.parameterClause.parameters {
            let paramName = param.firstName.text

            guard paramName != "_" else {
                let localName = param.secondName?.text ?? "_"
                throw MacroError.message(
                    "@FuncTool cannot wrap the '_'-labeled parameter '\(localName)': every parameter needs a label to be addressable as an MCP argument"
                )
            }
            guard param.ellipsis == nil else {
                throw MacroError.message(
                    "@FuncTool cannot wrap the variadic parameter '\(paramName)': variadic parameters are not supported"
                )
            }

            let typeText = trimmed(param.type.description)
            guard !typeText.hasPrefix("inout ") else {
                throw MacroError.message(
                    "@FuncTool cannot wrap the 'inout' parameter '\(paramName)': inout parameters are not supported"
                )
            }

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
        returnType: String,
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
            callArgs.append("\(param.name): \(param.name)")
        }

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

        // A Void return has no meaningful stringification — produce an empty
        // text block instead of String(describing:)'s "()".
        let isVoid = returnType == "Void"
        let invokeBody: String
        if isVoid {
            invokeBody = """
                        \(tryPrefix)\(awaitPrefix)run()
                        return .text("")
            """
        } else {
            invokeBody = """
                        let output = \(tryPrefix)\(awaitPrefix)run()
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

            public func run() \(asyncModifier)\(throwModifier)-> \(returnType) {
                return \(tryPrefix)\(awaitPrefix)\(callExpr)
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
        \(invokeBody)
            }
        }
        """

        return DeclSyntax(stringLiteral: source)
    }
}
