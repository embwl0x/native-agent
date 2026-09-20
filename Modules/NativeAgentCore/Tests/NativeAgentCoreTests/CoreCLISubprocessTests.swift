import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentCore

// Everything below runs against a temp data root; nothing touches the live tree.

// MARK: - bounded subprocess runner

private struct CLIRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Locate a built product next to this package's test bundle. `swift test`
/// builds every target in the package, so the CLI is present whenever these
/// tests run. A missing binary is a REAL failure of this eval's premise, not a
/// reason to skip — a silently-skipped CLI eval is exactly the vacuity the
/// coverage ledger exists to catch.
private func builtProduct(_ name: String) throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NativeAgentCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore (package root)
    let buildDir = packageRoot.appendingPathComponent(".build", isDirectory: true)
    var candidates: [URL] = ["debug", "release"].map {
        buildDir.appendingPathComponent($0, isDirectory: true).appendingPathComponent(name)
    }
    // Non-symlinked layouts (`.build/<triple>/debug/...`).
    if let entries = try? FileManager.default.contentsOfDirectory(
        at: buildDir, includingPropertiesForKeys: nil
    ) {
        for entry in entries where entry.lastPathComponent.contains("apple-macosx") {
            candidates.append(entry.appendingPathComponent("debug").appendingPathComponent(name))
            candidates.append(entry.appendingPathComponent("release").appendingPathComponent(name))
        }
    }
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw NSError(domain: "CoreCLISubprocessTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey:
            "built product '\(name)' not found under \(buildDir.path) — the CLI eval cannot run",
    ])
}

/// Run with a hard deadline and concurrent pipe drains on dedicated Threads.
/// An unbounded `waitUntilExit()` here would wedge the whole suite; a
/// `readDataToEndOfFile` on the main thread deadlocks on a full pipe buffer.
private func runCLI(
    _ executable: URL,
    _ arguments: [String],
    cwd: URL? = nil,
    environment: [String: String] = [:],
    removingEnvironment: Set<String> = [],
    timeout: TimeInterval = 60
) throws -> CLIRun {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    // Never let an ambient root leak into a precedence assertion.
    env.removeValue(forKey: "NATIVE_AGENT_DATA_ROOT")
    for key in removingEnvironment { env.removeValue(forKey: key) }
    for (key, value) in environment { env[key] = value }
    process.environment = env

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    let lock = NSLock()
    var outData = Data()
    var errData = Data()
    let group = DispatchGroup()
    for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
        group.enter()
        let thread = Thread {
            // 2026-09-08: readDataToEndOfFile raises an uncatchable ObjC exception when the
            // pipe closes under the pooled gate; the throwing read returns what arrived.
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            lock.lock()
            if isOut { outData = data } else { errData = data }
            lock.unlock()
            group.leave()
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    _ = group.wait(timeout: .now() + 10)

    lock.lock()
    defer { lock.unlock() }
    return CLIRun(
        exitCode: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

private func cliTempRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("core-cli-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "CoreCLISubprocessTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "not a JSON object: \(text.prefix(400))",
        ])
    }
    return object
}

// MARK: - task-ledger

@Test("task-ledger append → claim → list round-trips through a hermetic data root")
func taskLedgerCLIRoundTrip() throws {
    let cli = try builtProduct("task-ledger")
    let root = try cliTempRoot("ledger")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)

    let appended = try runCLI(cli, [
        "--data-root", dataRoot.path, "append",
        "--actor", "claude", "--kind", "created",
        "--title", "eval fixture", "--note", "from the coverage wave",
        "--ref", "docs/evals/ledger.json",
    ])
    #expect(appended.exitCode == 0, "append failed: \(appended.stderr)")
    let appendedJSON = try jsonObject(appended.stdout)
    #expect(appendedJSON["status"] as? String == "ok")
    let taskID = try #require(appendedJSON["task_id"] as? String)
    #expect(!taskID.isEmpty)

    let claimed = try runCLI(cli, [
        "--data-root", dataRoot.path, "claim",
        "--actor", "codex", "--task-id", taskID,
    ])
    #expect(claimed.exitCode == 0, "claim failed: \(claimed.stderr)")
    #expect(try jsonObject(claimed.stdout)["status"] as? String == "ok")

    let listed = try runCLI(cli, ["--data-root", dataRoot.path, "list", "--task-id", taskID])
    #expect(listed.exitCode == 0)
    let listedJSON = try jsonObject(listed.stdout)
    #expect(listedJSON["status"] as? String == "ok")
    let events = try #require(listedJSON["events"] as? [[String: Any]])
    #expect(events.count == 2, "the ledger dropped an event")
    #expect(events.compactMap { $0["kind"] as? String } == ["created", "claimed"])

    // The whole ledger listing sees the same task.
    let all = try runCLI(cli, ["--data-root", dataRoot.path, "list"])
    #expect(all.exitCode == 0)
    let tasks = try #require(try jsonObject(all.stdout)["tasks"] as? [[String: Any]])
    // NOTE the vocabulary split: the CLI envelope says `task_id`, the compacted
    // task state says `taskId`. Both spellings are load-bearing for shell callers.
    #expect(tasks.contains { ($0["taskId"] as? String) == taskID })
    #expect(tasks.first(where: { ($0["taskId"] as? String) == taskID })?["status"] as? String == "claimed")
    #expect(tasks.first(where: { ($0["taskId"] as? String) == taskID })?["owner"] as? String == "codex")
}

@Test("a second claim on the same task exits 3, not 0 and not 1")
func taskLedgerCLIClaimConflictExitCode() throws {
    let cli = try builtProduct("task-ledger")
    let root = try cliTempRoot("conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)

    let created = try runCLI(cli, [
        "--data-root", dataRoot.path, "append", "--actor", "claude", "--kind", "created",
        "--title", "contested",
    ])
    let taskID = try #require(try jsonObject(created.stdout)["task_id"] as? String)

    let first = try runCLI(cli, [
        "--data-root", dataRoot.path, "claim", "--actor", "claude", "--task-id", taskID,
    ])
    #expect(first.exitCode == 0)

    let second = try runCLI(cli, [
        "--data-root", dataRoot.path, "claim", "--actor", "codex", "--task-id", taskID,
    ])
    // 3 is the SHELL CONTRACT for "someone else holds this". Collapsing it to
    // 1 (generic error) or 0 (success) makes a lost race look like a won one.
    #expect(second.exitCode == 3, "conflict exit code drifted: \(second.exitCode) \(second.stderr)")
    #expect(try jsonObject(second.stdout)["status"] as? String == "conflict")

    // --force is the documented override and returns to exit 0.
    let forced = try runCLI(cli, [
        "--data-root", dataRoot.path, "claim", "--actor", "codex",
        "--task-id", taskID, "--force",
    ])
    #expect(forced.exitCode == 0, "forced claim failed: \(forced.stderr)")
}

@Test("usage errors exit 64 and never write a partial event")
func taskLedgerCLIUsageExitCodes() throws {
    let cli = try builtProduct("task-ledger")
    let root = try cliTempRoot("usage")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let base = ["--data-root", dataRoot.path]

    #expect(try runCLI(cli, base).exitCode == 64)                                  // no command
    #expect(try runCLI(cli, base + ["nonsense"]).exitCode == 64)                   // unknown command
    #expect(try runCLI(cli, base + ["append"]).exitCode == 64)                     // no --actor
    #expect(try runCLI(cli, base + ["append", "--actor", "martian"]).exitCode == 64)
    #expect(try runCLI(cli, base + ["append", "--actor", "claude", "--kind", "nope"]).exitCode == 64)
    #expect(try runCLI(cli, base + ["append", "--actor", "claude", "--kind", "done"]).exitCode == 64)
    #expect(try runCLI(cli, base + ["claim", "--actor", "claude"]).exitCode == 64) // no --task-id
    #expect(try runCLI(cli, base + ["list", "stray-positional"]).exitCode == 64)

    // `help` is a success, and it names every command a caller may rely on.
    let help = try runCLI(cli, ["help"])
    #expect(help.exitCode == 0)
    for command in ["append", "claim", "list"] {
        #expect(help.stderr.contains(command), "usage no longer names '\(command)'")
    }
    #expect(help.stderr.contains("NATIVE_AGENT_DATA_ROOT"))

    // None of the rejected invocations may have created a ledger.
    let listing = try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)
    #expect((listing ?? []).isEmpty, "a usage error wrote into the data root: \(listing ?? [])")
}

@Test("data-root precedence: --data-root beats the env var beats <cwd>/data")
func taskLedgerCLIDataRootPrecedence() throws {
    let cli = try builtProduct("task-ledger")
    let root = try cliTempRoot("precedence")
    defer { try? FileManager.default.removeItem(at: root) }
    let explicitRoot = root.appendingPathComponent("explicit", isDirectory: true)
    let envRoot = root.appendingPathComponent("env", isDirectory: true)
    let cwd = root.appendingPathComponent("cwd", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    func ledgerExists(_ dataRoot: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path) else {
            return false
        }
        return !entries.isEmpty
    }

    // 1. Explicit flag wins even with the env var set to somewhere else.
    let explicit = try runCLI(
        cli,
        ["--data-root", explicitRoot.path, "append", "--actor", "claude", "--title", "explicit"],
        cwd: cwd,
        environment: ["NATIVE_AGENT_DATA_ROOT": envRoot.path]
    )
    #expect(explicit.exitCode == 0, "\(explicit.stderr)")
    #expect(ledgerExists(explicitRoot))
    #expect(!ledgerExists(envRoot), "the env var overrode an explicit --data-root")
    #expect(!ledgerExists(cwd.appendingPathComponent("data", isDirectory: true)))

    // 2. Env var wins over the cwd fallback.
    let viaEnv = try runCLI(
        cli,
        ["append", "--actor", "claude", "--title", "env"],
        cwd: cwd,
        environment: ["NATIVE_AGENT_DATA_ROOT": envRoot.path]
    )
    #expect(viaEnv.exitCode == 0, "\(viaEnv.stderr)")
    #expect(ledgerExists(envRoot))
    #expect(
        !ledgerExists(cwd.appendingPathComponent("data", isDirectory: true)),
        "THE SPLIT-LEDGER HAZARD: an env-rooted run also wrote a stray <cwd>/data"
    )

    // 3. With neither, the LAST-RESORT is <cwd>/data — the stray-ledger shape
    //    the source comment warns about. Pinned so it stays last, not first.
    let viaCwd = try runCLI(cli, ["append", "--actor", "claude", "--title", "cwd"], cwd: cwd)
    #expect(viaCwd.exitCode == 0, "\(viaCwd.stderr)")
    #expect(ledgerExists(cwd.appendingPathComponent("data", isDirectory: true)))

    // The three roots hold three DIFFERENT ledgers — proof the precedence
    // actually routed the writes rather than all three landing in one place.
    for (label, dataRoot) in [
        ("explicit", explicitRoot), ("env", envRoot),
        ("cwd", cwd.appendingPathComponent("data", isDirectory: true)),
    ] {
        let listed = try runCLI(cli, ["--data-root", dataRoot.path, "list"])
        let tasks = try #require(try jsonObject(listed.stdout)["tasks"] as? [[String: Any]])
        #expect(tasks.count == 1, "\(label) root holds \(tasks.count) tasks, expected 1")
        #expect(tasks.first?["title"] as? String == label)
    }
}
