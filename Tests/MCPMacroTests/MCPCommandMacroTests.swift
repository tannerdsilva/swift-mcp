import Testing
import SwiftDiagnostics
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
@testable import MCPMacros

// strict macro-expansion asserts. Under Swift Testing the XCTest-backed
// default failure handler is a no-op, so every assertion below passes its
// failureHandler explicitly — otherwise mismatches are silently swallowed.
// Each assert additionally re-expands independently and gates on:
//   - zero macro diagnostics from the expansion context
//   - the emitted source re-parsing with zero syntax diagnostics
private func assertMCPExpansion(
    _ originalSource: String,
    expandedSource expectedExpandedSource: String,
    macros: [String: Macro.Type]
) {
    let specs = macros.mapValues { MacroSpec(type: $0) }
    assertMacroExpansion(
        originalSource,
        expandedSource: expectedExpandedSource,
        macroSpecs: specs,
        failureHandler: { spec in
            Issue.record(Comment(stringLiteral: spec.message))
        }
    )

    // independently expand the same source and verify well-formedness.
    let file = Parser.parse(source: originalSource)
    let context = BasicMacroExpansionContext()
    guard let expanded = try? file.expand(macros: macros, in: context) else {
        Issue.record("expansion raised an error — generated output is not well-formed")
        return
    }
    let expandedText = "\(expanded)"
    for diagnostic in context.diagnostics {
        Issue.record("macro emitted diagnostic: \(diagnostic.message)")
    }
    let reparsed = Parser.parse(source: expandedText)
    if reparsed.hasError {
        Issue.record("generated source does not parse cleanly")
    }
}

// Negative-path assert: expanding must either throw or emit a diagnostic.
// Use for misuse that is supposed to fail loudly.
private func assertMCPExpansionFails(
    _ originalSource: String,
    macros: [String: Macro.Type]
) {
    let file = Parser.parse(source: originalSource)
    let context = BasicMacroExpansionContext()
    do {
        let expanded = try file.expand(macros: macros, in: context)
        let diagnostics = context.diagnostics
        if diagnostics.isEmpty {
            Issue.record("expected expansion to fail, but it produced: \(expanded)")
        }
    } catch {
        // thrown misuse — the expected outcome
    }
}

// MARK: - MCPCommand Macro Tests

@Test("MCPCommand generates MCPTool extension with @Argument")
func mcpCommandWithArgument() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Test command")
        struct TestCommand {
            @Argument(description: "A name")
            var name: String = ""

            func run() async throws -> String {
                return "Hello, \\(name)!"
            }
        }
        """,
        expandedSource: """
        
        struct TestCommand {
            @Argument(description: "A name")
            var name: String = ""
        
            func run() async throws -> String {
                return "Hello, \\(name)!"
            }
        }
        
        extension TestCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Test command")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "name", description: "A name", required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)]
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["name"] {
                        try self._name._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with @Option generates @Option in CLI")
func mcpCommandWithOption() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Test")
        struct TestCommand {
            @Option(description: "Count")
            var count: Int = 1

            func run() async throws -> String { return "c" }
        }
        """,
        expandedSource: """
        
        struct TestCommand {
            @Option(description: "Count")
            var count: Int = 1
        
            func run() async throws -> String { return "c" }
        }
        
        extension TestCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Test")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "count", description: "Count", required: false, kind: .option, typeName: "Int", hasDefault: true, enumValues: nil)]
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["count"] {
                        try self._count._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with @Flag generates @Flag in CLI")
func mcpCommandWithFlag() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Test")
        struct TestCommand {
            @Flag(description: "Verbose mode")
            var verbose: Bool = false

            func run() async throws -> String { return "v" }
        }
        """,
        expandedSource: """
        
        struct TestCommand {
            @Flag(description: "Verbose mode")
            var verbose: Bool = false
        
            func run() async throws -> String { return "v" }
        }
        
        extension TestCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Test")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "verbose", description: "Verbose mode", required: false, kind: .flag, typeName: "Bool", hasDefault: true, enumValues: nil)]
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["verbose"] {
                        try self._verbose._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with explicit tool name")
func mcpCommandWithName() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Test", name: "my-test")
        struct TestCommand {
            @Argument(description: "A value")
            var value: String = ""

            func run() async throws -> String { return value }
        }
        """,
        expandedSource: """
        
        struct TestCommand {
            @Argument(description: "A value")
            var value: String = ""
        
            func run() async throws -> String { return value }
        }
        
        extension TestCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Test", name: "my-test")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "value", description: "A value", required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)]
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["value"] {
                        try self._value._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with mixed wrappers")
func mcpCommandMixed() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Mixed test")
        struct Mixed {
            @Argument(description: "Required input")
            var input: String = ""

            @Option(description: "Optional multiplier")
            var multiplier: Int = 1

            @Flag(description: "Enable verbose output")
            var verbose: Bool = false

            func run() async throws -> String { return input }
        }
        """,
        expandedSource: """
        
        struct Mixed {
            @Argument(description: "Required input")
            var input: String = ""
        
            @Option(description: "Optional multiplier")
            var multiplier: Int = 1
        
            @Flag(description: "Enable verbose output")
            var verbose: Bool = false
        
            func run() async throws -> String { return input }
        }
        
        extension Mixed: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Mixed test")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "input", description: "Required input", required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)] + [MCPParameterInfo(name: "multiplier", description: "Optional multiplier", required: false, kind: .option, typeName: "Int", hasDefault: true, enumValues: nil)] + [MCPParameterInfo(name: "verbose", description: "Enable verbose output", required: false, kind: .flag, typeName: "Bool", hasDefault: true, enumValues: nil)]
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["input"] {
                        try self._input._setValue(value)
                    }
                    if let value = arguments["multiplier"] {
                        try self._multiplier._setValue(value)
                    }
                    if let value = arguments["verbose"] {
                        try self._verbose._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with @OptionGroup passes through in CLI")
func mcpCommandWithOptionGroup() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Command with shared options")
        struct MyCommand {
            @Argument(description: "A required value")
            var value: String = ""

            @OptionGroup
            var shared: SharedOptions = SharedOptions()

            func run() async throws -> String { return value }
        }
        """,
        expandedSource: """
        
        struct MyCommand {
            @Argument(description: "A required value")
            var value: String = ""
        
            @OptionGroup
            var shared: SharedOptions = SharedOptions()
        
            func run() async throws -> String { return value }
        }
        
        extension MyCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Command with shared options")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "value", description: "A required value", required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)] + SharedOptions.mcpParameters
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["value"] {
                        try self._value._setValue(value)
                    }
                    let groupParamNames = SharedOptions.mcpParameters.map(\\.name)
                    if arguments.keys.contains(where: { groupParamNames.contains($0)
                    }) {
                        try self._shared.mcpApply(arguments: arguments)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand propagates enumValues into parameter metadata")
func mcpCommandWithEnumValues() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Levels")
        struct LevelCommand {
            @Option(description: "Log level", enumValues: ["debug", "info", "warning", "error"])
            var level: String = "info"

            func run() async throws -> String { return level }
        }
        """,
        expandedSource: """
        
        struct LevelCommand {
            @Option(description: "Log level", enumValues: ["debug", "info", "warning", "error"])
            var level: String = "info"
        
            func run() async throws -> String { return level }
        }
        
        extension LevelCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Levels")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "level", description: "Log level", required: false, kind: .option, typeName: "String", hasDefault: true, enumValues: ["debug", "info", "warning", "error"])]
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["level"] {
                        try self._level._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPOptionGroup generates StaticMCPGroup conformance")
func mcpOptionGroupMacro() {
    assertMCPExpansion(
        """
        @MCPOptionGroup
        struct SharedOptions {
            @Option(description: "Verbose output")
            var verbose: Bool = false

            @Option(description: "Output path")
            var outputPath: String = "."
        }
        """,
        expandedSource: """
        struct SharedOptions {
            @Option(description: "Verbose output")
            var verbose: Bool = false

            @Option(description: "Output path")
            var outputPath: String = "."
        }

        extension SharedOptions: StaticMCPGroup {
            public static var mcpParameters: [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "verbose", description: "Verbose output", required: false, kind: .option, typeName: "Bool", hasDefault: true, enumValues: nil)] + [MCPParameterInfo(name: "outputPath", description: "Output path", required: false, kind: .option, typeName: "String", hasDefault: true, enumValues: nil)]
            }

            public mutating func mcpApply(arguments: [String: Any]) throws {
                if let value = arguments["verbose"] {
                    try self._verbose._setValue(value)
                }
                if let value = arguments["outputPath"] {
                    try self._outputPath._setValue(value)
                }
            }
        }
        """,
        macros: ["MCPOptionGroup": MCPOptionGroupMacro.self]
    )
}

// MARK: - MCPApplication Macro Tests

@Test("MCPApplication generates ToolID enum and dispatch")
func mcpApplicationToolID() {
    assertMCPExpansion(
        """
        @MCPApplication(name: "test", version: "1.0.0")
        struct MyApp {
            @Tool var greet = Greet()
            @Tool var calculate = Calculate()
        }
        """,
        expandedSource: """
        struct MyApp {
            @Tool var greet = Greet()
            @Tool var calculate = Calculate()

            /// Compile-time unique tool identifiers generated by @MCPApplication.
            enum MyApp_ToolID: String, MCPToolID {
                case greet
                case calculate
            }

            /// Exhaustive dispatch for all registered tools.
            /// Each tool's concrete type is known in its branch — no type erasure.
            func callTool(_ id: MyApp_ToolID, arguments: [String: Any]) async throws -> MCPToolResult {
                switch id {
                case .greet:
                        var tool = Greet()
                        try tool.apply(arguments: arguments)
                        return try await tool.invoke(context: MCPContext(arguments: arguments))
                case .calculate:
                        var tool = Calculate()
                        try tool.apply(arguments: arguments)
                        return try await tool.invoke(context: MCPContext(arguments: arguments))
                }
            }

            /// Generated entry point for the MCP server application.
            static func main() async throws {
                let app = MyApp()
                let server = MCPServer(name: "test", version: "1.0.0") {
                        app.greet
                        app.calculate
                    }
                try await server.runService()
            }
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

@Test("MCPApplication with debug-only tool")
func mcpApplicationDebugTool() {
    assertMCPExpansion(
        """
        @MCPApplication(name: "test", version: "1.0.0")
        struct MyApp {
            @Tool var greet = Greet()
            @Tool(available: .debug) var debug = DebugTool()
        }
        """,
        expandedSource: """
        struct MyApp {
            @Tool var greet = Greet()
            @Tool(available: .debug) var debug = DebugTool()

            /// Compile-time unique tool identifiers generated by @MCPApplication.
            enum MyApp_ToolID: String, MCPToolID {
                case greet
                #if DEBUG
                case debug
                #endif
            }

            /// Exhaustive dispatch for all registered tools.
            /// Each tool's concrete type is known in its branch — no type erasure.
            func callTool(_ id: MyApp_ToolID, arguments: [String: Any]) async throws -> MCPToolResult {
                switch id {
                case .greet:
                        var tool = Greet()
                        try tool.apply(arguments: arguments)
                        return try await tool.invoke(context: MCPContext(arguments: arguments))
                #if DEBUG
                        case .debug:
                        var tool = DebugTool()
                        try tool.apply(arguments: arguments)
                        return try await tool.invoke(context: MCPContext(arguments: arguments))
                        #endif
                }
            }

            /// Generated entry point for the MCP server application.
            static func main() async throws {
                let app = MyApp()
                let server = MCPServer(name: "test", version: "1.0.0") {
                        app.greet
                        app.debug
                    }
                try await server.runService()
            }
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

@Test("MCPApplication with address binding")
func mcpApplicationWithAddress() {
    assertMCPExpansion(
        """
        @MCPApplication(name: "test", version: "1.0.0", address: .localhostIPv4(port: 8080))
        struct MyApp {
            @Tool var greet = Greet()
        }
        """,
        expandedSource: """
        struct MyApp {
            @Tool var greet = Greet()

            /// Compile-time unique tool identifiers generated by @MCPApplication.
            enum MyApp_ToolID: String, MCPToolID {
                case greet
            }

            /// Exhaustive dispatch for all registered tools.
            /// Each tool's concrete type is known in its branch — no type erasure.
            func callTool(_ id: MyApp_ToolID, arguments: [String: Any]) async throws -> MCPToolResult {
                switch id {
                case .greet:
                        var tool = Greet()
                        try tool.apply(arguments: arguments)
                        return try await tool.invoke(context: MCPContext(arguments: arguments))
                }
            }

            /// Generated entry point for the MCP server application.
            static func main() async throws {
                let app = MyApp()
                let server = MCPServer(name: "test", version: "1.0.0", address: .localhostIPv4(port: 8080)) {
                        app.greet
                    }
                try await server.runService()
            }
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

@Test("MCPApplication with custom transport")
func mcpApplicationWithTransport() {
    assertMCPExpansion(
        """
        @MCPApplication(name: "test", version: "1.0.0", transport: MyCustomTransport())
        struct MyApp {
            @Tool var greet = Greet()
        }
        """,
        expandedSource: """
        struct MyApp {
            @Tool var greet = Greet()

            /// Compile-time unique tool identifiers generated by @MCPApplication.
            enum MyApp_ToolID: String, MCPToolID {
                case greet
            }

            /// Exhaustive dispatch for all registered tools.
            /// Each tool's concrete type is known in its branch — no type erasure.
            func callTool(_ id: MyApp_ToolID, arguments: [String: Any]) async throws -> MCPToolResult {
                switch id {
                case .greet:
                        var tool = Greet()
                        try tool.apply(arguments: arguments)
                        return try await tool.invoke(context: MCPContext(arguments: arguments))
                }
            }

            /// Generated entry point for the MCP server application.
            static func main() async throws {
                let app = MyApp()
                let server = MCPServer(name: "test", version: "1.0.0", transport: MyCustomTransport()) {
                        app.greet
                    }
                try await server.runService()
            }
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

@Test("MCPApplication rejects address and transport together")
func mcpApplicationRejectsAddressAndTransport() {
    assertMCPExpansionFails(
        """
        @MCPApplication(name: "test", version: "1.0.0", address: .localhostIPv4(), transport: MyCustomTransport())
        struct MyApp {
            @Tool var greet = Greet()
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

// MARK: - @Tool Macro Tests

@Test("Tool generates struct from simple function")
func toolMacroSimple() {
    assertMCPExpansion(
        """
        enum MyTools {
            @FuncTool(description: "Greet someone")
            static func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
                return "hi"
            }
        }
        """,
        expandedSource: """
        enum MyTools {
            static func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
                return "hi"
            }
        
            /// Auto-generated MCP tool for `greet`.
            public struct greetTool: MCPTool {
                @Argument var name: String = ""
                @Option var count: Int = 1
                @Flag var formal: Bool = false
        
                public static var configuration: MCPToolConfiguration {
                    MCPToolConfiguration(description: "Greet someone")
                }
        
                public static func discoverParameters() -> [MCPParameterInfo] {
                    [] + [MCPParameterInfo(name: "name", description: nil, required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)] + [MCPParameterInfo(name: "count", description: nil, required: false, kind: .option, typeName: "Int", hasDefault: true, enumValues: nil)] + [MCPParameterInfo(name: "formal", description: nil, required: false, kind: .flag, typeName: "Bool", hasDefault: true, enumValues: nil)]
                }
        
                public mutating func apply(arguments: [String: Any]) throws {
                    if let value = arguments["name"] {
                        try self._name._setValue(value)
                    }
                    if let value = arguments["count"] {
                        try self._count._setValue(value)
                    }
                    if let value = arguments["formal"] {
                        try self._formal._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
                }
        
                public func run() -> String {
                    return greet(name: name, count: count, formal: formal)
                }
        
                public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = run()
                        return .text(String(describing: output))
                }
            }
        }
        
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("Tool generates struct with explicit name and access level")
func toolMacroWithOptions() {
    assertMCPExpansion(
        """
        enum AdminTools {
            @FuncTool(description: "Admin operation", name: "admin-op", requiredAccess: .admin)
            static func adminOp(userId: String) -> String {
                return "d"
            }
        }
        """,
        expandedSource: """
        enum AdminTools {
            static func adminOp(userId: String) -> String {
                return "d"
            }
        
            /// Auto-generated MCP tool for `adminOp`.
            public struct adminOpTool: MCPTool {
                @Argument var userId: String = ""
        
                public static var configuration: MCPToolConfiguration {
                    MCPToolConfiguration(description: "Admin operation", name: "admin-op", requiredAccess: .admin)
                }
        
                public static func discoverParameters() -> [MCPParameterInfo] {
                    [] + [MCPParameterInfo(name: "userId", description: nil, required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)]
                }
        
                public mutating func apply(arguments: [String: Any]) throws {
                    if let value = arguments["userId"] {
                        try self._userId._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
                }
        
                public func run() -> String {
                    return adminOp(userId: userId)
                }
        
                public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = run()
                        return .text(String(describing: output))
                }
            }
        }
        
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

// MARK: - Negative / misuse tests

@Test("Tool generates async struct")
func toolMacroAsync() {
    assertMCPExpansion(
        """
        enum Fetcher {
            @FuncTool(description: "Fetch data")
            static func fetchData(url: String) async throws -> String {
                return "x"
            }
        }
        """,
        expandedSource: """
        enum Fetcher {
            static func fetchData(url: String) async throws -> String {
                return "x"
            }
        
            /// Auto-generated MCP tool for `fetchData`.
            public struct fetchDataTool: MCPTool {
                @Argument var url: String = ""
        
                public static var configuration: MCPToolConfiguration {
                    MCPToolConfiguration(description: "Fetch data")
                }
        
                public static func discoverParameters() -> [MCPParameterInfo] {
                    [] + [MCPParameterInfo(name: "url", description: nil, required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)]
                }
        
                public mutating func apply(arguments: [String: Any]) throws {
                    if let value = arguments["url"] {
                        try self._url._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
                }
        
                public func run() async throws -> String {
                    return try await fetchData(url: url)
                }
        
                public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try await run()
                        return .text(String(describing: output))
                }
            }
        }
        
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("Nested option groups are rejected")
func nestedOptionGroupRejected() {
    assertMCPExpansionFails(
        """
        struct Inner {
            @Option var x: Int = 1
        }
        @MCPOptionGroup
        struct Outer {
            @OptionGroup var inner: Inner
        }
        """,
        macros: ["MCPOptionGroup": MCPOptionGroupMacro.self]
    )
}

@Test("MCPCommand on a non-struct is rejected")
func mcpCommandOnEnumRejected() {
    assertMCPExpansionFails(
        """
        @MCPCommand(description: "Bad")
        enum BadCommand {
            case a
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPOptionGroup on a non-struct is rejected")
func mcpOptionGroupOnClassRejected() {
    assertMCPExpansionFails(
        """
        @MCPOptionGroup
        class BadGroup {
            @Option var x: Int = 1
        }
        """,
        macros: ["MCPOptionGroup": MCPOptionGroupMacro.self]
    )
}

@Test("FuncTool on a non-function is rejected")
func funcToolOnNonFunctionRejected() {
    assertMCPExpansionFails(
        """
        @FuncTool(description: "Bad")
        struct NotAFunction {}
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

// MARK: - Edge-case expansion fixtures

@Test("MCPCommand with no parameters emits empty discovery")
func mcpCommandEmpty() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Empty")
        struct EmptyCommand {
            func run() -> String { return "x" }
        }
        """,
        expandedSource: """
        
        struct EmptyCommand {
            func run() -> String { return "x" }
        }
        
        extension EmptyCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Empty")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                []
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

// MARK: - F3/F4/F5 regression fixtures

@Test("MCPCommand sync non-throwing run() emits no try")
func mcpCommandSyncNonThrowing() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Sync")
        struct SyncCommand {
            func run() -> String { return "x" }
        }
        """,
        expandedSource: """
        
        struct SyncCommand {
            func run() -> String { return "x" }
        }
        
        extension SyncCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Sync")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                []
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}


@Test("MCPCommand async non-throwing run() emits await without try")
func mcpCommandAsyncNonThrowing() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Async")
        struct AsyncCommand {
            func run() async -> String { return "x" }
        }
        """,
        expandedSource: """
        
        struct AsyncCommand {
            func run() async -> String { return "x" }
        }
        
        extension AsyncCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Async")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                []
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = await run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand sync throwing run() emits try without await")
func mcpCommandSyncThrowing() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Throwing")
        struct ThrowingCommand {
            func run() throws -> String { return "x" }
        }
        """,
        expandedSource: """
        
        struct ThrowingCommand {
            func run() throws -> String { return "x" }
        }
        
        extension ThrowingCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Throwing")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                []
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = try run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with only optional parameters emits no setParams accumulator")
func mcpCommandOptionalOnlyHasNoSetParams() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "Optional only")
        struct OptionalOnlyCommand {
            @Option var count: Int = 1
            @Flag var verbose: Bool = false
            func run() -> String { return "x" }
        }
        """,
        expandedSource: """
        
        struct OptionalOnlyCommand {
            @Option var count: Int = 1
            @Flag var verbose: Bool = false
            func run() -> String { return "x" }
        }
        
        extension OptionalOnlyCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Optional only")
            }
        
            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "count", description: nil, required: false, kind: .option, typeName: "Int", hasDefault: true, enumValues: nil)] + [MCPParameterInfo(name: "verbose", description: nil, required: false, kind: .flag, typeName: "Bool", hasDefault: true, enumValues: nil)]
            }
        
            public mutating func apply(arguments: [String: Any]) throws {
                if let value = arguments["count"] {
                        try self._count._setValue(value)
                    }
                    if let value = arguments["verbose"] {
                        try self._verbose._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }
        
            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand without a member run() expands to a plain call (extension-provided run())")
func mcpCommandNoMemberRunFallsBack() {
    assertMCPExpansion(
        """
        @MCPCommand(description: "NoRun")
        struct NoRunCommand {
            var x: Int = 1
        }
        """,
        expandedSource: """
        struct NoRunCommand {
            var x: Int = 1
        }

        extension NoRunCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "NoRun")
            }

            public static func discoverParameters() -> [MCPParameterInfo] {
                []
            }

            public mutating func apply(arguments: [String: Any]) throws {
                for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = run()
                        return .text(String(describing: output))
            }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with multiple run() overloads is rejected")
func mcpCommandMultipleRunRejected() {
    assertMCPExpansionFails(
        """
        @MCPCommand(description: "Two Runs")
        struct TwoRunCommand {
            func run() -> String { return "a" }
            func run(x: Int) -> String { return "b" }
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("FuncTool supports a non-String return type")
func funcToolIntReturn() {
    assertMCPExpansion(
        """
        enum CalcTools {
            @FuncTool(description: "Add")
            static func add(a: Int, b: Int) -> Int {
                return a + b
            }
        }
        """,
        expandedSource: """
        enum CalcTools {
            static func add(a: Int, b: Int) -> Int {
                return a + b
            }
        
            /// Auto-generated MCP tool for `add`.
            public struct addTool: MCPTool {
                @Argument var a: Int = 0
                @Argument var b: Int = 0
        
                public static var configuration: MCPToolConfiguration {
                    MCPToolConfiguration(description: "Add")
                }
        
                public static func discoverParameters() -> [MCPParameterInfo] {
                    [] + [MCPParameterInfo(name: "a", description: nil, required: true, kind: .argument, typeName: "Int", hasDefault: false, enumValues: nil)] + [MCPParameterInfo(name: "b", description: nil, required: true, kind: .argument, typeName: "Int", hasDefault: false, enumValues: nil)]
                }
        
                public mutating func apply(arguments: [String: Any]) throws {
                    if let value = arguments["a"] {
                        try self._a._setValue(value)
                    }
                    if let value = arguments["b"] {
                        try self._b._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
                }
        
                public func run() -> Int {
                    return add(a: a, b: b)
                }
        
                public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        let output = run()
                        return .text(String(describing: output))
                }
            }
        }
        
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("FuncTool with a Void return produces an empty text block")
func funcToolVoidReturn() {
    assertMCPExpansion(
        """
        enum NotifyTools {
            @FuncTool(description: "Notify")
            static func notify(message: String) -> Void {
                print(message)
            }
        }
        """,
        expandedSource: """
        enum NotifyTools {
            static func notify(message: String) -> Void {
                print(message)
            }
        
            /// Auto-generated MCP tool for `notify`.
            public struct notifyTool: MCPTool {
                @Argument var message: String = ""
        
                public static var configuration: MCPToolConfiguration {
                    MCPToolConfiguration(description: "Notify")
                }
        
                public static func discoverParameters() -> [MCPParameterInfo] {
                    [] + [MCPParameterInfo(name: "message", description: nil, required: true, kind: .argument, typeName: "String", hasDefault: false, enumValues: nil)]
                }
        
                public mutating func apply(arguments: [String: Any]) throws {
                    if let value = arguments["message"] {
                        try self._message._setValue(value)
                    }
                    for param in Self.discoverParameters() where param.required {
                        if arguments[param.name] == nil {
                            throw MCPError.missingArgument(param.name)
                        }
                    }
                }
        
                public func run() -> Void {
                    return notify(message: message)
                }
        
                public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                        run()
                        return .text("")
                }
            }
        }
        
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("FuncTool on a non-static instance method is rejected")
func funcToolInstanceMethodRejected() {
    assertMCPExpansionFails(
        """
        final class BadToolHost {
            @FuncTool(description: "Bad")
            func f(x: Int) -> String { return "x" }
        }
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("FuncTool rejects underscore-labeled parameters")
func funcToolUnderscoreParamRejected() {
    assertMCPExpansionFails(
        """
        enum BadToolNamespace {
            @FuncTool(description: "Bad")
            static func f(_ x: Int) -> String { return "x" }
        }
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("FuncTool rejects inout parameters")
func funcToolInoutParamRejected() {
    assertMCPExpansionFails(
        """
        enum BadToolNamespace {
            @FuncTool(description: "Bad")
            static func f(x: inout Int) -> String { return "x" }
        }
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("FuncTool rejects variadic parameters")
func funcToolVariadicParamRejected() {
    assertMCPExpansionFails(
        """
        enum BadToolNamespace {
            @FuncTool(description: "Bad")
            static func f(x: Int...) -> String { return "x" }
        }
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}
