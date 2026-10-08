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

import Foundation
import QuickJSON

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Locating a built binary

/// Locates a built executable target's binary, resolved relative to a source
/// file inside the consuming package.
///
/// Pass `#filePath` at the call site; the search walks up from that file until
/// it finds the binary under a build directory, so it does not assume a fixed
/// nesting depth between the test file and the package root.
///
/// ```swift
/// let binary = try builtToolPath(named: "MyToolPack", relativeTo: #filePath)
/// ```
///
/// `swift build` must have run first — a test target does not build the
/// executables it spawns.
public func builtToolPath(named name: String, relativeTo sourceFile: String) throws -> String {
    var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
    while directory.path != "/" {
        for layout in [".build/debug", ".build/arm64-apple-macosx/debug", ".build/out/Products/Debug"] {
            let candidate = directory.appendingPathComponent("\(layout)/\(name)").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        directory = directory.deletingLastPathComponent()
    }
    throw ToolSpawnError.binaryNotFound(name)
}

// MARK: - Errors and exit status

/// A spawn-harness failure: the binary is missing, `posix_spawn` failed, the
/// child outlived its bound, or a frame did not decode.
public enum ToolSpawnError: Error, Equatable, CustomStringConvertible {
    /// No built binary with that name was found; `swift build` has not run.
    case binaryNotFound(String)
    /// `pipe()` or `posix_spawn` failed.
    case spawnFailed(String)
    /// The child did not exit within the harness bound (it was killed).
    case waitTimeout(seconds: TimeInterval)
    /// A response did not carry the shape the harness expected.
    case malformedFrame(String)

    public var description: String {
        switch self {
        case .binaryNotFound(let name):
            "\(name) binary not found: run `swift build` first"
        case .spawnFailed(let detail):
            "spawn failed: \(detail)"
        case .waitTimeout(let seconds):
            "tool did not exit within \(seconds)s"
        case .malformedFrame(let detail):
            "malformed frame: \(detail)"
        }
    }
}

/// A child process's decoded termination.
public enum ToolExit: Equatable, Sendable {
    /// The child exited normally with this status.
    case code(Int32)
    /// The child was killed by this signal.
    case signal(Int32)

    /// Decodes a raw `waitpid` status word.
    public static func decode(_ status: Int32) -> ToolExit {
        let signal = status & 0x7F
        return signal == 0 ? .code((status >> 8) & 0xFF) : .signal(signal)
    }
}

// MARK: - Spawned handle

/// A spawned tool binary with the parent-facing pipe ends held raw, so a test
/// controls stdin's open/closed state exactly.
///
/// That control is the point: the one-shot completion contract ("answer
/// without waiting for stdin EOF") is only meaningful if the harness can hold
/// stdin open across the response. `stdinWrite` is therefore never closed for
/// you — call ``closeStdin()`` when the test is done writing.
///
/// The caller owns the three descriptor numbers; a short-lived test process
/// need not close them, but a suite that spawns many tools can call
/// ``closeAll()``.
public final class SpawnedTool {
    /// The child's process id.
    public let pid: pid_t
    /// The parent's end of the child's stdin pipe — writes become frames.
    public let stdinWrite: Int32
    /// The parent's end of the child's stdout pipe — reads are responses.
    public let stdoutRead: Int32
    /// The parent's end of the child's stderr pipe — reads are diagnostics.
    public let stderrRead: Int32

    private init(pid: pid_t, stdinWrite: Int32, stdoutRead: Int32, stderrRead: Int32) {
        self.pid = pid
        self.stdinWrite = stdinWrite
        self.stdoutRead = stdoutRead
        self.stderrRead = stderrRead
    }

    /// Spawns `path` with its three standard streams bound to pipes.
    ///
    /// - Parameters:
    ///   - path: The absolute path to the built binary.
    ///   - arguments: Arguments after `argv[0]`.
    ///   - environment: The child's *entire* environment, when non-empty. An
    ///     empty dictionary inherits the parent's, which is what most tests
    ///     want.
    public static func spawn(
        path: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> SpawnedTool {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw ToolSpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }

        // every end starts CLOEXEC: the child receives exactly its stdio via
        // the dup2 file actions (dup2 clears CLOEXEC on fds 0/1/2), and an
        // inherited copy of the stdin WRITE end would defeat EOF forever.
        for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        // an empty environment inherits the parent's (the sane default for a
        // test harness); a non-empty one is passed exactly, so a test can
        // scope identity to the child — never via `setenv`, which a parallel
        // sibling would inherit.
        let spawnResult: Int32
        if environment.isEmpty {
            spawnResult = posix_spawn(&pid, path, &fileActions, nil, &argv, nil)
        } else {
            spawnResult = posix_spawn(&pid, path, &fileActions, nil, &argv, &envp)
        }
        posix_spawn_file_actions_destroy(&fileActions)
        // the child owns its ends now; the parent must close them or the
        // output pipes never reach EOF.
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard spawnResult == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw ToolSpawnError.spawnFailed("posix_spawn failed: \(String(cString: strerror(spawnResult)))")
        }
        return SpawnedTool(pid: pid, stdinWrite: stdinPipe[1], stdoutRead: stdoutPipe[0], stderrRead: stderrPipe[0])
    }

    /// Spawns the binary with one or both std streams bound to a **regular
    /// file** — the shell-redirection shape (`< in` / `> out`) the host's
    /// preflight rejects before the transport starts.
    ///
    /// The file is opened by `posix_spawn` itself (`addopen`), so the child
    /// sees a real regular file on that descriptor; the stream that is *not*
    /// redirected keeps its pipe. A stream that is not redirected reports `-1`
    /// for its parent-facing end.
    public static func spawnWithFileStreams(
        path: String,
        arguments: [String] = [],
        stdinFile: String? = nil,
        stdoutFile: String? = nil
    ) throws -> SpawnedTool {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        if stdinFile == nil, pipe(&stdinPipe) != 0 {
            throw ToolSpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }
        if stdoutFile == nil, pipe(&stdoutPipe) != 0 {
            throw ToolSpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }
        guard pipe(&stderrPipe) == 0 else {
            throw ToolSpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }
        for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] where fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        if let stdinFile {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, stdinFile, O_RDONLY, 0)
        } else {
            posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
        }
        if let stdoutFile {
            posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, stdoutFile, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        } else {
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        }
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, path, &fileActions, nil, &argv, nil)
        posix_spawn_file_actions_destroy(&fileActions)
        // the parent's copies of the child's ends must go, or the pipes never
        // reach EOF.
        if stdinFile == nil { close(stdinPipe[0]) }
        if stdoutFile == nil { close(stdoutPipe[1]) }
        close(stderrPipe[1])

        guard spawnResult == 0 else {
            if stdinFile == nil { close(stdinPipe[1]) }
            if stdoutFile == nil { close(stdoutPipe[0]) }
            close(stderrPipe[0])
            throw ToolSpawnError.spawnFailed("posix_spawn failed: \(String(cString: strerror(spawnResult)))")
        }
        return SpawnedTool(pid: pid, stdinWrite: stdinPipe[1], stdoutRead: stdoutPipe[0], stderrRead: stderrPipe[0])
    }

    /// Blocks (with a bounded sleep loop) until the child exits, then returns
    /// the decoded exit. Kills the child on timeout so a broken tool cannot
    /// wedge the suite.
    public func waitForExit(timeout: TimeInterval = 10) async throws -> ToolExit {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return ToolExit.decode(status) }
            if result < 0 { throw ToolSpawnError.spawnFailed("waitpid failed: \(String(cString: strerror(errno)))") }
            try await Task.sleep(for: .milliseconds(20))
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
        throw ToolSpawnError.waitTimeout(seconds: timeout)
    }

    /// Writes raw bytes to the child's stdin. The caller is responsible for
    /// terminating a frame with a newline.
    public func writeFrame(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(stdinWrite, base.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw ToolSpawnError.spawnFailed("stdin write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }

    /// Writes one newline-terminated plugin-envelope request frame.
    ///
    /// The trailing newline is not cosmetic: the transport delivers complete
    /// frames only, so an unterminated frame is never delivered — not even at
    /// EOF — and the call reads as a total hang.
    public func writePluginFrame(tool: String, args: [String: String] = [:]) throws {
        try writeFrame(try pluginFrame(tool: tool, args: args))
    }

    /// Drains the child's stdout until a quiet period passes (or EOF).
    public func drainStdout(quiet: TimeInterval = 0.3, deadline: TimeInterval = 5) -> String {
        drain(fd: stdoutRead, quiet: quiet, deadline: deadline)
    }

    /// Drains the child's stderr until a quiet period passes (or EOF).
    public func drainStderr(quiet: TimeInterval = 0.3, deadline: TimeInterval = 5) -> String {
        drain(fd: stderrRead, quiet: quiet, deadline: deadline)
    }

    /// Drains stdout and returns the plugin envelope's `result` text.
    ///
    /// The failure path a tool takes is a *result*, not an exit code, so this
    /// is the assertion surface for tool-level errors too.
    public func readResult(quiet: TimeInterval = 0.3, deadline: TimeInterval = 5) throws -> String {
        try pluginResult(from: drainStdout(quiet: quiet, deadline: deadline))
    }

    /// Closes the parent's stdin write end — the child's only shutdown signal.
    public func closeStdin() {
        close(stdinWrite)
    }

    /// Closes all three parent-facing descriptors.
    ///
    /// Named `closeAll()` rather than `close()` so the global C `close(2)`
    /// stays reachable from inside this type.
    public func closeAll() {
        close(stdinWrite)
        close(stdoutRead)
        close(stderrRead)
    }
}

// MARK: - Pipe reads

/// Reads everything the descriptor has until a quiet period passes (or EOF),
/// so multi-line output (a pretty manifest, several stderr lines) is drained
/// without an EOF dependency.
public func drain(fd: Int32, quiet: TimeInterval = 0.3, deadline: TimeInterval = 5) -> String {
    var text = ""
    let limit = Date().addingTimeInterval(deadline)
    var lastData = Date()
    while Date() < limit {
        var pollFds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&pollFds, 1, 50)
        if result > 0, pollFds.revents & Int16(POLLIN) != 0 {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                text += String(decoding: bytes[0..<count], as: UTF8.self)
                lastData = Date()
                continue
            }
            if count == 0 { break }
        }
        if Date().timeIntervalSince(lastData) > quiet { break }
    }
    return text
}

// MARK: - The plugin envelope

/// The one-shot harness's envelope: `{"tool": …, "args": {…}}` in,
/// `{"result": …}` out.
public enum PluginFrame {
    private struct Request: Encodable {
        let tool: String
        let args: [String: String]
    }

    private struct Response: Decodable {
        let result: String
    }

    /// One newline-terminated request frame, ready for a tool's stdin.
    ///
    /// String-valued arguments cover the harness convention (every tool
    /// parameter arrives as a JSON scalar or string); a tool that needs a
    /// nested object is better driven through raw bytes.
    public static func request(tool: String, args: [String: String] = [:]) throws -> [UInt8] {
        var bytes = try QuickJSON.encode(Request(tool: tool, args: args))
        bytes.append(0x0A)
        return bytes
    }

    /// The `result` text from a `{"result": …}` response line.
    public static func result(from response: String) throws -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = try? QuickJSON.decode(Response.self, from: Array(trimmed.utf8)) else {
            throw ToolSpawnError.malformedFrame(trimmed.isEmpty ? "<empty stdout>" : trimmed)
        }
        return decoded.result
    }
}

/// One newline-terminated plugin-envelope request frame — the free-function
/// spelling of ``PluginFrame/request(tool:args:)``.
public func pluginFrame(tool: String, args: [String: String] = [:]) throws -> [UInt8] {
    try PluginFrame.request(tool: tool, args: args)
}

/// The `result` text from a `{"result": …}` response line — the free-function
/// spelling of ``PluginFrame/result(from:)``.
public func pluginResult(from response: String) throws -> String {
    try PluginFrame.result(from: response)
}