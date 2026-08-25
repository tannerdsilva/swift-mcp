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

// MARK: - Macro Edge Fixtures (compiled + runtime)

@MCPCommand(description: "Empty command")
struct EmptyCommand {
    func run() async throws -> String { "done" }
}

@MCPCommand(description: "Group-only command")
struct GroupOnlyCommand {
    @OptionGroup
    var options: SharedPrintOptions = SharedPrintOptions()

    func run() async throws -> String { options.verbose ? "v" : "" }
}

@MCPCommand(description: "Varied types")
struct VariedTypesCommand {
    @Argument(description: "A name")
    var name: String = ""

    @Option(description: "A count")
    var count: Int = 1

    @Option(description: "A ratio")
    var ratio: Double = 0.5

    @Flag(description: "Enabled")
    var enabled: Bool = false

    @Option(description: "Tags")
    var tags: [String] = []

    @Option(description: "Optional level")
    var level: String? = nil

    func run() async throws -> String { name }
}

@MCPApplication(name: "app-server", version: "1.0.0")
struct AppServer {
    @Tool var greet = Greet()
    @Tool var calculate = Calculator()
}

@Test("MCPCommand with zero parameters advertises none")
func emptyCommandDefaults() async throws {
    #expect(EmptyCommand.discoverParameters().isEmpty)
    var tool = EmptyCommand()
    try tool.apply(arguments: ["unexpected": "x"])
    let context = MCPContext(arguments: [:])
    let result = try await tool.invoke(context: context)
    #expect(result.isError == false)
}

@Test("Group-only tool flattens group parameters")
func groupOnlyToolDiscovery() {
    let params = GroupOnlyCommand.discoverParameters()
    #expect(params.count == 2)
    #expect(params.first { $0.name == "verbose" } != nil)
    #expect(params.first { $0.name == "copies" } != nil)
}

@Test("Shorthand types are normalized and mapped in schema")
func shorthandTypeNormalization() {
    let params = VariedTypesCommand.discoverParameters()

    let tags = params.first { $0.name == "tags" }
    #expect(tags?.typeName == "Array<String>")

    let level = params.first { $0.name == "level" }
    #expect(level?.typeName == "Optional<String>")

    let schema = JSONSchemaBuilder.buildSchema(for: VariedTypesCommand.self)
    let properties = schema["properties"] as? [String: Any]

    let tagsSchema = properties?["tags"] as? [String: Any]
    #expect(tagsSchema?["type"] as? String == "array")

    // Optional-typed parameter metadata is emitted; a JSON value decodes into
    // `String?` via the wrapper's Codable fallback.
    #expect(properties?["level"] != nil)
}

@Test("Varied-types injection round-trips")
func variedTypesInjection() async throws {
    var tool = VariedTypesCommand()
    try tool.apply(arguments: [
        "name": "n",
        "count": 7,
        "ratio": 1.5,
        "enabled": true,
        "tags": ["a", "b"],
    ])
    #expect(tool.name == "n")
    #expect(tool.count == 7)
    #expect(tool.ratio == 1.5)
    #expect(tool.enabled == true)
    #expect(tool.tags == ["a", "b"])
    #expect(tool.level == nil) // not provided, optional stays nil

    let context = MCPContext(arguments: [:])
    let result = try await tool.invoke(context: context)
    #expect(result.isError == false)
}

@Test("MCPApplication compiles and dispatches through generated callTool")
func mcpApplicationDispatch() async throws {
    let app = AppServer()
    let greetResult = try await app.callTool(.greet, arguments: ["name": "Skeptic"])
    #expect(greetResult.isError == false)
    if case .text(let text) = greetResult.content[0] {
        #expect(text == "Hello, Skeptic!")
    } else {
        Issue.record("Expected text content")
    }

    let calcResult = try await app.callTool(.calculate, arguments: ["a": 4.0, "b": 2.0, "operation": "multiply"])
    #expect(calcResult.isError == false)
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

// MARK: - Termination & Protocol Path Tests

@MCPCommand(description: "Numeric coercion probe")
struct NumericProbe {
    @Option(description: "ratio") var ratio: Double = 0
    @Option(description: "i8") var i8: Int8 = 0
    @Option(description: "i32") var i32: Int32 = 0
    @Option(description: "count") var count: Int = 0
    func run() async throws -> String { "\(ratio) \(i8) \(i32) \(count)" }
}

/// A transport that finishes on its own after dispatching queued messages,
/// simulating a clean client EOF on the stdio pipe.
final class EOFMockTransport: MCPTransport, @unchecked Sendable {
    var receivedMessages: [Data] = []
    var sentMessages: [Data] = []

    func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws {
        for message in receivedMessages {
            if let response = try await handler(message, MCPCallerInfo(sourceAddress: "eof", accessLevel: .admin)) {
                sentMessages.append(response)
            }
        }
        // Never stopped externally: the transport finishing is the EOF event.
        return
    }

    func stop() async throws {}
}

@Test("Server returns cleanly when the transport completes on its own (EOF)")
func serverReturnsCleanlyOnTransportEOF() async throws {
    let transport = EOFMockTransport()
    let server = MCPServer(name: "TestServer", version: "1.0.0", transport: transport) { Greet() }
    // Regression guard for F1: before the fix this threw
    // ServiceGroupError.serviceFinishedUnexpectedly (crash in real processes).
    try await server.runService()
    #expect(transport.sentMessages.isEmpty)
}

@Test("Server returns cleanly when stopped externally")
func serverReturnsCleanlyWhenStopped() async throws {
    let transport = MockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
    ]
    let server = MCPServer(name: "TestServer", version: "1.0.0", transport: transport) { Greet() }

    let task = Task { try await server.runService() }
    try await Task.sleep(nanoseconds: 300_000_000)
    try await server.stop()

    let result = await task.result
    #expect(throws: Never.self) { try result.get() }
}

@Test("Server echoes string request IDs")
func serverEchoesStringIDs() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "abc", "method": "ping"]),
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "xyz", "method": "tools/list"])
    ]
    let server = MCPServer(name: "TestServer", version: "1.0.0", transport: transport) { Greet() }
    try await server.runService()

    #expect(transport.sentMessages.count == 2)
    let ping = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    #expect(ping?["id"] as? String == "abc")
    #expect(ping?["result"] != nil)
    let list = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    #expect(list?["id"] as? String == "xyz")
}

@Test("Server returns a parse error for a malformed frame")
func serverParseError() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [Data("this is not json".utf8)]
    let server = MCPServer(name: "TestServer", version: "1.0.0", transport: transport) { Greet() }
    try await server.runService()

    #expect(transport.sentMessages.count == 1)
    let response = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    let error = response?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32700)
}

@Test("Integer JSON values satisfy Double and fixed-width parameters")
func numericCoercionIntToWider() throws {
    var tool = NumericProbe()
    try tool.apply(arguments: ["ratio": 1, "i8": -7, "i32": 70000, "count": 9])
    #expect(tool.ratio == 1.0)
    #expect(tool.i8 == -7)
    #expect(tool.i32 == 70000)
    #expect(tool.count == 9)
}

@Test("Whole Double JSON values satisfy Int parameters; fractional ones are rejected")
func numericCoercionWholeDoubleOnly() throws {
    var tool = NumericProbe()
    try tool.apply(arguments: ["count": 3.0])
    #expect(tool.count == 3)

    #expect(throws: MCPError.self) {
        try tool.apply(arguments: ["count": 3.5])
    }
}

@Test("AnyCodable round-trips JSON null")
func anyCodableNullRoundTrip() throws {
    let data = try JSONEncoder().encode(AnyCodable(NSNull()))
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value is NSNull)
}

@Test("Null argument values produce a type mismatch, not a parse error")
func serverNullArgumentIsTypeMismatch() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "greet", "arguments": ["name": NSNull()]]
        ])
    ]
    let server = MCPServer(name: "TestServer", version: "1.0.0", transport: transport) { Greet() }
    try await server.runService()

    #expect(transport.sentMessages.count == 1)
    let response = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    let error = response?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32603)
}

// MARK: - F3/F4/F5 Compiled Integration Fixtures

enum MathTools {
    @FuncTool(description: "Add integers")
    static func addInts(a: Int, b: Int) -> Int { a + b }
}

struct Point: CustomStringConvertible {
    let x: Int
    let y: Int
    var description: String { "Point(x: \(x), y: \(y))" }
}

enum GeomTools {
    @FuncTool(description: "Make point")
    static func makePoint(x: Int, y: Int) -> Point { Point(x: x, y: y) }
}

enum SideEffectTools {
    @FuncTool(description: "Notify")
    static func notifyToDo(message: String) -> Void { _ = message }
}

enum AsyncTools {
    @FuncTool(description: "Async add")
    static func asyncAdd(a: Int, b: Int) async throws -> Int { a + b }
}

enum ThrowTools {
    @FuncTool(description: "Failing tool")
    static func failing(x: Int) throws -> String {
        if x < 0 { throw MCPError.internalError("negative input") }
        return "ok \(x)"
    }
}

@Test("FuncTool wraps a function returning Int (was a hard compile error)")
func funcToolIntInvocation() async throws {
    var tool = MathTools.addIntsTool()
    try tool.apply(arguments: ["a": 2, "b": 3])
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "5")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("FuncTool wraps a function returning a custom type")
func funcToolCustomReturnInvocation() async throws {
    var tool = GeomTools.makePointTool()
    try tool.apply(arguments: ["x": 1, "y": 2])
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "Point(x: 1, y: 2)")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("FuncTool wraps a Void-returning function as an empty text block")
func funcToolVoidInvocation() async throws {
    var tool = SideEffectTools.notifyToDoTool()
    try tool.apply(arguments: ["message": "hi"])
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("FuncTool wraps an async throwing function")
func funcToolAsyncThrowingInvocation() async throws {
    var tool = AsyncTools.asyncAddTool()
    try tool.apply(arguments: ["a": 4, "b": 5])
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "9")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("FuncTool propagates thrown errors")
func funcToolThrownErrorPropagation() async throws {
    var tool = ThrowTools.failingTool()
    try tool.apply(arguments: ["x": -1])
    do {
        _ = try await tool.invoke(context: MCPContext(arguments: [:]))
        Issue.record("Expected the tool's thrown error to propagate")
    } catch MCPError.internalError {
        // expected: the wrapped function threw
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@MCPCommand(description: "Sync no throw")
struct SyncNoThrowCommand {
    @Option(description: "n") var n: Int = 1
    func run() -> String { "sync \(n)" }
}

@MCPCommand(description: "Async no throw")
struct AsyncNoThrowCommand {
    func run() async -> String { "async done" }
}

@MCPCommand(description: "Sync throwing")
struct SyncThrowingCommand {
    func run() throws -> String {
        throw MCPError.internalError("boom")
    }
}

@Test("MCPCommand sync non-throwing run() compiles and invokes")
func mcpCommandSyncNonThrowingInvocation() async throws {
    var tool = SyncNoThrowCommand()
    try tool.apply(arguments: ["n": 2])
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "sync 2")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("MCPCommand async non-throwing run() compiles and invokes")
func mcpCommandAsyncNonThrowingInvocation() async throws {
    var tool = AsyncNoThrowCommand()
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "async done")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("MCPCommand sync throwing run() propagates errors")
func mcpCommandSyncThrowingInvocation() async throws {
    var tool = SyncThrowingCommand()
    do {
        _ = try await tool.invoke(context: MCPContext(arguments: [:]))
        Issue.record("Expected the command's thrown error to propagate")
    } catch MCPError.internalError {
        // expected: run() threw
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

// MARK: - Transport End-to-End Tests

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A self-contained stdio pair over injected pipes, so the transport's EOF and
/// shutdown paths are exercised in-process instead of via a subprocess.
final class StdioPair {
    let transport: StdioTransport
    let inputWrite: FileHandle
    let outputRead: FileHandle
    let outputWrite: FileHandle

    init() {
        let input = Pipe()
        let output = Pipe()
        transport = StdioTransport(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        inputWrite = input.fileHandleForWriting
        outputRead = output.fileHandleForReading
        outputWrite = output.fileHandleForWriting
    }
}

/// A minimal blocking TCP client used to drive the TCP transport end-to-end.
private enum RawSocketClient {
    static func request(_ payload: String, port: Int) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPError.transportError("socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw MCPError.transportError("connect() failed: \(String(cString: strerror(errno)))")
        }

        // Bound the reads so a broken server fails the test instead of hanging it.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        _ = payload.withCString { send(fd, $0, strlen($0), 0) }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let readCount = recv(fd, &buffer, buffer.count, 0)
        guard readCount > 0 else {
            throw MCPError.transportError("recv() failed: \(String(cString: strerror(errno)))")
        }
        return String(decoding: buffer[0..<readCount], as: UTF8.self)
    }
}

@Test("Stdio transport exchanges messages and exits cleanly on client EOF")
func stdioTransportExchangeAndEOF() async throws {
    let pair = StdioPair()
    let server = MCPServer(name: "stdio-test", version: "1.0.0", transport: pair.transport) { Greet() }

    let payload = """
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"probe","version":"1"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/list"}
    """ + "\n"
    try pair.inputWrite.write(contentsOf: Data(payload.utf8))
    // Clean EOF — before the F1 fix this ended in ServiceGroupError + SIGTRAP.
    try pair.inputWrite.close()

    try await server.runService()

    try pair.outputWrite.close()
    let output = try pair.outputRead.readToEnd() ?? Data()
    let text = String(decoding: output, as: UTF8.self)
    #expect(text.contains("\"id\":1"))
    #expect(text.contains("\"serverInfo\""))
    #expect(text.contains("\"tools\""))
    #expect(text.contains("\"greet\""))
}

@Test("Stdio transport stops cleanly via server stop()")
func stdioTransportStopsCleanly() async throws {
    let pair = StdioPair()
    let server = MCPServer(name: "stdio-test", version: "1.0.0", transport: pair.transport) { Greet() }

    let task = Task { try await server.runService() }
    try await Task.sleep(nanoseconds: 200_000_000)
    try await server.stop()

    let result = await task.result
    #expect(throws: Never.self) { try result.get() }

    try pair.outputWrite.close()
    _ = try? pair.outputRead.readToEnd()
}

@Test("TCP transport serves requests over a real socket and stops cleanly")
func tcpTransportEndToEnd() async throws {
    let transport = TCPTransport(address: .hostname("127.0.0.1", port: 0))
    let server = MCPServer(name: "tcp-test", version: "1.0.0", transport: transport) { Greet() }

    let serverTask = Task { try await server.runService() }

    var port: Int?
    for _ in 0..<50 {
        if let bound = transport.boundPort {
            port = bound
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let port else {
        Issue.record("TCP server never reported a bound port")
        try? await server.stop()
        _ = await serverTask.result
        return
    }

    let initialize = try RawSocketClient.request(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"clientInfo\":{\"name\":\"probe\",\"version\":\"1\"}}}\n",
        port: port
    )
    #expect(initialize.contains("\"serverInfo\""))
    #expect(initialize.contains("\"id\":1"))

    let call = try RawSocketClient.request(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\",\"arguments\":{\"name\":\"TCP\"}}}\n",
        port: port
    )
    #expect(call.contains("\"Hello, TCP!\""))

    try await server.stop()
    let result = await serverTask.result
    #expect(throws: Never.self) { try result.get() }
}

// MARK: - Default Access Resolver Tests

@Test("Default TCP access resolver grants IPv4 and IPv6 loopback")
func defaultAccessResolverLoopback() {
    // Canonical NIO remote-address spellings (verified format with scheme prefix).
    #expect(TCPTransport.defaultAccessResolver("[IPv4]127.0.0.1:49152") == .admin)
    #expect(TCPTransport.defaultAccessResolver("[IPv6]::1:49152") == .admin)
    #expect(TCPTransport.defaultAccessResolver("[IPv6]::ffff:127.0.0.1:49152") == .admin)
    #expect(TCPTransport.defaultAccessResolver("[IPv4]192.168.1.5:1234") == .public)
    #expect(TCPTransport.defaultAccessResolver("[IPv6]fd00::1:49152") == .public)
    // Robustness spellings (bare / bracket-without-scheme) are also accepted.
    #expect(TCPTransport.defaultAccessResolver("127.0.0.1:49152") == .admin)
    #expect(TCPTransport.defaultAccessResolver("::1:49152") == .admin)
    #expect(TCPTransport.defaultAccessResolver("[::1]:49152") == .admin)
    #expect(TCPTransport.defaultAccessResolver("192.168.1.5:1234") == .public)
    #expect(TCPTransport.defaultAccessResolver("10.0.0.4:443") == .public)
}

// MARK: - Registry Fix Tests

@Test("unregister removes instance-registered tools")
func unregisterRemovesInstanceTool() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "greet", "arguments": ["name": "x"]]
        ]),
    ]
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport)
    server.registerInstance("greet", instance: Greet())
    server.unregister("greet")

    try await server.runService()

    #expect(transport.sentMessages.count == 2)
    let list = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    #expect(tools?.isEmpty == true)

    let call = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let error = call?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32602)
}

@Test("Instance-registered tool is invoked through tools/call")
func instanceRegisteredToolInvocation() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "greet", "arguments": ["name": "Inst"]]
        ]),
    ]
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport)
    server.registerInstance("greet", instance: Greet())

    try await server.runService()

    #expect(transport.sentMessages.count == 1)
    let response = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]]
    #expect(content?.first?["text"] as? String == "Hello, Inst!")
}

@Test("Registry stays consistent under concurrent register/unregister")
func registryConcurrentStress() async throws {
    let transport = RunUntilStoppedTransport()
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport) { Greet() }
    server.register(Greet())

    let serverTask = Task { try await server.runService() }
    try await Task.sleep(nanoseconds: 100_000_000)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for taskIndex in 0..<4 {
            group.addTask {
                for iteration in 0..<250 {
                    let name = "transient_\(taskIndex)_\(iteration)"
                    server.registerInstance(name, instance: Greet())
                    server.unregister(name)
                }
            }
        }
        try await group.waitForAll()
    }

    try await server.stop()
    let result = await serverTask.result
    #expect(throws: Never.self) { try result.get() }
}

/// A transport that keeps running until stopped, for registry stress tests.
final class RunUntilStoppedTransport: MCPTransport, @unchecked Sendable {
    private var isRunning = false

    func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws {
        isRunning = true
        while isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func stop() async throws {
        isRunning = false
    }
}

// MARK: - Resource Content Shape Tests

struct ResourceTool: MCPTool {
    static let configuration = MCPToolConfiguration(description: "resource tool")
    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .init(content: [.resource(uri: "file:///x", mimeType: nil, text: nil)], isError: false)
    }
}

@Test("MCPContent resource encodes the spec's nested EmbeddedResource shape")
func resourceContentSpecShape() throws {
    let result = MCPToolResult(content: [.resource(uri: "file:///x", mimeType: "text/plain", text: "hi")], isError: false)
    let data = try JSONEncoder().encode(result)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let content = json?["content"] as? [[String: Any]]
    let block = content?.first
    #expect(block?["type"] as? String == "resource")
    #expect(block?["uri"] == nil)
    let resource = block?["resource"] as? [String: Any]
    #expect(resource?["uri"] as? String == "file:///x")
    #expect(resource?["mimeType"] as? String == "text/plain")
    #expect(resource?["text"] as? String == "hi")
}

@Test("tools/call returns spec-nested resource content over the wire")
func toolsCallResourceWireShape() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "resourceTool", "arguments": [:]]
        ]),
    ]
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport)
    server.register(ResourceTool())

    try await server.runService()

    #expect(transport.sentMessages.count == 1)
    let response = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]]
    let block = content?.first
    #expect(block?["type"] as? String == "resource")
    let resource = block?["resource"] as? [String: Any]
    #expect(resource?["uri"] as? String == "file:///x")
}

@Test("MCPContent resource decodes the spec-nested shape back")
func resourceContentSpecDecode() throws {
    let payload = """
    {"type":"resource","resource":{"uri":"file:///y","mimeType":"application/json","text":"{}"}}
    """
    let data = Data(payload.utf8)
    let decoded = try JSONDecoder().decode(MCPContent.self, from: data)
    if case .resource(let uri, let mimeType, let text) = decoded {
        #expect(uri == "file:///y")
        #expect(mimeType == "application/json")
        #expect(text == "{}")
    } else {
        Issue.record("Expected a resource content block")
    }
}

// MARK: - Codable Parameter Injection Tests

enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

struct Point2D: Codable, Sendable, Equatable {
    let x: Int
    let y: Int
}

@MCPCommand(description: "Codable parameter probe")
struct CodableProbe {
    @Option(description: "level") var level: LogLevel = .debug
    @Option(description: "origin") var origin: Point2D = Point2D(x: 0, y: 0)
    @Option(description: "opt") var optionalName: String? = nil
    func run() async throws -> String { "\(level) \(origin.x),\(origin.y) \(optionalName ?? "none")" }
}

@Test("Custom Codable enum parameters decode from JSON strings")
func codableEnumParameterInjection() throws {
    var tool = CodableProbe()
    try tool.apply(arguments: ["level": "info"])
    #expect(tool.level == .info)
}

@Test("Custom Codable struct parameters decode from JSON objects")
func codableStructParameterInjection() throws {
    var tool = CodableProbe()
    try tool.apply(arguments: ["origin": ["x": 3, "y": 4]])
    #expect(tool.origin == Point2D(x: 3, y: 4))
}

@Test("Optional parameters clear on JSON null and set on JSON string")
func codableOptionalParameterInjection() throws {
    var tool = CodableProbe()
    try tool.apply(arguments: ["optionalName": "hello"])
    #expect(tool.optionalName == "hello")

    try tool.apply(arguments: ["optionalName": NSNull()])
    #expect(tool.optionalName == nil)
}

@MCPCommand(description: "Void side effect")
struct VoidSideEffectCommand {
    func run() { /* side effect only */ }
}

@Test("MCPCommand with a Void run() yields an empty text block")
func mcpCommandVoidRunInvocation() async throws {
    var tool = VoidSideEffectCommand()
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "")
    } else {
        Issue.record("Expected text content")
    }
}

// MARK: - Skeptic probe: fractional JSON-RPC ids

@Test("Fractional JSON-RPC request ids are echoed (spec: ids may be any Number)")
func fractionalRequestIDIsEchoed() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1.5, "method": "ping"])
    ]
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport)

    try await server.runService()

    print("[probe] fractional-id sent messages: \(transport.sentMessages.count)")
    if let data = transport.sentMessages.first {
        print("[probe] fractional-id response: \(String(decoding: data, as: UTF8.self))")
    }
    // JSON-RPC 2.0: request ids are String, Number (including fractions), or null.
    // A request with a fractional id must receive a response echoing that id.
    #expect(transport.sentMessages.count == 1)
    guard let data = transport.sentMessages.first else { return }
    let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(response?["id"] as? Double == 1.5)
    #expect(response?["result"] != nil)
}

// MARK: - Skeptic probe: instance-tool access enforcement

/// A transport that delivers all messages to the handler with a `.public` caller.
final class PublicCallerTransport: MCPTransport, @unchecked Sendable {
    var receivedMessages: [Data] = []
    var sentMessages: [Data] = []

    func start(handler: @Sendable @escaping (Data, MCPCallerInfo) async throws -> Data?) async throws {
        for message in receivedMessages {
            if let response = try await handler(message, MCPCallerInfo(sourceAddress: "public-probe", accessLevel: .public)) {
                sentMessages.append(response)
            }
        }
    }

    func stop() async throws {}
}

@Test("Instance-registered admin tool is hidden from and denied to .public callers")
func instanceToolAccessEnforcement() async throws {
    let transport = PublicCallerTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]),
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "adminInstance", "arguments": [:]]
        ]),
    ]
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport)
    server.registerInstance("adminInstance", instance: AdminInstanceTool())

    try await server.runService()

    print("[probe] instance-access messages: \(transport.sentMessages.count)")
    for data in transport.sentMessages {
        print("[probe]   \(String(decoding: data, as: UTF8.self))")
    }
    guard transport.sentMessages.count == 2 else { return }

    let list = try JSONSerialization.jsonObject(with: transport.sentMessages[0]) as? [String: Any]
    let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    #expect(tools?.isEmpty == true)

    let call = try JSONSerialization.jsonObject(with: transport.sentMessages[1]) as? [String: Any]
    let error = call?["error"] as? [String: Any]
    #expect(error?["code"] as? Int == -32000)
}

struct AdminInstanceTool: MCPTool {
    static let configuration = MCPToolConfiguration(
        description: "admin-only instance tool",
        requiredAccess: .admin
    )
    func invoke(context: MCPContext) async throws -> MCPToolResult {
        .text("admin secret")
    }
}

// MARK: - Skeptic findings: extension run(), builder array literal, string-id round trip

@MCPCommand(description: "Extension-run probe")
struct ExtRunTool {
    @Option(description: "n") var n: Int = 1
}

extension ExtRunTool {
    func run() -> String { "ext-\(n)" }
}

@Test("MCPCommand with an extension-provided run() compiles and invokes")
func extensionProvidedRunWorks() async throws {
    var tool = ExtRunTool()
    try tool.apply(arguments: ["n": 7])
    let result = try await tool.invoke(context: MCPContext(arguments: [:]))
    #expect(result.isError == false)
    if case .text(let text) = result.content[0] {
        #expect(text == "ext-7")
    } else {
        Issue.record("Expected text content")
    }
}

@Test("Empty builder closure registers no tools")
func emptyBuilderClosureWorks() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]),
    ]
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport, tools: { [] })
    try await server.runService()

    guard let data = transport.sentMessages.first else {
        Issue.record("expected a tools/list response")
        return
    }
    let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    #expect(tools?.isEmpty == true)
}

@Test("Array parameters advertise their element type in JSON Schema")
func arrayParameterSchemaItems() {
    let schema = JSONSchemaBuilder.buildSchema(for: VariedTypesCommand.self)
    let properties = schema["properties"] as? [String: Any]
    let tags = properties?["tags"] as? [String: Any]
    #expect(tags?["type"] as? String == "array")
    let items = tags?["items"] as? [String: Any]
    #expect(items?["type"] as? String == "string")
}

@Test("Invalid JSON-RPC request id types get a -32600 Invalid Request response, not silence")
func invalidIDTypesGetErrorResponse() async throws {
    let transport = EOFMockTransport()
    transport.receivedMessages = [
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": true, "method": "ping"]),
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": ["bad"], "method": "ping"]),
    ]
    let server = MCPServer(name: "T", version: "1.0.0", transport: transport)

    try await server.runService()

    #expect(transport.sentMessages.count == 2)
    for data in transport.sentMessages {
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = response?["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32600)
    }
}
