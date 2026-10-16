//
//  MCPNestedLadderFixture.swift
//  MCPNestedLadderFixture
//
//  test-only fixture: proves the subprocess transport's shutdown ladder
//  reaches a server that leads NO process group of its own.
//
//  the ladder's naive target (`kill(-pid)`) is only correct for a child that
//  leads its own group. a top-level process gets that placement by default, so
//  the defect is invisible there — but every real deployment puts the
//  transport inside a launch (a harness spawns the MCP host), and a launch
//  child resolves `.inherited`, so it leads no group: the negated pid then
//  names a process group that does not exist, `kill` answers ESRCH, and the
//  ladder's signal rungs silently do nothing.
//
//  this fixture is that inner process. the suite spawns it through SwiftSlash
//  (so it is a launch child), and it drives the transport itself, so the server
//  the transport starts is genuinely `.inherited`.
//
//  usage: MCPNestedLadderFixture <marker>
//  the fixture writes `key=value` lines to <marker>; the suite reads them.
//

import Foundation
import MCP
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct MCPNestedLadderFixture {
	static func main() async {
		let arguments = CommandLine.arguments
		guard arguments.count >= 2 else {
			FileHandle.standardError.write(Data("usage: MCPNestedLadderFixture <marker>\n".utf8))
			exit(2)
		}
		let marker = arguments[1]
		let pidFile = marker + ".child"

		var report: [String: String] = [
			"fixturepid": String(getpid()),
			"fixturepgid": String(getpgid(0)),
			"fixturesid": String(getsid(0)),
		]

		// the server never reads stdin, so rung 1's EOF cannot stop it and the
		// ladder must escalate to its signal rungs. `exec` keeps it a single
		// process: one pid, no descendant, and nothing that could hide in a
		// second group. its only job is to publish its own pid so the placement
		// can be read while it is still alive.
		let script = "echo $$ > '\(pidFile)'; exec sleep 30"
		let transport = SubprocessClientTransport(
			configuration: .init(
				executable: "/bin/sh",
				arguments: ["-c", script],
				shutdownGrace: .milliseconds(300)
			)
		)

		do {
			try await transport.start()
		} catch {
			report["error"] = "start: \(error)"
			write(report, to: marker)
			exit(3)
		}

		var childPID: Int32 = -1
		let deadline = ContinuousClock.now + .seconds(5)
		while ContinuousClock.now < deadline {
			if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
			   let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
			   value > 0 {
				childPID = value
				break
			}
			try? await Task.sleep(for: .milliseconds(20))
		}

		report["childpid"] = String(childPID)
		if childPID > 0 {
			report["childpgid"] = String(getpgid(childPID))
			report["childsid"] = String(getsid(childPID))
		}

		do {
			try await transport.stop()
		} catch {
			report["stopError"] = "\(error)"
		}

		if childPID > 0 {
			let alive = kill(childPID, 0) == 0
			report["alive"] = alive ? "1" : "0"
			report["reaped"] = transport.childExit == nil ? "0" : "1"
		}

		write(report, to: marker)
		exit(0)
	}

	private static func write(_ report: [String: String], to path: String) {
		let text = report.keys.sorted().map { "\($0)=\(report[$0]!)" }.joined(separator: "\n") + "\n"
		try? text.write(toFile: path, atomically: true, encoding: .utf8)
	}
}