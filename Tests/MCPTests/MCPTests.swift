import Testing
import Foundation
@testable import MCP

// MARK: - Test Tools

@MCPCommand(description: "Greet someone by name", name: "greet")
struct Greet {
    @Argument(description: "The name of the person to greet")
    var name: String = ""

    @Option(description: "Number of times to repeat")
    var count: Int = 1

    @Flag(description: "Use formal greeting")
    var formal: Bool = false

    func run() async throws -> String {
        let greeting = formal ? "Greetings" : "Hello"
        return Array(repeating: "\(greeting), \(name)!", count: count).joined(separator: "\n")
    }
}

// Hand-written conformer with explicit static discovery — the documented
// migration path for tools that cannot use the macro.
struct Calculator: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Perform arithmetic",
        name: "calculate"
    )

    @Argument(description: "First operand")
    var a: Double = 0.0

    @Argument(description: "Second operand")
    var b: Double = 0.0

    @Argument(description: "Operation")
    var operation: String = "add"

    static func discoverParameters() -> [MCPParameterInfo] {
        [
            MCPParameterInfo(name: "a", description: "First operand", required: true, kind: .argument, typeName: "Double", hasDefault: false, enumValues: nil),
            MCPParameterInfo(name: "b", description: "Second operand", required: true, kind: .argument, typeName: "Double", hasDefault: false, enumValues: nil),
            MCPParameterInfo(name: "operation", description: "Operation", required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil),
        ]
    }

    mutating func apply(arguments: [String: Any]) throws {
        if let value = arguments["a"] { try self._a._setValue(value) }
        if let value = arguments["b"] { try self._b._setValue(value) }
        if let value = arguments["operation"] { try self._operation._setValue(value) }
    }

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        let result: Double
        switch operation.lowercased() {
        case "add", "+": result = a + b
        case "subtract", "-": result = a - b
        case "multiply", "*": result = a * b
        case "divide", "/":
            guard b != 0 else { return .error("Division by zero") }
            result = a / b
        default:
            return .error("Unknown operation: \(operation)")
        }
        return .text("\(a) \(operation) \(b) = \(result)")
    }
}

// MARK: - Async Test Tool

struct AsyncGreet: AsyncMCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Async greeting tool",
        name: "asyncGreet"
    )

    @Argument(description: "The name of the person to greet")
    var name: String = ""

    static func discoverParameters() -> [MCPParameterInfo] {
        [
            MCPParameterInfo(name: "name", description: "The name of the person to greet", required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil),
        ]
    }

    mutating func apply(arguments: [String: Any]) throws {
        if let value = arguments["name"] { try self._name._setValue(value) }
    }

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        // Simulate async work
        let greeting = try await String("Hello, \(name)!")
        return .text(greeting)
    }
}

// A zero-wrapper conformer that reads context.arguments directly.
// Its discovery/apply must fall back to the empty defaults (no reflection).
struct DynamicEchoTool: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "Echoes an argument back",
        name: "echo"
    )

    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text(String(describing: context.arguments["message"] as? String ?? "nil"))
    }
}

// MARK: - Tool Name Tests

@Test("Tool name is derived from type name")
func toolNameDerivation() {
    #expect(Greet.toolName == "greet")
    #expect(Calculator.toolName == "calculate")
}

@Test("Tool name from configuration overrides type name")
func toolNameFromConfig() {
    #expect(Greet.toolName == "greet") // "greet" from config.name
}

// MARK: - Parameter Discovery Tests

@Test("Discover Greet parameters")
func discoverGreetParameters() {
    let params = Greet.discoverParameters()
    #expect(params.count == 3)

    let nameParam = params.first { $0.name == "name" }
    #expect(nameParam != nil)
    #expect(nameParam?.required == true)
    #expect(nameParam?.kind == .argument)
    #expect(nameParam?.typeName == "String")
    #expect(nameParam?.description == "The name of the person to greet")

    let countParam = params.first { $0.name == "count" }
    #expect(countParam != nil)
    #expect(countParam?.required == false)
    #expect(countParam?.kind == .option)
    #expect(countParam?.hasDefault == true)

    let formalParam = params.first { $0.name == "formal" }
    #expect(formalParam != nil)
    #expect(formalParam?.required == false)
    #expect(formalParam?.kind == .flag)
    #expect(formalParam?.typeName == "Bool")
}

@Test("Discover Calculator parameters")
func discoverCalculatorParameters() {
    let params = Calculator.discoverParameters()
    #expect(params.count == 3)
    for param in params {
        #expect(param.required == true)
        #expect(param.kind == .argument)
    }
}

// MARK: - Argument Application Tests

@Test("Apply valid arguments to Greet")
func applyValidArguments() async throws {
    var greet = Greet()
    try greet.apply(arguments: ["name": "World"])
    #expect(greet.name == "World")
    #expect(greet.count == 1) // default
    #expect(greet.formal == false) // default
}

@Test("Apply all arguments to Greet")
func applyAllArguments() async throws {
    var greet = Greet()
    try greet.apply(arguments: ["name": "Alice", "count": 3, "formal": true])
    #expect(greet.name == "Alice")
    #expect(greet.count == 3)
    #expect(greet.formal == true)
}

@Test("Missing required argument throws error")
func missingRequiredArgument() {
    var greet = Greet()
    #expect(throws: MCPError.missingArgument("name")) {
        try greet.apply(arguments: [:])
    }
}

@Test("Type mismatch throws error")
func typeMismatch() {
    var greet = Greet()
    #expect(throws: MCPError.self) {
        try greet.apply(arguments: ["name": 42])
    }
}

// MARK: - Tool Invocation Tests (Sync)

@Test("Greet invocation with default options")
func greetInvocation() async throws {
    var greet = Greet()
    try greet.apply(arguments: ["name": "World"])
    let context = MCPContext(arguments: ["name": "World"])
    let result = try await greet.invoke(context: context)
    #expect(result.isError == false)
    #expect(result.content.count == 1)
    if case .text(let text) = result.content[0] {
        #expect(text == "Hello, World!")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("Greet invocation with formal flag")
func greetFormalInvocation() async throws {
    var greet = Greet()
    try greet.apply(arguments: ["name": "Alice", "formal": true])
    let context = MCPContext(arguments: ["name": "Alice", "formal": true])
    let result = try await greet.invoke(context: context)
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "Greetings, Alice!")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("Greet invocation with repeat count")
func greetRepeatInvocation() async throws {
    var greet = Greet()
    try greet.apply(arguments: ["name": "Bob", "count": 3])
    let context = MCPContext(arguments: ["name": "Bob", "count": 3])
    let result = try await greet.invoke(context: context)
    if case .text(let text) = result.content[0] {
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0 == "Hello, Bob!" })
    } else {
        Issue.record("Expected text content")
    }
}

@Test("Calculator addition")
func calculatorAdd() async throws {
    var calc = Calculator()
    try calc.apply(arguments: ["a": 10.0, "b": 5.0, "operation": "add"])
    let context = MCPContext(arguments: ["a": 10.0, "b": 5.0, "operation": "add"])
    let result = try await calc.invoke(context: context)
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "10.0 add 5.0 = 15.0")
    }
}

@Test("Calculator division by zero")
func calculatorDivideByZero() async throws {
    var calc = Calculator()
    try calc.apply(arguments: ["a": 10.0, "b": 0.0, "operation": "divide"])
    let context = MCPContext(arguments: ["a": 10.0, "b": 0.0, "operation": "divide"])
    let result = try await calc.invoke(context: context)
    #expect(result.isError == true)
}

// MARK: - Async Tool Invocation Tests

@Test("AsyncMCPTool invoke dispatches to async run()")
func asyncToolInvocation() async throws {
    var tool = AsyncGreet()
    try tool.apply(arguments: ["name": "Async World"])
    let context = MCPContext(arguments: ["name": "Async World"])
    let result = try await tool.invoke(context: context)
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "Hello, Async World!")
    }
}

@Test("AsyncMCPTool discovery works")
func asyncToolDiscovery() {
    let params = AsyncGreet.discoverParameters()
    #expect(params.count == 1)
    #expect(params[0].name == "name")
}

// MARK: - JSON Schema Tests

@Test("JSON Schema for Greet tool")
func greetJSONSchema() {
    let schema = JSONSchemaBuilder.buildSchema(for: Greet.self)
    #expect(schema["type"] as? String == "object")

    let properties = schema["properties"] as? [String: Any]
    #expect(properties != nil)
    #expect(properties?["name"] != nil)
    #expect(properties?["count"] != nil)
    #expect(properties?["formal"] != nil)

    let required = schema["required"] as? [String]
    #expect(required == ["name"])

    // Check name property schema
    let nameSchema = properties?["name"] as? [String: Any]
    #expect(nameSchema?["type"] as? String == "string")
    #expect(nameSchema?["description"] as? String == "The name of the person to greet")

    // Check count property schema
    let countSchema = properties?["count"] as? [String: Any]
    #expect(countSchema?["type"] as? String == "integer")

    // Check formal property schema
    let formalSchema = properties?["formal"] as? [String: Any]
    #expect(formalSchema?["type"] as? String == "boolean")
}

// MARK: - MCPContent Tests

@Test("MCPContent text encoding")
func contentTextEncoding() throws {
    let content = MCPContent.text("Hello")
    let encoded = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(MCPContent.self, from: encoded)
    if case .text(let text) = decoded {
        #expect(text == "Hello")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("MCPToolResult text helper")
func toolResultText() {
    let result = MCPToolResult.text("Hello")
    #expect(result.isError == false)
    #expect(result.content.count == 1)
}

@Test("MCPToolResult error helper")
func toolResultError() {
    let result = MCPToolResult.error("Something went wrong")
    #expect(result.isError == true)
    #expect(result.content.count == 1)
}

// MARK: - MCPToolConfiguration Tests

@Test("MCPToolConfiguration defaults")
func toolConfiguration() {
    let config = MCPToolConfiguration(description: "A test tool")
    #expect(config.description == "A test tool")
    #expect(config.name == nil)
}

@Test("MCPToolConfiguration with explicit name")
func toolConfigurationWithName() {
    let config = MCPToolConfiguration(description: "Test", name: "my-tool")
    #expect(config.name == "my-tool")
}

// MARK: - MCPError Tests

@Test("MCPError descriptions")
func errorDescriptions() {
    #expect(MCPError.missingArgument("foo").errorDescription == "Missing required argument: foo")
    #expect(MCPError.typeMismatch(expected: "String", actual: "Int").errorDescription == "Type mismatch: expected String, got Int")
    #expect(MCPError.toolNotFound("bar").errorDescription == "Tool not found: bar")
}

// MARK: - Option Group Tests

// Shared options struct for testing option groups — metadata is generated
// at compile time by @MCPOptionGroup.
@MCPOptionGroup
struct SharedPrintOptions {
    @Option(description: "Enable verbose output")
    var verbose: Bool = false

    @Option(description: "Number of copies")
    var copies: Int = 1
}

@MCPCommand(description: "Print a message", name: "print")
struct PrintTool {
    @Argument(description: "Message to print")
    var message: String = ""

    @OptionGroup
    var printOptions: SharedPrintOptions = SharedPrintOptions()

    func run() async throws -> String {
        let prefix = printOptions.verbose ? "[VERBOSE] " : ""
        return Array(repeating: "\(prefix)\(message)", count: printOptions.copies).joined(separator: "\n")
    }
}

@Test("Zero-wrapper conformer uses empty defaults")
func zeroWrapperDefaults() {
    #expect(DynamicEchoTool.discoverParameters().isEmpty)
    var tool = DynamicEchoTool()
    #expect(throws: Never.self) { try tool.apply(arguments: ["message": "hi"]) }
}

@Test("Option group parameters are flattened in discovery")
func optionGroupDiscovery() {
    let params = PrintTool.discoverParameters()
    // Should include message (argument) + verbose (option) + copies (option)
    #expect(params.count == 3)

    let messageParam = params.first { $0.name == "message" }
    #expect(messageParam != nil)
    #expect(messageParam?.required == true)

    let verboseParam = params.first { $0.name == "verbose" }
    #expect(verboseParam != nil)
    #expect(verboseParam?.required == false)
    #expect(verboseParam?.typeName == "Bool")

    let copiesParam = params.first { $0.name == "copies" }
    #expect(copiesParam != nil)
    #expect(copiesParam?.required == false)
    #expect(copiesParam?.typeName == "Int")
}

@Test("Option group arguments are applied correctly")
func optionGroupApply() async throws {
    var tool = PrintTool()
    try tool.apply(arguments: [
        "message": "Hello",
        "verbose": true,
        "copies": 3
    ])

    #expect(tool.message == "Hello")
    #expect(tool.printOptions.verbose == true)
    #expect(tool.printOptions.copies == 3)
}

@Test("Option group with only parent argument")
func optionGroupPartialApply() async throws {
    var tool = PrintTool()
    try tool.apply(arguments: ["message": "Hi"])

    #expect(tool.message == "Hi")
    #expect(tool.printOptions.verbose == false) // default
    #expect(tool.printOptions.copies == 1) // default
}

@Test("Option group invocation uses flattened params")
func optionGroupInvocation() async throws {
    var tool = PrintTool()
    try tool.apply(arguments: ["message": "Test", "copies": 2])
    let context = MCPContext(arguments: ["message": "Test", "copies": 2])
    let result = try await tool.invoke(context: context)
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0 == "Test" })
    }
}

// MARK: - AnyCodable Tests

@Test("AnyCodable encodes and decodes String")
func anyCodableString() throws {
    let original = AnyCodable("hello")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? String == "hello")
}

@Test("AnyCodable encodes and decodes Int")
func anyCodableInt() throws {
    let original = AnyCodable(42)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? Int == 42)
}

@Test("AnyCodable encodes and decodes Double")
func anyCodableDouble() throws {
    let original = AnyCodable(3.14)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? Double == 3.14)
}

@Test("AnyCodable encodes and decodes Bool")
func anyCodableBool() throws {
    let original = AnyCodable(true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? Bool == true)
}

@Test("AnyCodable encodes and decodes dictionary")
func anyCodableDict() throws {
    let original = AnyCodable(["key": "value"])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    let dict = decoded.value as? [String: String]
    #expect(dict?["key"] == "value")
}

@Test("AnyCodable encodes and decodes array")
func anyCodableArray() throws {
    let original = AnyCodable([1, 2, 3])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    let arr = decoded.value as? [Int]
    #expect(arr == [1, 2, 3])
}

// MARK: - MCPContent Extended Tests

@Test("MCPContent image encoding and decoding")
func contentImageEncoding() throws {
    let content = MCPContent.image(data: "base64data", mimeType: "image/png")
    let encoded = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(MCPContent.self, from: encoded)
    if case .image(let data, let mimeType) = decoded {
        #expect(data == "base64data")
        #expect(mimeType == "image/png")
    } else {
        Issue.record("Expected image content")
    }
}

@Test("MCPContent resource encoding and decoding")
func contentResourceEncoding() throws {
    let content = MCPContent.resource(uri: "file:///path", mimeType: "text/plain", text: "content")
    let encoded = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(MCPContent.self, from: encoded)
    if case .resource(let uri, let mimeType, let text) = decoded {
        #expect(uri == "file:///path")
        #expect(mimeType == "text/plain")
        #expect(text == "content")
    } else {
        Issue.record("Expected resource content")
    }
}

@Test("MCPContent resource with nil mimeType and text")
func contentResourceNilFields() throws {
    let content = MCPContent.resource(uri: "file:///path", mimeType: nil, text: nil)
    let encoded = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(MCPContent.self, from: encoded)
    if case .resource(let uri, let mimeType, let text) = decoded {
        #expect(uri == "file:///path")
        #expect(mimeType == nil)
        #expect(text == nil)
    } else {
        Issue.record("Expected resource content")
    }
}

// MARK: - MCPToolResult Codable Tests

@Test("MCPToolResult encodes and decodes")
func toolResultCodable() throws {
    let original = MCPToolResult.text("Hello")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MCPToolResult.self, from: data)
    #expect(decoded.isError == false)
    #expect(decoded.content.count == 1)
}

@Test("MCPToolResult error encodes and decodes")
func toolResultErrorCodable() throws {
    let original = MCPToolResult.error("Error message")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MCPToolResult.self, from: data)
    #expect(decoded.isError == true)
}

// MARK: - MCPError Extended Tests

@Test("MCPError all descriptions")
func allErrorDescriptions() {
    #expect(MCPError.missingArgument("x").errorDescription == "Missing required argument: x")
    #expect(MCPError.typeMismatch(expected: "A", actual: "B").errorDescription == "Type mismatch: expected A, got B")
    #expect(MCPError.toolNotFound("t").errorDescription == "Tool not found: t")
    #expect(MCPError.jsonRPCError(code: -1, message: "err").errorDescription == "JSON-RPC error -1: err")
    #expect(MCPError.transportError("eof").errorDescription == "Transport error: eof")
    #expect(MCPError.internalError("bug").errorDescription == "Internal error: bug")
}

@Test("MCPError equality")
func errorEquality() {
    #expect(MCPError.missingArgument("x") == MCPError.missingArgument("x"))
    #expect(MCPError.missingArgument("x") != MCPError.missingArgument("y"))
    #expect(MCPError.typeMismatch(expected: "A", actual: "B") == MCPError.typeMismatch(expected: "A", actual: "B"))
}

// MARK: - JSON Schema Extended Tests

@Test("JSON Schema for empty tool")
func emptyToolSchema() {
    struct EmptyTool: MCPTool {
        func invoke(context: MCPContext) async throws -> MCPToolResult { .text("") }
    }
    let schema = JSONSchemaBuilder.buildSchema(for: EmptyTool.self)
    #expect(schema["type"] as? String == "object")
    let properties = schema["properties"] as? [String: Any]
    #expect(properties?.isEmpty == true)
    #expect(schema["required"] == nil)
}

@Test("JSON Schema type mapping")
func jsonSchemaTypeMapping() {
    let stringSchema = JSONSchemaBuilder.buildPropertySchema(for: MCPParameterInfo(name: "s", description: nil, required: true, kind: .argument, typeName: "String", hasDefault: false))
    #expect(stringSchema["type"] as? String == "string")

    let intSchema = JSONSchemaBuilder.buildPropertySchema(for: MCPParameterInfo(name: "i", description: nil, required: true, kind: .argument, typeName: "Int", hasDefault: false))
    #expect(intSchema["type"] as? String == "integer")

    let doubleSchema = JSONSchemaBuilder.buildPropertySchema(for: MCPParameterInfo(name: "d", description: nil, required: true, kind: .argument, typeName: "Double", hasDefault: false))
    #expect(doubleSchema["type"] as? String == "number")

    let boolSchema = JSONSchemaBuilder.buildPropertySchema(for: MCPParameterInfo(name: "b", description: nil, required: true, kind: .argument, typeName: "Bool", hasDefault: false))
    #expect(boolSchema["type"] as? String == "boolean")
}

// MARK: - Tool with Only Optionals

@Test("Tool with only optional parameters")
func toolWithOnlyOptionals() async throws {
    struct OptionalOnlyTool: MCPTool {
        @Option(description: "Optional value")
        var value: String = "default"

        static func discoverParameters() -> [MCPParameterInfo] {
            [MCPParameterInfo(name: "value", description: "Optional value", required: false, kind: .option, typeName: "String", hasDefault: true, enumValues: nil)]
        }

        mutating func apply(arguments: [String: Any]) throws {
            if let value = arguments["value"] { try self._value._setValue(value) }
        }

        func invoke(context: MCPContext) async throws -> MCPToolResult { .text(value) }
    }

    // Should not throw (no required params)
    var tool = OptionalOnlyTool()
    try tool.apply(arguments: [:])
    #expect(tool.value == "default")

    // Should accept provided value
    try tool.apply(arguments: ["value": "custom"])
    #expect(tool.value == "custom")
}

// MARK: - MCPContext Tests

@Test("MCPContext stores arguments")
func mcpContextStorage() {
    let context = MCPContext(arguments: ["key": "value"])
    #expect(context.arguments["key"] as? String == "value")
}

// MARK: - MCPTool Default Configuration

@Test("MCPTool default configuration")
func defaultConfiguration() {
    struct DefaultConfigTool: MCPTool {
        func invoke(context: MCPContext) async throws -> MCPToolResult { .text("") }
    }
    #expect(DefaultConfigTool.configuration.description == "")
    #expect(DefaultConfigTool.configuration.name == nil)
    #expect(DefaultConfigTool.toolName == "defaultConfigTool")
}

// MARK: - MCPParamKind Tests

@Test("MCPParamKind raw values")
func paramKindRawValues() {
    #expect(MCPParamKind.argument.rawValue == "argument")
    #expect(MCPParamKind.option.rawValue == "option")
    #expect(MCPParamKind.flag.rawValue == "flag")
}

@Test("MCPParamKind Codable")
func paramKindCodable() throws {
    let kinds: [MCPParamKind] = [.argument, .option, .flag]
    let data = try JSONEncoder().encode(kinds)
    let decoded = try JSONDecoder().decode([MCPParamKind].self, from: data)
    #expect(decoded == kinds)
}

// MARK: - MCPParameterInfo Tests

@Test("MCPParameterInfo equality")
func parameterInfoEquality() {
    let a = MCPParameterInfo(name: "x", description: "desc", required: true, kind: .argument, typeName: "String", hasDefault: false)
    let b = MCPParameterInfo(name: "x", description: "desc", required: true, kind: .argument, typeName: "String", hasDefault: false)
    let c = MCPParameterInfo(name: "y", description: "desc", required: true, kind: .argument, typeName: "String", hasDefault: false)
    #expect(a == b)
    #expect(a != c)
}

@Test("MCPParameterInfo Codable")
func parameterInfoCodable() throws {
    let original = MCPParameterInfo(name: "test", description: "A test param", required: true, kind: .argument, typeName: "String", hasDefault: false)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MCPParameterInfo.self, from: data)
    #expect(decoded == original)
}

// MARK: - Flag Value Acceptance Tests

@Test("Flag accepts various truthy values")
func flagTruthyValues() throws {
    var flag = Flag()

    try flag._setValue(true as Bool)
    #expect(flag.wrappedValue == true)

    try flag._setValue(1 as Int)
    #expect(flag.wrappedValue == true)

    try flag._setValue("true" as String)
    #expect(flag.wrappedValue == true)

    try flag._setValue("yes" as String)
    #expect(flag.wrappedValue == true)

    try flag._setValue("1" as String)
    #expect(flag.wrappedValue == true)
}

@Test("Flag accepts various falsy values")
func flagFalsyValues() throws {
    var flag = Flag(wrappedValue: true)

    try flag._setValue(false as Bool)
    #expect(flag.wrappedValue == false)

    try flag._setValue(0 as Int)
    #expect(flag.wrappedValue == false)

    try flag._setValue("false" as String)
    #expect(flag.wrappedValue == false)

    try flag._setValue("no" as String)
    #expect(flag.wrappedValue == false)

    try flag._setValue("0" as String)
    #expect(flag.wrappedValue == false)
}

@Test("Flag throws on invalid string")
func flagInvalidString() {
    var flag = Flag()
    #expect(throws: MCPError.self) {
        try flag._setValue("invalid" as String)
    }
}

@Test("Flag throws on unsupported type")
func flagUnsupportedType() {
    var flag = Flag()
    #expect(throws: MCPError.self) {
        try flag._setValue([1, 2, 3])
    }
}

// MARK: - MCPToolResult Content Access

@Test("MCPToolResult content is accessible")
func toolResultContent() {
    let result = MCPToolResult(content: [.text("a"), .text("b")])
    #expect(result.content.count == 2)
    if case .text(let a) = result.content[0] {
        #expect(a == "a")
    }
    if case .text(let b) = result.content[1] {
        #expect(b == "b")
    }
}

// MARK: - ServerAddress Tests

@Test("ServerAddress hostname creates correct value")
func serverAddressHostname() {
    let addr = ServerAddress.hostname("127.0.0.1", port: 8080)
    if case .hostname(let host, let port) = addr.value {
        #expect(host == "127.0.0.1")
        #expect(port == 8080)
    } else {
        Issue.record("Expected hostname address")
    }
}

@Test("ServerAddress unixDomainSocket creates correct value")
func serverAddressUnixSocket() {
    let addr = ServerAddress.unixDomainSocket(path: "/tmp/mcp.sock")
    if case .unixDomainSocket(let path) = addr.value {
        #expect(path == "/tmp/mcp.sock")
    } else {
        Issue.record("Expected unixDomainSocket address")
    }
}

@Test("ServerAddress convenience methods")
func serverAddressConvenience() {
    let v4 = ServerAddress.localhostIPv4(port: 3000)
    if case .hostname(let host, let port) = v4.value {
        #expect(host == "127.0.0.1")
        #expect(port == 3000)
    }

    let v6 = ServerAddress.localhostIPv6(port: 3001)
    if case .hostname(let host, let port) = v6.value {
        #expect(host == "::1")
        #expect(port == 3001)
    }

    let all4 = ServerAddress.allInterfacesIPv4(port: 80)
    if case .hostname(let host, let port) = all4.value {
        #expect(host == "0.0.0.0")
        #expect(port == 80)
    }

    let all6 = ServerAddress.allInterfacesIPv6(port: 443)
    if case .hostname(let host, let port) = all6.value {
        #expect(host == "::")
        #expect(port == 443)
    }
}

@Test("ServerAddress description")
func serverAddressDescription() {
    #expect(ServerAddress.hostname("127.0.0.1", port: 8080).description == "127.0.0.1:8080")
    #expect(ServerAddress.hostname("::1", port: 8080).description == "[::1]:8080")
    #expect(ServerAddress.hostname("::", port: 8080).description == "[::]:8080")
    #expect(ServerAddress.unixDomainSocket(path: "/tmp/mcp.sock").description == "unix:/tmp/mcp.sock")
}

@Test("ServerAddress equality")
func serverAddressEquality() {
    let a = ServerAddress.hostname("127.0.0.1", port: 8080)
    let b = ServerAddress.hostname("127.0.0.1", port: 8080)
    let c = ServerAddress.hostname("0.0.0.0", port: 8080)
    #expect(a == b)
    #expect(a != c)
}

@Test("ServerAddress Sendable conformance")
func serverAddressSendable() {
    // Compile-time check: ServerAddress must be Sendable
    let address = ServerAddress.hostname("127.0.0.1", port: 8080)
    let closure: @Sendable () -> Void = {
        let _ = address
    }
    closure()
}

// MARK: - Mock Transport for Testing

/// A mock transport that records sent messages and provides canned responses.
final class MockTransport: MCPTransport, @unchecked Sendable {
    var receivedMessages: [Data] = []
    var sentMessages: [Data] = []
    var shouldThrowOnStart = false
    var onStart: (@Sendable () async throws -> Void)?
    private var isRunning = false

    func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws {
        if shouldThrowOnStart { throw MCPError.transportError("mock failure") }
        isRunning = true
        try await onStart?()
        for message in receivedMessages {
            if let response = try await handler(message, MCPCallerInfo(sourceAddress: "mock", accessLevel: .admin)) {
                sentMessages.append(response)
            }
        }
        // Keep the transport alive until stop() is called
        while isRunning {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }

    func stop() async throws {
        isRunning = false
    }
}

// MARK: - Server Message Handling Tests

/// Helper: runs a server with the given transport in a background task,
/// waits for message processing, then stops the server.
private func runTestServer(
    transport: MockTransport,
    name: String = "TestServer",
    version: String = "1.0.0",
    @MCPToolBuilder tools: () -> [any MCPTool] = { [] }
) async throws {
    let server = MCPServer(name: name, version: version, transport: transport) {
        for tool in tools() { tool }
    }

    // Run the server in a background task
    let serverTask = Task { try await server.runService() }

    // Give the server a moment to process messages
    try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

    // Stop the server (which stops the transport)
    try await server.stop()
    _ = await serverTask.result
}

@Test("Server responds to initialize request")
func serverInitialize() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ])
    ]

    try await runTestServer(transport: transport)

    #expect(transport.sentMessages.count == 1)
    let response = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    #expect(response?["jsonrpc"] as? String == "2.0")
    #expect(response?["id"] as? Int == 1)

    let result = response?["result"] as? [String: Any]
    #expect(result?["protocolVersion"] as? String == "2025-06-18")
    let serverInfo = result?["serverInfo"] as? [String: Any]
    #expect(serverInfo?["name"] as? String == "TestServer")
}

@Test("Server responds to ping request")
func serverPing() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "ping"
        ])
    ]

    try await runTestServer(transport: transport) { Greet() }

    #expect(transport.sentMessages.count == 2)
    let pingResponse = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    #expect(pingResponse?["id"] as? Int == 2)
    #expect(pingResponse?["result"] != nil)
}

@Test("Server returns tools/list with registered tools")
func serverToolsList() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]
        )
    ]

    try await runTestServer(transport: transport) { Greet(); Calculator() }

    #expect(transport.sentMessages.count == 2)
    let listResponse = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let result = listResponse?["result"] as? [String: Any]
    let tools = result?["tools"] as? [[String: Any]]
    #expect(tools?.count == 2)

    let toolNames = tools?.compactMap { $0["name"] as? String }.sorted()
    #expect(toolNames == ["calculate", "greet"])
}

@Test("Server invokes a tool via tools/call")
func serverToolsCall() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "greet", "arguments": ["name": "World"]]
        ])
    ]

    try await runTestServer(transport: transport) { Greet() }

    #expect(transport.sentMessages.count == 2)
    let callResponse = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let result = callResponse?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    #expect(content?.first?["text"] as? String == "Hello, World!")
}

@Test("Server returns error for unknown tool")
func serverUnknownTool() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "nonexistent", "arguments": [:]]
        ])
    ]

    try await runTestServer(transport: transport) { Greet() }

    #expect(transport.sentMessages.count == 2)
    let errorResponse = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let error = errorResponse?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32602)
    #expect((error?["message"] as? String)?.contains("nonexistent") == true)
}

@Test("Server returns error for unknown method")
func serverUnknownMethod() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "unknown_method"
        ])
    ]

    try await runTestServer(transport: transport)

    #expect(transport.sentMessages.count == 2)
    let errorResponse = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let error = errorResponse?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32601)
}

@Test("Server handles notifications without response")
func serverNotification() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized"
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/cancelled"
        ])
    ]

    try await runTestServer(transport: transport)

    // Notifications should not produce responses
    #expect(transport.sentMessages.count == 1) // only the initialize response
}

@Test("Server registers tools via builder")
func serverBuilderRegistration() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]
        )
    ]

    try await runTestServer(transport: transport) { Greet(); Calculator() }

    #expect(transport.sentMessages.count == 2)
    let listResponse = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let result = listResponse?["result"] as? [String: Any]
    let tools = result?["tools"] as? [[String: Any]]
    #expect(tools?.count == 2)
}

// MARK: - TransportMessageHandler Tests

@Test("TransportMessageHandler processes messages in order")
func transportMessageHandlerOrdering() async throws {
    let actor = TransportMessageHandler(
        handler: { data, _ in
            // Echo back the message
            return data
        },
        caller: MCPCallerInfo(sourceAddress: "test", accessLevel: .admin),
        write: { data in
            // Just verify we can write
            #expect(!data.isEmpty)
        },
        makeError: { _, _ in nil as Data? }
    )

    let message1 = Data("message1".utf8)
    let message2 = Data("message2".utf8)

    await actor.process(message1)
    await actor.process(message2)
}

@Test("TransportMessageHandler respects cancellation")
func transportMessageHandlerCancellation() async throws {
    let count = MutableBox(0)
    let actor = TransportMessageHandler(
        handler: { data, _ in
            count.value += 1
            return data
        },
        caller: MCPCallerInfo(sourceAddress: "test", accessLevel: .admin),
        write: { _ in },
        makeError: { _, _ in nil as Data? }
    )

    await actor.cancel()
    await actor.process(Data("should not process".utf8))

    #expect(count.value == 0)
}

// MARK: - Unregister Tests

@Test("Server can unregister a tool")
func serverUnregister() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1.0"]]
        ]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]
        )
    ]

    let server = MCPServer(name: "TestServer", version: "1.0.0", transport: transport) {
        Greet()
        Calculator()
    }

    // Unregister greet before running
    server.unregister("greet")

    let serverTask = Task { try await server.runService() }
    try await Task.sleep(nanoseconds: 200_000_000)
    try await server.stop()
    _ = await serverTask.result

    #expect(transport.sentMessages.count == 2)
    let listResponse = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let result = listResponse?["result"] as? [String: Any]
    let tools = result?["tools"] as? [[String: Any]]
    #expect(tools?.count == 1)
    #expect(tools?.first?["name"] as? String == "calculate")
}

// MARK: - Enum Values Tests

@Test("Parameter enum values are included in JSON Schema")
func parameterEnumValues() async throws {
    // Create a tool with enum values using manual MCPTool conformance
    struct EnumTool: MCPTool {
        @Argument(description: "Log level", enumValues: ["debug", "info", "warning", "error"])
        var level: String = ""

        static func discoverParameters() -> [MCPParameterInfo] {
            [MCPParameterInfo(name: "level", description: "Log level", required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: ["debug", "info", "warning", "error"])]
        }

        mutating func apply(arguments: [String: Any]) throws {
            if let value = arguments["level"] { try self._level._setValue(value) }
        }

        func run(context: MCPContext) async throws -> MCPToolResult {
            return .text(level)
        }

        static var configuration: MCPToolConfiguration {
            MCPToolConfiguration(description: "Enum test")
        }

        mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
            return try await run(context: context)
        }
    }

    let params = EnumTool.discoverParameters()
    #expect(params.count == 1)
    #expect(params[0].enumValues == ["debug", "info", "warning", "error"])

    let schema = JSONSchemaBuilder.buildSchema(for: EnumTool.self)
    let properties = schema["properties"] as? [String: Any]
    let levelSchema = properties?["level"] as? [String: Any]
    #expect(levelSchema?["enum"] as? [String] == ["debug", "info", "warning", "error"])
}

/// A simple mutable box for use in Sendable closures.
final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
