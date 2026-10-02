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

import Logging
import QuickJSON
import ServiceLifecycle
import Synchronization
import UnixSignals

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A failure surfaced by ``MCPStdinHost``.
///
/// The host never reports failures on stdout — that channel carries results,
/// and a harness reads it as such. Failures are thrown; the process entry
/// point (``MCPStdinHost/runMain()``) writes one diagnostic line to stderr
/// and exits with status `1`.
public enum MCPStdinHostError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The first frame matched no configured dialect.
    case noDialectRecognized(String)
    /// Stdin reached EOF without a single request (empty input).
    case noInputReceived
    /// A frame that claimed a dialect could not be transcoded or answered.
    case malformedFrame(String)
    /// `--mcp-manifest <name>` named a format the host does not serve.
    case manifestFormatUnknown(String)
    /// The manifest needs the running binary's absolute path, and neither
    /// `argv[0]` nor a `PATH` search resolved it.
    case executablePathUnresolved
    /// Writing a response to the output descriptor failed.
    case writeFailed(String)

    public var description: String {
        switch self {
        case .noDialectRecognized(let preview):
            "no dialect recognized the first frame: \(preview)"
        case .noInputReceived:
            "no request received (stdin was empty)"
        case .malformedFrame(let detail):
            "frame handling failed: \(detail)"
        case .manifestFormatUnknown(let name):
            "unknown manifest format: \(name)"
        case .executablePathUnresolved:
            "cannot resolve this binary's executable path for the manifest"
        case .writeFailed(let detail):
            "output write failed: \(detail)"
        }
    }
}

/// A one-shot stdin tool host: the binary shape that makes a tool as easy to
/// call as an argv CLI.
///
/// The host drives the existing ``MCPMessageRouter`` + ``MCPTransport``
/// pipeline through pluggable ``MCPStdinDialect``s, serves its own
/// self-description (`--mcp-list`, `--mcp-manifest <name>`), and defines the
/// process exit contract. It is a `Service`: run it via ``runService(gracefulShutdownSignals:)``
/// (or a host `ServiceGroup`), and use ``runMain()`` as the process entry so
/// failures map onto exit status `1` with a one-line stderr diagnostic.
///
/// ## Who owns stdout
///
/// The host writes every response itself, synchronously, at the moment it is
/// produced (the transport's outbound path is deliberately unused). That is
/// what makes ``MCPStdinDialect/completesAfterFirstRequest`` deterministic: a
/// completing dialect can stop the transport immediately after its response
/// without racing a channel-drain close against an enqueued write — the bytes
/// are already in the kernel before any close is issued. The transport still
/// owns everything inbound: framing, the size cap, EOF, and caller identity.
///
/// ## Exit contract
///
/// - `0` — a response was written for every request, or introspection was
///   emitted.
/// - `1` — no dialect recognized the first frame, stdin was empty, a frame
///   failed to transcode, or an introspection request could not be served.
///   The diagnostic goes to stderr; stdout stays untouched.
///
/// Tool-level failures are *results* (`isError` / `Error: …` text), never
/// exit codes — harnesses read stdout, not status.
public struct MCPStdinHost<Dispatcher: MCPToolDispatcher>: Service, Sendable {

    /// Host configuration: how frames are understood and where results go.
    public struct Configuration: Sendable {
        /// The dialects to detect, in order. The first frame pins the match
        /// for the rest of the process; later frames the pinned dialect does
        /// not recognize still reach the router (which owns classification).
        public var dialects: [any MCPStdinDialect]

        /// Whether `--mcp-list` / `--mcp-manifest <name>` are served.
        /// Introspection is answered before the transport starts and never
        /// reads stdin.
        public var introspection: Bool

        /// The arguments inspected for introspection flags (and `argv[0]` for
        /// manifest path resolution). Injectable so in-process tests never
        /// have to touch the process environment.
        public var arguments: [String]

        /// Where responses and introspection output are written, as a raw
        /// descriptor. Defaults to stdout; tests inject a pipe.
        public var outputFD: Int32

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - dialects: Detection order. Defaults to the plugin envelope
        ///     first, JSON-RPC second.
        ///   - introspection: Serve introspection flags. Defaults to `true`.
        ///   - arguments: Process arguments to inspect. Defaults to
        ///     `CommandLine.arguments`.
        ///   - outputFD: The result descriptor. Defaults to stdout.
        public init(
            dialects: [any MCPStdinDialect] = [MCPPluginDialect(), MCPJSONRPCDialect()],
            introspection: Bool = true,
            arguments: [String] = CommandLine.arguments,
            outputFD: Int32 = STDOUT_FILENO
        ) {
            self.dialects = dialects
            self.introspection = introspection
            self.arguments = arguments
            self.outputFD = outputFD
        }
    }

    private let name: String
    private let version: String
    private let description: String
    private let dispatcher: Dispatcher
    private let transport: any MCPTransport
    private let router: MCPMessageRouter
    private let manifestFormats: [any MCPToolManifestFormat]
    private let configuration: Configuration
    private let state = HostState()

    /// Creates a one-shot host.
    ///
    /// - Parameters:
    ///   - name: The binary's name (catalog identity).
    ///   - version: The binary's version.
    ///   - description: The binary's description (catalog identity). An empty
    ///     string yields no description.
    ///   - dispatcher: The compile-time-known dispatch surface
    ///     (macro-generated by `MCPApplication`).
    ///   - transport: The inbound carrier — framing, size cap, EOF, and caller
    ///     identity. Defaults to ``StdioTransport``.
    ///   - manifestFormats: The manifest formats `--mcp-manifest <name>`
    ///     serves. `nil` (the default) serves exactly the arc plugin manifest,
    ///     with the toolset set to `name`.
    ///   - configuration: Dialect order, introspection, arguments, and output
    ///     descriptor.
    public init(
        name: String,
        version: String,
        description: String = "",
        dispatcher: Dispatcher,
        transport: any MCPTransport = StdioTransport(),
        manifestFormats: [any MCPToolManifestFormat]? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.dispatcher = dispatcher
        self.transport = transport
        self.manifestFormats = manifestFormats ?? [ArcPluginManifest(toolset: name)]
        self.configuration = configuration
        var logger = Logger(label: "mcp.stdin.host")
        logger.logLevel = .critical
        self.router = MCPMessageRouter(name: name, version: version, logger: logger, dispatcher: dispatcher)
    }

    // MARK: - Service

    /// Serves the binary: introspection first (never touching stdin), then
    /// inbound frames over the transport until completion or EOF.
    ///
    /// - Throws: ``MCPStdinHostError`` for the failure paths in the exit
    ///   contract; transport start failures propagate as thrown.
    public func run() async throws {
        if configuration.introspection, let request = MCPIntrospectionRequest.parse(arguments: configuration.arguments) {
            try emitIntrospection(for: request)
            return
        }

        state.reset()
        try await withGracefulShutdownHandler {
            try await self.transport.start { [self] frame, caller in
                await self.handleFrame(frame, caller: caller)
            }
        } onGracefulShutdown: {
            // the shutdown callback is synchronous; the stop is fanned out on
            // a short-lived task, exactly as the session server does.
            Task { try? await self.transport.stop() }
        }

        if let failure = state.failure() { throw failure }
        if state.handledCount() == 0 { throw MCPStdinHostError.noInputReceived }
    }

    /// Runs the host inside a `ServiceGroup` with signal-based graceful
    /// shutdown — the session server's exact lifecycle, for the one-shot
    /// shape. One-shot mode is not an exemption from the Second Law.
    ///
    /// - Parameter gracefulShutdownSignals: Signals that trigger graceful
    ///   shutdown. Defaults to `[.sigterm, .sigint]`.
    public func runService(gracefulShutdownSignals: [UnixSignal] = [.sigterm, .sigint]) async throws {
        let serviceGroup = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [
                    ServiceGroupConfiguration.ServiceConfiguration(
                        service: self,
                        successTerminationBehavior: .gracefullyShutdownGroup
                    )
                ],
                gracefulShutdownSignals: gracefulShutdownSignals,
                logger: Logger(label: "mcp.stdin.host")
            )
        )
        try await serviceGroup.run()
    }

    /// Runs the host as a process entry point, mapping failures onto the exit
    /// contract: a thrown error writes one diagnostic line to stderr and exits
    /// `1`; a clean finish returns so `main` exits `0`.
    ///
    /// This is what an `interface: .oneShot` generated `main()` calls — the
    /// mapping lives here, in the framework, because generated code cannot add
    /// the C imports (`exit`, raw descriptors) that it would need.
    public func runMain() async {
        do {
            try await runService()
        } catch {
            try? Self.writeLine(Array("\(name): \(readableErrorDescription(error))".utf8), to: STDERR_FILENO)
            exit(1)
        }
    }

    // MARK: - Frame handling

    /// Handles one inbound frame: pin the dialect on frame one, transcode to
    /// JSON-RPC, route, transcode back, and write the result.
    ///
    /// Never returns bytes to the transport (the host owns stdout), never
    /// throws (failures are recorded and the transport is stopped — `run()`
    /// rethrows once it returns).
    private func handleFrame(_ frame: [UInt8], caller: MCPCallerInfo) async -> [UInt8]? {
        if state.isComplete() { return nil }

        let dialect: any MCPStdinDialect
        if let pinned = state.pinnedDialect() {
            dialect = pinned
        } else if let match = configuration.dialects.first(where: { type(of: $0).recognizes(frame) }) {
            state.pin(match)
            dialect = match
        } else {
            let preview = String(decoding: frame.prefix(160), as: UTF8.self)
            await fail(with: .noDialectRecognized(preview))
            return nil
        }

        do {
            let jsonrpcBytes = try dialect.route(frame)
            let response = try await router.route(jsonrpcBytes, caller: caller)
            guard let harnessBytes = try dialect.respond(response, to: frame) else {
                state.markHandled()
                return nil
            }
            try Self.writeLine(harnessBytes, to: configuration.outputFD)
            state.markHandled()
            if type(of: dialect).completesAfterFirstRequest {
                state.markComplete()
                // deterministic completion: the response bytes are already in
                // the kernel (synchronous write above), so closing the
                // transport now cannot race the write.
                try? await transport.stop()
            }
            return nil
        } catch {
            await fail(with: .malformedFrame(readableErrorDescription(error)))
            return nil
        }
    }

    /// Records a failure (first one wins) and stops the transport so `run()`
    /// unwinds promptly.
    private func fail(with error: MCPStdinHostError) async {
        state.recordFailure(error)
        try? await transport.stop()
    }

    // MARK: - Introspection

    /// Serves `--mcp-list` / `--mcp-manifest <name>` from the compiled
    /// surface; never reads stdin.
    private func emitIntrospection(for request: MCPIntrospectionRequest) throws {
        switch request.kind {
        case .list:
            let catalog = MCPToolCatalog.discover(
                name: name,
                version: version,
                description: description,
                dispatcher: dispatcher
            )
            try Self.writeLine(try QuickJSON.encode(catalog), to: configuration.outputFD)
        case .manifest(let formatName):
            guard let format = manifestFormats.first(where: { type(of: $0).formatName == formatName }) else {
                throw MCPStdinHostError.manifestFormatUnknown(formatName)
            }
            guard let binaryPath = MCPManifestContext.resolveExecutablePath(arguments: configuration.arguments) else {
                throw MCPStdinHostError.executablePathUnresolved
            }
            let catalog = MCPToolCatalog.discover(
                name: name,
                version: version,
                description: description,
                dispatcher: dispatcher
            )
            let context = MCPManifestContext(binaryPath: binaryPath, invocationArguments: [])
            try Self.writeLine(try format.encode(catalog, context: context), to: configuration.outputFD)
        }
    }

    // MARK: - Output

    /// Writes one newline-framed payload — the host's whole outbound contract
    /// (the same framing rule the transport's codec applies).
    private static func writeLine(_ bytes: [UInt8], to fd: Int32) throws {
        var framed = bytes
        framed.append(0x0A)
        var offset = 0
        while offset < framed.count {
            let written = framed.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), framed.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw MCPStdinHostError.writeFailed(String(cString: strerror(errno)))
            }
            if written == 0 {
                throw MCPStdinHostError.writeFailed("write returned zero")
            }
            offset += written
        }
    }
}

// MARK: - Host state

/// Mutable host state, serialized: the pinned dialect, the first failure, and
/// the handled-frame count.
///
/// State lives in a class so the `Sendable` host struct can share it with the
/// transport's handler closure; the lock makes the sharing safe.
private final class HostState: @unchecked Sendable {
    private struct State {
        var pinnedDialect: (any MCPStdinDialect)?
        var failure: MCPStdinHostError?
        var handledFrames = 0
        var isComplete = false
    }

    private let mutex = Mutex<State>(State())

    func reset() {
        mutex.withLock { $0 = State() }
    }

    func pinnedDialect() -> (any MCPStdinDialect)? {
        mutex.withLock { $0.pinnedDialect }
    }

    func pin(_ dialect: any MCPStdinDialect) {
        mutex.withLock { $0.pinnedDialect = dialect }
    }

    func recordFailure(_ error: MCPStdinHostError) {
        mutex.withLock { state in
            if state.failure == nil { state.failure = error }
        }
    }

    func failure() -> MCPStdinHostError? {
        mutex.withLock { $0.failure }
    }

    func markHandled() {
        mutex.withLock { $0.handledFrames += 1 }
    }

    func handledCount() -> Int {
        mutex.withLock { $0.handledFrames }
    }

    func markComplete() {
        mutex.withLock { $0.isComplete = true }
    }

    func isComplete() -> Bool {
        mutex.withLock { $0.isComplete }
    }
}

// MARK: - Introspection request parsing

/// The introspection flags a one-shot tool answers without reading stdin.
struct MCPIntrospectionRequest: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case list
        case manifest(String)
    }

    let kind: Kind

    /// Parses `--mcp-list` / `--mcp-manifest <name>` (`--mcp-manifest=<name>`
    /// accepted too) from process arguments, skipping `argv[0]`.
    static func parse(arguments: [String]) -> MCPIntrospectionRequest? {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--mcp-list" {
                return MCPIntrospectionRequest(kind: .list)
            }
            if argument == "--mcp-manifest" {
                return MCPIntrospectionRequest(kind: .manifest(iterator.next() ?? ""))
            }
            if argument.hasPrefix("--mcp-manifest=") {
                return MCPIntrospectionRequest(kind: .manifest(String(argument.dropFirst("--mcp-manifest=".count))))
            }
        }
        return nil
    }
}