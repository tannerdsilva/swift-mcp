//===----------------------------------------------------------------------===//
//
// This source file is part of the MCP open source project
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

/// A macro that generates dual `AsyncParsableCommand` and `MCPTool` conformances
/// from a single struct declaration.
///
/// Apply this macro to a struct that uses `@Argument`, `@Option`, `@Flag`, and
/// `@OptionGroup` property wrappers and defines a `run()` method. The macro
/// generates:
///
/// 1. An extension adding `MCPTool` conformance for MCP server use
/// 2. A nested `CLI` type conforming to `AsyncParsableCommand` for CLI use
///    (requires `import ArgumentParser` in the client file)
///
/// The wrapper mapping is 1:1 and transparent:
///   `@Argument`   → `@Argument`   / `@Argument` (MCP)
///   `@Option`     → `@Option`     / `@Option` (MCP)
///   `@Flag`       → `@Flag`       / `@Flag` (MCP)
///   `@OptionGroup` → `@OptionGroup` / `@OptionGroup` (MCP)
///
/// Usage with individual wrappers:
/// ```swift
/// import ArgumentParser
/// import MCP
///
/// @MCPCommand(description: "Greet someone by name")
/// struct Greet {
///     @Argument(description: "The person to greet")
///     var name: String = ""
///
///     @Option(description: "Number of times")
///     var count: Int = 1
///
///     @Flag(description: "Use a formal greeting")
///     var formal: Bool = false
///
///     func run() async throws -> String {
///         let greeting = formal ? "Greetings" : "Hello"
///         return Array(repeating: "\\(greeting), \\(name)!", count: count)
///             .joined(separator: "\\n")
///     }
/// }
/// ```
///
/// Usage with option groups:
/// ```swift
/// struct SharedOptions {
///     @Option(description: "Verbose output")
///     var verbose: Bool = false
///
///     @Option(description: "Output path")
///     var outputPath: String = "."
/// }
///
/// @MCPCommand(description: "My command")
/// struct MyCommand {
///     @OptionGroup var shared: SharedOptions
///
///     func run() async throws -> String { ... }
/// }
/// ```
///
/// The generated `CLI` type can be used as a root command:
/// ```swift
/// Greet.CLI.main()
/// ```
///
/// The generated `MCPTool` conformance allows the struct to be registered
/// directly with an `MCPServer`:
/// ```swift
/// let server = MCPServer(name: "demo", version: "1.0") {
///     Greet()
/// }
/// ```
@attached(extension, conformances: MCPTool, names: named(configuration), named(invoke), named(CLI))
public macro MCPCommand(
    description: String = "",
    name: String? = nil,
    requiredAccess: AccessLevel = .public
) = #externalMacro(module: "MCPMacros", type: "MCPCommandMacro")

/// A macro that generates a `main()` entry point, a `ToolID` enum, and
/// exhaustive dispatch for an MCP server application.
///
/// Apply this macro to a struct whose properties are marked with ``Tool``.
/// The macro generates:
///
/// 1. A ``MCPToolID``-conforming enum with one case per ``Tool`` property,
///    providing compile-time unique tool names.
/// 2. A `callTool(_:arguments:)` method with exhaustive `switch` dispatch
///    that preserves each tool's concrete type.
/// 3. A `static func main()` that creates an ``MCPServer``, registers each
///    ``Tool`` property, and starts the server via ``MCPServer/runService()``.
///
/// ## Basic Usage
///
/// ```swift
/// @MCPApplication(name: "demo", version: "1.0.0")
/// struct MyApp {
///     @Tool var greet = Greet()
///     @Tool var calculate = Calculate()
/// }
/// ```
///
/// The generated `main()` is equivalent to:
/// ```swift
/// static func main() async throws {
///     let app = Self()
///     let server = MCPServer(name: "demo", version: "1.0.0")
///     server.register(app.greet)
///     server.register(app.calculate)
///     try await server.runService()
/// }
/// ```
///
/// ## Debug-Only Tools
///
/// Use the `available` parameter to conditionally register tools:
///
/// ```swift
/// @MCPApplication(name: "demo", version: "1.0.0")
/// struct MyApp {
///     @Tool var greet = Greet()
///     @Tool(available: .debug) var debug = DebugTool()
/// }
/// ```
///
/// The debug tool's registration and dispatch branch are wrapped in
/// `#if DEBUG` / `#endif`.
///
/// ## Address Binding
///
/// Pass an ``ServerAddress`` to bind the server to a specific network
/// address. Supports IPv4, IPv6, dual-stack, and Unix domain sockets:
///
/// ```swift
/// @MCPApplication(
///     name: "demo",
///     version: "1.0.0",
///     address: .hostname("127.0.0.1", port: 8080)
/// )
/// struct MyApp {
///     @Tool var greet = Greet()
/// }
/// ```
///
/// ## Generated Code
///
/// For the basic example above, the macro generates:
///
/// ```swift
/// enum MyApp_ToolID: String, MCPToolID {
///     case greet
///     case calculate
/// }
///
/// func callTool(_ id: MyApp_ToolID, arguments: [String: Any]) async throws -> MCPToolResult {
///     switch id {
///     case .greet:
///         var tool = Greet()
///         try tool.apply(arguments: arguments)
///         return try await tool.invoke(context: MCPContext(arguments: arguments))
///     case .calculate:
///         var tool = Calculate()
///         try tool.apply(arguments: arguments)
///         return try await tool.invoke(context: MCPContext(arguments: arguments))
///     }
/// }
///
/// static func main() async throws {
///     let app = MyApp()
///     let server = MCPServer(name: "demo", version: "1.0.0")
///     server.register(app.greet)
///     server.register(app.calculate)
///     try await server.runService()
/// }
/// ```
@attached(member, names: named(main), named(callTool), arbitrary)
public macro MCPApplication(
    name: String,
    version: String,
    address: ServerAddress? = nil,
    transport: (any MCPTransport)? = nil
) = #externalMacro(module: "MCPMacros", type: "MCPApplicationMacro")

/// A macro that generates an ``MCPTool``-conforming struct from a function.
///
/// Apply this macro to a function to automatically create an MCP tool.
/// The function's parameters become tool parameters:
///
/// - Parameters **without** default values → ``Argument`` (required)
/// - Parameters **with** default values → ``Option`` (optional)
/// - ``Bool`` parameters with default `false` → ``Flag``
///
/// The generated struct is named `{FunctionName}Tool` and can be registered
/// with an ``MCPServer``.
///
/// ```swift
/// @FuncTool(description: "Greet someone by name")
/// func greet(name: String, count: Int = 1, formal: Bool = false) -> String {
///     let greeting = formal ? "Greetings" : "Hello"
///     return "\\(greeting), \\(name)!"
/// }
///
/// let server = MCPServer(name: "demo", version: "1.0.0") {
///     greetTool()
/// }
/// try await server.runService()
/// ```
@attached(peer, names: arbitrary)
public macro FuncTool(
    description: String = "",
    name: String? = nil,
    requiredAccess: AccessLevel = .public
) = #externalMacro(module: "MCPMacros", type: "ToolMacro")
