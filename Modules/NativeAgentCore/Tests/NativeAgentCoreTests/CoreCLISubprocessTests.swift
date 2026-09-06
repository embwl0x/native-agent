import Foundation
import PersistenceCore
import ProviderRouting
import Testing
@testable import NativeAgentCore

// Ledger rows: cli.taskLedger.commands, cli.taskLedger.dataRootPrecedence,
//              cli.deskSweep.flags, cli.chatDrive.chat,
//              cli.chatDrive.physiologySoakReport, cli.chatDrive.workshopCancel
//
// Silent-failure class: DEAD CONTROL + SPLIT LEDGER. These two CLIs are
// operator surfaces with no test target of their own (they are executable
// targets, not subsystems), so nothing has ever run them. Two named hazards:
//
//   * task-ledger's data-root precedence is `--data-root` > NATIVE_AGENT_DATA_ROOT
//     > `<cwd>/data` LAST-RESORT. The source comment at main.swift:199-205 spells
//     out the hazard: a non-repo cwd silently splits the CROSS-AGENT ledger onto
//     a stray `<cwd>/data` with its own flock sidecar, so Claude and codex stop
//     seeing each other's claims with no error on either side.
//   * task-ledger's exit codes ARE its contract for shell callers: 0 ok,
//     3 claim conflict, 64 usage. A conflict that starts exiting 1 (or 0) makes
//     `script/task_ledger.sh` treat a lost race as a won one.
//   * desk-sweep's argv loop exits 2 on an unknown argument. A regression that
//     falls through instead would run a WRITING sweep with a typo'd flag.
//
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
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

private func jsonArray(_ text: String) throws -> [[String: Any]] {
    guard let data = text.data(using: .utf8),
          let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw NSError(domain: "CoreCLISubprocessTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "not a JSON array: \(text.prefix(400))",
        ])
    }
    return array
}

private func writeJSONLFixture(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    // An empty lane is an EMPTY FILE. `[] -> "\n"` would plant one blank
    // physical line per fixture, which the bounded reader honestly reports as
    // a malformed row — corrupting malformed-count assertions with fixture
    // artifacts no production writer ever produces (appendJSONL always writes
    // exactly `row\n`).
    let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try Data(content.utf8).write(to: url)
}

private func regularFileSnapshot(under root: URL) throws -> [String: Data] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: []
    ) else { return [:] }
    var snapshot: [String: Data] = [:]
    for case let url as URL in enumerator {
        if try url.resourceValues(forKeys: Set(keys)).isRegularFile == true {
            snapshot[url.path.replacingOccurrences(of: root.path + "/", with: "")] = try Data(contentsOf: url)
        }
    }
    return snapshot
}

/// Decode the JSONL event records written by a CLI subprocess without
/// coupling the contract to encoder whitespace or trace-file rotation names.
private func jsonLines(in snapshot: [String: Data]) -> [[String: Any]] {
    snapshot.values.flatMap { data in
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? jsonObject(String($0)) }
    }
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

// MARK: - desk-sweep

// MARK: - chat-drive

// EVAL FENCE: core.misc / cli.chatDrive.chat
//
// The CLI's hermetic fixture supplies only provider transport. It must still
// traverse the real command parser, route admission, turn orchestration,
// session persistence, and canonical terminal trace path. The reply's prose
// is deliberately not asserted: the contract is a non-empty assistant result
// plus its durable turn receipt, not fixture-word matching.
@Test("chat-drive chat completes a hermetic turn with assistant text and a terminal receipt")
func chatDriveChatCLIRoundTripsHermeticTurn() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-chat")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let session = "chat-eval-session"
    let run = try runCLI(
        cli,
        ["chat", "--surface", "chat", "--model", "fixture-model", "say hello"],
        cwd: root,
        environment: [
            "NATIVE_AGENT_DATA_ROOT": dataRoot.path,
            "NA_CHAT_SESSION": session,
            "NATIVE_AGENT_CHAT_DRIVE_HERMETIC": "1",
            "NATIVE_AGENT_CHAT_DRIVE_REPLY": "hermetic provider response",
        ]
    )

    #expect(run.exitCode == 0, "chat failed: \(run.stderr)\n\(run.stdout)")
    let replySection = try #require(
        run.stdout.components(separatedBy: "--- ASSISTANT REPLY ---\n")
            .dropFirst()
            .first?
            .components(separatedBy: "--- META ---")
            .first
    )
    #expect(!replySection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!run.stdout.contains("--- ERROR ---"))

    // Decode persisted rows as JSON rather than substring-matching the
    // encoder's whitespace style: the durable encoder writes spaced keys
    // (`"kind": "turn.terminal"`), and the contract is the ROW, not its
    // byte formatting.
    let persisted = try regularFileSnapshot(under: dataRoot)
    let terminalForSession = jsonLines(in: persisted).contains {
        $0["kind"] as? String == "turn.terminal"
            && $0["sessionId"] as? String == session
    }
    #expect(terminalForSession)

    // A fixture reply is never an ambient production override: explicit
    // hermetic consent and a non-empty value are both required before any
    // chat owner is constructed or data-root bytes can be created.
    let adverseRoot = root.appendingPathComponent("adverse", isDirectory: true)
    for environment in [
        ["NATIVE_AGENT_DATA_ROOT": adverseRoot.path,
         "NATIVE_AGENT_CHAT_DRIVE_REPLY": "fixture response"],
        ["NATIVE_AGENT_DATA_ROOT": adverseRoot.path,
         "NATIVE_AGENT_CHAT_DRIVE_HERMETIC": "1",
         "NATIVE_AGENT_CHAT_DRIVE_REPLY": "   "],
    ] {
        let adverse = try runCLI(cli, ["chat", "no provider call"], cwd: root, environment: environment)
        #expect(adverse.exitCode == 64)
        #expect(adverse.stderr.contains("NATIVE_AGENT_CHAT_DRIVE_REPLY"))
        #expect(!FileManager.default.fileExists(atPath: adverseRoot.path))
    }
}

@Test("chat-drive stream emits incremental deltas before one matching terminal reply on a hermetic root")
func chatDriveStreamCLIRoundTripsHermeticStreamingTurn() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-stream")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let session = "stream-eval-session"
    // Each fixture chunk clears the surface stream's deliberate <=16-char
    // protocol-marker holdback (flushCompatibilityDeltaBuffer), so the turn
    // MUST surface at least two incremental deltas. Provider chunks do not
    // map 1:1 onto surface deltas — the holdback re-segments them — so the
    // pin is "incremental (>=2) and lossless", not an exact delta count.
    let expectedReply = "the first fixture chunk clears the holdback before the second lands"
    let run = try runCLI(
        cli,
        ["stream", "--surface", "chat", "--model", "fixture-model", "stream this"],
        cwd: root,
        environment: [
            "NATIVE_AGENT_DATA_ROOT": dataRoot.path,
            "NA_CHAT_SESSION": session,
            "NATIVE_AGENT_CHAT_DRIVE_HERMETIC": "1",
            "NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS":
                #"["the first fixture chunk clears the holdback ","before the second lands"]"#,
        ]
    )

    #expect(run.exitCode == 0, "stream failed: \(run.stderr)\n\(run.stdout)")
    #expect(run.stdout.hasPrefix("\(expectedReply)\n--- STREAM META ---"))
    #expect(run.stdout.contains("reply: \(expectedReply)"))
    let deltaCount = run.stdout
        .split(whereSeparator: \.isNewline)
        .first(where: { $0.hasPrefix("delta_count:") })
        .flatMap { Int($0.dropFirst("delta_count:".count).trimmingCharacters(in: .whitespaces)) }
    #expect((deltaCount ?? 0) >= 2, "stream was not incremental: \(run.stdout)")
    #expect(!run.stdout.contains("--- STREAM ERROR ---"))

    // The subprocess must reach the same terminal persistence boundary as the
    // Mac stream, not merely print fixture chunks. Search the hermetic root's
    // durable files rather than assuming a trace rotation filename.
    let persisted = try regularFileSnapshot(under: dataRoot)
    #expect(jsonLines(in: persisted).contains {
        $0["kind"] as? String == "turn.terminal"
            && $0["sessionId"] as? String == session
    })

    let beforeMalformed = try regularFileSnapshot(under: dataRoot)
    let malformed = try runCLI(
        cli,
        ["stream", "bad fixture"],
        cwd: root,
        environment: [
            "NATIVE_AGENT_DATA_ROOT": dataRoot.path,
            "NATIVE_AGENT_CHAT_DRIVE_HERMETIC": "1",
            "NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS": "[]",
        ]
    )
    #expect(malformed.exitCode == 64)
    #expect(malformed.stderr.contains("must be a non-empty JSON string array"))
    #expect(try regularFileSnapshot(under: dataRoot) == beforeMalformed)

    // An unguarded fixture value is an invalid invocation, not a hidden way
    // to redirect a production stream. Validation must precede root assembly.
    let unguardedRoot = root.appendingPathComponent("unguarded", isDirectory: true)
    let unguarded = try runCLI(
        cli,
        ["stream", "no fixture consent"],
        cwd: root,
        environment: [
            "NATIVE_AGENT_DATA_ROOT": unguardedRoot.path,
            "NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS": #"["not allowed"]"#,
        ]
    )
    #expect(unguarded.exitCode == 64)
    #expect(unguarded.stderr.contains("requires NATIVE_AGENT_CHAT_DRIVE_HERMETIC=1"))
    #expect(!FileManager.default.fileExists(atPath: unguardedRoot.path))
}

// EVAL FENCE: core.misc / cli.chatDrive.env.chatSession
@Test("chat-drive normalizes NA_CHAT_SESSION once, retains it across turns, and refuses hostile values before opening state")
func chatDriveEnvironmentSessionIsDurableAndFailClosed() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-env-session")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let rawSession = " \n cli-session:durable \t "
    let session = "cli-session:durable"
    let commonEnvironment = [
        "NATIVE_AGENT_DATA_ROOT": dataRoot.path,
        "NA_CHAT_SESSION": rawSession,
        "NATIVE_AGENT_CHAT_DRIVE_HERMETIC": "1",
    ]

    // Two normal turns and the mounted stream all use the one normalized
    // identity and append to its one durable conversation.
    for (message, reply) in [("first retained turn", "first reply"), ("second retained turn", "second reply")] {
        var environment = commonEnvironment
        environment["NATIVE_AGENT_CHAT_DRIVE_REPLY"] = reply
        let run = try runCLI(cli, ["chat", "--model", "fixture-model", message], environment: environment)
        #expect(run.exitCode == 0, "chat session run failed: \(run.stderr)\n\(run.stdout)")
        #expect(run.stdout.contains("session: \(session)"))
        #expect(run.stderr.contains("sessionId=\(session)"))
    }
    var streamEnvironment = commonEnvironment
    streamEnvironment["NATIVE_AGENT_CHAT_DRIVE_STREAM_CHUNKS"] = #"["stream ","reply"]"#
    let stream = try runCLI(
        cli,
        ["stream", "--model", "fixture-model", "third retained turn"],
        environment: streamEnvironment
    )
    #expect(stream.exitCode == 0, "stream session run failed: \(stream.stderr)\n\(stream.stdout)")
    #expect(stream.stdout.contains("session: \(session)"))
    #expect(stream.stderr.contains("sessionId=\(session)"))

    let transcript = dataRoot
        .appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(session).jsonl")
    #expect(FileManager.default.fileExists(atPath: transcript.path))
    let transcriptRows = String(decoding: try Data(contentsOf: transcript), as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .compactMap { try? jsonObject(String($0)) }
    #expect(transcriptRows.filter { ($0["role"] as? String) == "user" }.count == 3)
    #expect(transcriptRows.filter { ($0["role"] as? String) == "assistant" }.count == 3)
    let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
    let sessionRows = try JSONSerialization.jsonObject(with: Data(contentsOf: sessionsPath)) as? [[String: Any]] ?? []
    #expect(sessionRows.map { $0["id"] as? String } == [session])
    #expect(!FileManager.default.fileExists(
        atPath: transcript.deletingLastPathComponent().appendingPathComponent(rawSession + ".jsonl").path
    ))

    // Unset remains a mounted new-session request: it creates a visible fresh
    // `drive-` identity, not a nil session or reuse of the last env session.
    let fallbackRoot = root.appendingPathComponent("fallback", isDirectory: true)
    let fallback = try runCLI(
        cli,
        ["chat", "--model", "fixture-model", "fresh mounted session"],
        environment: [
            "NATIVE_AGENT_DATA_ROOT": fallbackRoot.path,
            "NATIVE_AGENT_CHAT_DRIVE_HERMETIC": "1",
            "NATIVE_AGENT_CHAT_DRIVE_REPLY": "fresh reply",
        ],
        removingEnvironment: ["NA_CHAT_SESSION"]
    )
    #expect(fallback.exitCode == 0, "unset session fallback failed: \(fallback.stderr)")
    let fallbackSession = fallback.stdout
        .split(whereSeparator: \.isNewline)
        .first(where: { $0.hasPrefix("session:") })
        .map { String($0.dropFirst("session:".count)).trimmingCharacters(in: .whitespaces) }
    #expect(fallbackSession?.hasPrefix("drive-") == true)
    #expect(fallbackSession != session)

    // A supplied but blank/path-hostile identity is never treated as unset.
    // Refusal occurs before fixture/client, routing, or chat persistence opens
    // the selected root.
    for badSession in ["", " \t\n", "../escape", "chat/messages", "a..b", ".hidden"] {
        let adverseRoot = root.appendingPathComponent("adverse-\(UUID().uuidString)", isDirectory: true)
        let adverse = try runCLI(
            cli,
            ["chat", "must refuse"],
            environment: [
                "NATIVE_AGENT_DATA_ROOT": adverseRoot.path,
                "NA_CHAT_SESSION": badSession,
                "NATIVE_AGENT_CHAT_DRIVE_HERMETIC": "1",
                "NATIVE_AGENT_CHAT_DRIVE_REPLY": "unreachable",
            ]
        )
        #expect(adverse.exitCode == 64, "\(String(reflecting: badSession)) exited \(adverse.exitCode): \(adverse.stderr)")
        #expect(adverse.stderr.contains("NA_CHAT_SESSION must be"))
        #expect(!FileManager.default.fileExists(atPath: adverseRoot.path))
    }
}

// EVAL FENCE: core.misc / cli.chatDrive.subcommandRouter
//
// The declared catalog is an operator contract. Probe every advertised name
// through the real executable's router-only help path: this is deliberately
// before each command owner, so commands that mutate stores or call providers
// are proven reachable without being exercised as side effects. The canonical
// enum also makes a missing production switch case a compile error.
@Test("chat-drive command catalog and router acknowledge every declared subcommand")
func chatDriveSubcommandRouterAcknowledgesCanonicalCatalog() throws {
    let cli = try builtProduct("chat-drive")
    let expected: Set<String> = [
        "dispatch", "chat", "stream", "provider-prefs", "doctor",
        "memory-migrate", "memory-recall", "memory-embedding-epoch",
        "memory-eval", "memory-hygiene", "living-fabric-eval", "procedure",
        "physiology-soak-report", "workshop-cancel", "provider-transplant-eval",
        "provider-transplant-fixture",
    ]

    let catalog = try runCLI(cli, ["--help"])
    #expect(catalog.exitCode == 0, "global help failed: \(catalog.stderr)")
    let usage = catalog.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(usage.hasPrefix("usage: chat-drive {"))
    let declared: Set<String> = {
        guard let open = usage.firstIndex(of: "{"),
              let close = usage[open...].firstIndex(of: "}") else { return [] }
        return Set(usage[usage.index(after: open)..<close].split(separator: "|").map(String.init))
    }()
    #expect(declared == expected, "catalog drifted: \(declared.sorted())")

    for command in declared.sorted() {
        let probe = try runCLI(cli, [command, "--help"])
        #expect(probe.exitCode == 0, "\(command) did not reach the router: \(probe.stderr)")
        #expect(
            probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "usage: chat-drive \(command) ...",
            "\(command) was not acknowledged by its canonical router path"
        )
        #expect(!probe.stderr.contains("unknown mode"))
    }

    let unknown = try runCLI(cli, ["not-a-chat-drive-command", "--help"])
    #expect(unknown.exitCode == 64)
    #expect(unknown.stderr.contains("unknown mode: not-a-chat-drive-command"))
}

@Test("chat-drive canonical read-only routes emit their top-level report shape on a hermetic root")
func chatDriveReadOnlySubcommandsEmitDocumentedTopLevelShapes() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-read-only-router")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    // Provider routing has its own canonical data-root lookup; seed only its
    // public authority so the route can return every documented row key.
    let providers = dataRoot.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try Data(#"{"chat":{"model":"gpt-5.6-sol","reasoningEffort":"high"}}"#.utf8)
        .write(to: providers.appendingPathComponent("surfaces.json"))
    try Data(#"{"chat":"codex"}"#.utf8).write(to: providers.appendingPathComponent("active.json"))
    let environment = [
        "NATIVE_AGENT_DATA_ROOT": dataRoot.path,
        "NATIVE_AGENT_EMBEDDING_MOCK": "1",
        "NATIVEAGENT_RELEASE_GATE": "0",
    ]

    let prefs = try runCLI(cli, ["provider-prefs"], environment: environment)
    #expect(prefs.exitCode == 0, "provider-prefs failed: \(prefs.stderr)")
    let preferenceRows = try jsonArray(prefs.stdout)
    let firstPreference = try #require(preferenceRows.first)
    #expect(firstPreference["surface"] is String)
    #expect(firstPreference["provider"] is String)
    #expect(firstPreference["model"] is String)

    let doctor = try runCLI(
        cli, ["doctor", "--repair", "false"], environment: environment
    )
    #expect(doctor.exitCode == 0, "doctor failed: \(doctor.stderr)")
    let doctorOutput = try jsonObject(doctor.stdout)
    #expect(doctorOutput["status"] is String)
    #expect(doctorOutput["repair"] as? Bool == false)
    #expect(doctorOutput["checks"] is [[String: Any]])

    let recall = try runCLI(cli, ["memory-recall", dataRoot.path, "hermetic query"], environment: environment)
    #expect(recall.exitCode == 0, "memory-recall failed: \(recall.stderr)")
    let recallOutput = try jsonObject(recall.stdout)
    #expect(recallOutput["query"] as? String == "hermetic query")
    #expect(recallOutput["total"] is Int)
    #expect(recallOutput["hits"] is [[String: Any]])

    let epoch = try runCLI(
        cli, ["memory-embedding-epoch", "status", dataRoot.path], environment: environment
    )
    #expect(epoch.exitCode == 0, "memory-embedding-epoch status failed: \(epoch.stderr)")
    let epochOutput = try jsonObject(epoch.stdout)
    #expect(epochOutput["schema"] as? String == "nativeagent.memory-embedding-epoch.v1")
    #expect(epochOutput["action"] as? String == "status")
    #expect(epochOutput["rollbackAvailable"] is Bool)

    let memoryEval = try runCLI(
        cli, ["memory-eval", "--query-mode", "natural", dataRoot.path], environment: environment, timeout: 60
    )
    #expect(memoryEval.exitCode == 0, "memory-eval failed: \(memoryEval.stderr)")
    let memoryEvalOutput = try jsonObject(memoryEval.stdout)
    #expect(memoryEvalOutput["embeddingMock"] as? Bool == true)
    #expect(memoryEvalOutput["verdict"] is [String: Any])
    #expect(memoryEvalOutput["liveStoreMutated"] as? Bool == false)

    let livingFabric = try runCLI(cli, ["living-fabric-eval", dataRoot.path], environment: environment)
    #expect(livingFabric.exitCode == 0, "living-fabric-eval failed: \(livingFabric.stderr)")
    let livingFabricOutput = try jsonObject(livingFabric.stdout)
    #expect(livingFabricOutput["traceWindow"] is [String: Any])
    #expect(livingFabricOutput["evidenceSources"] is [String: Any])

    let procedure = try runCLI(cli, ["procedure", "status", dataRoot.path], environment: environment)
    #expect(procedure.exitCode == 0, "procedure status failed: \(procedure.stderr)")
    let procedureOutput = try jsonObject(procedure.stdout)
    #expect(procedureOutput["schema"] as? String == "procedure.operator.status.v1")
    #expect(procedureOutput["artifactCount"] is Int)
    #expect(procedureOutput["payloadFree"] as? Bool == true)

    let soak = try runCLI(cli, ["physiology-soak-report", dataRoot.path], environment: environment)
    #expect(soak.exitCode == 0, "physiology-soak-report failed: \(soak.stderr)")
    let soakOutput = try jsonObject(soak.stdout)
    #expect(soakOutput["schema"] as? String == "chat-drive-physiology-soak-report.v1")
    #expect(soakOutput["evidenceSourceState"] as? String == "absent")
    #expect(soakOutput["report"] is [String: Any])
}

// EVAL FENCE: core.misc / cli.chatDrive.physiologySoakReport
//
// The report's zero-record analyzer output is legitimate only after the
// durable evidence directory was opened. This subprocess exercises the real
// ChatDrive route and the same bounded store reader the installed recorder
// uses, so an absent source can never be mistaken for a completed quiet soak.
@Test("chat-drive physiology-soak-report names absent, empty, and adverse evidence sources")
func chatDrivePhysiologySoakReportDisclosesEvidenceSource() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("physiology-soak-report")
    defer { try? FileManager.default.removeItem(at: root) }

    let absentRoot = root.appendingPathComponent("absent", isDirectory: true)
    let absent = try runCLI(cli, ["physiology-soak-report", absentRoot.path])
    #expect(absent.exitCode == 0, "absent source report failed: \(absent.stderr)")
    let absentOutput = try jsonObject(absent.stdout)
    #expect(absentOutput["schema"] as? String == "chat-drive-physiology-soak-report.v1")
    #expect(absentOutput["evidenceSourceState"] as? String == "absent")
    #expect(absentOutput["retainedDayFileCount"] as? Int == 0)
    #expect(absentOutput["unreadableDayFileCount"] as? Int == 0)
    let absentReport = try #require(absentOutput["report"] as? [String: Any])
    #expect(absentReport["recordCount"] as? Int == 0)
    #expect(
        (absentReport["claimBlockers"] as? [String] ?? []).contains("evidence is generated, mixed, or absent")
    )
    #expect(!FileManager.default.fileExists(atPath: absentRoot.path), "read-only report created an absent source")

    // An existing readable directory with no day files is a measured empty
    // store. It deliberately shares recordCount=0 with the absent case while
    // carrying a different source fact.
    let emptyRoot = root.appendingPathComponent("empty", isDirectory: true)
    let emptyStore = emptyRoot
        .appendingPathComponent("evals", isDirectory: true)
        .appendingPathComponent("installed_physiology_soak", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyStore, withIntermediateDirectories: true)
    let empty = try runCLI(cli, ["physiology-soak-report", emptyRoot.path])
    #expect(empty.exitCode == 0, "empty source report failed: \(empty.stderr)")
    let emptyOutput = try jsonObject(empty.stdout)
    #expect(emptyOutput["evidenceSourceState"] as? String == "readable")
    #expect(emptyOutput["retainedDayFileCount"] as? Int == 0)
    let emptyReport = try #require(emptyOutput["report"] as? [String: Any])
    #expect(emptyReport["recordCount"] as? Int == 0)

    // A malformed retained day is read as adverse evidence, not silently
    // dropped into an empty source. A directory masquerading as a day file
    // proves the reader also reports an actual open failure as unreadable.
    let adverseRoot = root.appendingPathComponent("adverse", isDirectory: true)
    let adverseStore = adverseRoot
        .appendingPathComponent("evals", isDirectory: true)
        .appendingPathComponent("installed_physiology_soak", isDirectory: true)
    try FileManager.default.createDirectory(at: adverseStore, withIntermediateDirectories: true)
    try Data("not-json\n".utf8).write(to: adverseStore.appendingPathComponent("2026-08-24.jsonl"))
    let malformed = try runCLI(cli, ["physiology-soak-report", adverseRoot.path])
    #expect(malformed.exitCode == 0, "malformed source report failed: \(malformed.stderr)")
    let malformedOutput = try jsonObject(malformed.stdout)
    #expect(malformedOutput["evidenceSourceState"] as? String == "readable")
    #expect(malformedOutput["retainedDayFileCount"] as? Int == 1)
    let malformedReport = try #require(malformedOutput["report"] as? [String: Any])
    #expect(malformedReport["malformedOrInvalidRecordCount"] as? Int == 1)
    #expect(malformedReport["realMultiDayClaimEligible"] as? Bool == false)

    let partialRoot = root.appendingPathComponent("partial", isDirectory: true)
    let partialStore = partialRoot
        .appendingPathComponent("evals", isDirectory: true)
        .appendingPathComponent("installed_physiology_soak", isDirectory: true)
    try FileManager.default.createDirectory(
        at: partialStore.appendingPathComponent("2026-08-25.jsonl", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("also-not-json\n".utf8).write(to: partialStore.appendingPathComponent("2026-08-24.jsonl"))
    let partial = try runCLI(cli, ["physiology-soak-report", partialRoot.path])
    #expect(partial.exitCode == 0, "partial source report failed: \(partial.stderr)")
    let partialOutput = try jsonObject(partial.stdout)
    #expect(partialOutput["evidenceSourceState"] as? String == "partial")
    #expect(partialOutput["retainedDayFileCount"] as? Int == 2)
    #expect(partialOutput["unreadableDayFileCount"] as? Int == 1)

    let unreadableRoot = root.appendingPathComponent("unreadable", isDirectory: true)
    let unreadableStore = unreadableRoot
        .appendingPathComponent("evals", isDirectory: true)
        .appendingPathComponent("installed_physiology_soak", isDirectory: true)
    try FileManager.default.createDirectory(
        at: unreadableStore.appendingPathComponent("2026-08-25.jsonl", isDirectory: true),
        withIntermediateDirectories: true
    )
    let unreadable = try runCLI(cli, ["physiology-soak-report", unreadableRoot.path])
    #expect(unreadable.exitCode == 0, "unreadable source report failed: \(unreadable.stderr)")
    let unreadableOutput = try jsonObject(unreadable.stdout)
    #expect(unreadableOutput["evidenceSourceState"] as? String == "unreadable")
    #expect(unreadableOutput["retainedDayFileCount"] as? Int == 1)
    #expect(unreadableOutput["unreadableDayFileCount"] as? Int == 1)
    let unreadableReport = try #require(unreadableOutput["report"] as? [String: Any])
    #expect(unreadableReport["malformedOrInvalidRecordCount"] as? Int == 1)
    #expect(unreadableReport["recordCount"] as? Int == 0)
}

// EVAL FENCE: core.misc / cli.chatDrive.workshopCancel
//
// Seed only the canonical Workshop execution record, then let the real CLI
// traverse the production runner. This proves the receipt comes from the
// durable cancellation owner rather than an argv-only acknowledgement.
@Test("chat-drive workshop-cancel persists one bounded cancellation receipt and rejects adverse invocations")
func chatDriveWorkshopCancelCLIRoundTripsCanonicalExecution() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("workshop-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("owner-data", isDirectory: true)
    let executionID = "cancel-eval-execution"
    let objective = "private objective must not appear in the cancellation receipt"
    let executionDirectory = dataRoot
        .appendingPathComponent("workshop/executions", isDirectory: true)
        .appendingPathComponent(executionID, isDirectory: true)
    try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
    let recordPath = executionDirectory.appendingPathComponent("execution.json")
    let timelinePath = executionDirectory.appendingPathComponent("timeline.jsonl")
    let record: JSONValue = .object([
        "id": .string(executionID),
        "title": .string("private title"),
        "objective": .string(objective),
        "created_at": .string("2026-08-01T00:00:00Z"),
        "status": .string("running"),
        "plan": .array([]),
        "steps_completed": .array([]),
        "receipts_dir": .string("receipts"),
        "trigger_source": .string("manual"),
        "trust_required": .string("none"),
        "expected_outputs": .array([]),
        "current_step_id": .string("step-1"),
        "updated_at": .string("2026-08-01T00:00:00Z"),
        "result": .null,
        "rerun_count": .int(0),
    ])
    try record.serializedData(pretty: false).write(to: recordPath)
    try writeJSONLFixture([
        #"{"event":"created","ts":"2026-08-01T00:00:00Z"}"#,
    ], to: timelinePath)

    let cancelled = try runCLI(
        cli,
        ["workshop-cancel", dataRoot.path, executionID],
        cwd: root
    )
    #expect(cancelled.exitCode == 0, "cancel failed: \(cancelled.stderr)\n\(cancelled.stdout)")
    let receipt = try jsonObject(cancelled.stdout)
    #expect(receipt["schema"] as? String == "workshop.cancel.receipt.v1")
    #expect(receipt["status"] as? String == "cancelled")
    #expect(receipt["phase"] as? String == "cancelled")
    #expect(receipt["verification"] as? String == "not_required")
    #expect(receipt["payloadFree"] as? Bool == true)
    let executionIdentity = try #require(receipt["executionIdentity"] as? String)
    #expect(!executionIdentity.isEmpty)
    #expect(executionIdentity != executionID)
    #expect(!cancelled.stdout.contains(objective))
    #expect(!cancelled.stdout.contains("private title"))

    let persistedRecord = try jsonObject(String(decoding: Data(contentsOf: recordPath), as: UTF8.self))
    #expect(persistedRecord["status"] as? String == "cancelled")
    let timelineAfterCancel = try Data(contentsOf: timelinePath)
    let cancelledEvents = jsonLines(in: ["timeline": timelineAfterCancel]).filter {
        $0["event"] as? String == "cancelled"
    }
    #expect(cancelledEvents.count == 1)

    // A new process sees the persisted terminal record and leaves both its
    // bytes and the single cancellation event alone.
    let repeated = try runCLI(
        cli,
        ["workshop-cancel", dataRoot.path, executionID],
        cwd: root
    )
    #expect(repeated.exitCode == 0, "idempotent cancel failed: \(repeated.stderr)")
    #expect(try Data(contentsOf: timelinePath) == timelineAfterCancel)
    #expect(try jsonObject(repeated.stdout)["status"] as? String == "cancelled")

    let beforeAdverse = try regularFileSnapshot(under: dataRoot)
    let missing = try runCLI(
        cli,
        ["workshop-cancel", dataRoot.path, "missing-execution"],
        cwd: root
    )
    #expect(missing.exitCode == 1)
    #expect(missing.stderr.contains("Workshop execution not found: missing-execution"))
    #expect(try regularFileSnapshot(under: dataRoot) == beforeAdverse)

    let blankID = try runCLI(cli, ["workshop-cancel", dataRoot.path, "   "], cwd: root)
    #expect(blankID.exitCode == 64)
    #expect(blankID.stderr.contains("usage: chat-drive workshop-cancel"))
    #expect(try regularFileSnapshot(under: dataRoot) == beforeAdverse)

    let traversal = try runCLI(
        cli,
        ["workshop-cancel", dataRoot.path, "../outside-selected-root"],
        cwd: root
    )
    #expect(traversal.exitCode == 1)
    #expect(traversal.stderr.contains("executionId must be a single path component"))
    #expect(try regularFileSnapshot(under: dataRoot) == beforeAdverse)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("workshop/outside-selected-root").path
    ))
}

// EVAL FENCE: core.chat.persistence / chat.metacognition.livingFabricEvalRoute
@Test("chat-drive living-fabric-eval discloses its canonical trace window and adverse input")
func chatDriveLivingFabricEvalRouteDisclosesTraceWindow() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("living-fabric-eval")
    defer { try? FileManager.default.removeItem(at: root) }

    // Missing turn_traces is a valid read-only evaluation window, not a crash
    // or a fabricated 0% score. The window receipt names the no-evidence state
    // explicitly.
    let missingRoot = root.appendingPathComponent("missing", isDirectory: true)
    let missing = try runCLI(cli, ["living-fabric-eval", missingRoot.path])
    #expect(missing.exitCode == 0, "missing trace root failed: \(missing.stderr)")
    let missingReport = try jsonObject(missing.stdout)
    let missingWindow = try #require(missingReport["traceWindow"] as? [String: Any])
    #expect(missingWindow["inputStatus"] as? String == "no trace files found")
    #expect(missingWindow["filesScanned"] as? Int == 0)
    #expect(missingReport["metacognition"] == nil)

    let boundedRoot = root.appendingPathComponent("bounded", isDirectory: true)
    let traces = boundedRoot.appendingPathComponent("turn_traces", isDirectory: true)
    // Twenty-two lexically dated lanes prove that the real CLI selects the
    // newest canonical 21-file window rather than scanning an archival root.
    for day in 1...22 {
        let file = traces.appendingPathComponent(String(format: "2026-07-%02d.jsonl", day))
        try writeJSONLFixture([], to: file)
    }
    let selectedFixture = traces.appendingPathComponent("2026-07-02.jsonl")
    try writeJSONLFixture([
        #"{"turnId":"trace-turn","ts":"2026-07-02T12:00:00.000Z","kind":"turn.plan","surface":"chat","payload":{"goalType":"build_task"}}"#,
        #"{"turnId":"plain-turn","ts":"2026-07-02T12:00:01.000Z","kind":"turn.plan","surface":"chat","payload":{}}"#,
        #"{"turnId":"trace-turn","ts":"2026-07-02T12:00:02.000Z","kind":"turn.terminal","payload":{"schema":"metacognition.observed.v1","status":"completed","modelUsed":"gpt-5.6","reasoningEffort":"high","turnElapsedMs":20}}"#,
        #"{"turnId":"trace-turn","ts":"2026-07-02T12:00:03.000Z","kind":"llm.call","payload":{"provider":"openai","model":"gpt-5.6","durationMs":10}}"#,
        "not-json",
        #"{"turnId":"rejected-event","kind":"turn.terminal","payload":{}}"#,
    ], to: selectedFixture)

    let bounded = try runCLI(cli, ["living-fabric-eval", boundedRoot.path])
    #expect(bounded.exitCode == 0, "bounded trace root failed: \(bounded.stderr)")
    let boundedReport = try jsonObject(bounded.stdout)
    let boundedWindow = try #require(boundedReport["traceWindow"] as? [String: Any])
    #expect(boundedWindow["filesDiscovered"] as? Int == 22)
    #expect(boundedWindow["filesScanned"] as? Int == 21)
    #expect(boundedWindow["filesOmittedBy21DayWindow"] as? Int == 1)
    #expect(boundedWindow["malformedJSONRows"] as? Int == 1)
    #expect(boundedWindow["rejectedEventRows"] as? Int == 1)
    #expect(boundedWindow["eventsRetained"] as? Int == 4)
    #expect(boundedWindow["eventsDiscardedByGlobalCap"] as? Int == 0)
}

// EVAL FENCE: core.misc / cli.chatDrive.livingFabricEval
@Test("chat-drive living-fabric-eval receipts distinguish absent, read, and unreadable evidence")
func chatDriveLivingFabricEvalEvidenceSourcesAreTruthful() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("living-fabric-evidence-sources")
    defer { try? FileManager.default.removeItem(at: root) }

    func evidenceSources(_ output: String) throws -> [String: Any] {
        let report = try jsonObject(output)
        return try #require(report["evidenceSources"] as? [String: Any])
    }
    func state(_ name: String, in sources: [String: Any]) throws -> String {
        let source = try #require(sources[name] as? [String: Any])
        return try #require(source["state"] as? String)
    }

    // Every named source is absent on a clone with no Living Fabric stores.
    // Its numeric projections may be zero, but the receipt is the controlling
    // fact: no section is allowed to make that zero look observed.
    let absentRoot = root.appendingPathComponent("absent", isDirectory: true)
    let absent = try runCLI(cli, ["living-fabric-eval", absentRoot.path])
    #expect(absent.exitCode == 0, "absent evidence root failed: \(absent.stderr)")
    let absentSources = try evidenceSources(absent.stdout)
    for source in [
        "turnTraces", "githubCommand", "workshopExecutions", "procedureArtifacts",
        "privacyClassification", "rollbackManifest",
    ] {
        #expect(try state(source, in: absentSources) == "source absent", "\(source) hid absence")
    }
    let absentTrace = try #require(absentSources["turnTraces"] as? [String: Any])
    #expect(absentTrace["filesRead"] as? Int == 0)
    #expect(!FileManager.default.fileExists(atPath: absentRoot.path), "read-only eval created an absent root")

    // Positive control: a real trace is opened by the compiled command and
    // renders a read receipt plus its bounded file count.
    let observedRoot = root.appendingPathComponent("observed", isDirectory: true)
    try writeJSONLFixture([
        #"{"turnId":"receipt-turn","ts":"2026-08-20T12:00:00.000Z","kind":"turn.plan","payload":{}}"#,
    ], to: observedRoot.appendingPathComponent("turn_traces/2026-08-20.jsonl"))
    let observed = try runCLI(cli, ["living-fabric-eval", observedRoot.path])
    #expect(observed.exitCode == 0, "observed evidence root failed: \(observed.stderr)")
    let observedSources = try evidenceSources(observed.stdout)
    #expect(try state("turnTraces", in: observedSources) == "read")
    let observedTrace = try #require(observedSources["turnTraces"] as? [String: Any])
    #expect(observedTrace["filesDiscovered"] as? Int == 1)
    #expect(observedTrace["filesRead"] as? Int == 1)

    // Negative control: a file where the trace directory must be is neither a
    // quiet lane nor a missing one. The report remains executable/read-only,
    // but names the source unreadable and derives no retained events from it.
    let unreadableRoot = root.appendingPathComponent("unreadable", isDirectory: true)
    try FileManager.default.createDirectory(at: unreadableRoot, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(
        to: unreadableRoot.appendingPathComponent("turn_traces"),
        options: .atomic
    )
    let unreadable = try runCLI(cli, ["living-fabric-eval", unreadableRoot.path])
    #expect(unreadable.exitCode == 0, "unreadable evidence root failed: \(unreadable.stderr)")
    let unreadableReport = try jsonObject(unreadable.stdout)
    let unreadableSources = try evidenceSources(unreadable.stdout)
    #expect(try state("turnTraces", in: unreadableSources) == "source unreadable")
    let unreadableWindow = try #require(unreadableReport["traceWindow"] as? [String: Any])
    #expect(unreadableWindow["inputStatus"] as? String == "source unreadable")
    #expect(unreadableWindow["eventsRetained"] as? Int == 0)
}

@Test("chat-drive rejects unknown or incomplete options before they become positional arguments")
func chatDriveCLIRejectsUnknownOrIncompleteOptions() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-options")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)

    for (arguments, expectedError) in [
        (["memory-hygiene", dataRoot.path, "--approve-swaps", "true"], "unknown option"),
        (["memory-hygiene", dataRoot.path, "--approve-swap"], "requires a value"),
        (["provider-transplant-fixture", "--targets"], "requires a value"),
    ] {
        let run = try runCLI(cli, arguments)
        #expect(run.exitCode == 64, "\(arguments) exited \(run.exitCode): \(run.stderr)")
        #expect(run.stderr.contains(expectedError), "\(arguments) hid its argv error: \(run.stderr)")
    }
    #expect(
        !FileManager.default.fileExists(atPath: dataRoot.path),
        "argv refusal opened a hygiene store at \(dataRoot.path)"
    )
}

@Test("chat-drive well-formed options preserve each positional consumer's binding")
func chatDriveCLIWellFormedOptionsPreservePositionalBinding() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-positive-options")
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("cwd", isDirectory: true)
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let fixture = root.appendingPathComponent("frozen-mind.json")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    // `chat` and `stream` use every positional as prompt text. With their one
    // well-formed option present, no prompt remains, so usage is the only
    // acceptable outcome. If --surface becomes a positional again these would
    // enter a provider call instead of failing at the CLI boundary.
    for mode in ["chat", "stream"] {
        let run = try runCLI(cli, [mode, "--surface", "chat"])
        #expect(run.exitCode == 64, "\(mode) option leaked into prompt positionals: \(run.stderr)")
        #expect(run.stderr.contains("usage: chat-drive \(mode)"))
    }

    // These one-positional consumers must likewise see no data root after a
    // well-formed option, rather than treating the option spelling as the
    // root. The usage exit happens before any owner/store is opened.
    for (mode, option, value) in [
        ("memory-eval", "--query-mode", "compact"),
        ("memory-hygiene", "--approve-swap", "false"),
    ] {
        let run = try runCLI(cli, [mode, option, value])
        #expect(run.exitCode == 64, "\(mode) option leaked into data-root position: \(run.stderr)")
        #expect(run.stderr.contains("usage: chat-drive \(mode)"))
    }
    #expect(!FileManager.default.fileExists(atPath: dataRoot.path))

    // Dispatch has two positionals. Its intentional unknown-tool failure is
    // a safe executable receipt of all three bindings: option→surface,
    // positional[0]→tool, positional[1]→JSON input.
    let dispatch = try runCLI(cli, [
        "dispatch", "--surface", "telegram", "not_a_real_tool", "{}",
    ], cwd: cwd, environment: ["NATIVE_AGENT_DATA_ROOT": dataRoot.path])
    #expect(dispatch.exitCode == 1, "dispatch did not reach its bound tool: \(dispatch.stderr)")
    #expect(dispatch.stderr.contains("surface=telegram tool=not_a_real_tool input={}"))
    #expect(dispatch.stdout.contains("=== ERROR ==="))

    // Procedure's first two positionals select an action and data root while
    // --scope stays an option. `status` is read-only and gives a stable
    // executable receipt without manufacturing review/activation state.
    let procedure = try runCLI(cli, [
        "procedure", "status", dataRoot.path, "--scope", "manual",
    ])
    #expect(procedure.exitCode == 0, "procedure positional binding failed: \(procedure.stderr)")
    #expect(procedure.stdout.contains("procedure.operator.status.v1"))

    // The option-only fixture command is a positive control for the other
    // parser consumer: both required options are consumed, not appended as
    // stray positionals, and its requested output is produced under the
    // hermetic root.
    let transplantFixture = try runCLI(cli, [
        "provider-transplant-fixture",
        "--targets", "openai:gpt-5.4",
        "--output", fixture.path,
        "--mode", "smoke",
    ])
    #expect(transplantFixture.exitCode == 0, "fixture argv binding failed: \(transplantFixture.stderr)")
    #expect(FileManager.default.fileExists(atPath: fixture.path))

    // Doctor owns no positionals, but its boolean must still be consumed as an
    // option rather than drifting into a silently ignored argv tail.
    let doctor = try runCLI(cli, [
        "doctor", "--repair", "false",
    ], cwd: cwd, environment: ["NATIVE_AGENT_DATA_ROOT": dataRoot.path])
    #expect(doctor.exitCode == 0, "doctor option binding failed: \(doctor.stderr)")
    #expect(doctor.stderr.contains("[doctor] repair=false"))

    // FIX-5b: `--check-llm` never selected any behavior. It is gone from the
    // CLI, and a caller that still passes it must be told so instead of
    // getting a green report that pretends an LLM was probed.
    let staleFlag = try runCLI(cli, [
        "doctor", "--repair", "false", "--check-llm", "true",
    ], cwd: cwd, environment: ["NATIVE_AGENT_DATA_ROOT": dataRoot.path])
    #expect(staleFlag.exitCode == 64, "a retired flag must fail loudly: \(staleFlag.stderr)")
    #expect(staleFlag.stderr.contains("unknown option: --check-llm"))

    // Provider-transplant evaluation also has no positionals. A missing
    // fixture is an intentionally non-egress positive binding probe: a bound
    // --fixture reaches bounded artifact validation (ordinary failure), while
    // a positional regression instead fails the CLI's missing-fixture usage
    // guard before it can read anything.
    let missingFixture = root.appendingPathComponent("missing-fixture.json")
    let transplantEval = try runCLI(cli, [
        "provider-transplant-eval", "--fixture", missingFixture.path, "--public-safe", "true",
    ], cwd: cwd, environment: ["NATIVE_AGENT_DATA_ROOT": dataRoot.path])
    #expect(transplantEval.exitCode != 0)
    #expect(transplantEval.exitCode != 64, "provider eval lost its --fixture binding: \(transplantEval.stderr)")
}

// EVAL FENCE: core.misc / cli.chatDrive.providerPrefs
@Test("chat-drive provider-prefs reports a checked read-only provider and model for every surface")
func chatDriveProviderPrefsReportsDurableRoutingWithoutRecoveryWrites() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("provider-prefs")
    defer { try? FileManager.default.removeItem(at: root) }
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    let surfaces = providers.appendingPathComponent("surfaces.json")
    let active = providers.appendingPathComponent("active.json")
    try Data(#"{"chat":{"model":"gpt-5.6-sol","reasoningEffort":"high"},"missions":{"model":"gpt-5.4"}}"#.utf8)
        .write(to: surfaces)
    try Data(#"{"chat":"codex","telegram":"openai_oauth_direct"}"#.utf8)
        .write(to: active)
    let before = try regularFileSnapshot(under: root)

    let all = try runCLI(cli, ["provider-prefs"], environment: ["NATIVE_AGENT_DATA_ROOT": root.path])
    #expect(all.exitCode == 0, "provider-prefs failed: \(all.stderr)")
    let rows = try jsonArray(all.stdout)
    #expect(rows.count == MODEL_SURFACES.count)
    for row in rows {
        let surface = row["surface"] as? String
        let provider = row["provider"] as? String
        let model = row["model"] as? String
        #expect(surface?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(provider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(model != "claude-opus-4-8", "an unpinned surface used the retired hardcoded Claude default")
    }
    let chat = try #require(rows.first { ($0["surface"] as? String) == "chat" })
    #expect(chat["provider"] as? String == "codex")
    #expect(chat["providerSource"] as? String == "active_provider")
    #expect(chat["model"] as? String == "gpt-5.6-sol")
    let reflection = try #require(rows.first { ($0["surface"] as? String) == "cognition_reflection" })
    #expect(reflection["model"] as? String == "gpt-5.6-sol")
    #expect(reflection["provider"] as? String == "openai_oauth_direct")
    #expect(try regularFileSnapshot(under: root) == before, "read-only provider-prefs changed routing bytes")

    // The legacy spelling reads the exact same canonical Workshop preference.
    let legacyWorkshop = try runCLI(
        cli,
        ["provider-prefs", "missions"],
        environment: ["NATIVE_AGENT_DATA_ROOT": root.path]
    )
    #expect(legacyWorkshop.exitCode == 0, "legacy workshop lookup failed: \(legacyWorkshop.stderr)")
    let workshop = try jsonObject(legacyWorkshop.stdout)
    #expect(workshop["surface"] as? String == "workshop")
    #expect(workshop["model"] as? String == "gpt-5.4")

    for (arguments, expectedError) in [
        (["provider-prefs", "not-a-surface"], "unknown surface"),
        (["provider-prefs", "chat", "extra"], "usage: chat-drive provider-prefs"),
        (["provider-prefs", "--surface", "chat"], "unknown option"),
    ] {
        let refusal = try runCLI(cli, arguments, environment: ["NATIVE_AGENT_DATA_ROOT": root.path])
        #expect(refusal.exitCode == 64, "\(arguments) exited \(refusal.exitCode): \(refusal.stderr)")
        #expect(refusal.stderr.contains(expectedError), "\(arguments) hid its refusal: \(refusal.stderr)")
    }
    #expect(try regularFileSnapshot(under: root) == before, "CLI refusal changed routing bytes")

    // A pending two-file selection is explicitly unavailable to the read-only
    // probe. It must not perform the execution path's recovery write merely to
    // print a plausible-looking mixed provider/model answer.
    let pending = providers.appendingPathComponent("pending-surface-configuration.json")
    try Data(#"{"schemaVersion":1}"#.utf8).write(to: pending)
    let pendingBefore = try regularFileSnapshot(under: root)
    let adverse = try runCLI(cli, ["provider-prefs"], environment: ["NATIVE_AGENT_DATA_ROOT": root.path])
    #expect(adverse.exitCode != 0)
    #expect(adverse.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(try regularFileSnapshot(under: root) == pendingBefore, "read-only probe recovered a pending selection")

    // Existing malformed authority is unavailable, never an empty picker that
    // quietly re-seeds defaults. The bytes stay available for explicit repair.
    let corruptRoot = try cliTempRoot("provider-prefs-corrupt")
    defer { try? FileManager.default.removeItem(at: corruptRoot) }
    let corruptProviders = corruptRoot.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: corruptProviders, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: corruptProviders.appendingPathComponent("surfaces.json"))
    try Data("{}".utf8).write(to: corruptProviders.appendingPathComponent("active.json"))
    let corruptBefore = try regularFileSnapshot(under: corruptRoot)
    let corrupt = try runCLI(
        cli,
        ["provider-prefs"],
        environment: ["NATIVE_AGENT_DATA_ROOT": corruptRoot.path]
    )
    #expect(corrupt.exitCode != 0)
    #expect(corrupt.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(try regularFileSnapshot(under: corruptRoot) == corruptBefore)
}

@Test("chat-drive dispatch refuses malformed JSON instead of dispatching an empty dictionary")
func chatDriveCLIDispatchRejectsMalformedInput() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-malformed-dispatch")
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("cwd", isDirectory: true)
    let dataRoot = root.appendingPathComponent("isolated-data", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    // Sentinels make the absence of any pre-parse dispatcher/root work
    // observable: malformed argv must leave both the selected data root and
    // process cwd byte-for-byte unchanged. `runCLI` removes the ambient root
    // before installing this one, so no user/repository state participates.
    let cwdSentinel = cwd.appendingPathComponent("cwd-sentinel")
    let dataSentinel = dataRoot.appendingPathComponent("data-sentinel")
    let cwdBytes = Data("cwd stays untouched".utf8)
    let dataBytes = Data("data root stays untouched".utf8)
    try cwdBytes.write(to: cwdSentinel)
    try dataBytes.write(to: dataSentinel)

    for invalidInput in ["{\"query\":", "[]", "true", ""] {
        let run = try runCLI(
            cli,
            ["dispatch", "recall_memory", invalidInput],
            cwd: cwd,
            environment: ["NATIVE_AGENT_DATA_ROOT": dataRoot.path]
        )
        #expect(run.exitCode == 64, "\(invalidInput) exited \(run.exitCode): \(run.stderr)")
        #expect(run.stderr.contains("dispatch input must be a JSON object"))
        #expect(!run.stdout.contains("returned"), "malformed input reached the dispatcher: \(run.stdout)")
    }

    #expect(try Data(contentsOf: cwdSentinel) == cwdBytes)
    #expect(try Data(contentsOf: dataSentinel) == dataBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cwd.path).sorted() == ["cwd-sentinel"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dataRoot.path).sorted() == ["data-sentinel"])

    // Adverse control: well-formed object input reaches the real dispatcher.
    // The intentionally unknown tool must fail as a dispatch error (1), not
    // as an input parse refusal (64), proving the positive path is still live.
    let valid = try runCLI(
        cli,
        ["dispatch", "not_a_real_tool", "{}"],
        cwd: cwd,
        environment: ["NATIVE_AGENT_DATA_ROOT": dataRoot.path]
    )
    #expect(valid.exitCode == 1, "valid JSON did not reach dispatch: \(valid.stderr) \(valid.stdout)")
    #expect(valid.stdout.contains("=== ERROR ==="))
}

@Test("chat-drive memory hygiene refuses malformed mutation controls before opening storage")
func chatDriveCLIMemoryHygieneRejectsMalformedMutationControls() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-hygiene")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)

    for (arguments, expectedError) in [
        (["memory-hygiene", dataRoot.path, "--max-passes", "zero"], "positive integer"),
        (["memory-hygiene", dataRoot.path, "--max-passes", "0"], "positive integer"),
        (["memory-hygiene", dataRoot.path, "--approve-swap", "perhaps"], "true or false"),
    ] {
        let run = try runCLI(cli, arguments)
        #expect(run.exitCode == 64, "\(arguments) exited \(run.exitCode): \(run.stderr)")
        #expect(run.stderr.contains(expectedError))
    }
    #expect(!FileManager.default.fileExists(atPath: dataRoot.path))
}

@Test("chat-drive procedure validates action, scope, and activation approval at the CLI boundary")
func chatDriveCLIProcedureRejectsInvalidBindingWithoutWriting() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-procedure")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let artifactID = String(repeating: "a", count: 64)

    for (arguments, expectedError) in [
        (["procedure", "spelled-wrong", dataRoot.path], "action must be"),
        (["procedure", "status", dataRoot.path, "--scope", "experimental"], "scope must be"),
        (["procedure", "activate", dataRoot.path, artifactID], "requires --approval"),
        (["procedure", "activate", dataRoot.path, artifactID, "--approva", "id"], "unknown option"),
    ] {
        let run = try runCLI(cli, arguments)
        #expect(run.exitCode == 64, "\(arguments) exited \(run.exitCode): \(run.stderr)")
        #expect(run.stderr.contains(expectedError))
    }
    #expect(!FileManager.default.fileExists(atPath: dataRoot.path))

    // The read-only status action remains a usable production entrypoint.
    let status = try runCLI(cli, ["procedure", "status", dataRoot.path, "--scope", "manual"])
    #expect(status.exitCode == 0, "procedure status failed: \(status.stderr)")
    #expect(status.stdout.contains("procedure.operator.status.v1"))
}

// EVAL FENCE: core.misc / cli.chatDrive.procedure
@Test("chat-drive procedure preserves a hermetic root on read-only and refused operator paths")
func chatDriveCLIProcedureOperatorReceiptAndRefusalAreEffectBounded() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("chat-drive-procedure-operator")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    let invocationLedger = dataRoot
        .appendingPathComponent("living_fabric/procedures/invocations.jsonl")
    // A malformed physical line is intentionally retained to prove status is
    // a bounded read: it reports the integrity condition and never repairs it.
    try writeJSONLFixture(["{ malformed invocation ledger"], to: invocationLedger)
    let beforeStatus = try regularFileSnapshot(under: dataRoot)

    let status = try runCLI(cli, ["procedure", "status", dataRoot.path])
    #expect(status.exitCode == 0, "procedure status failed: \(status.stderr)")
    let statusReceipt = try jsonObject(status.stdout)
    #expect(statusReceipt["schema"] as? String == "procedure.operator.status.v1")
    #expect(statusReceipt["corruptInvocationCount"] as? Int == 1)
    #expect(statusReceipt["payloadFree"] as? Bool == true)
    #expect(
        try regularFileSnapshot(under: dataRoot) == beforeStatus,
        "read-only procedure status repaired or otherwise changed the hermetic root"
    )

    let shapeID = String(repeating: "a", count: 64)
    let beforeRefusals = try regularFileSnapshot(under: dataRoot)
    let stageReview = try runCLI(cli, [
        "procedure", "stage-review", dataRoot.path, shapeID, "--scope", "manual",
    ])
    #expect(stageReview.exitCode != 0, "empty canonical evidence unexpectedly staged a review")
    #expect(stageReview.stderr.contains("procedure candidate not found"))
    #expect(
        try regularFileSnapshot(under: dataRoot) == beforeRefusals,
        "refused stage-review wrote an approval or recovery artifact"
    )

    // Whitespace is not an approval identity. This must be rejected at the
    // CLI boundary before an artifact/active-pointer mutation is possible.
    let missingApproval = try runCLI(cli, [
        "procedure", "activate", dataRoot.path, shapeID, "--approval", "   ",
    ])
    #expect(missingApproval.exitCode != 0)
    #expect(missingApproval.stderr.contains("requires --approval"))
    #expect(
        try regularFileSnapshot(under: dataRoot) == beforeRefusals,
        "activate without a valid approval changed the procedure root"
    )
}

@Test("chat-drive doctor defaults malformed repair to false and preserves all existing bytes")
func chatDriveCLIDoctorMalformedRepairIsReadOnly() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("doctor")
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = root.appendingPathComponent("operator-sentinel.bin")
    let sentinelBytes = Data([0x00, 0xff, 0x41, 0x79, 0x61, 0x6c, 0x61])
    try sentinelBytes.write(to: sentinel)

    for arguments in [["doctor"], ["doctor", "--repair", "garbage"]] {
        let before = try regularFileSnapshot(under: root)
        let run = try runCLI(
            cli,
            arguments,
            environment: ["NATIVE_AGENT_DATA_ROOT": root.path],
            timeout: 30
        )
        #expect(run.exitCode == 0, "\(arguments): \(run.stderr)")
        #expect(run.stderr.contains("repair=false"), "malformed repair did not fail closed")
        let report = try jsonObject(run.stdout)
        #expect(report["repair"] as? Bool == false)
        #expect(report["checks"] is [[String: Any]])
        let after = try regularFileSnapshot(under: root)
        for (path, bytes) in before {
            #expect(after[path] == bytes, "doctor changed pre-existing file \(path)")
        }
        #expect(
            Set(after.keys).subtracting(before.keys).isEmpty,
            "doctor wrote persistent files outside its transient storage probe: \(Set(after.keys).subtracting(before.keys))"
        )
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
    }
}

@Test("public-safe env override refuses before opening provider artifacts or output")
func chatDriveCLIPublicSafeEnvironmentIsAnAdverseBoundary() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("public-safe")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = root.appendingPathComponent("fixture.json")
    let generated = try runCLI(cli, [
        "provider-transplant-fixture", "--targets", "openai:gpt-5.4",
        "--output", fixture.path, "--mode", "smoke",
    ])
    #expect(generated.exitCode == 0, "\(generated.stderr)")
    let output = root.appendingPathComponent("must-not-exist.json")
    let before = try regularFileSnapshot(under: root)

    let refused = try runCLI(
        cli,
        [
            "provider-transplant-eval", "--fixture", fixture.path,
            "--public-safe", "false", "--output", output.path,
        ],
        environment: [
            "NATIVE_AGENT_DATA_ROOT": root.path,
            "NATIVEAGENT_PUBLIC_SAFE_MODE": "1",
        ]
    )
    #expect(refused.exitCode != 0)
    #expect(refused.exitCode != 64, "the production eval route was not reached")
    #expect(refused.stderr.contains("publicSafeMode=true envForced=true"))
    #expect(refused.stderr.lowercased().contains("publicsafemode"))
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try regularFileSnapshot(under: root) == before)
}

// EVAL FENCE: core.misc / cli.chatDrive.memoryOps
@Test("memory-eval scores a frozen clone with production embeddings or names the unavailable boundary")
func chatDriveCLIMemoryEvalScoresOrDisclosesBoundary() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("embedding-mock")
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = root.appendingPathComponent("sentinel.bin")
    let bytes = Data([0xde, 0xad, 0xbe, 0xef])
    try bytes.write(to: sentinel)
    let before = try regularFileSnapshot(under: root)

    let gated = try runCLI(
        cli,
        ["memory-eval", "--query-mode", "natural", root.path],
        environment: [
            "NATIVE_AGENT_EMBEDDING_MOCK": "1",
            "NATIVEAGENT_RELEASE_GATE": "1",
        ]
    )
    #expect(gated.exitCode != 0)
    #expect(gated.stderr.contains("refuses NATIVE_AGENT_EMBEDDING_MOCK=1"))
    #expect(try regularFileSnapshot(under: root) == before)

    let disclosed = try runCLI(
        cli,
        ["memory-eval", "--query-mode", "natural", root.path],
        environment: [
            "NATIVE_AGENT_EMBEDDING_MOCK": "1",
            "NATIVEAGENT_RELEASE_GATE": "0",
        ],
        timeout: 60
    )
    #expect(disclosed.exitCode == 0, "\(disclosed.stderr)")
    let report = try jsonObject(disclosed.stdout)
    #expect(report["embeddingMock"] as? Bool == true)
    #expect((report["total"] as? Int ?? 0) > 0, "mock report passed vacuously")
    #expect((report["summary"] as? String)?.isEmpty == false)
    let mockVerdict = try #require(report["verdict"] as? [String: Any])
    let mockTotal = try #require(report["total"] as? Int)
    #expect(mockVerdict["status"] as? String == "scored")
    #expect(mockVerdict["probesExecuted"] as? Int == mockTotal)
    #expect(try Data(contentsOf: sentinel) == bytes)

    let canonicalRoot = root.appendingPathComponent("canonical-memory", isDirectory: true)
    let probePath = canonicalRoot
        .appendingPathComponent("memory/probes/probe_set.json", isDirectory: false)
    try FileManager.default.createDirectory(
        at: probePath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("""
    {
      "version": 1,
      "top_k": 1,
      "probes": [{
        "id": "production-boundary",
        "question": "Does this isolated memory evaluation execute?",
        "expect_any_substring": ["isolated memory evaluation"]
      }]
    }
    """.utf8).write(to: probePath)
    // Build the source with the real migration owner, then clone it. The
    // production-evaluation invocation below must only read that clone.
    let initialized = try runCLI(
        cli,
        ["memory-migrate", canonicalRoot.path],
        environment: ["NATIVE_AGENT_EMBEDDING_MOCK": "1"]
    )
    #expect(initialized.exitCode == 0, "memory fixture initialization failed: \(initialized.stderr)")
    let productionRoot = root.appendingPathComponent("production-clone", isDirectory: true)
    try FileManager.default.copyItem(at: canonicalRoot, to: productionRoot)
    let productionBefore = try regularFileSnapshot(under: productionRoot)

    let production = try runCLI(
        cli,
        ["memory-eval", "--query-mode", "natural", productionRoot.path],
        removingEnvironment: ["NATIVE_AGENT_EMBEDDING_MOCK"],
        timeout: 60
    )
    let productionReport = try jsonObject(production.stdout)
    #expect(productionReport["embeddingMock"] as? Bool == false)
    let verdict = try #require(productionReport["verdict"] as? [String: Any])
    if production.exitCode == 0 {
        #expect(verdict["status"] as? String == "scored")
        #expect(verdict["probesExecuted"] as? Int == 1)
        #expect(verdict["allConfiguredProbesExecuted"] as? Bool == true)
        #expect(productionReport["frozenCopy"] as? Bool == true)
        #expect(productionReport["liveStoreMutated"] as? Bool == false)
    } else {
        let verdictStatus = verdict["status"] as? String
        #expect(verdictStatus == "unavailable" || verdictStatus == "failed")
        #expect(verdict["probesExecuted"] as? Int == 0)
        if verdictStatus == "unavailable" {
            #expect(productionReport["frozenCopy"] as? Bool == false)
            #expect(production.stderr.contains("cannot score without the CoreML embedding provider"))
        } else {
            #expect(productionReport["frozenCopy"] as? Bool == true)
        }
    }
    #expect(
        try regularFileSnapshot(under: productionRoot) == productionBefore,
        "memory-eval changed its canonical clone instead of only its frozen copy"
    )
}

@Test("memory-eval refuses a present probe override with zero executable probes")
func chatDriveCLIMemoryEvalRejectsZeroProbeOverride() throws {
    let cli = try builtProduct("chat-drive")
    let root = try cliTempRoot("memory-eval-empty-probes")
    defer { try? FileManager.default.removeItem(at: root) }
    let probePath = root.appendingPathComponent("memory/probes/probe_set.json", isDirectory: false)
    try FileManager.default.createDirectory(
        at: probePath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(#"{"version":1,"top_k":1,"probes":[]}"#.utf8).write(to: probePath)
    let before = try regularFileSnapshot(under: root)

    let run = try runCLI(
        cli,
        ["memory-eval", "--query-mode", "natural", root.path],
        environment: [
            "NATIVE_AGENT_EMBEDDING_MOCK": "1",
            "NATIVEAGENT_RELEASE_GATE": "0",
        ]
    )
    #expect(run.exitCode != 0)
    #expect(run.stderr.contains("zero valid probes"))
    #expect(try regularFileSnapshot(under: root) == before)
}

@Test("desk-sweep rejects an unknown argument with exit 2 before touching the store")
func deskSweepCLIRejectsUnknownFlags() throws {
    let cli = try builtProduct("DeskSweepCLI")
    let root = try cliTempRoot("desk")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    for bad in ["--close-settled", "--retire-tracker", "-n", "--dryrun", "close-aliases"] {
        let run = try runCLI(cli, ["--data-root", dataRoot.path, bad])
        #expect(run.exitCode == 2, "'\(bad)' did not exit 2 (got \(run.exitCode))")
        #expect(run.stderr.contains("unknown argument"))
    }
    // The argv loop rejects BEFORE any store is opened, so a typo cannot leave
    // desk state behind.
    let entries = try FileManager.default.contentsOfDirectory(atPath: dataRoot.path)
    #expect(entries.isEmpty, "a rejected invocation wrote: \(entries)")
}

@Test("desk-sweep on an empty desk closes nothing and says so")
func deskSweepCLIEmptyDeskIsANoOp() throws {
    let cli = try builtProduct("DeskSweepCLI")
    let root = try cliTempRoot("desk-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

    let dry = try runCLI(cli, [
        "--data-root", dataRoot.path, "--close-aliases", "nothing.here", "--dry-run",
    ])
    #expect(dry.exitCode == 0, "\(dry.stderr)")
    #expect(dry.stdout.contains("nothing to close"))
    // No CLOSE lines on a dry run, ever.
    #expect(!dry.stdout.contains("CLOSE "))

    let wet = try runCLI(cli, ["--data-root", dataRoot.path, "--close-aliases", "nothing.here"])
    #expect(wet.exitCode == 0, "\(wet.stderr)")
    #expect(wet.stdout.contains("nothing to close"))
}
