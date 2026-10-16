import Testing
import Foundation
import SwiftSlash
@testable import MCP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The shutdown ladder's signal target must follow the child's placement.
///
/// A top-level transport starts a server that leads its own process group, and
/// `kill(-pid)` cascades through its tree. The same transport inside a launch —
/// the shape every real deployment has, because a harness owns the MCP host —
/// starts a server that is `.inherited`: it joins the enclosing group and leads
/// none of its own, so a negated pid addresses a group that does not exist and
/// the signal rungs of the ladder silently do nothing.
///
/// The nested case can only be reached from inside a launch, so the driver is a
/// fixture process spawned through SwiftSlash (see `MCPNestedLadderFixture`).
@Suite(.serialized)
struct SubprocessLadderPlacementTests {

	/// Locates the built `MCPNestedLadderFixture` binary. `swift build` must
	/// have run first (the test target does not build the executable itself).
	private func fixturePath() throws -> String {
		let source = URL(fileURLWithPath: #filePath)
		let repoRoot = source
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let candidates = [
			repoRoot.appendingPathComponent(".build/debug/MCPNestedLadderFixture"),
			repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/MCPNestedLadderFixture"),
			repoRoot.appendingPathComponent(".build/out/Products/Debug/MCPNestedLadderFixture"),
		]
		for path in candidates where FileManager.default.fileExists(atPath: path.path) {
			return path.path
		}
		throw MCPClientError.spawnFailed("MCPNestedLadderFixture binary not found; run `swift build` first")
	}

	private func readReport(_ path: String) throws -> [String: String] {
		let text = try String(contentsOfFile: path, encoding: .utf8)
		var report: [String: String] = [:]
		for line in text.split(separator: "\n") {
			guard let separator = line.firstIndex(of: "=") else { continue }
			report[String(line[..<separator])] = String(line[line.index(after: separator)...])
		}
		return report
	}

	@Test("the ladder stops a server that leads no process group of its own")
	func ladderStopsAnInheritedServer() async throws {
		let scratch = FileManager.default.temporaryDirectory
			.appendingPathComponent("mcp-ladder-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: scratch) }
		let marker = scratch.appendingPathComponent("report.txt").path

		// spawn the fixture through SwiftSlash: being a launch child is what
		// makes the transport's own server resolve `.inherited`.
		var command = Command(absolutePath: Path(try fixturePath()), arguments: [marker])
		command.inheritCurrentEnvironment()
		let fixture = ChildProcess(command, dataChannels: [
			STDIN_FILENO: .read(.fromNull),
			STDOUT_FILENO: .write(.toNull),
			STDERR_FILENO: .write(.toNull),
		])
		_ = try await fixture.run(cancellationSignal: SIGTERM)

		let report = try readReport(marker)
		#expect(report["error"] == nil)

		// never leave the server behind: if it survived, this test must not be
		// the thing that leaks a 30s process.
		let childPID = Int32(report["childpid"] ?? "") ?? -1
		if childPID > 0, report["alive"] == "1" {
			_ = kill(childPID, SIGKILL)
		}

		// the mechanism: the server joined the fixture's group and leads none of
		// its own — which is exactly why a negated pid cannot address it.
		#expect(childPID > 0)
		#expect(report["childpgid"] == report["fixturepid"])
		#expect(report["childpgid"] != report["childpid"])

		// the outcome: the ladder's signal actually arrived.
		#expect(report["alive"] == "0")
		#expect(report["reaped"] == "1")
	}
}