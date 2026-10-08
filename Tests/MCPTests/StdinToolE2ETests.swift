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

import Testing
import Foundation
import MCP
import QuickJSON

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Fixture location

/// Locates the built `MCPFixtureTool` binary.
///
/// `swift build` must have run first (the test target does not build the
/// executable itself). Resolved relative to this file, so the suite works from
/// any checkout.
private func fixtureToolPath() throws -> String {
    let source = URL(fileURLWithPath: #filePath)
    let repoRoot = source
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        repoRoot.appendingPathComponent(".build/debug/MCPFixtureTool"),
        repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/MCPFixtureTool"),
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path.path) {
        return path.path
    }
    throw SpawnError.spawnFailed("MCPFixtureTool binary not found; run `swift build` first")
}

// MARK: - Raw process spawning (the facade's own contract, not the transport's)

private enum SpawnError: Error, CustomStringConvertible {
    case spawnFailed(String)
    case waitTimeout

    var description: String {
        switch self {
        case .spawnFailed(let detail): "spawn failed: \(detail)"
        case .waitTimeout: "tool did not exit within the test bound"
        }
    }
}

private enum ToolExit: Equatable {
    case code(Int32)
    case signal(Int32)

    static func decode(_ status: Int32) -> ToolExit {
        let signal = status & 0x7F
        return signal == 0 ? .code((status >> 8) & 0xFF) : .signal(signal)
    }
}

/// A spawned fixture tool with the parent-facing pipe ends held raw, so the
/// test controls stdin's open/closed state exactly — the completion contract
/// is only meaningful if the harness can hold stdin open.
private final class SpawnedTool {
    let pid: pid_t
    let stdinWrite: Int32
    let stdoutRead: Int32
    let stderrRead: Int32

    private init(pid: pid_t, stdinWrite: Int32, stdoutRead: Int32, stderrRead: Int32) {
        self.pid = pid
        self.stdinWrite = stdinWrite
        self.stdoutRead = stdoutRead
        self.stderrRead = stderrRead
    }

    static func spawn(path: String, arguments: [String] = [], environment: [String: String] = [:]) throws -> SpawnedTool {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw SpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
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
        let spawnResult = posix_spawn(&pid, path, &fileActions, nil, &argv, &envp)
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
            throw SpawnError.spawnFailed("posix_spawn failed: \(String(cString: strerror(spawnResult)))")
        }
        return SpawnedTool(pid: pid, stdinWrite: stdinPipe[1], stdoutRead: stdoutPipe[0], stderrRead: stderrPipe[0])
    }

    /// Spawns the fixture with one or both std streams bound to a **regular
    /// file** — the shell-redirection shape (`< in` / `> out`) the host's
    /// preflight must reject before the transport starts.
    ///
    /// The file is opened by `posix_spawn` itself (`addopen`), so the child
    /// sees a real regular file on that descriptor; the stream that is *not*
    /// redirected keeps its pipe. A stream that is not redirected reports
    /// `-1` for its parent-facing end.
    static func spawnWithFileStreams(
        path: String,
        arguments: [String] = [],
        stdinFile: String? = nil,
        stdoutFile: String? = nil
    ) throws -> SpawnedTool {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        if stdinFile == nil, pipe(&stdinPipe) != 0 {
            throw SpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }
        if stdoutFile == nil, pipe(&stdoutPipe) != 0 {
            throw SpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
        }
        guard pipe(&stderrPipe) == 0 else {
            throw SpawnError.spawnFailed("pipe() failed: \(String(cString: strerror(errno)))")
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
            throw SpawnError.spawnFailed("posix_spawn failed: \(String(cString: strerror(spawnResult)))")
        }
        return SpawnedTool(pid: pid, stdinWrite: stdinPipe[1], stdoutRead: stdoutPipe[0], stderrRead: stderrPipe[0])
    }

    /// Blocks (with a bounded sleep loop) until the child exits, then returns
    /// the decoded exit. Kills the child on timeout so a broken tool cannot
    /// wedge the suite.
    func waitForExit(timeout: TimeInterval = 10) async throws -> ToolExit {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return ToolExit.decode(status) }
            if result < 0 { throw SpawnError.spawnFailed("waitpid failed: \(String(cString: strerror(errno)))") }
            try await Task.sleep(for: .milliseconds(20))
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
        throw SpawnError.waitTimeout
    }

    func writeFrame(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(stdinWrite, base.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw SpawnError.spawnFailed("stdin write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

// MARK: - Pipe reads

/// Reads everything the descriptor has until a quiet period passes (or EOF),
/// so a multi-line pretty manifest is drained without an EOF dependency.
private func drain(fd: Int32, quiet: TimeInterval = 0.3, deadline: TimeInterval = 5) -> String {
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

// MARK: - The spawned binary's faces

/// End-to-end acceptance for a compiled `interface: .oneShot` binary: every
/// face of the facade, driven the way a harness drives it — a real process,
/// real pipes, real exit codes.
@Suite(.serialized)
struct StdinToolE2ETests {

    @Test("plugin frame answers with stdin held open, then the process exits 0")
    func pluginFrameCompletesWithStdinOpen() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array(#"{"tool":"echo","args":{"message":"hi"}}"#.utf8) + [0x0A])

        // stdin stays OPEN (the write end is never closed): the process must
        // still answer and exit — a stdin-holding harness cannot hang.
        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"result":"hi"}"#)
    }

    @Test("json-rpc frames are served and stdin EOF exits 0")
    func jsonrpcFrameServedAtEOF() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8) + [0x0A])
        close(tool.stdinWrite)

        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.contains("\"id\":1"))
        #expect(stdout.contains("\"echo\""))
        #expect(stdout.contains("\"admin\""))
    }

    @Test("tool-level failures are results, not exit codes")
    func toolFailureIsAResult() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array(#"{"tool":"fail","args":{"message":"boom"}}"#.utf8) + [0x0A])
        close(tool.stdinWrite)

        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"result":"Error: boom"}"#)
    }

    @Test("introspection runs without stdin: --mcp-list and --mcp-manifest arc")
    func introspectionWithoutStdin() async throws {
        let listTool = try SpawnedTool.spawn(path: try fixtureToolPath(), arguments: ["--mcp-list"])
        let listExit = try await listTool.waitForExit()
        #expect(listExit == .code(0))
        let listText = drain(fd: listTool.stdoutRead)
        let catalog = try #require((try? QuickJSON.decode(AnyCodable.self, from: Array(listText.utf8)))?.value as? [String: Any])
        #expect(catalog["name"] as? String == "mcp-fixture-tool")
        #expect((catalog["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["echo", "add", "fail", "admin"])

        let manifestTool = try SpawnedTool.spawn(path: try fixtureToolPath(), arguments: ["--mcp-manifest", "arc"])
        let manifestExit = try await manifestTool.waitForExit()
        #expect(manifestExit == .code(0))
        let manifestText = drain(fd: manifestTool.stdoutRead)
        let manifest = try #require((try? QuickJSON.decode(AnyCodable.self, from: Array(manifestText.utf8)))?.value as? [String: Any])
        #expect(manifest["name"] as? String == "mcp-fixture-tool")
        let tools = try #require(manifest["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["echo", "add", "fail", "admin"])
        #expect(tools.first?["toolset"] as? String == "mcp-fixture-tool")
        // the manifest's command is this very binary, absolutely resolved.
        #expect(tools.first?["command"] as? String == (try fixtureToolPath()))
    }

    @Test("an unrecognized first frame exits 1 with a stderr diagnostic and silent stdout")
    func malformedFirstFrameExitsOne() async throws {
        let tool = try SpawnedTool.spawn(path: try fixtureToolPath())
        try tool.writeFrame(Array("definitely not json".utf8) + [0x0A])

        let exit = try await tool.waitForExit()
        #expect(exit == .code(1))

        let stdout = drain(fd: tool.stdoutRead, quiet: 0.1)
        #expect(stdout.isEmpty)
        let stderr = drain(fd: tool.stderrRead, quiet: 0.1)
        #expect(stderr.contains("no dialect recognized the first frame"))
    }

    @Test("the MCP_ACCESS_LEVEL environment gates dispatch in the spawned child")
    func accessLevelEnvironmentGatesDispatch() async throws {
        // public trust: the admin-gated tool must be denied — and the failure
        // is a result (exit 0), never an exit code.
        let tool = try SpawnedTool.spawn(
            path: try fixtureToolPath(),
            environment: ["MCP_ACCESS_LEVEL": "0"]
        )
        try tool.writeFrame(Array(#"{"tool":"admin","args":{"message":"hi"}}"#.utf8) + [0x0A])

        let exit = try await tool.waitForExit()
        #expect(exit == .code(0))

        let stdout = drain(fd: tool.stdoutRead)
        #expect(stdout.contains(#""Error: Access denied: admin""#))
    }

    @Test("a regular-file stdin is rejected before transport start, naming the stream")
    func regularFileStdinIsRejected() async throws {
        let inFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-preflight-stdin-\(UUID().uuidString).json").path
        try Data(#"{"tool":"echo","args":{"message":"hi"}}"#.utf8).write(to: URL(fileURLWithPath: inFile))
        defer { try? FileManager.default.removeItem(atPath: inFile) }

        // the harness shape `< file`: a perfectly valid frame, on a stream that
        // can never deliver it.
        let tool = try SpawnedTool.spawnWithFileStreams(path: try fixtureToolPath(), stdinFile: inFile)
        let exit = try await tool.waitForExit()
        #expect(exit == .code(1))

        let stdout = drain(fd: tool.stdoutRead, quiet: 0.1)
        #expect(stdout.isEmpty)
        let stderr = drain(fd: tool.stderrRead, quiet: 0.1)
        #expect(stderr.contains("stdin"))
        #expect(stderr.contains("regular file"))
        // the whole point of the preflight: not NIO's opaque transport-start
        // failure, which names neither the stream nor the cause.
        #expect(!stderr.contains("Operation unsupported"))
    }

    @Test("a regular-file stdout is rejected for transport, but --mcp-manifest may write to one")
    func regularFileStdoutShape() async throws {
        let dir = FileManager.default.temporaryDirectory

        // (a) the frame path: a redirected stdout is rejected up front, named,
        // and nothing is written into the file.
        let outFile = dir.appendingPathComponent("mcp-preflight-stdout-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: outFile) }
        let transport = try SpawnedTool.spawnWithFileStreams(path: try fixtureToolPath(), stdoutFile: outFile)
        let exit = try await transport.waitForExit()
        #expect(exit == .code(1))
        let stderr = drain(fd: transport.stderrRead, quiet: 0.1)
        #expect(stderr.contains("stdout"))
        #expect(!stderr.contains("Operation unsupported"))
        #expect((try? String(contentsOfFile: outFile, encoding: .utf8))?.isEmpty ?? true)

        // (b) the install path: introspection is answered before the preflight,
        // so `my-tool --mcp-manifest arc > manifest.json` still works.
        let manifestFile = dir.appendingPathComponent("mcp-preflight-manifest-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: manifestFile) }
        let manifest = try SpawnedTool.spawnWithFileStreams(
            path: try fixtureToolPath(),
            arguments: ["--mcp-manifest", "arc"],
            stdoutFile: manifestFile
        )
        let manifestExit = try await manifest.waitForExit()
        #expect(manifestExit == .code(0))
        let written = try String(contentsOfFile: manifestFile, encoding: .utf8)
        #expect(written.contains("\"mcp-fixture-tool\""))
    }

    @Test("/dev/null on stdin stays allowed — a char device is not a regular file")
    func characterDeviceStdinIsAllowed() async throws {
        // the preflight tests S_IFREG, not "is it a tty". /dev/null must keep
        // working, and the failure it does produce must be the host's own
        // empty-stdin contract, never the preflight.
        let tool = try SpawnedTool.spawnWithFileStreams(path: try fixtureToolPath(), stdinFile: "/dev/null")
        let exit = try await tool.waitForExit()
        #expect(exit == .code(1))

        let stderr = drain(fd: tool.stderrRead, quiet: 0.1)
        #expect(!stderr.contains("regular file"))
        #expect(stderr.contains("no request received"))
    }
}