import Testing
import Foundation
@testable import SwarmRuns
import NativeAgentCore
import PersistenceCore

// ============================================================================
// Coverage-ledger evals — fence core.toolexec (docs/evals/ledger.json).
//
// Rows closed here:
//   • swarm.policy.fromTrustPolicy
//   • swarm.runLedgerDataRoot
//   • swarm.runLedgerRow
//   • swarm.withTimeout
//   • swarm.workerPrompt
//   • swarm.persist.retentionCap
//
// Hermetic: every run uses a temp data root and a stub LLM. No network, no
// live data/ tree.
// ============================================================================

// MARK: - Stubs

/// Records every prompt/system/model it is handed and returns a canned reply.
private final class EvalSwarmLLM: LLMClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "EvalSwarmLLM")
    private var _prompts: [String] = []
    private var _systems: [String?] = []
    var prompts: [String] { queue.sync { _prompts } }
    var systems: [String?] { queue.sync { _systems } }

    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, surface: "chat")
    }
    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        queue.sync { _prompts.append(prompt); _systems.append(system) }
        return prompt.contains("SYNTHESIS:") ? "synth" : "worker output"
    }
}

/// Never returns. Used to prove the timeout path fires and that the losing
/// task is cancelled rather than leaked.
private final class HangingSwarmLLM: LLMClient, @unchecked Sendable {
    let started = EvalCounter()
    let cancelled = EvalCounter()
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, surface: "chat")
    }
    func complete(prompt: String, system: String?, model: String?, surface: String) async throws -> String {
        started.increment()
        do {
            // Far longer than any timeout under test; cancellation is the exit.
            try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
        } catch {
            cancelled.increment()
            throw error
        }
        return "never"
    }
}

/// Minimal thread-safe counter (the suite runs in parallel). Uses a serial
/// queue rather than NSLock — NSLock is unavailable from async contexts.
final class EvalCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EvalCounter")
    private var value = 0
    func increment() { queue.sync { value += 1 } }
    var count: Int { queue.sync { value } }
}

/// Records which workers reached the tool-capable runner (the `inherit` route).
private final class RecordingWorkerRunner: AgentSwarmWorkerRunning, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecordingWorkerRunner")
    private var _prompts: [String] = []
    private var _accesses: [String] = []
    var prompts: [String] { queue.sync { _prompts } }
    var accesses: [String] { queue.sync { _accesses } }
    func runWorker(
        prompt: String, model: String, reasoningEffort: String,
        access: String, originSurface: String, originSessionId: String?
    ) async throws -> String {
        queue.sync { _prompts.append(prompt); _accesses.append(access) }
        return "tool worker output"
    }
}

private func evalSwarmRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwarmCoverageEvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// `<root>/swarms/runs.json` — the CANONICAL shape the runs-ledger derivation
/// keys on. Every existing SwarmRunsTests case passes `<tmp>/runs.json`, which
/// is why the whole Runs-UI integration is skipped by the current suite.
private func canonicalRunsPath(_ root: URL) throws -> URL {
    let dir = root.appendingPathComponent("swarms", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("runs.json")
}

private func runLedgerRows(_ root: URL) -> [JSONValue] {
    let path = root
        .appendingPathComponent("runs", isDirectory: true)
        .appendingPathComponent("runs.json")
    guard let data = try? Data(contentsOf: path),
          case .array(let rows)? = try? JSONValue.parse(data) else { return [] }
    return rows
}

// MARK: - swarm.policy.fromTrustPolicy
//
// ZERO TESTS repo-wide. It is the user-facing switch for the whole swarm
// feature and it is DEFAULT-OPEN: a missing/malformed swarmPolicy returns
// enabled:true, maxAgents:20.

@Test func evalSwarmPolicy_fromTrustPolicy_parsesEveryInputShape() {
    // Absent / non-object roots fall back to the permissive default. Pinned
    // because it INVERTS the usual fail-closed bias — a corrupted policy file
    // leaves the swarm fully enabled.
    for absent in [JSONValue.object([:]), .array([]), .null, .string("nope"),
                   .object(["swarmPolicy": .string("not-an-object")])] {
        let policy = AgentSwarmPolicy.fromTrustPolicy(absent)
        #expect(policy.enabled, "KNOWN DEFAULT-OPEN: a missing/malformed swarmPolicy leaves the swarm ENABLED")
        #expect(policy.maxAgents == AgentSwarmPolicy.hardMaxAgents)
        #expect(policy.maxParallel == 6)
        #expect(policy.storeReceipts)
    }

    func parse(_ swarm: [String: JSONValue]) -> AgentSwarmPolicy {
        AgentSwarmPolicy.fromTrustPolicy(.object(["swarmPolicy": .object(swarm)]))
    }

    // The enablement coercion table, stated exactly.
    #expect(parse(["enabled": .bool(false)]).enabled == false)
    #expect(parse(["enabled": .string("false")]).enabled == false)
    #expect(parse(["enabled": .string("off")]).enabled == false)
    #expect(parse(["enabled": .string("0")]).enabled == false)
    #expect(parse(["enabled": .string("no")]).enabled == false)
    #expect(parse(["enabled": .string(" FALSE ")]).enabled == false, "trim + case-fold")
    #expect(parse(["enabled": .string("on")]).enabled == true)
    #expect(parse(["enabled": .string("1")]).enabled == true)
    // KNOWN FAIL-OPEN: an UNRECOGNISED string falls back to the default (true).
    // A typo'd `enabled: "of"` therefore reads as ENABLED. Pinned so a future
    // fail-closed fix shows up here rather than silently changing behaviour.
    #expect(
        parse(["enabled": .string("of")]).enabled == true,
        "KNOWN FAIL-OPEN changed: an unparseable enablement value now fails CLOSED. Good — update this eval and the ledger row."
    )
    #expect(parse(["enabled": .int(0)]).enabled == true, "a non-bool, non-string type also falls back to the default")

    // maxAgents / maxParallel are clamped into [1, hardMaxAgents] from every
    // input type the coercer accepts.
    #expect(parse(["maxAgents": .int(7)]).maxAgents == 7)
    #expect(parse(["maxAgents": .string("7")]).maxAgents == 7)
    #expect(parse(["maxAgents": .double(7.9)]).maxAgents == 7)
    #expect(parse(["maxAgents": .int(999)]).maxAgents == AgentSwarmPolicy.hardMaxAgents,
            "a policy can never raise the hard cap")
    #expect(parse(["maxAgents": .int(0)]).maxAgents == 1)
    #expect(parse(["maxAgents": .int(-5)]).maxAgents == 1)
    #expect(parse(["maxAgents": .string("seven")]).maxAgents == AgentSwarmPolicy.hardMaxAgents,
            "an unparseable count falls back to the default, not to 0")
    #expect(parse(["maxParallel": .int(999)]).maxParallel == AgentSwarmPolicy.hardMaxAgents)
    #expect(parse(["maxParallel": .int(0)]).maxParallel == 1)

    // Strings: empty/whitespace must not blank the model out.
    #expect(parse(["defaultModel": .string("  ")]).defaultModel == nativeAgentPrimaryModel)
    #expect(parse(["defaultModel": .string(" gpt-5.5 ")]).defaultModel == "gpt-5.5", "trimmed")
    #expect(parse(["defaultReasoningEffort": .string("")]).defaultReasoningEffort == "medium")
    #expect(parse(["storeReceipts": .bool(false)]).storeReceipts == false)

    // A DISABLED policy must actually stop a run at parse time — the switch
    // is only real if it reaches the request gate.
    do {
        _ = try AgentSwarmRunRequest.parse(
            input: ["objective": .string("go")],
            policy: parse(["enabled": .bool(false)])
        )
        Issue.record("a disabled swarmPolicy must deny the request")
    } catch AgentSwarmError.policyDenied(let message) {
        #expect(message.contains("swarmPolicy.enabled"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

// MARK: - swarm.runLedgerDataRoot + swarm.runLedgerRow
//
// DROPPED ROW BY CONSTRUCTION: the cross-surface Runs-UI row is skipped
// entirely when runLedgerDataRoot is nil, which happens whenever runsPath's
// parent dir is not literally named "swarms". Every existing SwarmRunsTests
// case passes a non-canonical path, so the whole integration is skipped by the
// suite — a broken derivation would leave every test green while swarms
// vanished from the Runs UI and the iOS runs snapshot.

@Test func evalSwarmRunLedger_canonicalPathWritesExactlyOneRow_nonCanonicalWritesNone() async throws {
    // (a) CANONICAL <root>/swarms/runs.json → exactly one ledger row.
    let root = try evalSwarmRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runsPath = try canonicalRunsPath(root)
    let llm = EvalSwarmLLM()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, runsPath: runsPath)
    #expect(executor.runLedgerDataRoot?.path == root.path,
            "a canonical runsPath must derive the data root by stripping swarms/runs.json")

    let out = try await executor.runTool(
        input: [
            "objective": .string("ledger me"),
            "agentCount": .int(2),
            "synthesize": .bool(false),
        ],
        policy: AgentSwarmPolicy(storeReceipts: true)
    )
    guard case .object(let obj) = out, case .string(let runID)? = obj["id"] else {
        Issue.record("expected a run id")
        return
    }

    let rows = runLedgerRows(root)
    #expect(rows.count == 1, "exactly ONE runs-ledger row per completed swarm — got \(rows.count)")
    guard case .object(let row)? = rows.first else {
        Issue.record("ledger row was not an object")
        return
    }
    #expect(row["id"] == .string(runID), "the ledger row must carry the SAME id as the receipt")
    #expect(row["kind"] == .string("swarm"), "the Runs UI filters on kind")
    #expect(row["status"] == .string("succeeded"), "status must match the run outcome")
    #expect(row["prompt"] == .string("ledger me"))
    if case .string(let createdAt)? = row["createdAt"] {
        #expect(!createdAt.isEmpty, "the Runs UI sorts on createdAt")
    } else {
        Issue.record("ledger row carries no createdAt")
    }
    if case .double(let seconds)? = row["durationSeconds"] {
        #expect(seconds >= 0)
    } else {
        Issue.record("ledger row carries no durationSeconds")
    }
    // The receipt file is written too — the two writes are independent.
    #expect(SwarmRunsStore.load(path: runsPath).runs.count == 1)

    // (b) NON-CANONICAL runsPath → NO ledger row, and the skip is ASSERTED so
    //     the derivation cannot silently invert.
    let flat = try evalSwarmRoot()
    defer { try? FileManager.default.removeItem(at: flat) }
    let flatPath = flat.appendingPathComponent("runs.json")
    let flatExec = SwiftNativeAgentSwarmExecutor(llm: EvalSwarmLLM(), runsPath: flatPath)
    #expect(flatExec.runLedgerDataRoot == nil,
            "a non-canonical runsPath must NOT guess a data root to write outside its tree")
    _ = try await flatExec.runTool(
        input: ["objective": .string("no ledger"), "agentCount": .int(1), "synthesize": .bool(false)],
        policy: AgentSwarmPolicy(storeReceipts: true)
    )
    #expect(runLedgerRows(flat).isEmpty, "a non-canonical path writes no ledger row")
    #expect(SwarmRunsStore.load(path: flatPath).runs.count == 1,
            "…while the receipt is unaffected — that asymmetry IS the silent failure")
}

@Test func evalSwarmRunLedger_failedRunRecordsFailedStatusAndAnError() async throws {
    // The row's status is derived from summary.completed, so a run where every
    // worker failed must surface as `failed` in the Runs UI — not as a healthy
    // row with an empty output.
    let root = try evalSwarmRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runsPath = try canonicalRunsPath(root)
    // No workerRunner + inherit access → every worker fails honestly.
    let executor = SwiftNativeAgentSwarmExecutor(llm: EvalSwarmLLM(), runsPath: runsPath)
    let out = try await executor.runTool(
        input: [
            "objective": .string("fail me"),
            "access": .string("inherit"),
            "agentCount": .int(2),
            "synthesize": .bool(false),
        ],
        policy: AgentSwarmPolicy(storeReceipts: true)
    )
    guard case .object(let obj) = out else {
        Issue.record("expected run object")
        return
    }
    #expect(obj["status"] == .string("failed"))
    let rows = runLedgerRows(root)
    #expect(rows.count == 1)
    guard case .object(let row)? = rows.first else {
        Issue.record("ledger row was not an object")
        return
    }
    #expect(row["status"] == .string("failed"))
    if case .string(let err)? = row["error"] {
        #expect(err.contains("failed"), "a failed row must carry a non-empty error; got \(err)")
    } else {
        Issue.record("a failed ledger row must carry an error string")
    }
}

// MARK: - swarm.withTimeout
//
// NO TEST TOUCHES THE TIMEOUT PATH. Both the per-worker call and the synthesis
// call are wrapped, and both catch the timeout into a `status:"failed"` worker
// result — so a systematically-too-short timeout degrades every swarm into
// partial results that still report run status "completed".

@Test func evalSwarmWithTimeout_firesPerWorker_cancelsTheLoser_andAllTimedOutIsAFailedRun() async throws {
    let root = try evalSwarmRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runsPath = try canonicalRunsPath(root)
    let llm = HangingSwarmLLM()
    let executor = SwiftNativeAgentSwarmExecutor(llm: llm, runsPath: runsPath)

    // `parse` clamps timeoutSeconds to a 15 s floor, so the request is built
    // directly — the wrapper under test takes whatever the request carries.
    let request = AgentSwarmRunRequest(
        objective: "hang",
        mode: "parallel",
        workers: [
            AgentSwarmWorkerSpec(name: "w1", role: "r1", model: "m", reasoningEffort: "medium"),
            AgentSwarmWorkerSpec(name: "w2", role: "r2", model: "m", reasoningEffort: "medium"),
        ],
        maxParallel: 2,
        synthesize: false,
        synthesisModel: "m",
        timeoutSeconds: 1,
        dryRun: false,
        maxOutputChars: 4_000,
        readOnly: true,
        requestedModel: "m",
        requestedBy: "eval",
        originSessionId: nil,
        digestBudgetTokens: nil
    )
    let started = Date()
    let result = try await executor.run(request: request, policy: AgentSwarmPolicy(storeReceipts: true))
    let elapsed = Date().timeIntervalSince(started)

    // Structural, not a tight wall-clock bound: the run must not have waited
    // for the 120 s stub. A generous ceiling keeps this stable under load.
    #expect(elapsed < 30, "the timeout wrapper did not bound the run (elapsed \(elapsed)s)")

    #expect(result.workers.count == 2)
    for worker in result.workers {
        #expect(worker.status == "failed", "a timed-out worker must report status failed")
        // 2026-09-06 (06ebf4a3): the worker error names the deadline and its
        // length, and says explicitly that any output arriving after
        // cancellation is evidence rather than a verified completion — the
        // phrase "timed out" was replaced by that fuller statement.
        #expect(
            (worker.error ?? "").contains("deadline exceeded (1s)"),
            "the timeout must be NAMED in the worker error; got \(worker.error ?? "nil")"
        )
        #expect(worker.output.isEmpty)
    }
    // A run where ALL workers timed out is a FAILED run — not a completed one.
    #expect(result.status == "failed")
    #expect(result.summary.completed == 0)
    #expect(result.summary.failed == 2)

    // The losing task is cancelled, not leaked: both hung calls observed a
    // cancellation. (`group.cancelAll()` after the winner returns.)
    #expect(llm.started.count == 2, "both workers must have reached the LLM")
    for _ in 0..<100 where llm.cancelled.count < 2 {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(
        llm.cancelled.count == 2,
        "the hung task must be CANCELLED when the timeout wins — got \(llm.cancelled.count) of 2 (a leaked child task otherwise survives the turn)"
    )

    // And the failed run still lands one honest row in the cross-surface ledger.
    let rows = runLedgerRows(root)
    #expect(rows.count == 1)
    if case .object(let row)? = rows.first {
        #expect(row["status"] == .string("failed"))
    }
}

@Test func evalSwarmWithTimeout_requestParseClampsIntoTheDocumentedWindow() throws {
    // The floor/ceiling are the only guard against a wedged worker pinning a
    // chat turn. 15 s floor, 900 s ceiling, 240 s default.
    func timeout(_ value: JSONValue?) throws -> Int {
        var input: [String: JSONValue] = ["objective": .string("x"), "agentCount": .int(1)]
        if let value { input["timeoutSeconds"] = value }
        return try AgentSwarmRunRequest.parse(input: input, policy: AgentSwarmPolicy()).timeoutSeconds
    }
    #expect(try timeout(nil) == 240, "the default budget")
    #expect(try timeout(.int(1)) == 15, "floor")
    #expect(try timeout(.int(0)) == 15)
    #expect(try timeout(.int(-100)) == 15, "a negative can never reach the UInt64 sleep conversion")
    #expect(try timeout(.int(9_999)) == 900, "ceiling")
    #expect(try timeout(.int(120)) == 120)
    #expect(try timeout(.string("120")) == 120, "string coercion")
    #expect(try timeout(.string("abc")) == 240, "unparseable falls back to the default, not to 0")
    // snake_case + bare aliases are honoured.
    #expect(
        try AgentSwarmRunRequest.parse(
            input: ["objective": .string("x"), "timeout_seconds": .int(60)],
            policy: AgentSwarmPolicy()
        ).timeoutSeconds == 60
    )
    #expect(
        try AgentSwarmRunRequest.parse(
            input: ["objective": .string("x"), "timeout": .int(60)],
            policy: AgentSwarmPolicy()
        ).timeoutSeconds == 60
    )
}

// MARK: - swarm.workerPrompt
//
// PROMPT-ONLY ENFORCEMENT presented as a policy: for read_only workers the
// restriction is a sentence appended to the prompt. The REAL enforcement is
// structural (no tool surface on the llm.complete route). The two can silently
// diverge — if the access branch inverted, a read_only worker would get the
// real tool runner while its prompt still said read-only. This asserts the
// route and the text always agree, in ONE run carrying both.

@Test func evalSwarmWorkerPrompt_routeAndTextAlwaysAgree() async throws {
    let root = try evalSwarmRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let llm = EvalSwarmLLM()
    let runner = RecordingWorkerRunner()
    let executor = SwiftNativeAgentSwarmExecutor(
        llm: llm,
        runsPath: root.appendingPathComponent("runs.json"),
        workerRunner: runner
    )
    let out = try await executor.runTool(
        input: [
            "objective": .string("mixed access"),
            "synthesize": .bool(false),
            "workers": .array([
                .object([
                    "name": .string("reader"),
                    "role": .string("read-only analyst"),
                    "access": .string("read_only"),
                    "model": .string("m"),
                ]),
                .object([
                    "name": .string("doer"),
                    "role": .string("tool worker"),
                    "access": .string("inherit"),
                    "model": .string("m"),
                ]),
            ]),
        ],
        policy: AgentSwarmPolicy(storeReceipts: false)
    )
    guard case .object(let obj) = out else {
        Issue.record("expected run object")
        return
    }
    #expect(obj["status"] == .string("completed"))

    // ROUTE: exactly one worker reached each destination.
    #expect(llm.prompts.count == 1, "the read_only worker must reach llm.complete — and only it")
    #expect(runner.prompts.count == 1, "the inherit worker must reach the tool-capable runner — and only it")
    #expect(runner.accesses == ["inherit"])

    // TEXT: each prompt carries the clause matching the route it took.
    let readOnlyPrompt = try #require(llm.prompts.first)
    #expect(readOnlyPrompt.contains("READ-ONLY CONSTRAINT:"),
            "the llm-routed worker's prompt must carry the read-only constraint")
    #expect(readOnlyPrompt.contains("Do not claim to have used tools or changed files."))
    #expect(!readOnlyPrompt.contains("TOOL ACCESS:"),
            "a read_only prompt must NOT advertise tools it structurally cannot reach")
    #expect(readOnlyPrompt.contains("OBJECTIVE:\nmixed access"))
    #expect(readOnlyPrompt.contains("name: reader"))

    let inheritPrompt = try #require(runner.prompts.first)
    #expect(inheritPrompt.contains("TOOL ACCESS:"),
            "the runner-routed worker's prompt must carry the tool-access clause")
    #expect(inheritPrompt.contains("TrustCenter"), "the clause must keep naming the gates that still apply")
    #expect(!inheritPrompt.contains("READ-ONLY CONSTRAINT:"))

    // SYSTEM PROMPT: the read-only system prompt is the second half of the
    // same claim — it asserts the worker cannot call tools. If the route
    // inverted, this sentence would be handed to a tool-capable worker.
    let system = try #require(llm.systems.compactMap { $0 }.first)
    #expect(system.contains("read-only"))
    #expect(system.contains("cannot call tools"))
}

// MARK: - swarm.persist.retentionCap
//
// Unbounded-growth guard with no test. Each record carries the full workers[]
// + synthesis text, so the file is heavyweight; a regression that drops the
// trim leaves it growing until the read-modify-write under flock becomes the
// slowest thing in a chat turn. (PersistenceCore's own RunLedger cap IS
// tested; this bigger, heavier file was not.)

@Test func evalSwarmPersist_retentionCapTrimsTheOldestTail() async throws {
    let root = try evalSwarmRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runsPath = try canonicalRunsPath(root)

    // Seed the file at the cap with identifiable rows, newest first.
    let cap = 1_000
    let seeded: [JSONValue] = (0..<cap).map { i in
        .object([
            "id": .string("seed-\(String(format: "%04d", i))"),
            "createdAt": .string("2026-06-16T00:00:00Z"),
        ])
    }
    try JSONValue.array(seeded).serializedData(pretty: false).write(to: runsPath)

    let executor = SwiftNativeAgentSwarmExecutor(llm: EvalSwarmLLM(), runsPath: runsPath)
    let out = try await executor.runTool(
        input: ["objective": .string("one more"), "agentCount": .int(1), "synthesize": .bool(false)],
        policy: AgentSwarmPolicy(storeReceipts: true)
    )
    guard case .object(let obj) = out, case .string(let newID)? = obj["id"] else {
        Issue.record("expected a run id")
        return
    }

    let stored = SwarmRunsStore.load(path: runsPath)
    #expect(
        stored.runs.count == cap,
        "the retained-run cap must hold the file at \(cap) rows — got \(stored.runs.count). An unbounded file is the failure this guards."
    )
    // Newest-first insert: the new run is at the head…
    if case .object(let head)? = stored.runs.first {
        #expect(head["id"] == .string(newID))
    } else {
        Issue.record("head row was not an object")
    }
    // …and the OLDEST tail row is the one dropped.
    let ids: Set<String> = Set(stored.runs.compactMap { row in
        if case .object(let o) = row, case .string(let id)? = o["id"] { return id }
        return nil
    })
    #expect(!ids.contains("seed-0999"), "the oldest row must be the one trimmed")
    #expect(ids.contains("seed-0000"), "the newest seeded row must survive")
    #expect(ids.contains(newID))
}
