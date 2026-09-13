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
import NIOCore
import NIOPosix
import QuickJSON
import SwiftSlash
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A ``ClientTransport`` carrier that runs a standalone MCP server binary as a
/// subprocess, speaking MCP over its stdio.
///
/// ## SwiftSlash v5 BYO data channels
///
/// The child's stdin and stdout are caller-owned pipe ends handed to SwiftSlash
/// via `.byo(fd:)` — SwiftSlash `dup2`s them onto the child and then stays out
/// of the data path entirely (it never reads, writes, registers, mutates, or
/// closes them; reaping and cancellation stay intact). The parent-facing ends
/// become a NIO duplex pipe channel (input = stdout read end, output = stdin
/// write end) running the shared `MCPFrameCodec` — the exact NIO framing
/// every other carrier uses. The child's stderr stays on SwiftSlash's built-in
/// line stream (mixed built-in + BYO per-fh is supported): it is drained to the
/// logger and retained as a tail for crash diagnostics.
///
/// ## The shutdown ladder
///
/// MCP over stdio has no shutdown RPC — EOF on the child's stdin **is** the
/// shutdown signal. `stop()` runs the strictly-ordered ladder:
///
/// ```
/// 1. close the NIO channel      → child's stdin read end sees EOF → it exits
/// 2. await exit with grace      → clean exit in `shutdownGrace`
/// 3. SIGTERM to the process group
/// 4. SIGKILL to the process group
///    reap guaranteed on every rung (SwiftSlash run() always reaps).
/// ```
///
/// - Warning: This class uses `@unchecked Sendable` because its runtime state
///   (`started`, `channel`, `child`, the retained stderr tail) is mutated from
///   `start()`, `sendFrame()`, and `stop()`, which graceful shutdown
///   deliberately overlaps. All access is serialized through `stateLock`.
public final class SubprocessClientTransport: ClientTransport, @unchecked Sendable {

    /// How to spawn the child server.
    public struct Configuration: Sendable {
        /// The server executable: an absolute or relative path, or a name
        /// resolved against `PATH`.
        public var executable: String
        /// Arguments passed to the executable.
        public var arguments: [String]
        /// Extra environment for the child, merged **over** the inherited
        /// parent environment (values here win). Set
        /// `inheritParentEnvironment` to `false` to spawn with exactly these
        /// values and nothing else — the scrub path for harnesses that must
        /// keep host secrets out of a plugin.
        ///
        /// Note the real trust boundary: a subprocess shares the host uid and,
        /// by default, the full parent environment, so any spawned server can
        /// read every host secret. `trustLevel` is policy signaling from the
        /// harness to its own first-party child — it is **not** a security
        /// boundary. Treat spawned plugins as extensions of the harness
        /// process, not contained parties.
        public var environment: [String: String]
        /// Whether the child inherits the parent process's environment before
        /// `environment` is merged over it. Defaults to `true`. Set `false`
        /// for credential scrubbing (see ``environment``).
        public var inheritParentEnvironment: Bool
        /// An optional working directory for the child.
        public var workingDirectory: String?
        /// The maximum client-side frame size. A larger frame from the child
        /// is rejected and the connection closes. Defaults to 10 MiB.
        public var maxMessageSize: Int
        /// How long `stop()` waits for a graceful child exit before escalating
        /// to signals. Defaults to 2s.
        public var shutdownGrace: Duration = .seconds(2)
        /// The access level the harness declares for this plugin. Injected into
        /// the child over the environment, so the plugin's server applies the
        /// same access gates a networked caller would. Defaults to `.root`.
        public var trustLevel: AccessLevel = .root
        /// An optional caller identity to surface to the plugin (logged and
        /// available in tool `MCPContext.callerInfo`). Defaults to `nil`.
        public var callerIdentity: String?

        /// Creates a spawn configuration.
        ///
        /// - Parameters:
        ///   - executable: The server executable path or `PATH` name.
        ///   - arguments: Arguments for the executable.
        ///   - environment: Extra environment values (merged over the parent's).
        ///   - workingDirectory: Optional working directory for the child.
        ///   - maxMessageSize: Max client-side frame size (default 10 MiB).
        ///   - shutdownGrace: Grace period before signal escalation (default 2s).
        ///   - trustLevel: The declared plugin access level (default `.root`).
        ///   - callerIdentity: Optional caller identity surfaced to the plugin.
        public init(
            executable: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            inheritParentEnvironment: Bool = true,
            workingDirectory: String? = nil,
            maxMessageSize: Int = 10 * 1024 * 1024,
            shutdownGrace: Duration = .seconds(2),
            trustLevel: AccessLevel = .root,
            callerIdentity: String? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.inheritParentEnvironment = inheritParentEnvironment
            self.workingDirectory = workingDirectory
            self.maxMessageSize = maxMessageSize
            self.shutdownGrace = shutdownGrace
            self.trustLevel = trustLevel
            self.callerIdentity = callerIdentity
        }
    }

    /// The child's stderr, retained for crash diagnostics (newest first).
    public static let retainedStderrLineCount = 50

    private let configuration: Configuration
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger?
    private let oversizeErrorFrame: [UInt8]
    /// Records the size cap when the inbound codec rejects an oversized frame,
    /// so `handleTransportClosed` can fail in-flight calls with a size-specific
    /// error instead of a generic `connectionClosed`. Filled exactly once by
    /// the event loop, read after the channel closes.
    private let sizeCapRecorder = SizeCapRecorder()
    /// The backpressured producer/consumer halves of the frame stream.
    private let clientFrames: ClientFrames
    /// Live stderr lines (newest-dropping), for callers that want real-time
    /// diagnostics in addition to the retained tail.
    private let stderrStream: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    /// Guards the runtime state below.
    private let stateLock = Mutex<()>(())
    private var started = false
    /// Set by `stop()` so a `start()` racing a concurrent stop aborts cleanly
    /// instead of continuing to set up a channel over already-closed fds.
    private var stopRequested = false
    private var channel: Channel?
    private var child: ChildProcess?
    private var runTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    /// The child-facing pipe ends retained for the child's lifetime; closed in
    /// the teardown, once the child holds its own `dup2`'d copies.
    private var childFacingFDs: [Int32] = []
    /// The parent's stdin write end toward the child. The transport owns this
    /// descriptor (NIO gets a `dup`), and closing it in `stop()` is what
    /// delivers the EOF that ends an MCP session — the shutdown signal.
    private var parentStdinWriteFD: Int32 = -1
    /// The parent's stdout read end from the child (transport-owned; NIO gets
    /// a `dup`). Closed in the teardown once the session is over.
    private var parentStdoutReadFD: Int32 = -1
    /// The child's exit code, once reaped (`ChildProcess.Exit.code` /
    /// `ChildProcess.Exit.signal`).
    private var lastExit: ChildProcess.Exit?
    /// The last `retainedStderrLineCount` stderr lines (newest first).
    private var stderrTail: [String] = []

    /// Creates a subprocess carrier.
    ///
    /// - Parameters:
    ///   - configuration: How to spawn the child.
    ///   - eventLoopGroup: The NIO event loop group for the pipe channel.
    ///     `.singleton` is correct — one shared group, no pooling needed.
    ///   - logger: An optional logger for transport diagnostics.
    public init(
        configuration: Configuration,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.oversizeErrorFrame =
            (try? QuickJSON.encode(JSONRPCErrorResponse(id: .null, code: -32700, message: "Message too large"))) ?? []
        self.clientFrames = ClientFrames()
        var stderrContinuation: AsyncStream<String>.Continuation!
        self.stderrStream = AsyncStream<String>(bufferingPolicy: .bufferingNewest(256)) { stderrContinuation = $0 }
        self.stderrContinuation = stderrContinuation
    }

    /// The child's exit status, once the process has been reaped.
    ///
    /// `nil` before `start()` or while the child is still alive.
    public var childExit: ChildProcess.Exit? {
        stateLock.withLock { _ in lastExit }
    }

    /// The retained stderr tail (newest first) for crash diagnostics.
    public func stderrTailSnapshot() -> [String] {
        stateLock.withLock { _ in stderrTail }
    }

    // MARK: - ClientTransport

    /// Spawns the child and opens the NIO pipe channel over its stdio.
    ///
    /// The child-facing pipe ends are handed to SwiftSlash (BYO); the
    /// parent-facing ends are owned by the NIO channel. SwiftSlash handles
    /// spawn, reaping, and cancellation; every byte on the wire flows through
    /// NIO.
    public func start() async throws {
        let alreadyStarted: Bool = stateLock.withLock { _ in
            if started { return true }
            started = true
            return false
        }
        if alreadyStarted { return }

        let maxMessageSize = configuration.maxMessageSize

        // A child dying mid-write raises SIGPIPE on the parent; ignore it so it
        // cannot kill us (mirrors the server's stdio transport).
        #if canImport(Darwin)
        _ = signal(SIGPIPE, SIG_IGN)
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif

        // Two pipes: child stdin + child stdout. stderr stays on SwiftSlash's
        // built-in stream (mixed BYO + built-in per-fh is supported).
        var stdin = [Int32](repeating: 0, count: 2)
        var stdout = [Int32](repeating: 0, count: 2)
        var pipesOK = true
        pipesOK = pipesOK && pipe(&stdin) == 0
        pipesOK = pipesOK && pipe(&stdout) == 0
        guard pipesOK else {
            throw MCPClientError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }

        // Mark every parent pipe end CLOEXEC. posix_spawn inherits all
        // non-CLOEXEC descriptors into the child, and an inherited copy of the
        // stdin WRITE end would keep the pipe open forever — the child would
        // never see stdin EOF, so the clean shutdown ladder would always
        // escalate to signals. Closing them at exec leaves the child with
        // exactly its stdio (bound through the BYO file actions).
        for fd in [stdin[0], stdin[1], stdout[0], stdout[1]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        // child-facing ends: stdin read end (child reads), stdout write end (child writes).
        let command: Command
        do {
            let wd = configuration.workingDirectory.map(Path.init) ?? CurrentEnvironment.workingDirectory()
            let environment = Self.spawnEnvironment(configuration)
            if configuration.executable.contains("/") {
                command = Command(
                    absolutePath: Path(configuration.executable),
                    arguments: configuration.arguments,
                    environment: environment,
                    workingDirectory: wd
                )
            } else {
                command = try Command(
                    configuration.executable,
                    arguments: configuration.arguments,
                    environment: environment,
                    workingDirectory: wd
                )
            }
        } catch {
            close(stdin[0]); close(stdin[1])
            close(stdout[0]); close(stdout[1])
            throw MCPClientError.spawnFailed("cannot build command '\(configuration.executable)': \(error)")
        }

        let child = ChildProcess(
            command,
            dataChannels: [
                STDIN_FILENO: .read(.byo(fd: FileDescriptor(rawValue: stdin[0]))),
                STDOUT_FILENO: .write(.byo(fd: FileDescriptor(rawValue: stdout[1]))),
                STDERR_FILENO: .write(.toParentProcess(stream: .init(), separator: [0x0A])),
            ]
        )

        // The child lifecycle: launch, reap, and — on exit — release the
        // transport-owned pipe ends. run(cancellationSignal:) makes task
        // cancellation signal the whole process group too (plain run()
        // cancels without signaling, which silently leaks an EOF-ignoring
        // child on the error paths that cancel).
        let childLogger = logger
        let runTask = Task { [child, childLogger] in
            let exit: ChildProcess.Exit
            do {
                exit = try await child.run(cancellationSignal: SIGTERM)
            } catch {
                // spawn failure or cancellation both end the process; record a
                // signal-shaped exit so diagnostics never see a missing entry.
                childLogger?.warning("subprocess ended with error: \(error)")
                exit = .signal(-1)
            }
            self.childDidExit(exit)
        }

        // Publish child + reaper + pipe ends in ONE step, so stop() racing
        // start() never observes a child without its reaper — the two are
        // atomic and both the ladder and childDidExit can act on them.
        stateLock.withLock { _ in
            self.child = child
            self.runTask = runTask
            self.stopRequested = false
            self.childFacingFDs = [stdin[0], stdout[1]]
            self.parentStdinWriteFD = stdin[1]
            self.parentStdoutReadFD = stdout[0]
        }

        // Drain stderr (built-in SwiftSlash stream) to the logger, the retained
        // tail, AND a live listener stream for diagnostics.
        let stderrStream = child.stderr
        let stderrContinuation = self.stderrContinuation
        let stderrTask = Task { [stderrStream, childLogger] in
            for await lines in stderrStream {
                for line in lines {
                    let text = String(decoding: line, as: UTF8.self)
                    self.recordStderrLine(text)
                    stderrContinuation.yield(text)
                    childLogger?.debug("child stderr: \(text)")
                }
            }
        }

        // The NIO pipe channel: input = stdout read end, output = stdin write
        // end, running the shared frame codec. NIO takes ownership of dup'd
        // copies; the transport retains the originals so it controls EOF
        // deterministically (NIO does not close user-provided pipe fds at
        // channel close, observed empirically).
        let nioInputFD = dup(stdout[0])
        guard nioInputFD >= 0 else {
            // Nothing NIO owns yet: stop() tears the child down via the ladder
            // and closes every retained pipe end exactly once.
            try? await self.stop()
            throw MCPClientError.spawnFailed("dup(stdout read end) failed: \(String(cString: strerror(errno)))")
        }
        let nioOutputFD = dup(stdin[1])
        guard nioOutputFD >= 0 else {
            close(nioInputFD)
            try? await self.stop()
            throw MCPClientError.spawnFailed("dup(stdin write end) failed: \(String(cString: strerror(errno)))")
        }
        // The dups go to NIO, but they must not be inherited by the child —
        // an inherited copy of the stdin write end is the exact leak that
        // defeats EOF (see the pipe-creation loop above).
        _ = fcntl(nioInputFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(nioOutputFD, F_SETFD, FD_CLOEXEC)

        let channel: Channel
        do {
            let sizeCapRecorder = self.sizeCapRecorder
            channel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelInitializer { [clientFrames, maxMessageSize, oversizeErrorFrame, sizeCapRecorder, logger] channel in
                    channel.pipeline.addHandlers(
                        MCPFrameCodec(
                            maxMessageSize: maxMessageSize,
                            oversizeErrorFrame: oversizeErrorFrame,
                            onRejectOversize: { sizeCapRecorder.record(maxMessageSize) }
                        ),
                        ClientFrameBridge(source: clientFrames.source, demand: clientFrames.demand, logger: logger)
                    )
                }
                .takingOwnershipOfDescriptors(input: nioInputFD, output: nioOutputFD)
                .get()
        } catch {
            // NIO returned a failed future: we still own the dup'd copies.
            close(nioInputFD)
            close(nioOutputFD)
            // stop() runs the ladder (child teardown) and closes the retained
            // pipe ends exactly once; it cannot hang because it never relies
            // on cancelling run() (which plain run() ignores).
            try? await self.stop()
            throw MCPClientError.spawnFailed("pipe channel creation failed: \(error)")
        }

        // A concurrent stop() may have landed while this start() was setting
        // up (it closes the retained fds and reclaims the child). Abort
        // without touching those fds — close only what this branch created.
        let aborted: Bool = stateLock.withLock { _ in
            let wasStopped = self.stopRequested
            if !wasStopped {
                self.channel = channel
                self.stderrTask = stderrTask
            }
            return wasStopped
        }
        if aborted {
            close(nioInputFD)
            close(nioOutputFD)
            try await channel.close(mode: .all)
            throw MCPClientError.notConnected
        }
    }

    /// Writes one complete JSON-RPC frame to the child, awaiting the actual
    /// flush — real backpressure into the child's pipe instead of overrunning
    /// its kernel buffer.
    public func sendFrame(_ bytes: [UInt8]) async throws {
        let channel: Channel? = stateLock.withLock { _ in self.channel }
        guard let channel else {
            throw MCPClientError.notConnected
        }
        do {
            try await channel.writeAndFlush(bytes).get()
        } catch {
            throw MCPClientError.connectionClosed
        }
    }

    /// The frames the child emits, until EOF or `stop()`.
    nonisolated public func frames() -> ClientFrameSequence {
        clientFrames.sequence
    }

    /// Whether the peer understands the best-effort `shutdown` extension.
    ///
    /// The child's stdio server exits on stdin EOF, so it can be asked to drain
    /// in-flight work before the ladder runs.
    public var supportsCooperativeShutdown: Bool { true }

    /// The child's stderr, as a live line stream (newest-dropping).
    ///
    /// Single-consumer fan-out of the built-in SwiftSlash line pipeline; the
    /// retained tail (`stderrTailSnapshot()`) remains available without a
    /// consumer.
    nonisolated public func stderrLines() -> AsyncStream<String> {
        stderrStream
    }

    /// Reports the size cap when the connection was torn down by an oversized
    /// inbound frame, or `nil` for plain EOF/crash.
    public var sizeCapViolation: Int? {
        sizeCapRecorder.value
    }

    /// Builds the child environment.
    ///
    /// By default the child inherits the parent's environment (`environ`) with
    /// `configuration.environment` merged over it, then the identity/trust
    /// plumbing the child's `StdioTransport` reads for access gating
    /// (`MCP_ACCESS_LEVEL`, optional `MCP_CALLER_IDENT`). SwiftSlash passes the
    /// environment dict to `posix_spawn` as the child's **complete** envp — an
    /// empty dict spawns an empty environment — so inheritance must be done
    /// here explicitly. With `inheritParentEnvironment: false` the child gets
    /// exactly `configuration.environment` plus the MCP plumbing (the scrub
    /// path for secrets).
    private static func spawnEnvironment(_ configuration: Configuration) -> [String: String] {
        var environment = configuration.inheritParentEnvironment
            ? parentEnvironment()
            : [:]
        for (key, value) in configuration.environment {
            environment[key] = value
        }
        environment["MCP_ACCESS_LEVEL"] = String(configuration.trustLevel.rawValue)
        if let identity = configuration.callerIdentity {
            environment["MCP_CALLER_IDENT"] = identity
        }
        return environment
    }

    /// Reads the current process's environment (`environ`) into a dictionary.
    ///
    /// Foundation-free: parses the C `environ` array directly. Values are
    /// split at the first `=`.
    private static func parentEnvironment() -> [String: String] {
        var result: [String: String] = [:]
        var cursor = environ
        while let entry = cursor.pointee {
            if let string = String(cString: entry, encoding: .utf8),
               let separator = string.firstIndex(of: "=") {
                let key = String(string[..<separator])
                let value = String(string[string.index(after: separator)...])
                result[key] = value
            }
            cursor = cursor.advanced(by: 1)
        }
        return result
    }

    /// Runs the shutdown ladder: EOF on the child's stdin → grace → SIGTERM →
    /// SIGKILL, with the reap guaranteed on every rung.
    public func stop() async throws {
        let snapshot: (channel: Channel?, child: ChildProcess?, runTask: Task<Void, Never>?, stdinWriteFD: Int32, teardownFDs: [Int32]) =
            stateLock.withLock { _ in
                var teardown = self.childFacingFDs
                let stdinWrite = self.parentStdinWriteFD
                self.parentStdinWriteFD = -1
                if parentStdoutReadFD >= 0 {
                    teardown.append(parentStdoutReadFD)
                    parentStdoutReadFD = -1
                }
                let snapshot = (self.channel, self.child, self.runTask, stdinWrite, teardown)
                self.channel = nil
                self.child = nil
                self.started = false
                self.stopRequested = true
                self.childFacingFDs = []
                return snapshot
            }

        defer {
            for fd in snapshot.teardownFDs { close(fd) }
        }

        // rung 1 — EOF on the child's stdin: explicitly close the parent's
        // stdin write end (the transport owns it; NIO has a dup). Combined
        // with the channel close this delivers the child's stdin EOF — the
        // only shutdown signal MCP over stdio has — deterministically.
        if snapshot.stdinWriteFD >= 0 {
            close(snapshot.stdinWriteFD)
        }
        if let channel = snapshot.channel {
            try? await channel.close(mode: .all)
        }

        guard let child = snapshot.child, let runTask = snapshot.runTask else {
            return
        }

        // rung 2 — grace; wait for a clean exit.
        do {
            try await waitForExit(runTask: runTask, grace: configuration.shutdownGrace)
            return
        } catch {
            // rung 3 — SIGTERM to the whole process group (descendants such as
            // a git or swift child die with the server).
            await signalProcessGroup(child, SIGTERM)
            do {
                try await waitForExit(runTask: runTask, grace: configuration.shutdownGrace)
                return
            } catch {
                // rung 4 — SIGKILL to the process group; the reap is guaranteed.
                await signalProcessGroup(child, SIGKILL)
                _ = try? await waitForExit(runTask: runTask, grace: configuration.shutdownGrace)
            }
        }
    }

    /// Waits for the child to be reaped, bounded by `grace`. Throws
    /// `MCPClientError.callTimeout` if the child outlives the grace period.
    ///
    /// Deliberately no task group: group-child scheduling proved unreliable in
    /// strict-concurrency builds on this toolchain, while plain unstructured
    /// `Task`s (the child-run/tread-loop tasks) are consistent. The two racers
    /// resolve the continuation exactly once through `ResumeOnce`.
    private func waitForExit(runTask: Task<Void, Never>, grace: Duration) async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { [runTask] in
                _ = await runTask.value
                once.run { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: grace)
                once.run { continuation.resume(throwing: MCPClientError.callTimeout) }
            }
        }
    }

    /// Sends a signal to the child's whole process group (`kill(-pid, ...)`).
    ///
    /// Wait briefly for the child to reach `.running` first: a `stop()` that
    /// lands during `start()`'s launch window would otherwise find
    /// `.launching` and silently skip the rung (the launch's pgroup is not
    /// signaled). Bounded — a child that never launches surfaces through
    /// `waitForExit`'s deadline instead of blocking here.
    private func signalProcessGroup(_ child: ChildProcess, _ signal: Int32) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            let state = await child.state
            if case .running(let pid) = state {
                _ = kill(-pid, signal)
                return
            }
            if case .reaped = state {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Records the child's exit and releases the transport-owned pipe ends.
    ///
    /// This is what closes the EOF-path leak: whether the session ends via
    /// `stop()` (which closes them in its snapshot) or because the child exited
    /// on its own (server EOF or crash — no `stop()` ever runs), the retained
    /// fds are closed exactly once, by whichever path clears the state fields
    /// first. The child-facing ends must stay open until the child's spawn, so
    /// this runs only after `run()` has reaped it.
    private func childDidExit(_ exit: ChildProcess.Exit) {
        let channel: Channel? = stateLock.withLock { _ in
            lastExit = exit
            var fds: [Int32] = []
            for fd in childFacingFDs {
                fds.append(fd)
            }
            childFacingFDs = []
            if parentStdinWriteFD >= 0 {
                fds.append(parentStdinWriteFD)
                parentStdinWriteFD = -1
            }
            if parentStdoutReadFD >= 0 {
                fds.append(parentStdoutReadFD)
                parentStdoutReadFD = -1
            }
            for fd in fds {
                close(fd)
            }
            // release the process handle: the child is reaped and nothing needs
            // it (diagnostics read `childExit`, not `child`); dropping it lets
            // SwiftSlash free its own per-process resources (stderr pipe).
            self.child = nil
            self.stderrTask = nil
            let active = self.channel
            self.channel = nil
            return active
        }
        // The session ended on its own (child EOF/crash, no stop()): tear the
        // channel down too so NIO's dup'd pipe ends are released
        // deterministically instead of on eventual dealloc. Closing an already
        // inactive channel is a no-op.
        if let channel {
            Task { try? await channel.close(mode: .all) }
        }
    }

    private func recordStderrLine(_ line: String) {
        stateLock.withLock { _ in
            stderrTail.insert(line, at: 0)
            if stderrTail.count > Self.retainedStderrLineCount {
                stderrTail.removeLast(stderrTail.count - Self.retainedStderrLineCount)
            }
        }
    }
}
