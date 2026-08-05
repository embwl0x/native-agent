import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// MISSIONS EXECUTOR PORT (2026-06-10) — tests for WorkshopExecution+Executor.swift.
//
// FIXTURES: the three "golden" plans + expected timeline event sequences are
// extracted VERBATIM from real daemon-era COMPLETED executions in the reaped
// queue backup `data/workshop/executions.bak.pre-reap-20260610T045233/`:
//   - 36dccb68-f6f7-4681-95d0-65e697e6ebbb  "Read-only retry"
//       plan: local_files.search (tool) + chat.synthesize (llm)
//   - cffa81fd-e0ee-45fa-b0c2-8a7d5cc4032a  "Draft a status update..."
//       plan: step-plan/step-report chat.synthesize pair (the stub shape)
//   - 0d15ac14-d89a-489e-b4b4-8a3bac2259c9  single chat.synthesize step
// The replay contract is EVENT-NAME + step_id + status SEQUENCE equality
// (not timestamps, not payload bytes) against the daemon timelines.
// All roots are tmp dirs — no production data is touched.

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopExecutorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Seed a Workshop execution dir the way submit() leaves it: mission.json (status
/// queued by default) + the `enqueued` timeline event + receipts/.
@discardableResult
private func seedWorkshopExecution(
    root: URL,
    id: String,
    title: String,
    objective: String,
    planJSON: String,
    trustRequired: String = "none",
    status: String = "queued",
    stepsCompleted: [JSONValue] = []
) async throws -> WorkshopExecutionRecord {
    let persistence = SwiftNativePersistenceCore()
    let dir = root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)
    let receipts = dir.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let planParsed = try JSONValue.parse(Data(planJSON.utf8))
    let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(Date())
    let record = WorkshopExecutionRecord(
        id: id,
        title: title,
        objective: objective,
        createdAt: nowStr,
        status: status,
        plan: SwiftNativeWorkshopRunner.parsePlanSteps(planParsed),
        stepsCompleted: stepsCompleted,
        receiptsDir: receipts.path,
        triggerSource: "manual",
        trustRequired: trustRequired,
        expectedOutputs: [],
        currentStepId: "",
        updatedAt: nowStr,
        result: .null,
        rerunCount: 0
    )
    try await persistence.writeJSON(record.toJSON(), to: dir.appendingPathComponent("mission.json"))
    try await persistence.appendJSONL(
        .object([
            "event": .string("enqueued"),
            "title": .string(title),
            "trigger_source": .string("manual"),
            "ts": .string(nowStr),
        ]),
        to: dir.appendingPathComponent("timeline.jsonl")
    )
    return record
}

/// Timeline as "event|step_id|status" (or "event" when neither extra field
/// is present) — the fixture-equivalence projection.
private func timelineSignature(root: URL, id: String) async throws -> [String] {
    let persistence = SwiftNativePersistenceCore()
    let path = root.appendingPathComponent("workshop/executions/\(id)/timeline.jsonl")
    let rows = try await persistence.readJSONL(path)
    return rows.map { row in
        guard case .object(let o) = row else { return "malformed" }
        func s(_ k: String) -> String? {
            if case .string(let v)? = o[k] { return v }
            return nil
        }
        var sig = s("event") ?? "?"
        if let sid = s("step_id") { sig += "|\(sid)" }
        if let st = s("status") { sig += "|\(st)" }
        return sig
    }
}

/// True iff the raw timeline has an event row whose `error` field STARTS WITH
/// the given prefix (the approval-timeout sweep writes
/// `approval_timeout_exceeded_<label>`).
private func rawTimelineHasErrorPrefix(root: URL, id: String, prefix: String) async throws -> Bool {
    let persistence = SwiftNativePersistenceCore()
    let path = root.appendingPathComponent("workshop/executions/\(id)/timeline.jsonl")
    let rows = try await persistence.readJSONL(path)
    return rows.contains { row in
        guard case .object(let o) = row,
              case .string(let e)? = o["error"] else { return false }
        return e.hasPrefix(prefix)
    }
}

/// True iff the raw timeline has an event row with the given `event` name and
/// a matching `reason` field (the projection in `timelineSignature` drops
/// non-status extras like `reason`).
private func rawTimelineHas(root: URL, id: String, event: String, reason: String) async throws -> Bool {
    let persistence = SwiftNativePersistenceCore()
    let path = root.appendingPathComponent("workshop/executions/\(id)/timeline.jsonl")
    let rows = try await persistence.readJSONL(path)
    return rows.contains { row in
        guard case .object(let o) = row,
              case .string(let e)? = o["event"], e == event,
              case .string(let r)? = o["reason"], r == reason else { return false }
        return true
    }
}

private func readWorkshopExecution(root: URL, id: String) async -> WorkshopExecutionRecord? {
    let persistence = SwiftNativePersistenceCore()
    let raw = await persistence.readJSON(
        root.appendingPathComponent("workshop/executions/\(id)/mission.json"),
        defaultValue: .null
    )
    guard case .object(let obj) = raw else { return nil }
    return SwiftNativeWorkshopRunner.recordFromJSON(obj)
}

private actor Counter {
    var count = 0
    var labels: [String] = []
    func bump(_ label: String = "") { count += 1; labels.append(label) }
    func snapshot() -> (Int, [String]) { (count, labels) }
}

private final class CancellationReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private actor ParentCancellationControl {
    private var cancellation: (@Sendable () -> Void)?
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []

    func arm(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
        let waiters = armedWaiters
        armedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilArmed() async {
        if cancellation != nil { return }
        await withCheckedContinuation { armedWaiters.append($0) }
    }

    func cancelParent() {
        cancellation?()
    }
}

/// In-memory WorkshopExecutionRecord with the given completed-step records — for unit
/// testing the pure `{{step:id}}` resolver without touching disk.
private func recordWithCompleted(_ stepsCompleted: [JSONValue]) -> WorkshopExecutionRecord {
    let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(Date())
    return WorkshopExecutionRecord(
        id: "t", title: "t", objective: "o", createdAt: nowStr, status: "running",
        plan: [], stepsCompleted: stepsCompleted, receiptsDir: "/tmp", triggerSource: "manual",
        trustRequired: "none", expectedOutputs: [], currentStepId: "", updatedAt: nowStr,
        result: .null, rerunCount: 0
    )
}

// MARK: - Daemon-era fixtures (verbatim plans from the reaped queue backup)

/// 36dccb68-f6f7-4681-95d0-65e697e6ebbb — tool step + synthesize step.
private let fixturePlanReadOnlyRetry = """
[{"id": "step-1", "description": "Search local files for USER.md files that mention the user.", "tool_or_action": "local_files.search", "args": {"query": "the user filename:USER.md"}, "autonomy": "auto"}, {"id": "step-2", "description": "Synthesize only the discovered USER.md content about the user; if no matching content is found, state explicitly that results were empty and do not invent anything.", "tool_or_action": "chat.synthesize", "args": {"instruction": "Report any USER.md content about the user found in the local search. If the search returns no matching content, say explicitly: No USER.md content about the user was found. Do not invent or infer content."}, "autonomy": "auto"}]
"""
/// Daemon timeline for 36dccb68 (event|step_id|status projection):
private let fixtureEventsReadOnlyRetry = [
    "enqueued",
    "started",
    "step_completed|step-1|succeeded",
    "step_completed|step-2|succeeded",
    "completed",
]

/// cffa81fd-e0ee-45fa-b0c2-8a7d5cc4032a — the 2-step stub plan shape.
private let fixturePlanStubShape = """
[{"id": "step-plan", "description": "Analyze objective and gather context", "tool_or_action": "chat.synthesize", "args": {"prompt": "Given this objective: Compose a 3-sentence message I could post to a team Slack channel. Use email.draft to save it as a draft. Do not send anything.\\n\\nProduce a brief action plan."}, "autonomy": "auto"}, {"id": "step-report", "description": "Summarize findings", "tool_or_action": "chat.synthesize", "args": {"prompt": "Summarize the outcome for: Compose a 3-sentence message I could post to a team Slack channel. Use email.draft to save it as a draft. Do not send anything."}, "autonomy": "auto"}]
"""
private let fixtureEventsStubShape = [
    "enqueued",
    "started",
    "step_completed|step-plan|succeeded",
    "step_completed|step-report|succeeded",
    "completed",
]

/// 0d15ac14-d89a-489e-b4b4-8a3bac2259c9 — single synthesize step.
private let fixturePlanSingleStep = """
[{"id": "step-1", "description": "Clarify the execution objective because the provided title and objective are placeholders.", "tool_or_action": "chat.synthesize", "args": {"prompt": "Ask the user to provide the real execution title, objective, constraints, and preferred output format."}, "autonomy": "auto"}]
"""
private let fixtureEventsSingleStep = [
    "enqueued",
    "started",
    "step_completed|step-1|succeeded",
    "completed",
]

// MARK: - Fixture replay

@Suite("WorkshopExecutorLoop: daemon fixture replay")
struct WorkshopExecutorFixtureReplaySuite {

    @Test func synthesizeTextAliasReachesCanonicalPromptBoundary() {
        let step = WorkshopExecutionStep(
            id: "step-1",
            description: "fallback description",
            toolOrAction: "chat.synthesize",
            args: .object(["text": .string("Return exactly: native procedure proof")])
        )
        let record = WorkshopExecutionRecord(
            id: "prompt-alias",
            title: "Prompt alias",
            objective: "Exercise the planner's historical text key.",
            createdAt: SwiftNativeWorkshopRunner.isoTimestamp(Date()),
            status: "queued",
            plan: [step],
            stepsCompleted: [],
            receiptsDir: "/tmp/prompt-alias",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: SwiftNativeWorkshopRunner.isoTimestamp(Date()),
            result: .null,
            rerunCount: 0
        )

        #expect(
            WorkshopExecutorLoop.buildLLMPrompt(execution: record, step: step)
                == "Return exactly: native procedure proof"
        )
    }

    @Test func exactCriterionPersistsSatisfiedVerification() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "verified-exact-output"
        try await seedWorkshopExecution(
            root: root,
            id: id,
            title: "Exact output",
            objective: "Return exactly: Workshop live proof passed.",
            planJSON: fixturePlanSingleStep
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            measuredTooledLLMStep: { _ in
                WorkshopStepLLMCompletion(
                    model: "gpt-5.6-sol",
                    text: "Workshop live proof passed.",
                    providerCallCount: 2
                )
            },
            isEnabled: { true }
        )
        await executor.drainOnce()

        let record = try #require(await readWorkshopExecution(root: root, id: id))
        #expect(record.status == "completed")
        #expect(record.verification?.status == .satisfied)
        #expect(record.verification?.methods == ["exact_output"])
        let completed = try #require(record.stepsCompleted.first)
        guard case .object(let outcome) = completed else {
            Issue.record("expected step outcome object")
            return
        }
        #expect(outcome["provider_call_count"] == .int(2))
        #expect(outcome["removable_orchestration_provider_call_count"] == .int(0))
    }

    @Test func claimedWriteWithoutBytesFailsAtTerminalVerification() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "verification-catches-missing-write"
        let target = root.appendingPathComponent("never-created.txt").path
        let plan = """
        [{"id":"write","description":"write the file","tool_or_action":"write_file","args":{"path":\(String(reflecting: target)),"content":"expected"},"autonomy":"auto"}]
        """
        try await seedWorkshopExecution(
            root: root,
            id: id,
            title: "Write",
            objective: "Write the exact file.",
            planJSON: plan
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            toolDispatch: { _, _ in
                // Simulates a lying/buggy dispatcher receipt: the executor's
                // verification boundary must observe that no bytes landed.
                .object(["ok": .bool(true), "path": .string(target)])
            },
            isEnabled: { true }
        )
        await executor.drainOnce()

        let record = try #require(await readWorkshopExecution(root: root, id: id))
        #expect(record.status == "failed")
        #expect(record.verification?.status == .failed)
        #expect(record.verification?.methods == ["file_bytes"])
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(try await rawTimelineHasErrorPrefix(
            root: root,
            id: id,
            prefix: "verification_failed:"
        ))
    }

    @Test func replayReadOnlyRetryProducesEquivalentEventSequence() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "fixture-36dccb68"
        try await seedWorkshopExecution(
            root: root, id: id, title: "Read-only retry",
            objective: "Search local files for any USER.md content about the user. If empty results, say so explicitly. Do not invent content.",
            planJSON: fixturePlanReadOnlyRetry
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            // Daemon-parity fixtures run the PRODUCTION (tooled) synthesize
            // path → no synthesize_untooled note, so the timeline matches the
            // daemon-era sequence verbatim.
            tooledLLMStep: { _ in ("gpt-5.5", "No matching USER.md content about the user was found.") },
            toolDispatch: { tool, _ in
                .object([
                    "actionId": .string(tool),
                    "status": .string("succeeded"),
                    "output": .object(["query": .string("user filename:user.md"), "results": .array([])]),
                ])
            },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        let events = try await timelineSignature(root: root, id: id)
        #expect(events == fixtureEventsReadOnlyRetry)
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        #expect(final?.currentStepId == "")
        #expect(final?.stepsCompleted.count == 2)
        // Result extracted from the LAST step output (daemon calibrate-4).
        #expect(final?.result == .string("No matching USER.md content about the user was found."))
        // Per-step receipts landed in receiptsDir.
        let receipts = root.appendingPathComponent("workshop/executions/\(id)/receipts")
        #expect(FileManager.default.fileExists(atPath: receipts.appendingPathComponent("step-1.json").path))
        #expect(FileManager.default.fileExists(atPath: receipts.appendingPathComponent("step-2.json").path))
    }

    @Test func replayStubPlanShapeProducesEquivalentEventSequence() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "fixture-cffa81fd"
        try await seedWorkshopExecution(
            root: root, id: id, title: "Draft a status update for my team",
            objective: "Compose a 3-sentence message I could post to a team Slack channel.",
            planJSON: fixturePlanStubShape
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            tooledLLMStep: { prompt in ("gpt-5.5", "synthesized: \(prompt.prefix(40))") },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let events = try await timelineSignature(root: root, id: id)
        #expect(events == fixtureEventsStubShape)
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
    }

    @Test func replaySingleStepProducesEquivalentEventSequence() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "fixture-0d15ac14"
        try await seedWorkshopExecution(
            root: root, id: id, title: "x", objective: "x",
            planJSON: fixturePlanSingleStep
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            tooledLLMStep: { _ in ("gpt-5.5", "Please provide the real execution objective.") },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let events = try await timelineSignature(root: root, id: id)
        #expect(events == fixtureEventsSingleStep)
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        #expect(final?.result == .string("Please provide the real execution objective."))
    }

    /// The report/llm step must see PRIOR step outputs in its prompt (the
    /// daemon's calibrate-6 anti-confabulation block) — that's what makes
    /// the v1 "report" kind synthesize from receipts.
    @Test func laterLLMStepReceivesPriorStepContext() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "fixture-context-injection"
        try await seedWorkshopExecution(
            root: root, id: id, title: "Read-only retry", objective: "find things",
            planJSON: fixturePlanReadOnlyRetry
        )
        let prompts = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            tooledLLMStep: { prompt in
                await prompts.bump(prompt)
                return ("m", "ok")
            },
            toolDispatch: { _, _ in .object(["status": .string("succeeded"), "output": .object(["text": .string("TOOL-RESULT-MARKER")])]) },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let (count, labels) = await prompts.snapshot()
        #expect(count == 1)
        let prompt = labels.first ?? ""
        #expect(prompt.contains("Prior step outputs"))
        #expect(prompt.contains("TOOL-RESULT-MARKER"))
        #expect(prompt.contains("[step step-1 via local_files.search]"))
    }

    // MARK: - {{step:id}} threading into tool-step args (2026-06-15)

    /// END-TO-END: a write tool step whose content arg references an earlier
    /// step's output via {{step:step-1}} receives that step's ACTUAL output at
    /// dispatch — not the literal token. This is the "synthesize/fetch then write
    /// the result to a file" pattern that previously wrote a placeholder.
    @Test func toolStepArgReceivesPriorStepOutputViaToken() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "fixture-step-token-threading"
        let plan = """
        [{"id":"step-1","description":"fetch the body","tool_or_action":"data.fetch","args":{},"autonomy":"auto"},{"id":"step-2","description":"write the body to a file","tool_or_action":"files.write","args":{"content":"PREFIX::{{step:step-1}}::SUFFIX"},"autonomy":"auto"}]
        """
        try await seedWorkshopExecution(root: root, id: id, title: "Threading", objective: "build a file", planJSON: plan)
        let written = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            toolDispatch: { tool, args in
                if tool == "files.write" {
                    if case .object(let a) = args, case .string(let c)? = a["content"] {
                        await written.bump(c)
                    }
                    return .object(["status": .string("succeeded")])
                }
                // data.fetch → nested {output:{text:...}} shape (tool-step shape)
                return .object(["status": .string("succeeded"), "output": .object(["text": .string("BRIEF-BODY-MARKER")])])
            },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        let (count, labels) = await written.snapshot()
        #expect(count == 1)
        #expect(labels.first == "PREFIX::BRIEF-BODY-MARKER::SUFFIX")
    }

    /// The resolver substitutes a synthesize step's text output (the common
    /// "draft prose then write it" shape).
    @Test func resolveStepReferencesSubstitutesPriorOutput() {
        let m = recordWithCompleted([
            .object(["step_id": .string("gen"), "output": .object(["text": .string("BODY")])])
        ])
        let out = WorkshopExecutorLoop.resolveStepReferences(
            in: .object(["content": .string("X={{step:gen}}=Y")]), execution: m)
        guard case .object(let o) = out, case .string(let c)? = o["content"] else {
            Issue.record("expected object with content string"); return
        }
        #expect(c == "X=BODY=Y")
    }

    /// A token that appears INSIDE a referenced step's output must NOT be
    /// re-expanded (single-pass substitution; gpt-5.5 review 2026-06-15). Here
    /// step "a" output is the literal text "{{step:b}}" — resolving {{step:a}}
    /// inserts that literal, it does NOT then expand to b's output.
    @Test func resolveStepReferencesDoesNotRescanInsertedText() {
        let m = recordWithCompleted([
            .object(["step_id": .string("a"), "output": .object(["text": .string("{{step:b}}")])]),
            .object(["step_id": .string("b"), "output": .object(["text": .string("B-VALUE")])]),
        ])
        let out = WorkshopExecutorLoop.resolveStepReferences(
            in: .object(["content": .string("[{{step:a}}]")]), execution: m)
        guard case .object(let o) = out, case .string(let c)? = o["content"] else {
            Issue.record("expected object with content string"); return
        }
        #expect(c == "[{{step:b}}]")  // a's literal output, NOT "B-VALUE"
    }

    /// An id with no matching completed step is left VERBATIM — honest, not a
    /// silent blank.
    @Test func resolveStepReferencesLeavesUnknownIdVerbatim() {
        let m = recordWithCompleted([
            .object(["step_id": .string("gen"), "output": .object(["text": .string("BODY")])])
        ])
        let out = WorkshopExecutorLoop.resolveStepReferences(
            in: .object(["content": .string("{{step:missing}}")]), execution: m)
        guard case .object(let o) = out, case .string(let c)? = o["content"] else {
            Issue.record("expected object with content string"); return
        }
        #expect(c == "{{step:missing}}")
    }

    /// No token + non-string values → args returned unchanged (pure path that
    /// preserves every existing plan's behaviour).
    @Test func resolveStepReferencesNoTokenUnchanged() {
        let m = recordWithCompleted([
            .object(["step_id": .string("gen"), "output": .object(["text": .string("BODY")])])
        ])
        let args: JSONValue = .object(["content": .string("plain text"), "flag": .bool(true)])
        let out = WorkshopExecutorLoop.resolveStepReferences(in: args, execution: m)
        #expect(out == args)
    }

    /// fullStepOutputText extracts synthesize/tool text and maps empty → "".
    @Test func fullStepOutputTextExtractsTextAndHandlesEmpty() {
        #expect(WorkshopExecutorLoop.fullStepOutputText(.object(["text": .string("HI")])) == "HI")
        #expect(WorkshopExecutorLoop.fullStepOutputText(.null) == "")
        #expect(WorkshopExecutorLoop.fullStepOutputText(
            .object(["output": .object(["text": .string("NESTED")])])) == "NESTED")
    }
}

// MARK: - Synthesize quality: tooled turn + output validation (2026-06-11)
//
// Execution 752636c5 (found live by Agent): a `chat.synthesize` step ran a bare
// LLM call with NO tool access and NO output validation, so the model's
// refusal ("I can't access your filesystem, here's some jq") scored
// `succeeded`. These tests pin both halves of the fix.

/// Single chat.synthesize step (plan reused across the suite below).
private let synthSingleStepPlan = """
[{"id": "step-1", "description": "Read USER.md and summarize what it says about the user.", "tool_or_action": "chat.synthesize", "args": {"prompt": "Summarize USER.md."}, "autonomy": "auto"}]
"""

@Suite("WorkshopExecutorLoop: synthesize tooled turn + validation")
struct WorkshopExecutorSynthesizeQualitySuite {

    /// Tooled synthesize step actually drives an injected read tool and its
    /// result lands in the step output. (At the module level the tool loop
    /// lives in the injected `tooledLLMStep`; this proves the executor ROUTES
    /// synthesize through it and surfaces its text + tooled:true.)
    @Test func tooledSynthesizeDispatchesReadToolAndResultLandsInOutput() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "synth-tooled"
        try await seedWorkshopExecution(
            root: root, id: id, title: "Summarize USER.md", objective: "summarize",
            planJSON: synthSingleStepPlan
        )
        let toolCalls = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            // Bare closure must NOT be used when a tooled one is wired.
            llmStep: { _ in ("bare", "BARE-SHOULD-NOT-RUN") },
            tooledLLMStep: { _ in
                // Stand-in for the production tool loop: "call" a read tool and
                // synthesize from its content.
                await toolCalls.bump("read_file")
                let fileContent = "USER.md says the user ships fast."
                return ("opus", "Per USER.md: \(fileContent)")
            },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        let (count, labels) = await toolCalls.snapshot()
        #expect(count == 1)
        #expect(labels == ["read_file"])
        // The tooled result text is in the step output, flagged tooled:true.
        guard case .object(let last)? = final?.stepsCompleted.last,
              case .object(let out)? = last["output"] else {
            Issue.record("missing step output"); return
        }
        #expect(out["model"] == .string("opus"))
        #expect(out["tooled"] == .bool(true))
        if case .string(let text)? = out["text"] {
            #expect(text.contains("USER.md says the user ships fast."))
        } else {
            Issue.record("missing text")
        }
        // No untooled note when the tooled path ran.
        let events = try await timelineSignature(root: root, id: id)
        #expect(!events.contains { $0.hasPrefix("synthesize_untooled") })
        #expect(final?.result == .string("Per USER.md: USER.md says the user ships fast."))
    }

    /// A REFUSAL fails the step with model_refusal + a tripwire timeline event,
    /// instead of being scored succeeded.
    @Test func refusalFailsStepWithModelRefusalReceiptAndTimelineEvent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "synth-refusal"
        try await seedWorkshopExecution(
            root: root, id: id, title: "x", objective: "x",
            planJSON: synthSingleStepPlan
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            tooledLLMStep: { _ in
                ("opus", "I can't access your filesystem. Here's some jq you could run instead.")
            },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "failed")
        guard case .object(let last)? = final?.stepsCompleted.last else {
            Issue.record("missing step record"); return
        }
        #expect(last["status"] == .string("failed"))
        #expect(last["error"] == .string("model_refusal"))
        if case .object(let out)? = last["output"] {
            #expect(out["validation"] == .string("model_refusal"))
        } else {
            Issue.record("missing output validation marker")
        }
        // timelineSignature projects event|step_id (the validation event
        // carries `reason`, not `status`; the failed event carries `error`).
        // The reason itself is asserted on the step record above.
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.contains("synthesize_validation_failed|step-1"))
        #expect(events.contains("failed|step-1"))
        // The reason is in the raw validation event.
        #expect(try await rawTimelineHas(
            root: root, id: id, event: "synthesize_validation_failed", reason: "model_refusal"))
    }

    /// A legitimate, substantive answer that merely MENTIONS access must PASS —
    /// false-fail is worse than false-pass for long Workshop executions.
    @Test func legitAnswerMentioningAccessPasses() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "synth-legit"
        try await seedWorkshopExecution(
            root: root, id: id, title: "x", objective: "x",
            planJSON: synthSingleStepPlan
        )
        let answer = "The file you can't access from iOS is /Users/example/notes/USER.md, "
            + "and here is what it contains: the user prefers terse reports, ships fast, "
            + "and wants honest receipts over fabricated success. The document also "
            + "lists three active projects and his working-hours preference."
        let executor = WorkshopExecutorLoop(
            root: root,
            tooledLLMStep: { _ in ("opus", answer) },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        guard case .object(let last)? = final?.stepsCompleted.last else {
            Issue.record("missing step record"); return
        }
        #expect(last["status"] == .string("succeeded"))
        let events = try await timelineSignature(root: root, id: id)
        #expect(!events.contains { $0.hasPrefix("synthesize_validation_failed") })
    }

    /// Empty / whitespace output fails with empty_output + tripwire event.
    @Test func emptyOutputFailsWithEmptyOutput() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "synth-empty"
        try await seedWorkshopExecution(
            root: root, id: id, title: "x", objective: "x",
            planJSON: synthSingleStepPlan
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            tooledLLMStep: { _ in ("opus", "   \n  ") },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "failed")
        guard case .object(let last)? = final?.stepsCompleted.last else {
            Issue.record("missing step record"); return
        }
        #expect(last["error"] == .string("empty_output"))
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.contains("synthesize_validation_failed|step-1"))
        #expect(try await rawTimelineHas(
            root: root, id: id, event: "synthesize_validation_failed", reason: "empty_output"))
    }

    /// Tool-less fallback (no tooled closure injected) behaves as today but
    /// emits a `synthesize_untooled` tripwire note — honest, not silent.
    @Test func toollessFallbackEmitsUntooledNote() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "synth-untooled"
        try await seedWorkshopExecution(
            root: root, id: id, title: "x", objective: "x",
            planJSON: synthSingleStepPlan
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("gpt-5.5", "A perfectly fine bare-completion summary of the document.") },
            // no tooledLLMStep wired → fallback path
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")  // bare path still works
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.contains("synthesize_untooled|step-1"))
        // Output flagged tooled:false.
        guard case .object(let last)? = final?.stepsCompleted.last,
              case .object(let out)? = last["output"] else {
            Issue.record("missing output"); return
        }
        #expect(out["tooled"] == .bool(false))
    }
}

// MARK: - validateSynthesizeOutput unit pins (both directions)

@Suite("WorkshopExecutorLoop.validateSynthesizeOutput")
struct ValidateSynthesizeOutputSuite {
    @Test func actualRefusalStringIsFlagged() {
        for refusal in [
            "I can't access your filesystem, here's some jq.",
            "I don't have access to your files.",
            "I'm unable to read that from here.",
            "As an AI, I cannot open local files.",
        ] {
            #expect(WorkshopExecutorLoop.validateSynthesizeOutput(refusal) == .refusal,
                    "should flag: \(refusal)")
        }
    }

    @Test func legitAnswerMentioningAccessIsOk() {
        let legit = "The file you can't access from iOS is at /Users/example/USER.md, "
            + "and its content is: the user prefers terse, honest reports. He ships fast "
            + "and dislikes fabricated success. Three projects are listed inside."
        #expect(WorkshopExecutorLoop.validateSynthesizeOutput(legit) == .ok)
    }

    @Test func clarificationRequestIsNotARefusal() {
        // The daemon-era fixture shape — a legit ask, not a refusal.
        #expect(WorkshopExecutorLoop.validateSynthesizeOutput(
            "Please provide the real execution objective.") == .ok)
    }

    @Test func emptyAndWhitespaceAreEmpty() {
        #expect(WorkshopExecutorLoop.validateSynthesizeOutput("") == .empty)
        #expect(WorkshopExecutorLoop.validateSynthesizeOutput("   \n\t ") == .empty)
    }

    @Test func ordinarySynthesisIsOk() {
        #expect(WorkshopExecutorLoop.validateSynthesizeOutput(
            "the user shipped the executions executor and verified it end to end.") == .ok)
    }
}

// MARK: - Claim race + slot cap

@Suite("WorkshopExecutorLoop: claim + slots")
struct WorkshopExecutorClaimSuite {

    @Test func twoConcurrentExecutorsExactlyOneClaims() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "race-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "race", objective: "race",
            planJSON: fixturePlanSingleStep
        )
        let executions = Counter()
        let makeExec = {
            WorkshopExecutorLoop(
                root: root,
                llmStep: { _ in
                    await executions.bump()
                    // Slow step so the second drain overlaps the first run.
                    try await Task.sleep(nanoseconds: 200_000_000)
                    return ("m", "done")
                },
                cancellationPollInterval: 0.02
            )
        }
        let a = makeExec()
        let b = makeExec()
        async let ra: Void = a.drainOnce()
        async let rb: Void = b.drainOnce()
        _ = await (ra, rb)

        let events = try await timelineSignature(root: root, id: id)
        // Exactly ONE claim → exactly one `started`, one step run, one completed.
        #expect(events.filter { $0 == "started" }.count == 1)
        #expect(events.filter { $0 == "completed" }.count == 1)
        let (count, _) = await executions.snapshot()
        #expect(count == 1)
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
    }

    @Test func slotCapRecheckInsideClaimLockRefusesWhenFull() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executions = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await executions.bump()
                return ("m", "done")
            },
            maxActive: 1,
            cancellationPollInterval: 0.02
        )
        // Prime the one-time startup orphan-reclaim FIRST (empty queue → no-op)
        // so the `running` Workshop execution seeded below models a slot held by a Workshop execution
        // running AFTER launch — NOT a startup orphan, which is now reclaimed
        // to `failed` (single-instance app; see WorkshopExecutorOrphanReclaimSuite).
        await executor.drainOnce()
        // Workshop A holds the only slot (running post-launch, not an orphan).
        try await seedWorkshopExecution(
            root: root, id: "running-a", title: "a", objective: "a",
            planJSON: fixturePlanSingleStep, status: "running"
        )
        try await seedWorkshopExecution(
            root: root, id: "queued-b", title: "b", objective: "b",
            planJSON: fixturePlanSingleStep
        )
        await executor.drainOnce()
        // Cap full → queued-b must NOT have been claimed.
        let b1 = await readWorkshopExecution(root: root, id: "queued-b")
        #expect(b1?.status == "queued")
        let (count1, _) = await executions.snapshot()
        #expect(count1 == 0)

        // Free the slot → next drain claims and runs it.
        let persistence = SwiftNativePersistenceCore()
        let aPath = root.appendingPathComponent("workshop/executions/running-a/mission.json")
        let rawA = await persistence.readJSON(aPath, defaultValue: .null)
        if case .object(var o) = rawA {
            o["status"] = .string("completed")
            try await persistence.writeJSON(.object(o), to: aPath)
        }
        await executor.drainOnce()
        let b2 = await readWorkshopExecution(root: root, id: "queued-b")
        #expect(b2?.status == "completed")
        let (count2, _) = await executions.snapshot()
        #expect(count2 == 1)
    }

    @Test func disabledGateDrainsNothing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedWorkshopExecution(
            root: root, id: "gated", title: "g", objective: "g",
            planJSON: fixturePlanSingleStep
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            isEnabled: { false },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: "gated")
        #expect(final?.status == "queued")
    }
}

// MARK: - Honest failure

@Suite("WorkshopExecutorLoop: honest step failure")
struct WorkshopExecutorFailureSuite {

    @Test func stepFailureFailsWorkshopExecutionWithHonestError() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "fail-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "f", objective: "f",
            planJSON: fixturePlanReadOnlyRetry  // tool step first
        )
        let llmCalls = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await llmCalls.bump()
                return ("m", "should never run")
            },
            toolDispatch: { _, _ in throw WorkshopExecutionError.underlying("connector exploded") },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "failed")
        // NIT (gpt-5.5 2026-06-10): terminal failed clears current_step_id,
        // matching the completed path.
        #expect(final?.currentStepId == "")
        let events = try await timelineSignature(root: root, id: id)
        #expect(events == [
            "enqueued",
            "started",
            "step_completed|step-1|failed",
            "failed|step-1",
        ])
        // Step 2 must NOT execute after the failure.
        let (count, _) = await llmCalls.snapshot()
        #expect(count == 0)
        // The honest error string is preserved on the step record.
        if case .object(let sr)? = final?.stepsCompleted.first,
           case .string(let err)? = sr["error"] {
            #expect(err.contains("connector exploded"))
        } else {
            Issue.record("step record missing error")
        }
    }

    @Test func unknownStepKindFailsHonestlyWithoutDispatcher() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "unknown-kind"
        try await seedWorkshopExecution(
            root: root, id: id, title: "u", objective: "u",
            planJSON: """
            [{"id": "step-1", "description": "mystery", "tool_or_action": "frobnicate.widget", "args": {}, "autonomy": "auto"}]
            """
        )
        // NO toolDispatch injected — the unknown kind must FAIL, not no-op.
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "failed")
        if case .object(let sr)? = final?.stepsCompleted.first,
           case .string(let err)? = sr["error"] {
            #expect(err.contains("no tool dispatcher wired"))
        } else {
            Issue.record("step record missing error")
        }
    }
}

// MARK: - Approval staging + resume

@Suite("WorkshopExecutorLoop: approval staging + resume")
struct WorkshopExecutorApprovalSuite {

    private var twoStepPlan: String {
        """
        [{"id": "step-1", "description": "draft the email", "tool_or_action": "email.draft", "args": {"to": "x"}, "autonomy": "auto"}, {"id": "step-2", "description": "Summarize findings", "tool_or_action": "chat.synthesize", "args": {"prompt": "summarize"}, "autonomy": "auto"}]
        """
    }

    @Test func trustRequiredWorkshopExecutionStagesApprovalAndBlocks() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "approval-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "a", objective: "a",
            planJSON: twoStepPlan, trustRequired: "send_approval"
        )
        let staged = Counter()
        let toolRuns = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { _, _ in
                await toolRuns.bump()
                return .object(["status": .string("succeeded")])
            },
            stageApproval: { req in
                await staged.bump("\(req.executionId)/\(req.stepId)/\(req.tool)")
                return "approval-123"
            },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "blocked_on_approval")
        let (stageCount, labels) = await staged.snapshot()
        #expect(stageCount == 1)
        #expect(labels.first == "\(id)/step-1/email.draft")
        // The gated step did NOT execute.
        let (toolCount, _) = await toolRuns.snapshot()
        #expect(toolCount == 0)
        let events = try await timelineSignature(root: root, id: id)
        #expect(events == [
            "enqueued",
            "started",
            "step_blocked_on_approval|step-1",
        ])
        // approval_id stamped on the blocked step record.
        if case .object(let sr)? = final?.stepsCompleted.first,
           case .string(let aid)? = sr["approval_id"] {
            #expect(aid == "approval-123")
        } else {
            Issue.record("blocked step record missing approval_id")
        }
    }

    /// HARDENING (2026-06-15, re-applies a reverted gpt-5.5 HIGH): a non-yolo
    /// execution's planner cannot DOWNGRADE a send-tier tool's approval by marking
    /// it autonomy=auto. email.send (intrinsic send_approval) must gate even
    /// though the plan says "auto" and the execution's own trustRequired is "none".
    @Test func nonYoloPlannerCannotDowngradeSendTierTool() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "downgrade-guard"
        try await seedWorkshopExecution(
            root: root, id: id, title: "d", objective: "d",
            planJSON: """
            [{"id": "step-1", "description": "send the email", "tool_or_action": "email.send", "args": {"to": "x"}, "autonomy": "auto"}]
            """
        )
        let staged = Counter()
        let toolRuns = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            toolDispatch: { _, _ in
                await toolRuns.bump()
                return .object(["status": .string("succeeded")])
            },
            stageApproval: { req in
                await staged.bump("\(req.executionId)/\(req.stepId)/\(req.tool)")
                return "approval-send-1"
            },
            cancellationPollInterval: 0.02
            // stepApprovalEnforced defaults to {true} → non-yolo.
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "blocked_on_approval")
        let (stageCount, labels) = await staged.snapshot()
        #expect(stageCount == 1)
        #expect(labels.first == "\(id)/step-1/email.send")
        let (toolCount, _) = await toolRuns.snapshot()
        #expect(toolCount == 0)  // gated step did NOT fire the send
    }

    /// COMPLEMENT: under yolo (stepApprovalEnforced == false) the SAME send-tier
    /// tool runs unattended — "she does everything" — no staging, no block.
    @Test func yoloWorkshopExecutionRunsSendTierToolUnattended() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "yolo-send"
        try await seedWorkshopExecution(
            root: root, id: id, title: "y", objective: "y",
            planJSON: """
            [{"id": "step-1", "description": "send the email", "tool_or_action": "email.send", "args": {"to": "x"}, "autonomy": "auto"}]
            """
        )
        let staged = Counter()
        let toolRuns = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            toolDispatch: { _, _ in
                await toolRuns.bump()
                return .object(["status": .string("succeeded")])
            },
            stageApproval: { _ in
                await staged.bump()
                return "should-not-stage"
            },
            cancellationPollInterval: 0.02,
            stepApprovalEnforced: { false }  // yolo
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        let (stageCount, _) = await staged.snapshot()
        #expect(stageCount == 0)  // never staged
        let (toolCount, _) = await toolRuns.snapshot()
        #expect(toolCount == 1)  // ran unattended
    }

    @Test func resumeApprovedExecutesStepThenContinuesToCompletion() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "resume-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "r", objective: "r",
            planJSON: twoStepPlan, trustRequired: "send_approval"
        )
        let toolRuns = Counter()
        let llmRuns = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            tooledLLMStep: { _ in
                await llmRuns.bump()
                return ("m", "final summary")
            },
            toolDispatch: { tool, _ in
                await toolRuns.bump(tool)
                return .object(["status": .string("succeeded"), "output": .object(["text": .string("drafted")])])
            },
            stageApproval: { _ in "approval-xyz" },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let blocked = await readWorkshopExecution(root: root, id: id)
        #expect(blocked?.status == "blocked_on_approval")

        // Approve → the step must actually EXECUTE (W6: never
        // mark-without-executing), then the remaining plan runs. Note:
        // step-2 is approval-gated too on a send_approval execution, so the
        // post-resume continuation BLOCKS on step-2 — assert the re-stage.
        let afterResume = try await executor.resumeAfterApproval(
            executionId: id, stepId: "step-1", approved: true, approvalId: "approval-xyz"
        )
        let (toolCount, toolLabels) = await toolRuns.snapshot()
        #expect(toolCount == 1)
        #expect(toolLabels == ["email.draft"])
        #expect(afterResume.status == "blocked_on_approval")

        // Approve step-2 as well → Workshop execution completes.
        let completed = try await executor.resumeAfterApproval(
            executionId: id, stepId: "step-2", approved: true, approvalId: "approval-xyz"
        )
        let (llmCount, _) = await llmRuns.snapshot()
        #expect(llmCount == 1)
        #expect(completed.status == "completed")
        #expect(completed.result == .string("final summary"))

        let events = try await timelineSignature(root: root, id: id)
        // Daemon parity: NO step_completed for the resumed step itself
        // (fixture 3e718ce5 — approval_decision then the NEXT steps only).
        #expect(events == [
            "enqueued",
            "started",
            "step_blocked_on_approval|step-1",
            "approval_decision|step-1",
            "step_blocked_on_approval|step-2",
            "approval_decision|step-2",
            "completed",
        ])
    }

    @Test func resumeRejectedMarksStepRejectedAndFailsWorkshopExecution() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "reject-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "r", objective: "r",
            planJSON: twoStepPlan, trustRequired: "send_approval"
        )
        let toolRuns = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { _, _ in
                await toolRuns.bump()
                return .object(["status": .string("succeeded")])
            },
            stageApproval: { _ in "approval-reject" },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let rejected = try await executor.resumeAfterApproval(
            executionId: id, stepId: "step-1", approved: false, approvalId: "approval-reject"
        )
        #expect(rejected.status == "failed")
        // NIT (gpt-5.5 2026-06-10): the resume-deny terminal also clears
        // current_step_id, matching completed/failed.
        #expect(rejected.currentStepId == "")
        let (toolCount, _) = await toolRuns.snapshot()
        #expect(toolCount == 0)
        if case .object(let sr)? = rejected.stepsCompleted.first,
           case .string(let st)? = sr["status"] {
            #expect(st == "rejected")
        } else {
            Issue.record("step record not marked rejected")
        }
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.contains("approval_decision|step-1"))
        #expect(events.contains("failed|step-1"))
    }

    @Test func resumeWithMismatchedApprovalIdThrows() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "mismatch-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "m", objective: "m",
            planJSON: twoStepPlan, trustRequired: "send_approval"
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { _, _ in .object(["status": .string("succeeded")]) },
            stageApproval: { _ in "approval-real" },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        await #expect(throws: WorkshopExecutionError.invalidRequest("approval_id_does_not_match_blocked_step")) {
            _ = try await executor.resumeAfterApproval(
                executionId: id, stepId: "step-1", approved: true, approvalId: "approval-FORGED"
            )
        }
    }

    @Test func approvalStagerMissingFailsStepHonestly() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "no-stager"
        try await seedWorkshopExecution(
            root: root, id: id, title: "n", objective: "n",
            planJSON: twoStepPlan, trustRequired: "send_approval"
        )
        // No stager injected → an approval-tier step must FAIL, not block
        // forever on an approval that was never filed.
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { _, _ in .object(["status": .string("succeeded")]) },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "failed")
        if case .object(let sr)? = final?.stepsCompleted.first,
           case .string(let err)? = sr["error"] {
            #expect(err.contains("no approval stager"))
        } else {
            Issue.record("step record missing honest error")
        }
    }
}

// MARK: - Cancel mid-run

@Suite("WorkshopExecutorLoop: cancel mid-run")
struct WorkshopExecutorCancelSuite {

    @Test(.timeLimit(.minutes(1)))
    func cancelMidRunStopsInFlightStepTask() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "cancel-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "c", objective: "c",
            planJSON: fixturePlanStubShape  // 2 llm steps
        )
        let stepStarted = Counter()
        let stepCancelled = Counter()
        let cancellationReads = CancellationReadCounter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await stepStarted.bump()
                do {
                    // Long "LLM call" — must be cut short by the watcher.
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch is CancellationError {
                    await stepCancelled.bump()
                    throw CancellationError()
                }
                return ("m", "never finishes")
            },
            // A deliberately huge legacy interval proves it no longer controls
            // cancellation latency; the canonical file edge owns wakeup.
            cancellationPollInterval: 60,
            cancellationReadObserver: { cancellationReads.record() }
        )
        let drain = Task { await executor.drainOnce() }
        // Wait until the step is in flight.
        while await stepStarted.snapshot().0 == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // cancel() flips status on disk — the SAME write path the UI uses.
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root)
        let cancelStarted = DispatchTime.now().uptimeNanoseconds
        _ = try await runner.cancel(executionId: id)
        // Drain must return promptly (watcher cancels the in-flight task).
        await drain.value
        let cancelElapsed = DispatchTime.now().uptimeNanoseconds - cancelStarted

        let (cancelledCount, _) = await stepCancelled.snapshot()
        #expect(cancelledCount == 1)   // in-flight step Task actually cancelled
        let (startedCount, _) = await stepStarted.snapshot()
        #expect(startedCount == 1)     // step-report never started
        #expect(cancelElapsed < 1_000_000_000)
        #expect(cancellationReads.value() <= 3)
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "cancelled")
        let events = try await timelineSignature(root: root, id: id)
        // cancel() appends `cancelled`; the executor must NOT append
        // step_completed/completed afterwards (daemon parity: post-step
        // re-read sees cancelled and returns).
        #expect(events.filter { $0.hasPrefix("step_completed") }.isEmpty)
        #expect(!events.contains("completed"))
        #expect(events.contains("cancelled"))
    }

    @Test(.timeLimit(.minutes(1)))
    func healthyInFlightStepPerformsOneInitialCancellationReadAndNoIdlePolling() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "no-idle-cancel-poll"
        try await seedWorkshopExecution(
            root: root, id: id, title: "quiet", objective: "quiet",
            planJSON: fixturePlanSingleStep
        )
        let cancellationReads = CancellationReadCounter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                try await Task.sleep(nanoseconds: 300_000_000)
                return ("m", "done")
            },
            cancellationPollInterval: 0.005,
            cancellationReadObserver: { cancellationReads.record() }
        )

        await executor.drainOnce()

        #expect(await readWorkshopExecution(root: root, id: id)?.status == "completed")
        #expect(cancellationReads.value() == 1)
    }
}

// MARK: - Explicit start()

@Suite("WorkshopExecutorLoop: start(executionId:)")
struct WorkshopExecutorStartSuite {

    @Test func startRunsQueuedWorkshopExecution() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "start-queued"
        try await seedWorkshopExecution(
            root: root, id: id, title: "s", objective: "s",
            planJSON: fixturePlanSingleStep
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "done") },
            cancellationPollInterval: 0.02
        )
        let record = try await executor.start(executionId: id)
        #expect(record.status == "completed")
    }

    @Test func startRefusesNonQueuedWorkshopExecution() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "start-running"
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            cancellationPollInterval: 0.02
        )
        // Prime the one-shot orphan reclaim (empty queue) so the "running"
        // Workshop execution below is a legit slot-holder, not a startup orphan that the
        // reclaim would fail (see WorkshopExecutorOrphanReclaimSuite).
        await executor.drainOnce()
        try await seedWorkshopExecution(
            root: root, id: id, title: "s", objective: "s",
            planJSON: fixturePlanSingleStep, status: "running"
        )
        await #expect(throws: WorkshopExecutionError.invalidRequest("Workshop execution \(id) cannot be started (status=running)")) {
            _ = try await executor.start(executionId: id)
        }
    }

    @Test func startUnknownWorkshopExecutionThrowsNotFound() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = WorkshopExecutorLoop(root: root, cancellationPollInterval: 0.02)
        await #expect(throws: WorkshopExecutionError.invalidRequest("Workshop execution not found: nope")) {
            _ = try await executor.start(executionId: "nope")
        }
    }
}

// MARK: - Cancel vs terminal-write CAS (gpt-5.5 blockers #2 + #6)

@Suite("WorkshopExecutorLoop: cancelled status is never overwritten")
struct WorkshopExecutorCancelCASSuite {

    /// Blocker #2: a cancel that lands while a step is finishing — too late
    /// for the watcher (poll interval here is far longer than the step) —
    /// must NOT be overwritten by the step append or the `completed`
    /// terminal write. The status writes are CAS from "running"; the
    /// cancelled status on disk wins and the receipt/timeline appends are
    /// skipped.
    @Test(.timeLimit(.minutes(1)))
    func lateFinishingStepNeverOverwritesCancelled() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "cas-late-cancel"
        try await seedWorkshopExecution(
            root: root, id: id, title: "c", objective: "c",
            planJSON: fixturePlanSingleStep
        )
        // Watcher effectively disabled (poll ≫ step duration): the step
        // "succeeds" AFTER the cancel landed, and only the CAS stands
        // between that success and an overwrite.
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                // Cancel lands mid-step via the SAME write path the UI uses.
                let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root)
                _ = try await runner.cancel(executionId: id)
                return ("m", "late success")
            },
            cancellationPollInterval: 10.0
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "cancelled")
        // CAS lost → step record append skipped, receipt skipped,
        // step_completed/completed events skipped.
        #expect(final?.stepsCompleted.isEmpty == true)
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.filter { $0.hasPrefix("step_completed") }.isEmpty)
        #expect(!events.contains("completed"))
        #expect(events.contains("cancelled"))
        let receipt = root.appendingPathComponent("workshop/executions/\(id)/receipts/step-1.json")
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
    }

    /// Blocker #6 disposition test: a NON-COOPERATIVE step closure (swallows
    /// CancellationError, keeps running) cannot be preempted promptly — the
    /// task group awaits it — but once it eventually returns, the Workshop execution
    /// must STILL be cancelled: state correctness is guaranteed by the CAS
    /// even when preemption is not.
    @Test(.timeLimit(.minutes(1)))
    func cancelDuringNonCooperativeStepNeverOverwritesCancelled() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "non-coop-cancel"
        try await seedWorkshopExecution(
            root: root, id: id, title: "n", objective: "n",
            planJSON: fixturePlanSingleStep
        )
        let stepStarted = Counter()
        let stepFinished = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await stepStarted.bump()
                // NON-cooperative: ignore cancellation, run to the deadline,
                // then return a "success" anyway.
                let deadline = Date().addingTimeInterval(0.6)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                await stepFinished.bump()
                return ("m", "late success from non-cooperative closure")
            },
            cancellationPollInterval: 0.02
        )
        let drain = Task { await executor.drainOnce() }
        while await stepStarted.snapshot().0 == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root)
        _ = try await runner.cancel(executionId: id)
        await drain.value

        // The closure DID run to completion (no prompt preemption)…
        let (finished, _) = await stepFinished.snapshot()
        #expect(finished == 1)
        // …and the Workshop execution is STILL cancelled — the late result never lands.
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "cancelled")
        #expect(final?.stepsCompleted.isEmpty == true)
        let events = try await timelineSignature(root: root, id: id)
        #expect(!events.contains("completed"))
        #expect(events.filter { $0.hasPrefix("step_completed") }.isEmpty)
    }
}

// MARK: - Stale approval on a no-longer-blocked execution (gpt-5.5 blocker #3)

@Suite("WorkshopExecutorLoop: stale approval cards")
struct WorkshopExecutorStaleApprovalSuite {

    private var gatedPlan: String {
        """
        [{"id": "step-1", "description": "draft the email", "tool_or_action": "email.draft", "args": {"to": "x"}, "autonomy": "auto"}, {"id": "step-2", "description": "Summarize findings", "tool_or_action": "chat.synthesize", "args": {"prompt": "summarize"}, "autonomy": "auto"}]
        """
    }

    /// Drive a Workshop execution to blocked_on_approval, cancel it, then approve the
    /// (now stale) card: the step must NOT execute, the Workshop execution must NOT
    /// flip back to running, and the caller gets the typed staleApproval.
    @Test func approvingStaleCardOnCancelledWorkshopExecutionDoesNotExecute() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "stale-approve"
        try await seedWorkshopExecution(
            root: root, id: id, title: "s", objective: "s",
            planJSON: gatedPlan, trustRequired: "send_approval"
        )
        let toolRuns = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { tool, _ in
                await toolRuns.bump(tool)
                return .object(["status": .string("succeeded")])
            },
            stageApproval: { _ in "approval-stale" },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let blocked = await readWorkshopExecution(root: root, id: id)
        #expect(blocked?.status == "blocked_on_approval")

        // Workshop gets cancelled while the card sits in the inbox.
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root)
        _ = try await runner.cancel(executionId: id)

        await #expect(throws: WorkshopExecutionError.staleApproval(
            "Workshop execution no longer blocked (status=cancelled) — not executed")) {
            _ = try await executor.resumeAfterApproval(
                executionId: id, stepId: "step-1", approved: true, approvalId: "approval-stale")
        }
        // The gated step was NEVER executed and the Workshop execution stayed cancelled.
        let (toolCount, _) = await toolRuns.snapshot()
        #expect(toolCount == 0)
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "cancelled")
    }

    /// Deny on a stale card: the cancelled Workshop execution must not be flipped to
    /// failed and the blocked step record must not be marked rejected.
    @Test func denyingStaleCardOnCancelledWorkshopExecutionDoesNotFailWorkshopExecution() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "stale-deny"
        try await seedWorkshopExecution(
            root: root, id: id, title: "s", objective: "s",
            planJSON: gatedPlan, trustRequired: "send_approval"
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { _, _ in .object(["status": .string("succeeded")]) },
            stageApproval: { _ in "approval-stale-deny" },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let runner = SwiftNativeWorkshopRunner(executorAvailable: true, root: root)
        _ = try await runner.cancel(executionId: id)

        await #expect(throws: WorkshopExecutionError.staleApproval(
            "Workshop execution no longer blocked (status=cancelled) — not executed")) {
            _ = try await executor.resumeAfterApproval(
                executionId: id, stepId: "step-1", approved: false, approvalId: "approval-stale-deny")
        }
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "cancelled")
        if case .object(let sr)? = final?.stepsCompleted.first,
           case .string(let st)? = sr["status"] {
            #expect(st == "blocked_on_approval")   // NOT rejected
        } else {
            Issue.record("blocked step record missing")
        }
    }
}

// MARK: - Cross-execution slot atomicity (gpt-5.5 blocker #4)

/// Tracks the maximum number of concurrently running step closures.
private actor ConcurrencyGauge {
    private var active = 0
    private(set) var peak = 0
    private(set) var entries = 0
    func enter() { active += 1; entries += 1; peak = max(peak, active) }
    func exit() { active -= 1 }
    func snapshot() -> (peak: Int, entries: Int) { (peak, entries) }
}

/// Poll-based gate (deliberately ignores cancellation — nothing cancels it).
private actor TestGate {
    private var isOpen = false
    func open() { isOpen = true }
    func waitOpen() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@Suite("WorkshopExecutorLoop: cross-execution maxActive atomicity")
struct WorkshopExecutorSlotAtomicitySuite {

    /// Blocker #4: two executors claiming two DIFFERENT Workshop executions used to
    /// serialize on nothing shared — both could read runningCount == 0 and
    /// both claim past maxActive == 1. The queue-level claim flock makes
    /// scan+claim atomic across Workshop executions: the second claimer must observe
    /// the first's "running" write and refuse.
    @Test(.timeLimit(.minutes(1)))
    func concurrentClaimsOnDifferentWorkshopExecutionsRespectMaxActive() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedWorkshopExecution(
            root: root, id: "slot-m1", title: "1", objective: "1",
            planJSON: fixturePlanSingleStep
        )
        try await seedWorkshopExecution(
            root: root, id: "slot-m2", title: "2", objective: "2",
            planJSON: fixturePlanSingleStep
        )
        let gauge = ConcurrencyGauge()
        let gate = TestGate()
        let makeExec = {
            WorkshopExecutorLoop(
                root: root,
                llmStep: { _ in
                    await gauge.enter()
                    await gate.waitOpen()   // hold the slot until released
                    await gauge.exit()
                    return ("m", "done")
                },
                maxActive: 1,
                cancellationPollInterval: 0.02
            )
        }
        let a = makeExec()
        let b = makeExec()
        async let ra: WorkshopExecutionRecord? = try? a.start(executionId: "slot-m1")
        async let rb: WorkshopExecutionRecord? = try? b.start(executionId: "slot-m2")
        // Wait until ONE claimer holds the slot, then give the other ample
        // time to attempt its claim (it must refuse, not queue up).
        while await gauge.snapshot().entries == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await gate.open()
        let (resA, resB) = await (ra, rb)

        let (peak, entries) = await gauge.snapshot()
        #expect(peak == 1)        // never two Workshop executions running concurrently
        #expect(entries == 1)     // the loser never executed a step
        // Exactly one start succeeded; the other threw (cannot be started —
        // no slot free, Workshop execution left queued).
        #expect((resA == nil) != (resB == nil))
        let m1 = await readWorkshopExecution(root: root, id: "slot-m1")
        let m2 = await readWorkshopExecution(root: root, id: "slot-m2")
        let statuses = Set([m1?.status, m2?.status].compactMap { $0 })
        #expect(statuses == Set(["completed", "queued"]))
    }
}

// MARK: - Receipt path traversal (gpt-5.5 blocker #5)

@Suite("WorkshopExecutorLoop: receipt path sanitization")
struct WorkshopExecutorReceiptSanitizationSuite {

    @Test func sanitizedPathComponentRules() {
        #expect(WorkshopExecutorLoop.sanitizedPathComponent("step-1") == "step-1")
        #expect(WorkshopExecutorLoop.sanitizedPathComponent("a.b_C-9") == "a.b_C-9")
        #expect(WorkshopExecutorLoop.sanitizedPathComponent("../mission") == ".._mission")
        #expect(WorkshopExecutorLoop.sanitizedPathComponent("../../escape") == ".._.._escape")
        #expect(WorkshopExecutorLoop.sanitizedPathComponent("a/b c\0d") == "a_b_c_d")
        #expect(WorkshopExecutorLoop.sanitizedPathComponent("") == nil)
        let long = String(repeating: "x", count: 500)
        #expect(WorkshopExecutorLoop.sanitizedPathComponent(long)?.count == 180)
    }

    /// Traversal regression: a planner-derived step id of "../../escape"
    /// must land INSIDE receiptsDir under the sanitized name — never above.
    @Test func traversalStepIdCannotEscapeReceiptsDir() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "traversal-execution"
        try await seedWorkshopExecution(
            root: root, id: id, title: "t", objective: "t",
            planJSON: """
            [{"id": "../../escape", "description": "hostile id", "tool_or_action": "chat.synthesize", "args": {"prompt": "x"}, "autonomy": "auto"}]
            """
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "done") },
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")

        let fm = FileManager.default
        // Pre-fix landing spot: receipts/../../escape.json == workshop/executions/escape.json…
        #expect(!fm.fileExists(
            atPath: root.appendingPathComponent("workshop/executions/escape.json").path))
        // …and for safety, nothing above the queue either.
        #expect(!fm.fileExists(
            atPath: root.appendingPathComponent("missions/escape.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("escape.json").path))
        // Sanitized receipt landed inside receiptsDir.
        let receipt = root.appendingPathComponent(
            "workshop/executions/\(id)/receipts/.._.._escape.json")
        #expect(fm.fileExists(atPath: receipt.path))
    }
}

// MARK: - Shared missionPolicy gate rule (gpt-5.5 blocker #7, module half)

@Suite("SwiftNativeWorkshopRunner.workshopPolicyAllows")
struct WorkshopPolicyAllowsSuite {

    @Test func sharedPolicyRuleMirrorsSubmitGate() {
        // Absent missionPolicy → merged default enabled=true → allow.
        #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([:]))
        // developerMode truthy → allow regardless of missionPolicy.
        #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
            "developerMode": .bool(true), "missionPolicy": .string("broken"),
        ]))
        // Present-but-malformed → DENY (daemon AttributeError-bubble parity).
        #expect(!SwiftNativeWorkshopRunner.workshopPolicyAllows([
            "missionPolicy": .string("broken"),
        ]))
        #expect(!SwiftNativeWorkshopRunner.workshopPolicyAllows([
            "missionPolicy": .array([.string("x")]),
        ]))
        // enabled key absent → allow (merged default).
        #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
            "missionPolicy": .object(["showTimeline": .bool(true)]),
        ]))
        // Explicit false → deny; pyTruthy semantics for non-bool values.
        #expect(!SwiftNativeWorkshopRunner.workshopPolicyAllows([
            "missionPolicy": .object(["enabled": .bool(false)]),
        ]))
        #expect(SwiftNativeWorkshopRunner.workshopPolicyAllows([
            "missionPolicy": .object(["enabled": .int(1)]),
        ]))
        #expect(!SwiftNativeWorkshopRunner.workshopPolicyAllows([
            "missionPolicy": .object(["enabled": .string("")]),
        ]))
    }
}

// MARK: - Hard step deadline (unattended-hang backstop, 2026-06-15)
//
// TRUST log #1: a wedged tool (dead network, an MCP server that never answers)
// in an UNATTENDED execution reaches no cancel() and used to hang the step
// forever — and because drainOnce awaits each execution and slots are capped,
// enough hung steps starve ALL execution throughput until restart. The hard
// per-step deadline (raceWithCancellationWatch) auto-fails the step instead.

@Suite("WorkshopExecutorLoop: hard step deadline")
struct WorkshopExecutorStepDeadlineSuite {

    /// THE freeze fix: a cooperative tool that hangs far past the per-step
    /// deadline, with NO cancellation (no human in the loop). The deadline must
    /// auto-FAIL the step + execution promptly, not hang. .timeLimit guards
    /// against a regression that reintroduces the hang.
    @Test(.timeLimit(.minutes(1)))
    func hungStepHitsDeadlineAndFailsWorkshopExecutionUnattended() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "deadline-hang"
        try await seedWorkshopExecution(
            root: root, id: id, title: "h", objective: "h",
            planJSON: fixturePlanSingleStep
        )
        let stepStarted = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await stepStarted.bump()
                // Cooperative hang far beyond the deadline (a tool awaiting a
                // dead peer). NOTHING cancels it — the unattended case.
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return ("m", "never returns")
            },
            cancellationPollInterval: 0.02,
            stepTimeoutInterval: 0.3
        )
        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "failed")
        #expect(final?.currentStepId == "")   // terminal clears the pointer
        guard case .object(let sr)? = final?.stepsCompleted.first,
              case .string(let err)? = sr["error"] else {
            Issue.record("missing failed step record"); return
        }
        #expect(err.hasPrefix("step_timeout_exceeded_"))
        #expect(sr["status"] == .string("failed"))
        #expect(await stepStarted.snapshot().0 == 1)  // ran, then timed out
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.contains("failed|step-1"))
    }

    /// The default deadline is a BACKSTOP, not a budget: a normal fast step
    /// completes cleanly with no override (proves zero behavior change to
    /// normal Workshop executions).
    @Test func defaultDeadlineDoesNotAffectFastStep() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "deadline-fast"
        try await seedWorkshopExecution(
            root: root, id: id, title: "f", objective: "f",
            planJSON: fixturePlanSingleStep
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "quick done") },
            cancellationPollInterval: 0.02
            // no stepTimeoutInterval → default 3600s; never fires on a fast step
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        #expect(final?.result == .string("quick done"))
    }

    /// <= 0 disables the deadline (no deadline task spawned): a slow-but-fine
    /// step still completes — the explicit opt-out path.
    @Test(.timeLimit(.minutes(1)))
    func disabledDeadlineNeverFires() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "deadline-off"
        try await seedWorkshopExecution(
            root: root, id: id, title: "o", objective: "o",
            planJSON: fixturePlanSingleStep
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return ("m", "slow but ok")
            },
            cancellationPollInterval: 0.02,
            stepTimeoutInterval: 0   // disabled
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        #expect(final?.result == .string("slow but ok"))
    }
}

// MARK: - Parent/pass cancellation claim release

@Suite("WorkshopExecutorLoop: pass cancellation recovery")
struct WorkshopExecutorPassCancellationSuite {
    @Test(.timeLimit(.minutes(1)))
    func cancelledPassRequeuesClaimAndNextDrainCompletesWithoutReplayingDurableSteps() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "pass-cancel-retry"
        let plan = """
        [
          {"id":"step-1","description":"first","tool_or_action":"test.first","args":{},"autonomy":"auto"},
          {"id":"step-2","description":"second","tool_or_action":"test.second","args":{},"autonomy":"auto"}
        ]
        """
        try await seedWorkshopExecution(root: root, id: id, title: "cancel", objective: "retry", planJSON: plan)

        let calls = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            toolDispatch: { tool, _ in
                await calls.bump(tool)
                let (_, labels) = await calls.snapshot()
                if tool == "test.second" && labels.filter({ $0 == tool }).count == 1 {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
                return .object(["status": .string("succeeded"), "tool": .string(tool)])
            },
            maxActive: 1,
            cancellationPollInterval: 0.02,
            stepTimeoutInterval: 60
        )

        let firstPass = Task { await executor.drainOnce() }
        while true {
            let (_, labels) = await calls.snapshot()
            if labels.contains("test.second") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        firstPass.cancel()
        await firstPass.value

        let interrupted = await readWorkshopExecution(root: root, id: id)
        #expect(interrupted?.status == "queued")
        #expect(interrupted?.currentStepId == "")
        #expect(interrupted?.stepsCompleted.count == 1)
        #expect(try await rawTimelineHas(
            root: root,
            id: id,
            event: "execution_interrupted",
            reason: "parent_task_cancelled"
        ))

        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        #expect(final?.stepsCompleted.count == 2)
        let (_, labels) = await calls.snapshot()
        #expect(labels.filter { $0 == "test.first" }.count == 1)
        #expect(labels.filter { $0 == "test.second" }.count == 2)
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.filter { $0 == "started" }.count == 2)
        #expect(events.filter { $0 == "step_completed|step-1|succeeded" }.count == 1)
        #expect(events.filter { $0 == "step_completed|step-2|succeeded" }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulStepDuringParentCancellationCommitsBeforeRequeueAndIsNotRepeated() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "pass-cancel-success-boundary"
        let plan = """
        [
          {"id":"step-1","description":"side effect","tool_or_action":"test.side-effect","args":{},"autonomy":"auto"}
        ]
        """
        try await seedWorkshopExecution(root: root, id: id, title: "cancel", objective: "commit", planJSON: plan)

        let calls = Counter()
        let cancellation = ParentCancellationControl()
        let executor = WorkshopExecutorLoop(
            root: root,
            toolDispatch: { tool, _ in
                await calls.bump(tool)
                await cancellation.cancelParent()
                return .object(["status": .string("succeeded"), "tool": .string(tool)])
            },
            maxActive: 1,
            cancellationPollInterval: 0.02,
            stepTimeoutInterval: 60
        )

        let firstPass = Task {
            await cancellation.waitUntilArmed()
            await executor.drainOnce()
        }
        await cancellation.arm { firstPass.cancel() }
        await firstPass.value

        let interrupted = await readWorkshopExecution(root: root, id: id)
        #expect(interrupted?.status == "queued")
        #expect(interrupted?.currentStepId == "")
        #expect(interrupted?.stepsCompleted.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("workshop/executions/\(id)/receipts/step-1.json").path
        ))

        await executor.drainOnce()

        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "completed")
        #expect(final?.stepsCompleted.count == 1)
        let (count, labels) = await calls.snapshot()
        #expect(count == 1)
        #expect(labels == ["test.side-effect"])
        let events = try await timelineSignature(root: root, id: id)
        #expect(events.filter { $0 == "started" }.count == 2)
        #expect(events.filter { $0 == "execution_interrupted|queued" }.count == 1)
        #expect(events.filter { $0 == "step_completed|step-1|succeeded" }.count == 1)
        #expect(events.filter { $0 == "completed" }.count == 1)
    }
}

// MARK: - Startup orphan reclaim (crash/restart slot-leak fix, 2026-06-15)
//
// TRUST log #2: an execution left "running" by a crash is never re-claimed (claim
// requires "queued") yet still counts against maxActive — a silent slot leak
// that degrades throughput across restarts. Parent/pass cancellation requeues
// its live claim in-process; the first drain after launch fails only true
// restart orphans honestly so the slot frees.

@Suite("WorkshopExecutorLoop: startup orphan reclaim")
struct WorkshopExecutorOrphanReclaimSuite {

    /// An orphaned "running" Workshop execution is failed (interrupted_by_restart) on the
    /// first drain, AND its slot is freed — proven by a queued Workshop execution running
    /// under maxActive:1, which is impossible if the orphan still held a slot.
    @Test(.timeLimit(.minutes(1)))
    func orphanedRunningReclaimedAndSlotFreed() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Crash orphan: left "running" on disk by a dead prior instance.
        try await seedWorkshopExecution(
            root: root, id: "orphan-1", title: "o", objective: "o",
            planJSON: fixturePlanSingleStep, status: "running"
        )
        // A normal queued Workshop execution that must run once the slot frees.
        try await seedWorkshopExecution(
            root: root, id: "queued-1", title: "q", objective: "q",
            planJSON: fixturePlanSingleStep
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "done") },
            maxActive: 1,   // orphan + this: if the orphan still counted, queued-1 can't start
            cancellationPollInterval: 0.02
        )
        await executor.drainOnce()

        // Orphan failed honestly, step pointer cleared.
        let orphan = await readWorkshopExecution(root: root, id: "orphan-1")
        #expect(orphan?.status == "failed")
        #expect(orphan?.currentStepId == "")
        // …with the interrupted_by_restart timeline event (the failed event
        // carries `error`, which timelineSignature drops — read it raw).
        let persistence = SwiftNativePersistenceCore()
        let rows = try await persistence.readJSONL(
            root.appendingPathComponent("workshop/executions/orphan-1/timeline.jsonl"))
        #expect(rows.contains { row in
            if case .object(let o) = row,
               case .string("failed")? = o["event"],
               case .string("interrupted_by_restart")? = o["error"] { return true }
            return false
        })
        // The orphan's step was NOT executed (reclaim must not re-run side effects).
        #expect(orphan?.stepsCompleted.isEmpty == true)
        // Slot was freed → the queued Workshop execution actually ran to completion.
        let queued = await readWorkshopExecution(root: root, id: "queued-1")
        #expect(queued?.status == "completed")
    }

    /// The reclaim runs ONLY on the first drain: a "running" Workshop execution appearing
    /// AFTER the first drain (e.g. one this process is actively running) must
    /// NOT be reclaimed by a later drain.
    @Test(.timeLimit(.minutes(1)))
    func reclaimRunsOnlyOnFirstDrain() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "done") },
            cancellationPollInterval: 0.02
        )
        // First drain: nothing to reclaim, but it ARMS the once-guard.
        await executor.drainOnce()
        // Now a "running" Workshop execution appears (stand-in for one in flight).
        try await seedWorkshopExecution(
            root: root, id: "later-running", title: "l", objective: "l",
            planJSON: fixturePlanSingleStep, status: "running"
        )
        // Second drain must NOT touch it.
        await executor.drainOnce()
        let m = await readWorkshopExecution(root: root, id: "later-running")
        #expect(m?.status == "running")
    }

    /// gpt-5.5 BLOCKING regression: an execution STARTED via start() (the UI path,
    /// before the first background drain) must NOT be reclaimed as an orphan by
    /// that drain. The shared reconcile barrier makes start() run the reclaim
    /// FIRST (seeing the execution still "queued" — no orphan) before claiming it,
    /// so the later drain finds the reclaim already done and leaves the live
    /// execution alone. With the old bare-bool guard this test FAILS (the drain
    /// reclaims the live execution to failed/interrupted_by_restart).
    @Test(.timeLimit(.minutes(1)))
    func workshopExecutionStartedViaStartIsNotReclaimedByConcurrentDrain() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedWorkshopExecution(
            root: root, id: "user-started", title: "u", objective: "u",
            planJSON: fixturePlanSingleStep
        )
        let gate = TestGate()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await gate.waitOpen()   // hold the Workshop execution "running"
                return ("m", "done")
            },
            cancellationPollInterval: 0.02
        )
        // Start explicitly (claims → running → blocks on the gate).
        async let started: WorkshopExecutionRecord? = try? executor.start(executionId: "user-started")
        while await readWorkshopExecution(root: root, id: "user-started")?.status != "running" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // A background drain fires while it's live — must NOT reclaim it.
        await executor.drainOnce()
        // Release → the started Workshop execution completes normally (NOT interrupted).
        await gate.open()
        _ = await started
        let final = await readWorkshopExecution(root: root, id: "user-started")
        #expect(final?.status == "completed")
        let persistence = SwiftNativePersistenceCore()
        let rows = try await persistence.readJSONL(
            root.appendingPathComponent("workshop/executions/user-started/timeline.jsonl"))
        #expect(!rows.contains { row in
            if case .object(let o) = row,
               case .string("interrupted_by_restart")? = o["error"] { return true }
            return false
        })
    }

    /// gpt-5.5 re-review BLOCKING regression: the startup orphan-reclaim barrier
    /// is memoized PER DATA-ROOT, not per instance. The app can run TWO executor
    /// instances on one root (the background drain via WorkshopExecutorRef.shared
    /// AND a cold-start fallback in applyResolvedWorkshopStep). Instance A flips a
    /// execution to "running"; a SEPARATE instance B's first drain must NOT reclaim
    /// it as a crash orphan — both share the one per-root reclaim. With the old
    /// per-instance guard B runs its OWN reclaim and fails A's live execution.
    @Test(.timeLimit(.minutes(1)))
    func liveWorkshopExecutionOnOneInstanceNotReclaimedByAnotherInstanceSameRoot() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedWorkshopExecution(
            root: root, id: "shared-root", title: "s", objective: "s",
            planJSON: fixturePlanSingleStep
        )
        let gate = TestGate()
        // Instance A: starts the Workshop execution and holds it "running" on the gate.
        let execA = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await gate.waitOpen()
                return ("m", "done")
            },
            cancellationPollInterval: 0.02
        )
        async let started: WorkshopExecutionRecord? = try? execA.start(executionId: "shared-root")
        while await readWorkshopExecution(root: root, id: "shared-root")?.status != "running" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Instance B: a DIFFERENT executor on the SAME root drains while A's
        // Workshop execution is live. The per-root barrier means B shares A's already-run
        // reclaim and must leave the running Workshop execution alone.
        let execB = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "done") },
            cancellationPollInterval: 0.02
        )
        await execB.drainOnce()
        #expect(await readWorkshopExecution(root: root, id: "shared-root")?.status == "running")

        await gate.open()
        _ = await started
        let final = await readWorkshopExecution(root: root, id: "shared-root")
        #expect(final?.status == "completed")
        let persistence = SwiftNativePersistenceCore()
        let rows = try await persistence.readJSONL(
            root.appendingPathComponent("workshop/executions/shared-root/timeline.jsonl"))
        #expect(!rows.contains { row in
            if case .object(let o) = row,
               case .string("interrupted_by_restart")? = o["error"] { return true }
            return false
        })
    }
}

// MARK: - Approval-wait timeout (reconcileTimedOutApprovals)

/// The "no human is coming" stall fix: an execution blocked_on_approval past the
/// configured deadline is auto-failed, and the sweep is race-safe against a
/// concurrent resume (resume CAS-claims blocked_on_approval → running BEFORE
/// it executes the step, so the two are mutually exclusive).
@Suite("WorkshopExecutorLoop: approval-wait timeout")
struct WorkshopExecutorApprovalTimeoutSuite {

    private var gatedPlan: String {
        """
        [{"id": "step-1", "description": "draft the email", "tool_or_action": "email.draft", "args": {"to": "x"}, "autonomy": "auto"}, {"id": "step-2", "description": "Summarize findings", "tool_or_action": "chat.synthesize", "args": {"prompt": "summarize"}, "autonomy": "auto"}]
        """
    }

    /// A blocked step record matching what runSteps leaves on a real block,
    /// so the resume precondition logic exercises the same path in production.
    private var blockedStepRecord: JSONValue {
        .object([
            "step_id": .string("step-1"),
            "status": .string("blocked_on_approval"),
            "approval_id": .string("appr-1"),
            "executed_at": .string(SwiftNativeWorkshopRunner.isoTimestamp(Date())),
        ])
    }

    /// Past the deadline → auto-failed with the approval_timeout error.
    @Test func blockedWorkshopExecutionPastDeadlineIsAutoFailed() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "appr-timeout-fires"
        try await seedWorkshopExecution(
            root: root, id: id, title: "t", objective: "t",
            planJSON: gatedPlan, trustRequired: "send_approval",
            status: "blocked_on_approval", stepsCompleted: [blockedStepRecord]
        )
        // updatedAt ≈ now (seedMission). Executor clock is 3h ahead, deadline
        // 1h → elapsed ≈ 3h ≥ 1h, fires.
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { _, _ in .object(["status": .string("succeeded")]) },
            approvalTimeoutInterval: 3600,
            now: { Date().addingTimeInterval(3 * 3600) }
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "failed")
        #expect(final?.currentStepId == "")
        let hasTimeout = try await rawTimelineHasErrorPrefix(
            root: root, id: id, prefix: "approval_timeout_exceeded_")
        #expect(hasTimeout)
    }

    /// Still within the deadline → left blocked (no premature kill).
    @Test func blockedWorkshopExecutionWithinDeadlineSurvives() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "appr-timeout-survives"
        try await seedWorkshopExecution(
            root: root, id: id, title: "t", objective: "t",
            planJSON: gatedPlan, trustRequired: "send_approval",
            status: "blocked_on_approval", stepsCompleted: [blockedStepRecord]
        )
        // 10min elapsed vs 1h deadline → survives.
        let executor = WorkshopExecutorLoop(
            root: root,
            approvalTimeoutInterval: 3600,
            now: { Date().addingTimeInterval(600) }
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "blocked_on_approval")
    }

    @Test func blockedWorkshopExecutionPublishesExactApprovalDeadline() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedWorkshopExecution(
            root: root, id: "appr-exact-deadline", title: "t", objective: "t",
            planJSON: gatedPlan, trustRequired: "send_approval",
            status: "blocked_on_approval", stepsCompleted: [blockedStepRecord]
        )
        let executor = WorkshopExecutorLoop(root: root, approvalTimeoutInterval: 3600)
        let now = Date()
        let deadline = try #require(await executor.nextMeaningfulDeadline(after: now))
        #expect(deadline.timeIntervalSince(now) > 3_590)
        #expect(deadline.timeIntervalSince(now) <= 3_610)
    }

    /// Deadline 0 (the DEFAULT) disables the sweep entirely — a Workshop execution blocked
    /// for "10 days" is left untouched. Also assert the env-default is 0 when
    /// the opt-in env var is unset.
    @Test func disabledByDefaultLeavesBlockedWorkshopExecutionAlone() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "appr-timeout-off"
        try await seedWorkshopExecution(
            root: root, id: id, title: "t", objective: "t",
            planJSON: gatedPlan, trustRequired: "send_approval",
            status: "blocked_on_approval", stepsCompleted: [blockedStepRecord]
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            approvalTimeoutInterval: 0,
            now: { Date().addingTimeInterval(10 * 24 * 3600) }
        )
        await executor.drainOnce()
        let final = await readWorkshopExecution(root: root, id: id)
        #expect(final?.status == "blocked_on_approval")

        if ProcessInfo.processInfo.environment["NATIVE_AGENT_MISSION_APPROVAL_TIMEOUT_SECONDS"] == nil {
            #expect(WorkshopExecutorLoop.defaultApprovalTimeoutSeconds() == 0)
        }
    }

    /// SWEEP-WINS exclusivity: once the sweep has failed a blocked Workshop execution,
    /// approving the now-stale card must NOT execute the step (it sees
    /// status=failed and throws staleApproval). Proves no failed-mid-execution.
    @Test func approvingAfterTimeoutSweepDoesNotExecute() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "appr-timeout-then-approve"
        try await seedWorkshopExecution(
            root: root, id: id, title: "t", objective: "t",
            planJSON: gatedPlan, trustRequired: "send_approval",
            status: "blocked_on_approval", stepsCompleted: [blockedStepRecord]
        )
        let toolRuns = Counter()
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in ("m", "x") },
            toolDispatch: { tool, _ in
                await toolRuns.bump(tool)
                return .object(["status": .string("succeeded")])
            },
            approvalTimeoutInterval: 3600,
            now: { Date().addingTimeInterval(3 * 3600) }
        )
        await executor.drainOnce()   // sweep fails it
        #expect(await readWorkshopExecution(root: root, id: id)?.status == "failed")

        await #expect(throws: WorkshopExecutionError.staleApproval(
            "Workshop execution no longer blocked (status=failed) — not executed")) {
            _ = try await executor.resumeAfterApproval(
                executionId: id, stepId: "step-1", approved: true, approvalId: "appr-1")
        }
        let (toolCount, _) = await toolRuns.snapshot()
        #expect(toolCount == 0)
        #expect(await readWorkshopExecution(root: root, id: id)?.status == "failed")
    }

    /// RESUME-WINS path: with the timeout configured but NOT yet elapsed, a
    /// normal approve still claims blocked→running, EXECUTES the step, and
    /// completes — the sweep config must not break the happy path.
    @Test func resumeWithTimeoutConfiguredStillExecutesAndCompletes() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "appr-timeout-resume-ok"
        try await seedWorkshopExecution(
            root: root, id: id, title: "t", objective: "t",
            planJSON: fixturePlanSingleStep, trustRequired: "send_approval"
        )
        let llmRuns = Counter()
        // Default clock (real now) → freshly-blocked Workshop execution is well within
        // the 1h deadline, so the sweep never fires.
        let executor = WorkshopExecutorLoop(
            root: root,
            llmStep: { _ in
                await llmRuns.bump()
                return ("m", "done")
            },
            tooledLLMStep: { _ in
                await llmRuns.bump()
                return ("m", "done")
            },
            stageApproval: { _ in "appr-ok" },
            cancellationPollInterval: 0.02,
            approvalTimeoutInterval: 3600
        )
        await executor.drainOnce()
        #expect(await readWorkshopExecution(root: root, id: id)?.status == "blocked_on_approval")

        let completed = try await executor.resumeAfterApproval(
            executionId: id, stepId: "step-1", approved: true, approvalId: "appr-ok")
        #expect(completed.status == "completed")
        let (llmCount, _) = await llmRuns.snapshot()
        #expect(llmCount == 1)   // the step actually ran
    }
}
