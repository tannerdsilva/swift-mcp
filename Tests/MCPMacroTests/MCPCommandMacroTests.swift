import Testing
import SwiftSyntaxMacrosTestSupport
@testable import MCPMacros

// MARK: - MCPCommand Macro Tests

@Test("MCPCommand generates MCPTool extension with @Argument")
func mcpCommandWithArgument() {
    assertMacroExpansion(
        """
        @MCPCommand(description: "Test command")
        struct TestCommand {
            @Argument(description: "A name")
            var name: String = ""

            func run() async throws -> String {
                return "Hello, \\\\(name)!"
            }
        }
        """,
        expandedSource: """
        struct TestCommand {
            @Argument(description: "A name")
            var name: String = ""

            func run() async throws -> String {
                return "Hello, \\\\(name)!"
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
                var setParams = Set<String>()
                if let value = arguments["name"] {
                    try self._name._setValue(value)
                    setParams.insert("name")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
                        throw MCPError.missingArgument(param.name)
                    }
                }
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try await run()
                return .text(String(describing: output))
            }

            #if canImport(ArgumentParser)
            struct CLI: AsyncParsableCommand {
                @Argument(description: "A name") var name: String = ""

                mutating func run() async throws {
                    let command = TestCommand(name: name)
                    let result = try await command.run()
                    print(result)
                }
            }
            #endif
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with @Option generates @Option in CLI")
func mcpCommandWithOption() {
    assertMacroExpansion(
        """
        @MCPCommand(description: "Test")
        struct TestCommand {
            @Option(description: "Count")
            var count: Int = 1

            func run() async throws -> String {
                return "\\\\\\(count)"
            }
        }
        """,
        expandedSource: """
        struct TestCommand {
            @Option(description: "Count")
            var count: Int = 1

            func run() async throws -> String {
                return "\\\\\\(count)"
            }
        }

        extension TestCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Test")
            }

            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "count", description: "Count", required: false, kind: .option, typeName: "Int", hasDefault: true, enumValues: nil)]
            }

            public mutating func apply(arguments: [String: Any]) throws {
                var setParams = Set<String>()
                if let value = arguments["count"] {
                    try self._count._setValue(value)
                    setParams.insert("count")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
                        throw MCPError.missingArgument(param.name)
                    }
                }
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try await run()
                return .text(String(describing: output))
            }

            #if canImport(ArgumentParser)
            struct CLI: AsyncParsableCommand {
                @Option(description: "Count") var count: Int = 1

                mutating func run() async throws {
                    let command = TestCommand(count: count)
                    let result = try await command.run()
                    print(result)
                }
            }
            #endif
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with @Flag generates @Flag in CLI")
func mcpCommandWithFlag() {
    assertMacroExpansion(
        """
        @MCPCommand(description: "Test")
        struct TestCommand {
            @Flag(description: "Verbose mode")
            var verbose: Bool = false

            func run() async throws -> String {
                return verbose ? "verbose" : "quiet"
            }
        }
        """,
        expandedSource: """
        struct TestCommand {
            @Flag(description: "Verbose mode")
            var verbose: Bool = false

            func run() async throws -> String {
                return verbose ? "verbose" : "quiet"
            }
        }

        extension TestCommand: MCPTool {
            public static var configuration: MCPToolConfiguration {
                MCPToolConfiguration(description: "Test")
            }

            public static func discoverParameters() -> [MCPParameterInfo] {
                [] + [MCPParameterInfo(name: "verbose", description: "Verbose mode", required: false, kind: .flag, typeName: "Bool", hasDefault: true, enumValues: nil)]
            }

            public mutating func apply(arguments: [String: Any]) throws {
                var setParams = Set<String>()
                if let value = arguments["verbose"] {
                    try self._verbose._setValue(value)
                    setParams.insert("verbose")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
                        throw MCPError.missingArgument(param.name)
                    }
                }
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try await run()
                return .text(String(describing: output))
            }

            #if canImport(ArgumentParser)
            struct CLI: AsyncParsableCommand {
                @Flag(description: "Verbose mode") var verbose: Bool = false

                mutating func run() async throws {
                    let command = TestCommand(verbose: verbose)
                    let result = try await command.run()
                    print(result)
                }
            }
            #endif
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with explicit tool name")
func mcpCommandWithName() {
    assertMacroExpansion(
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
                var setParams = Set<String>()
                if let value = arguments["value"] {
                    try self._value._setValue(value)
                    setParams.insert("value")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
                        throw MCPError.missingArgument(param.name)
                    }
                }
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try await run()
                return .text(String(describing: output))
            }

            #if canImport(ArgumentParser)
            struct CLI: AsyncParsableCommand {
                @Argument(description: "A value") var value: String = ""

                mutating func run() async throws {
                    let command = TestCommand(value: value)
                    let result = try await command.run()
                    print(result)
                }
            }
            #endif
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with mixed wrappers")
func mcpCommandMixed() {
    assertMacroExpansion(
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
                var setParams = Set<String>()
                if let value = arguments["input"] {
                    try self._input._setValue(value)
                    setParams.insert("input")
                }
                if let value = arguments["multiplier"] {
                    try self._multiplier._setValue(value)
                    setParams.insert("multiplier")
                }
                if let value = arguments["verbose"] {
                    try self._verbose._setValue(value)
                    setParams.insert("verbose")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
                        throw MCPError.missingArgument(param.name)
                    }
                }
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try await run()
                return .text(String(describing: output))
            }

            #if canImport(ArgumentParser)
            struct CLI: AsyncParsableCommand {
                @Argument(description: "Required input") var input: String = ""
                @Option(description: "Optional multiplier") var multiplier: Int = 1
                @Flag(description: "Enable verbose output") var verbose: Bool = false

                mutating func run() async throws {
                    let command = Mixed(input: input, multiplier: multiplier, verbose: verbose)
                    let result = try await command.run()
                    print(result)
                }
            }
            #endif
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPCommand with @OptionGroup passes through in CLI")
func mcpCommandWithOptionGroup() {
    assertMacroExpansion(
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
                var setParams = Set<String>()
                if let value = arguments["value"] {
                    try self._value._setValue(value)
                    setParams.insert("value")
                }
                let groupParamNames = SharedOptions.mcpParameters.map(\\.name)
                if arguments.keys.contains(where: { groupParamNames.contains($0) }) {
                    try self._shared.mcpApply(arguments: arguments)
                    for gp in SharedOptions.mcpParameters where arguments[gp.name] != nil {
                        setParams.insert(gp.name)
                    }
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
                        throw MCPError.missingArgument(param.name)
                    }
                }
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try await run()
                return .text(String(describing: output))
            }

            #if canImport(ArgumentParser)
            struct CLI: AsyncParsableCommand {
                @Argument(description: "A required value") var value: String = ""
                @OptionGroup var shared: SharedOptions

                mutating func run() async throws {
                    let command = MyCommand(value: value, shared: shared)
                    let result = try await command.run()
                    print(result)
                }
            }
            #endif
        }
        """,
        macros: ["MCPCommand": MCPCommandMacro.self]
    )
}

@Test("MCPOptionGroup generates StaticMCPGroup conformance")
func mcpOptionGroupMacro() {
    assertMacroExpansion(
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
    assertMacroExpansion(
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
        }

        enum MyApp_ToolID: String, MCPToolID {
            case greet
            case calculate
        }

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

        static func main() async throws {
            let app = MyApp()
            let server = MCPServer(name: "test", version: "1.0.0") {
                app.greet
                app.calculate
            }
            _ = app
            try await server.runService()
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

@Test("MCPApplication with debug-only tool")
func mcpApplicationDebugTool() {
    assertMacroExpansion(
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
        }

        enum MyApp_ToolID: String, MCPToolID {
            case greet
            #if DEBUG
            case debug
            #endif
        }

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

        static func main() async throws {
            let app = MyApp()
            let server = MCPServer(name: "test", version: "1.0.0") {
                app.greet
                #if DEBUG
                app.debug
                #endif
            }
            _ = app
            try await server.runService()
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

@Test("MCPApplication with address binding")
func mcpApplicationWithAddress() {
    assertMacroExpansion(
        """
        @MCPApplication(name: "test", version: "1.0.0", address: .localhostIPv4(port: 8080))
        struct MyApp {
            @Tool var greet = Greet()
        }
        """,
        expandedSource: """
        struct MyApp {
            @Tool var greet = Greet()
        }

        enum MyApp_ToolID: String, MCPToolID {
            case greet
        }

        func callTool(_ id: MyApp_ToolID, arguments: [String: Any]) async throws -> MCPToolResult {
            switch id {
            case .greet:
                    var tool = Greet()
                    try tool.apply(arguments: arguments)
                    return try await tool.invoke(context: MCPContext(arguments: arguments))
            }
        }

        static func main() async throws {
            let app = MyApp()
            let server = MCPServer(name: "test", version: "1.0.0", address: .localhostIPv4(port: 8080)) {
                app.greet
            }
            _ = app
            try await server.runService()
        }
        """,
        macros: ["MCPApplication": MCPApplicationMacro.self]
    )
}

// MARK: - @Tool Macro Tests

@Test("Tool generates struct from simple function")
func toolMacroSimple() {
    assertMacroExpansion(
        """
        @FuncTool(description: "Greet someone")
        func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
            let greeting = formal ? "Greetings" : "Hello"
            return "\\\\(greeting), \\\\(name)!"
        }
        """,
        expandedSource: """
        func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
            let greeting = formal ? "Greetings" : "Hello"
            return "\\\\(greeting), \\\\(name)!"
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
                var setParams = Set<String>()
                if let value = arguments["name"] {
                    try self._name._setValue(value)
                    setParams.insert("name")
                }
                if let value = arguments["count"] {
                    try self._count._setValue(value)
                    setParams.insert("count")
                }
                if let value = arguments["formal"] {
                    try self._formal._setValue(value)
                    setParams.insert("formal")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
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
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("Tool generates struct with explicit name and access level")
func toolMacroWithOptions() {
    assertMacroExpansion(
        """
        @FuncTool(description: "Admin operation", name: "admin-op", requiredAccess: .admin)
        func adminOp(userId: String) -> String {
            return "Deleted \\\\(userId)"
        }
        """,
        expandedSource: """
        func adminOp(userId: String) -> String {
            return "Deleted \\\\(userId)"
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
                var setParams = Set<String>()
                if let value = arguments["userId"] {
                    try self._userId._setValue(value)
                    setParams.insert("userId")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
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
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}

@Test("Tool generates async struct")
func toolMacroAsync() {
    assertMacroExpansion(
        """
        @FuncTool(description: "Fetch data")
        func fetchData(url: String) async throws -> String {
            let data = try await URLSession.shared.data(from: URL(string: url)!)
            return String(decoding: data, as: UTF8.self)
        }
        """,
        expandedSource: """
        func fetchData(url: String) async throws -> String {
            let data = try await URLSession.shared.data(from: URL(string: url)!)
            return String(decoding: data, as: UTF8.self)
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
                var setParams = Set<String>()
                if let value = arguments["url"] {
                    try self._url._setValue(value)
                    setParams.insert("url")
                }
                for param in Self.discoverParameters() where param.required {
                    if !setParams.contains(param.name) {
                        throw MCPError.missingArgument(param.name)
                    }
                }
            }

            public func run() async throws -> String {
                return fetchData(url: url)
            }

            public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
                let output = try await run()
                return .text(String(describing: output))
            }
        }
        """,
        macros: ["FuncTool": ToolMacro.self]
    )
}
