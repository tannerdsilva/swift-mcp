import SwiftParser
import SwiftSyntax

// MARK: - Shared codegen helpers

// Escapes a value for embedding inside a Swift string literal in generated code.
// Foundation-free: uses only stdlib String/Character operations.
func escapeStringLiteral(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(ch)
        }
    }
    return out
}

// Extracts the `enumValues:` array literal from a wrapper attribute.
func extractEnumValues(from attribute: AttributeSyntax) -> [String]? {
    guard let argList = attribute.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for arg in argList {
        guard let label = arg.label, label.text == "enumValues" else { continue }
        guard let arrayExpr = arg.expression.as(ArrayExprSyntax.self) else { continue }
        var values: [String] = []
        for element in arrayExpr.elements {
            if let stringLiteral = element.expression.as(StringLiteralExprSyntax.self),
               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                values.append(segment.content.text)
            }
        }
        return values.isEmpty ? nil : values
    }
    return nil
}

// Normalizes a Swift type spelling to the canonical form the framework emits.
// Mirrors `String(describing: Value.self)` so schemas are stable regardless of
// whether the user writes shorthand (`[String]`, `Int?`) or long form.
func normalizedTypeName(_ typeName: String) -> String {
    let name = trimmed(typeName)
    if name.hasSuffix("!") || name.hasSuffix("?") {
        return "Optional<\(normalizedTypeName(String(name.dropLast())))>"
    }
    if name.hasPrefix("[") && name.hasSuffix("]") {
        let inner = String(name.dropFirst().dropLast())
        if let colon = inner.firstIndex(of: ":") {
            let key = String(inner[..<colon])
            let value = String(inner[inner.index(after: colon)...])
            return "Dictionary<\(normalizedTypeName(key)), \(normalizedTypeName(value))>"
        }
        return "Array<\(normalizedTypeName(inner))>"
    }
    return name
}

// Builds the MCPParameterInfo constructor expression for a non-group property.
// Returns nil for .optionGroup (callers handle those entries separately).
func parameterInfoExpression(
    name: String,
    typeName: String,
    kind: WrapperKind,
    description: String?,
    enumValues: [String]?,
    defaultValueExpression: String? = nil
) -> String? {
    let kindName: String
    let required: Bool
    let hasDefault: Bool
    switch kind {
    case .argument:
        kindName = ".argument"
        required = true
        hasDefault = false
    case .option:
        kindName = ".option"
        required = false
        hasDefault = true
    case .flag:
        kindName = ".flag"
        required = false
        hasDefault = true
    case .optionGroup:
        return nil
    }

    let typeNameLiteral = kind == .flag ? "\"Bool\"" : "\"\(escapeStringLiteral(normalizedTypeName(typeName)))\""
    let descriptionArg = description.map { "description: \"\(escapeStringLiteral($0))\"" } ?? "description: nil"
    let enumArg = enumValues.map { "enumValues: \($0)" } ?? "enumValues: nil"
    // only optional params (.option/.flag) advertise the default — a required
    // @Argument's initializer is an init value, not an omitted-argument default.
    let defaultArg = (kind == .option || kind == .flag)
        ? (defaultValueExpression.map { "defaultValue: AnyCodable(\($0))" } ?? "")
        : ""

    return "MCPParameterInfo(name: \"\(escapeStringLiteral(name))\", \(descriptionArg), required: \(required), kind: \(kindName), typeName: \(typeNameLiteral), hasDefault: \(hasDefault), \(enumArg)\(defaultArg.isEmpty ? "" : ", " + defaultArg))"
}

// Evaluates a property initializer expression to a Swift literal expression
// that AnyCodable can carry, when the initializer is statically evaluable.
// Only simple integer, float, string, bool, and negated-numeric literals are
// recognized; anything else (enum cases, expressions, member references)
// produces nil so the schema simply omits the `default` hint rather than
// guessing. Parsing through the Swift parser keeps the recognition exact.
func literalDefaultExpression(from expression: String?) -> String? {
    guard let expression else { return nil }
    // The parser wraps a lone literal in an expression statement; unwrap it.
    guard let statement = Parser.parse(source: expression).statements.first,
          let expr = statement.item.as(ExprSyntax.self) else {
        return nil
    }
    if let integer = expr.as(IntegerLiteralExprSyntax.self) {
        return integer.literal.text
    }
    if let float = expr.as(FloatLiteralExprSyntax.self) {
        return float.literal.text
    }
    if let boolean = expr.as(BooleanLiteralExprSyntax.self) {
        return boolean.literal.text
    }
    if let string = expr.as(StringLiteralExprSyntax.self),
       let segment = string.segments.first?.as(StringSegmentSyntax.self) {
        return "\"\(escapeStringLiteral(segment.content.text))\""
    }
    // Negative numeric literals (e.g. `-5`, `-1.5`) parse as prefix operators.
    if let prefix = expr.as(PrefixOperatorExprSyntax.self),
       prefix.operator.text == "-" {
        if let integer = prefix.expression.as(IntegerLiteralExprSyntax.self) {
            return "-\(integer.literal.text)"
        }
        if let float = prefix.expression.as(FloatLiteralExprSyntax.self) {
            return "-\(float.literal.text)"
        }
    }
    // Nil defaults are encoded as `nil` anyway; skip them.
    return nil
}

// Builds the body expression for a generated `discoverParameters()`.
// Non-group properties become single-element array literals; option groups
// flatten their static metadata inline.
func generateDiscoveryExpression(properties: [PropertyInfo]) -> String {
    var parts: [String] = ["[]"]
    for prop in properties {
        if prop.wrapperKind == .optionGroup {
            parts.append("\(prop.type).mcpParameters")
        } else if let expr = parameterInfoExpression(
            name: prop.name,
            typeName: prop.type,
            kind: prop.wrapperKind,
            description: prop.description,
            enumValues: prop.enumValues,
            defaultValueExpression: literalDefaultExpression(from: prop.initializerExpr)
        ) {
            parts.append("[\(expr)]")
        }
    }
    return parts.joined(separator: " + ")
}

// Builds the body for a generated `mutating func apply(arguments:)`.
// `includeRequiredCheck` is false for option-group `mcpApply` bodies: the
// parent tool's generated `apply` owns the missing-required check.
//
// The required-argument check is a direct scan of the request arguments
// against the compile-time parameter metadata; there is no per-application
// accumulator, so the generated code never carries an unused-variable
// warning regardless of parameter shape (required, optional-only, groups,
// or none at all).
func generateApplyBody(properties: [PropertyInfo], includeRequiredCheck: Bool = true) -> String {
    var lines: [String] = []

    for prop in properties {
        switch prop.wrapperKind {
        case .argument, .option, .flag:
            lines.append(#"if let value = arguments["\#(escapeStringLiteral(prop.name))"] {"#)
            lines.append("    try self._\(prop.name)._setValue(value)")
            lines.append("}")
        case .optionGroup:
            lines.append("let groupParamNames = \(prop.type).mcpParameters.map(\\.name)")
            lines.append("if arguments.keys.contains(where: { groupParamNames.contains($0) }) {")
            lines.append("    try self._\(prop.name).mcpApply(arguments: arguments)")
            lines.append("}")
        }
    }

    if includeRequiredCheck {
        lines.append("for param in Self.discoverParameters() where param.required {")
        lines.append("    if arguments[param.name] == nil {")
        lines.append("        throw MCPError.missingArgument(param.name)")
        lines.append("    }")
        lines.append("}")
    }

    return lines.joined(separator: "\n        ")
}
