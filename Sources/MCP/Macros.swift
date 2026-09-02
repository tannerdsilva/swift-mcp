//===----------------------------------------------------------------------===//
//
// This source file is part of the MCP open source project
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

/// A macro that generates an ``MCPTool`` conformance from a single struct declaration.
///
/// Apply this macro to a struct that uses `@Argument`, `@Option`, `@Flag`, and
/// `@OptionGroup` property wrappers and defines a `run()` method. The macro
/// generates:
///
/// 1. A static ``MCPToolConfiguration``.
/// 2. A static ``MCPTool/discoverParameters()`` returning compile-time
///    parameter metadata.
/// 3. ``MCPTool/apply(arguments:)`` and ``MCPTool/invoke(context:)`` that
///    call through to the user's `run()`.
///
/// The struct must declare **exactly one** `run()` method — or provide it from
/// an extension of the struct (the macro falls back to a plain call and the
/// extension resolves at compile time). Multiple `run()` overloads are
/// rejected. The detected signature (`async`, `throws`, `Void`) shapes the
/// generated `invoke`, which applies the matching `try`/`await` prefix — never
/// an unconditional one. The `run()` return value is rendered to text via
/// `String(describing:)`, so any return type works; throwing functions surface
/// errors as JSON-RPC `-32603`.
///
/// The wrapper mapping is 1:1 and transparent with the parameter kinds:
///   `@Argument` → ``MCPParamKind/argument`` (required)
///   `@Option`   → ``MCPParamKind/option``   (optional, has default value)
///   `@Flag`     → ``MCPParamKind/flag``     (Boolean)
///   `@OptionGroup` → flattened via generated ``StaticMCPGroup`` metadata
///
/// Usage:
/// ```swift
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
///         return Array(repeating: "\(greeting), \(name)!", count: count)
///             .joined(separator: "\n")
///     }
/// }
/// ```
///
/// Usage with option groups:
/// ```swift
/// @MCPOptionGroup
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
/// The generated `MCPTool` conformance allows the struct to be registered
/// directly with an `MCPServer`:
/// ```swift
/// let server = MCPServer(name: "demo", version: "1.0") {
///     Greet()
/// }
/// ```
@attached(extension, conformances: MCPTool, names: named(configuration), named(invoke), named(discoverParameters), named(apply))
public macro MCPCommand(
    description: String = "",
    name: String? = nil,
    requiredAccess: AccessLevel = .public
) = #externalMacro(module: "MCPMacros", type: "MCPCommandMacro")

/// A macro that generates compile-time parameter metadata for an option group struct.
///
/// Apply this macro to the struct type used with ``OptionGroup``:
///
/// ```swift
/// @MCPOptionGroup
/// struct SharedOptions {
///     @Option(description: "Verbose output")
///     var verbose: Bool = false
/// }
///
/// @MCPCommand(description: "My command")
/// struct MyCommand {
///     @OptionGroup var shared: SharedOptions
/// }
/// ```
///
/// The macro generates a ``StaticMCPGroup`` conformance with static parameter
/// metadata and an `mcpApply(arguments:)` method, so the parent ``MCPCommand``
/// conformance can flatten group parameters at compile time without reflection.
@attached(extension, conformances: StaticMCPGroup, names: named(mcpParameters), named(mcpApply))
public macro MCPOptionGroup() = #externalMacro(module: "MCPMacros", type: "MCPOptionGroupMacro")

/// A macro that generates a typed `MCPToolDispatcher`, a `ToolID` enum, and
/// exhaustive dispatch for an MCP server application.
///
/// Apply this macro to a struct whose properties are marked with ``Tool``.
/// The macro generates:
///
/// 1. A ``MCPToolID``-conforming enum with one case per ``Tool`` property,
///    providing compile-time unique tool names.
/// 2. A typed `callTool(_:arguments:context:)` method with exhaustive `switch`
///    dispatch that preserves each tool's concrete type.
/// 3. A ``MCPToolDispatcher`` conformance — `toolID(named:)`,
///    `requiredAccess(named:)`, `callTool(named:arguments:context:)`, and
///    `toolCatalog(for:)` — so the server serves `tools/list` and
///    `tools/call` through typed dispatch with no runtime type erasure.
/// 4. A `static func main()` that creates an ``MCPServer`` with the app as
///    its dispatcher and runs it via ``MCPServer/runService()``.
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
///     let server = MCPServer(name: "demo", version: "1.0.0", dispatcher: app)
///     try await server.runService()
/// }
/// ```
///
/// Every line of dispatch the server performs is generated from the concrete
/// tool types (`Greet`, `Calculate`) — the server holds only one existential:
/// the `dispatcher` reference itself.
///
/// ## Debug-Only Tools
///
/// Use the `available` parameter to conditionally include tools:
///
/// ```swift
/// @MCPApplication(name: "demo", version: "1.0.0")
/// struct MyApp {
///     @Tool var greet = Greet()
///     @Tool(available: .debug) var debug = DebugTool()
/// }
/// ```
///
/// The debug tool's enum case, dispatch branch, catalog entry, and access gate
/// are all wrapped in `#if DEBUG` / `#endif`, so a release build neither lists
/// nor invokes it.
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
/// ## Custom Transport
///
/// Pass a ``MCPTransport`` value to use a custom transport instead of the
/// default stdio transport. Specify either `address` or `transport`, not both:
///
/// ```swift
/// @MCPApplication(
///     name: "demo",
///     version: "1.0.0",
///     transport: TCPTransport(address: .localhostIPv4(port: 8080))
/// )
/// struct MyApp {
///     @Tool var greet = Greet()
/// }
/// ```
@attached(member, names: named(main), named(callTool), named(_invokeTool), named(toolID), named(requiredAccess), named(toolCatalog), arbitrary)
@attached(extension, conformances: MCPToolDispatcher)
public macro MCPApplication(
    name: String,
    version: String,
    address: ServerAddress? = nil,
    transport: (any MCPTransport)? = nil
) = #externalMacro(module: "MCPMacros", type: "MCPApplicationMacro")

/// A macro that generates an ``MCPTool``-conforming struct from a static function.
///
/// Apply this macro to a `static` function on a type to automatically create an
/// MCP tool. The function's parameters become tool parameters:
///
/// - Parameters **without** default values → ``Argument`` (required)
/// - Parameters **with** default values → ``Option`` (optional)
/// - ``Bool`` parameters with default `false` → ``Flag``
///
/// The generated struct is named `{FunctionName}Tool` and can be registered
/// with an ``MCPServer``.
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
/// try await server.runService()
/// ```
///
/// ## Scope constraint
///
/// ``FuncTool`` is a *peer* macro that introduces a new type at its attachment
/// scope. Because the compiler does not allow peer macros to introduce arbitrary
/// names at global scope, the annotated function must be a member of a type —
/// and because the generated `run()` calls it unqualified, it must be `static`
/// (instance methods cannot be wrapped). A function annotated at file scope is
/// rejected by the compiler itself.
///
/// ## Return types
///
/// Any return type is supported. The generated `run()` returns the function's
/// declared type and `invoke` renders the value to text via
/// `String(describing:)`. Functions that return `Void` produce an empty text
/// block. Errors thrown by the function surface as JSON-RPC `-32603` errors.
///
/// ## Parameter descriptions
///
/// Parameter descriptions are read from the function's `///` doc comment and
/// surfaced in the tool's JSON Schema — see the ``FuncTool`` macro
/// documentation for the supported spellings.
///
/// ## Parameter constraints
///
/// Every parameter must carry a label (no `_`-labeled parameters), and `inout`
/// and variadic parameters are rejected with a diagnostic — these cannot be
/// addressed as JSON-valued MCP arguments.
@attached(peer, names: arbitrary)
public macro FuncTool(
    description: String = "",
    name: String? = nil,
    requiredAccess: AccessLevel = .public
) = #externalMacro(module: "MCPMacros", type: "ToolMacro")
