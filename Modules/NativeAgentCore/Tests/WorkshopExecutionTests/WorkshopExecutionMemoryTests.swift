import Testing
import Foundation
@testable import WorkshopExecution
import MemoryV2
import NativeAgentCore
import PersistenceCore

// WORKSHOP → MEMORY PLUG (2026-08-02, NORTHSTAR clause 1).
//
// The claim under test is not "a function was called". It is: after a Workshop
// execution finishes, SHE CAN REMEMBER IT — the row is in the same MemoryV2
// store chat recall reads, and the disclosure policy releases it on the
// `missions` surface. `endToEnd*` proves exactly that against a real
// SQLite-backed MemoryV2 on a temp root; the rest pin the narrative shape,
// the drop logging, and the retention sweep.
//
// HERMETIC: every root is a unique tmp dir. No `.shared`, no live data — and
// the executor's own default-writer rule (only wire the real store when the
// executor root IS the default data root) is what keeps it that way even if a
// future test forgets to inject.

// MARK: - Fixtures

private func makeTempRoot(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopExecutionMemoryTests-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func stepOutcome(_ id: String, _ status: String, text: String = "") -> JSONValue {
    .object([
        "step_id": .string(id),
        "status": .string(status),
        "output": .object(["text": .string(text)]),
        "error": .string(""),
        "approval_id": .string(""),
        "executed_at": .string("2026-08-02T10:00:00Z"),
    ])
}

private func fixtureRecord(
    id: String = "wsx-1",
    title: String = "Sweep the stale release artifacts",
    objective: String = "Delete build artifacts older than 30 days from the release staging dir.",
    status: String,
    plan: Int = 2,
    stepsCompleted: [JSONValue] = [],
    result: JSONValue = .null,
    verification: WorkshopVerificationRecord? = nil,
    triggerSource: String = "manual"
) -> WorkshopExecutionRecord {
    WorkshopExecutionRecord(
        id: id,
        title: title,
        objective: objective,
        createdAt: "2026-08-02T09:00:00Z",
        status: status,
        plan: (0..<plan).map {
            WorkshopExecutionStep(id: "step-\($0)", description: "step \($0)", toolOrAction: "noop")
        },
        stepsCompleted: stepsCompleted,
        receiptsDir: "/tmp/receipts",
        triggerSource: triggerSource,
        trustRequired: "none",
        expectedOutputs: [],
        currentStepId: "",
        updatedAt: "2026-08-02T10:00:00Z",
        result: result,
        rerunCount: 0,
        verification: verification
    )
}

// MARK: - Fake writer

private actor FakeExecutionMemoryWriter: WorkshopExecutionMemoryWriting {
    struct Written: Sendable {
        let id: String
        let content: String
        let source: String
        let metadata: JSONValue
        let createdAt: String
    }

    private(set) var written: [Written] = []
    private(set) var retired: [String] = []
    private var counter = 0
    private let failWrites: Bool
    private let failRetire: Bool

    init(failWrites: Bool = false, failRetire: Bool = false) {
        self.failWrites = failWrites
        self.failRetire = failRetire
    }

    /// Pre-seed rows so the retention sweep has something to evict.
    func seed(count: Int) {
        for index in 0..<count {
            counter += 1
            written.append(
                Written(
                    id: "seed-\(String(format: "%04d", index))",
                    content: "seeded \(index)",
                    source: "\(WorkshopExecutionMemory.sourcePrefix)seed-\(index)",
                    metadata: .object([:]),
                    // Ascending timestamps: seed-0000 is the OLDEST.
                    createdAt: String(format: "2026-01-01T00:%02d:00Z", index % 60)
                        + "-\(String(format: "%04d", index))"
                )
            )
        }
    }

    func writeExecutionMemory(content: String, source: String, metadata: JSONValue) async throws -> String {
        if failWrites { throw MemoryV2Error.storageUnavailable }
        counter += 1
        let id = "mem-\(counter)"
        written.append(
            Written(
                id: id,
                content: content,
                source: source,
                metadata: metadata,
                createdAt: "2027-01-01T00:00:0\(counter % 10)Z"
            )
        )
        return id
    }

    /// Models the PRODUCTION read, limit included. The real writer asks SQLite
    /// for `retentionCap + retentionSweepWindow` rows, newest-first — so a fake
    /// that returns the whole lane hides exactly the non-convergence the sweep
    /// had (it would look bounded here and leave ~801 rows on the real store).
    /// Same class of divergence as the fixture/SQLite metadata contract.
    func executionMemories(sourcePrefix: String) async throws -> [WorkshopExecutionMemoryHandle] {
        let live = written
            .filter { $0.source.hasPrefix(sourcePrefix) && !retired.contains($0.id) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
        let limit = WorkshopExecutionMemory.retentionCap + WorkshopExecutionMemory.retentionSweepWindow
        return live.prefix(limit).map {
            WorkshopExecutionMemoryHandle(id: $0.id, createdAt: $0.createdAt, source: $0.source)
        }
    }

    func retireExecutionMemory(id: String) async throws {
        if failRetire { throw MemoryV2Error.storageUnavailable }
        retired.append(id)
    }

    var liveIDs: [String] { written.map(\.id).filter { !retired.contains($0) } }
}

/// A writer that is deliberately slow the way the real one can be (SQLite busy
/// for its 2s timeout, a CoreML embed stalling). Used to MEASURE that the
/// terminal path does not wait on it — see
/// `aStalledMemoryWriteDoesNotHoldUpExecutionCompletion`.
private actor StallingExecutionMemoryWriter: WorkshopExecutionMemoryWriting {
    /// Backstop so a REGRESSION (an awaited write) fails the test instead of
    /// hanging the suite forever. Far above any load-induced jitter, so the
    /// elapsed-time assertion is not a race.
    static let hangCapSeconds: TimeInterval = 30
    private var released = false
    private(set) var entered = 0
    private(set) var completed = 0

    func release() { released = true }

    func writeExecutionMemory(content: String, source: String, metadata: JSONValue) async throws -> String {
        entered += 1
        let deadline = Date().addingTimeInterval(Self.hangCapSeconds)
        while !released, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        completed += 1
        return "stalled-\(completed)"
    }

    func executionMemories(sourcePrefix: String) async throws -> [WorkshopExecutionMemoryHandle] { [] }
    func retireExecutionMemory(id: String) async throws {}
}

private final class LogSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(level: WorkshopExecutionMemoryLogLevel, text: String)] = []
    func append(_ level: WorkshopExecutionMemoryLogLevel, _ line: String) {
        lock.lock(); lines.append((level, line)); lock.unlock()
    }
    var all: [(level: WorkshopExecutionMemoryLogLevel, text: String)] {
        lock.lock(); defer { lock.unlock() }; return lines
    }
    func contains(_ needle: String) -> Bool { all.contains { $0.text.contains(needle) } }
    /// Severity matters: production routes this sink through `Logger.info`, so
    /// a failure logged at `.info` is not actually loud (gpt-5.5 review A1).
    func level(containing needle: String) -> WorkshopExecutionMemoryLogLevel? {
        all.first { $0.text.contains(needle) }?.level
    }
    var sink: WorkshopExecutionMemoryLog { { [self] level, line in append(level, line) } }
}

// MARK: - Suite

@Suite("WorkshopExecutionMemory")
struct WorkshopExecutionMemoryTests {

    // MARK: narrative shape

    @Test func completedNarrativeSaysWhatItWasAndWhatCameOfIt() {
        let record = fixtureRecord(
            status: "completed",
            stepsCompleted: [stepOutcome("step-0", "succeeded"), stepOutcome("step-1", "succeeded")],
            result: .string("Removed 14 artifacts, freed 2.1 GB."),
            verification: WorkshopVerificationRecord(
                status: .satisfied, checkedAt: "2026-08-02T10:00:00Z", methods: ["file_bytes"]
            )
        )
        let text = WorkshopExecutionMemory.narrative(record, reason: nil)

        #expect(text.hasPrefix("Workshop execution \"Sweep the stale release artifacts\" completed."))
        #expect(text.contains("The objective was: Delete build artifacts older than 30 days"))
        #expect(text.contains("2 of 2 planned steps succeeded."))
        #expect(text.contains("verified against the execution's own success criterion"))
        #expect(text.contains("What came of it: Removed 14 artifacts, freed 2.1 GB."))
        #expect(text.contains("It was started by manual."))
        // A memory, not a receipt: no identifiers in the prose.
        #expect(!text.contains("wsx-1"))
        #expect(!text.contains("/tmp/receipts"))
    }

    @Test func failedNarrativeCarriesTheFailureNotJustTheStatus() {
        let record = fixtureRecord(
            id: "execution-2",
            status: "failed",
            stepsCompleted: [stepOutcome("step-0", "succeeded"), stepOutcome("step-1", "failed")]
        )
        let text = WorkshopExecutionMemory.narrative(
            record, reason: "rm: /Volumes/staging: Operation not permitted"
        )
        #expect(text.hasPrefix("Workshop execution \"Sweep the stale release artifacts\" failed."))
        #expect(text.contains("1 of 2 planned steps succeeded."))
        #expect(text.contains("What went wrong: rm: /Volumes/staging: Operation not permitted"))
    }

    @Test func verificationFailureIsRecordedAsAFailedOutcomeNotASuccess() {
        // The honesty gate's own case: every step succeeded, the execution did not.
        let record = fixtureRecord(
            status: "failed",
            plan: 1,
            stepsCompleted: [stepOutcome("step-0", "succeeded")],
            result: .object([
                "error": .string("verification_failed"),
                "detail": .string("expected output \"proof passed\" absent"),
            ]),
            verification: WorkshopVerificationRecord(
                status: .failed,
                checkedAt: "2026-08-02T10:00:00Z",
                methods: ["exact_output"],
                detail: "expected output \"proof passed\" absent"
            )
        )
        let text = WorkshopExecutionMemory.narrative(record, reason: nil)
        #expect(text.contains("failed."))
        #expect(text.contains("Verification of the declared outcome failed"))
        #expect(text.contains("What went wrong: expected output"))
    }

    @Test func stepCountsNeverReportMoreCompletedThanPlanned() {
        // A resumed / re-planned run can durably complete more rows than the
        // final plan holds; "3 of 2" would be a lie.
        let record = fixtureRecord(
            status: "completed",
            plan: 2,
            stepsCompleted: [
                stepOutcome("a", "succeeded"), stepOutcome("b", "succeeded"), stepOutcome("c", "succeeded"),
            ]
        )
        #expect(WorkshopExecutionMemory.narrative(record, reason: nil).contains("3 of 3 planned steps succeeded."))
    }

    @Test func metadataCarriesTheReceiptFieldsAndTheDisclosureSurfaces() {
        let record = fixtureRecord(status: "completed", stepsCompleted: [stepOutcome("step-0", "succeeded")])
        guard case .object(let meta) = WorkshopExecutionMemory.metadata(record, reason: nil) else {
            Issue.record("metadata is not an object")
            return
        }
        #expect(meta["kind"] == .string("operational"))
        #expect(meta["workshop_execution_id"] == .string("wsx-1"))
        #expect(meta["workshop_status"] == .string("completed"))
        #expect(meta["workshop_steps_planned"] == .int(2))
        #expect(meta["workshop_steps_succeeded"] == .int(1))
        #expect(meta["workshop_trigger_source"] == .string("manual"))
        // The surfaces the row is disclosable on — local_private, verbatim.
        #expect(
            meta["permittedSurfaces"]
                == .array(MemoryRecordDisclosurePolicy.localPrivateSurfaces.sorted().map(JSONValue.string))
        )
    }

    // MARK: what is dropped, and that the drop is LOUD

    @Test func cancelledBeforeAnyStepRanIsDroppedAndLogged() async {
        let writer = FakeExecutionMemoryWriter()
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)

        let id = await recorder.record(fixtureRecord(status: "cancelled"), reason: nil)
        #expect(id == nil)
        #expect(await writer.written.isEmpty)
        #expect(spy.contains("DROPPED execution wsx-1"))
        #expect(spy.contains("cancelled_before_any_step_ran"))
    }

    @Test func cancelledAfterRealWorkIsStillRemembered() async {
        let writer = FakeExecutionMemoryWriter()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: { _, _ in })
        let record = fixtureRecord(status: "cancelled", stepsCompleted: [stepOutcome("step-0", "succeeded")])
        #expect(await recorder.record(record, reason: "cancelled by user") != nil)
        let written = await writer.written
        #expect(written.count == 1)
        #expect(written[0].content.contains("was cancelled before it finished"))
    }

    @Test func nonTerminalStatusIsDroppedWithItsStatusNamed() async {
        let writer = FakeExecutionMemoryWriter()
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)
        #expect(await recorder.record(fixtureRecord(status: "running"), reason: nil) == nil)
        #expect(spy.contains("non_terminal_status:running"))
    }

    @Test func aWriteFailureIsLoudNotSilent() async {
        let writer = FakeExecutionMemoryWriter(failWrites: true)
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)
        let record = fixtureRecord(status: "completed", stepsCompleted: [stepOutcome("step-0", "succeeded")])
        #expect(await recorder.record(record, reason: nil) == nil)
        #expect(spy.contains("ERROR writing execution wsx-1 memory"))
        // …and loud means LOUD: `.error`, not the `.info` production would swallow.
        #expect(spy.level(containing: "ERROR writing execution wsx-1 memory") == .error)
    }

    // MARK: retention — every add has a remove

    @Test func retentionEvictsOldestBeyondTheCapAndLogsWhatItDropped() async {
        let writer = FakeExecutionMemoryWriter()
        await writer.seed(count: WorkshopExecutionMemory.retentionCap)
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)

        // Cap + 1 rows exist after this write → exactly one eviction.
        let record = fixtureRecord(status: "completed", stepsCompleted: [stepOutcome("step-0", "succeeded")])
        _ = await recorder.record(record, reason: nil)

        let retired = await writer.retired
        #expect(retired == ["seed-0000"])           // the oldest, not the newest
        #expect(await writer.liveIDs.count == WorkshopExecutionMemory.retentionCap)
        #expect(spy.contains("retention: archived execution memory seed-0000"))
        #expect(spy.contains("exceeds cap \(WorkshopExecutionMemory.retentionCap)"))
    }

    /// NEEDS_FIX 3 (gpt-5.5 review, 2026-08-02) — THE SWEEP HAS TO CONVERGE.
    ///
    /// The read is bounded to `retentionCap + retentionSweepWindow` (400) rows.
    /// The old sweep archived `dropFirst(cap)` of THAT SLICE and stopped, so a
    /// lane sitting at 1,000 active rows went to ~801 and stayed there — it
    /// crept toward the cap only if more executions ever finished, and never
    /// converged at all if none did. A bound that only holds while the lane is
    /// busy is not a bound.
    ///
    /// One `record()` call must leave the lane AT the cap.
    @Test func retentionConvergesToTheCapInASingleSweepEvenFarOverIt() async {
        let writer = FakeExecutionMemoryWriter()
        await writer.seed(count: 1000)
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)

        _ = await recorder.record(
            fixtureRecord(status: "completed", stepsCompleted: [stepOutcome("step-0", "succeeded")]),
            reason: nil
        )

        // Pre-fix: 1001 - 200 archived in one slice = 801 live.
        #expect(
            await writer.liveIDs.count == WorkshopExecutionMemory.retentionCap,
            "the sweep left the lane above its own cap"
        )
        // It took more than one pass, and said so.
        #expect(spy.contains("(pass 2)"))
        // …and it did not silently give up.
        #expect(!spy.contains("gave up after"))
        // The newest row — the one just written — survived; the oldest did not.
        #expect(await writer.retired.contains("seed-0000"))
    }

    /// The backstop is loud, not silent: a writer whose archive always fails
    /// must not spin, and must say the lane is unbounded.
    @Test func aRetentionSweepThatCannotArchiveGivesUpLoudly() async {
        let writer = FakeExecutionMemoryWriter(failRetire: true)
        await writer.seed(count: 500)
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)

        _ = await recorder.record(
            fixtureRecord(status: "completed", stepsCompleted: [stepOutcome("step-0", "succeeded")]),
            reason: nil
        )

        #expect(spy.contains("made no progress"))
        #expect(spy.level(containing: "made no progress") == .error)
        #expect(await writer.retired.isEmpty)
    }

    @Test func retentionDoesNothingBelowTheCap() async {
        let writer = FakeExecutionMemoryWriter()
        await writer.seed(count: 3)
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)
        _ = await recorder.record(
            fixtureRecord(status: "completed", stepsCompleted: [stepOutcome("step-0", "succeeded")]),
            reason: nil
        )
        #expect(await writer.retired.isEmpty)
        #expect(!spy.contains("retention: archived"))
    }

    /// A2 (gpt-5.5 review, 2026-08-02) — RETENTION MUST NOT MINT TOMBSTONES.
    ///
    /// Against the REAL store, because the whole defect lives in MemoryV2's
    /// delete path: `deleteMemory` upserts a rejection tombstone for the
    /// deleted CONTENT, so the next execution producing the same prose is refused
    /// as `tombstoned` and the lane silently stops remembering repeats. On the
    /// pre-fix code the final write here fails and `rerun` is nil.
    @Test func retentionArchivesRatherThanTombstoningSoARepeatIsStillRemembered() async throws {
        let root = try makeTempRoot("retention-no-tombstone")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try makeMemory(root: root)
        let spy = LogSpy()
        // cap 1 so the sweep is provable without writing 201 rows.
        let recorder = WorkshopExecutionMemoryRecorder(
            writer: SwiftNativeWorkshopExecutionMemoryWriter(memory: memory),
            retentionCap: 1,
            log: spy.sink
        )

        let first = fixtureRecord(
            id: "wsx-alpha",
            title: "Sweep the stale release artifacts",
            status: "completed",
            plan: 1,
            stepsCompleted: [stepOutcome("step-0", "succeeded")],
            result: .string("Removed 14 artifacts, freed 2.1 GB.")
        )
        let firstID = try #require(await recorder.record(first, reason: nil))
        // `created_at` has SECOND resolution and the sweep orders on it: two
        // writes inside one second tie, fall back to the id tie-break, and
        // "the OLDEST is evicted" becomes a coin flip. Space them.
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let second = fixtureRecord(
            id: "wsx-beta",
            title: "Rotate the provider credentials",
            objective: "Rotate the anthropic oauth credential and re-verify the handshake.",
            status: "completed",
            plan: 1,
            stepsCompleted: [stepOutcome("step-0", "succeeded")],
            result: .string("Credential rotated; handshake verified.")
        )
        _ = try #require(await recorder.record(second, reason: nil))

        // The sweep ran and took the OLDEST out of the lane…
        #expect(spy.contains("retention: archived execution memory \(firstID)"))
        let live = try await SwiftNativeWorkshopExecutionMemoryWriter(memory: memory)
            .executionMemories(sourcePrefix: WorkshopExecutionMemory.sourcePrefix)
        #expect(!live.map(\.id).contains(firstID), "an archived row is out of the active lane")
        #expect(live.count == 1)

        // …by ARCHIVING it. The row is still there, still walkable.
        let archived = try #require(
            (try await memory.listMemory(kind: nil)).first { $0.id == firstID }
        )
        #expect(archived.status == "archived")
        #expect(archived.text.contains("Sweep the stale release artifacts"))

        // THE POINT: run the same execution to the same outcome again and she can
        // still remember it. Pre-fix this threw "tombstoned".
        let rerun = await recorder.record(first, reason: nil)
        #expect(rerun != nil, "an age-evicted memory must not become a rejection tombstone")
        #expect(!spy.contains("ERROR writing execution wsx-alpha"))
        #expect(spy.level(containing: "tombstoned") == nil)
    }

    // MARK: END TO END — a finished execution is a recallable memory

    /// Real MemoryV2 over a temp-dir SQLite store with the deterministic mock
    /// embedder — the same `store()`/`recallMemory()` path chat uses.
    private func makeMemory(root: URL) throws -> SwiftNativeMemoryV2 {
        let storage = try MemoryStorage(dataRoot: root)
        return SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(),
            storage: MemoryStorageBridge(storage: storage)
        )
    }

    /// The disclosure-gated recall lane. `recall(_:)` is what `recallMemory`
    /// (the chat tool) is built on; it returns the surviving RECORDS, which is
    /// what "she can remember this" has to mean.
    private func recall(
        _ memory: SwiftNativeMemoryV2,
        query: String,
        surface: String?
    ) async throws -> [MemoryRecord] {
        try await memory.recall(
            MemoryV2RecallRequest(text: query, topK: 10, persona: nil, surface: surface)
        ).scored.map(\.record)
    }

    @Test func endToEndCompletedExecutionBecomesARecallableWorkshopMemory() async throws {
        let root = try makeTempRoot("e2e-completed")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try makeMemory(root: root)
        let recorder = WorkshopExecutionMemoryRecorder(
            writer: SwiftNativeWorkshopExecutionMemoryWriter(memory: memory),
            log: { _, _ in }
        )

        let id = "verified-exact-output"
        try await seedExecutionMemoryExecution(
            root: root,
            id: id,
            title: "Exact output",
            objective: "Return exactly: Workshop live proof passed."
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            measuredTooledLLMStep: { _ in
                WorkshopStepLLMCompletion(
                    model: "gpt-5.6-sol", text: "Workshop live proof passed.", providerCallCount: 1
                )
            },
            isEnabled: { true },
            executionMemory: recorder
        )
        await executor.drainOnce()
        // The memory write is deliberately OFF the terminal path (A1), so a
        // reader has to wait for the tail before asserting on it.
        await executor.waitForExecutionMemoryWrites()

        // The execution really did finish.
        let persistence = SwiftNativePersistenceCore()
        let raw = await persistence.readJSON(
            ExecutionRecordFile.resolve(
                in: root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)),
            defaultValue: .null
        )
        guard case .object(let object) = raw else {
            Issue.record("execution record missing")
            return
        }
        #expect(object["status"] == .string("completed"))

        // …and she can remember it, ON THE MISSIONS SURFACE.
        let hits = try await recall(memory, query: "Workshop execution Exact output completed", surface: "missions")
        let execution = try #require(hits.first { ($0.sourceRunId ?? "").hasPrefix("workshop:") })
        #expect(execution.sourceRunId == "workshop:\(id)")
        #expect(execution.text.contains("Workshop execution \"Exact output\" completed."))
        #expect(execution.text.contains("Workshop live proof passed"))

        // `workshop` is the human spelling of the same surface — the mapping the
        // policy already carried, now with something behind it.
        #expect(!(try await recall(memory, query: execution.text, surface: "workshop")).isEmpty)
        // And it flows into the rest of her mind rather than sitting in a
        // executions-only silo…
        #expect(!(try await recall(memory, query: execution.text, surface: "chat")).isEmpty)
        // …but never onto a prompt-injectable no-human surface.
        #expect((try await recall(memory, query: execution.text, surface: "slack")).isEmpty)

        // The disclosure policy itself agrees, directly.
        let classification = try #require(MemoryRecordDisclosurePolicy.classify(execution))
        #expect(classification.permits(surface: "missions", personaID: nil))
        #expect(classification.permits(surface: "workshop", personaID: nil))
        #expect(!classification.permits(surface: "slack", personaID: nil))
    }

    @Test func endToEndFailedMissionIsRememberedToo() async throws {
        let root = try makeTempRoot("e2e-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try makeMemory(root: root)
        let recorder = WorkshopExecutionMemoryRecorder(
            writer: SwiftNativeWorkshopExecutionMemoryWriter(memory: memory),
            log: { _, _ in }
        )

        let id = "failing-tool-step"
        try await seedExecutionMemoryExecution(
            root: root,
            id: id,
            title: "Copy the release notes",
            objective: "Copy the notes into the staging directory.",
            planJSON: """
            [{"id":"copy","description":"copy the notes","tool_or_action":"local_files.copy","args":{},"autonomy":"auto"}]
            """
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            toolDispatch: { _, _ in
                throw MemoryV2Error.underlying("staging directory is read-only")
            },
            isEnabled: { true },
            executionMemory: recorder
        )
        await executor.drainOnce()
        await executor.waitForExecutionMemoryWrites()

        let persistence = SwiftNativePersistenceCore()
        let raw = await persistence.readJSON(
            ExecutionRecordFile.resolve(
                in: root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)),
            defaultValue: .null
        )
        guard case .object(let object) = raw else {
            Issue.record("execution record missing")
            return
        }
        #expect(object["status"] == .string("failed"))

        let hits = try await recall(memory, query: "Copy the release notes failed", surface: "missions")
        let execution = try #require(hits.first { ($0.sourceRunId ?? "").hasPrefix("workshop:") })
        #expect(execution.text.contains("Workshop execution \"Copy the release notes\" failed."))
        #expect(execution.text.contains("staging directory is read-only"))
        // Failures are remembered with the same disclosure reach as successes.
        let classification = try #require(MemoryRecordDisclosurePolicy.classify(execution))
        #expect(classification.permits(surface: "missions", personaID: nil))
    }

    /// A1 (gpt-5.5 review, BLOCKING) — THE MEMORY WRITE IS OFF THE HOT PATH.
    ///
    /// The failure this pins: the terminal path used to `await recorder.record`,
    /// which embeds, inserts, then sweeps retention. A SQLite busy-timeout or a
    /// stalled CoreML embed therefore held the executor's terminal transition,
    /// and the drain / `start()` / approval-resume did not advance to the next
    /// queued execution — even though the terminal CAS and the Desk receipt had
    /// already landed.
    ///
    /// Measured, not asserted: the writer stalls for `stallSeconds`, and
    /// `drainOnce()` — which INCLUDES the terminal transition — must return in
    /// a small fraction of that. On the pre-fix code the elapsed time is the
    /// full stall. The write is then proven not-lost through the wait seam.
    @Test func aStalledMemoryWriteDoesNotHoldUpExecutionCompletion() async throws {
        let root = try makeTempRoot("nonblocking")
        defer { try? FileManager.default.removeItem(at: root) }
        // The writer stalls until this test releases it — the shape of a SQLite
        // busy-timeout or a wedged embed, without a wall-clock guess.
        let writer = StallingExecutionMemoryWriter()
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)

        let id = "stalled-memory"
        try await seedExecutionMemoryExecution(
            root: root, id: id, title: "Exact output",
            objective: "Return exactly: Workshop live proof passed."
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            measuredTooledLLMStep: { _ in
                WorkshopStepLLMCompletion(
                    model: "gpt-5.6-sol", text: "Workshop live proof passed.", providerCallCount: 1
                )
            },
            isEnabled: { true },
            executionMemory: recorder
        )

        let started = Date()
        await executor.drainOnce()
        let elapsed = Date().timeIntervalSince(started)

        // The execution really did reach terminal…
        let persistence = SwiftNativePersistenceCore()
        let raw = await persistence.readJSON(
            ExecutionRecordFile.resolve(
                in: root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)),
            defaultValue: .null
        )
        guard case .object(let object) = raw else {
            Issue.record("execution record missing")
            return
        }
        #expect(object["status"] == .string("completed"))
        // …without waiting on the store. The bound is a quarter of the writer's
        // 30s hang cap: an AWAITED write cannot come in under it at any load,
        // and a handed-off one returns in milliseconds.
        #expect(elapsed < StallingExecutionMemoryWriter.hangCapSeconds / 4,
                "terminal path took \(elapsed)s while the memory write was stalled")
        // The write has NOT finished — the terminal path really did move on
        // without it. (Whether the detached task has been scheduled yet is a
        // race by design; `completed` is the claim that matters.)
        #expect(await writer.completed == 0)

        // And it is not LOST: released, the tail completes for anyone who waits.
        await writer.release()
        await executor.waitForExecutionMemoryWrites()
        #expect(await writer.entered == 1)
        #expect(await writer.completed == 1)
        #expect(spy.contains("remembered execution \(id)"))
    }

    // MARK: NEEDS_FIX 2 — the queue is bounded, and the bound is loud

    /// The queue used to be UNBOUNDED: with the head write hung in
    /// embed/SQLite, every later terminal event spawned another detached task
    /// awaiting `previous?.value`, each retaining a full
    /// `WorkshopExecutionRecord` for the length of the stall. `enqueued` was
    /// diagnostic only — no cap, no backpressure, and nothing said a word.
    ///
    /// Pre-fix this test cannot even be written: there is no bound to hit.
    @Test func aStalledQueueRefusesNewWritesAtItsBoundAndNamesWhatItDropped() async throws {
        let writer = StallingExecutionMemoryWriter()
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)
        let queue = WorkshopExecutionMemoryQueue(recorder: recorder, maxPending: 3)

        for index in 0..<6 {
            await queue.enqueue(
                fixtureRecord(id: "execution-\(index)", status: "completed",
                              stepsCompleted: [stepOutcome("step-0", "succeeded")]),
                reason: nil
            )
        }

        #expect(await queue.enqueuedCount() == 3, "the bound actually bounds")
        #expect(await queue.droppedCount() == 3)
        #expect(await queue.pendingCount() == 3)

        // LOUD: `.error` (production routes `.info` into a level nobody reads)
        // and the execution's own identity, not just a count.
        #expect(spy.contains("QUEUE FULL"))
        #expect(spy.level(containing: "QUEUE FULL") == .error)
        #expect(spy.contains("DROPPED the execution memory for execution-3"))
        #expect(spy.contains("DROPPED the execution memory for execution-5"))
        // The ones that made it in are not dropped.
        #expect(!spy.contains("DROPPED the execution memory for execution-0"))

        // Let the stall go so the suite doesn't leave detached tasks spinning,
        // and prove the bound RECOVERS: drained, the queue accepts again.
        await writer.release()
        await queue.drain()
        #expect(await queue.pendingCount() == 0)
        await queue.enqueue(
            fixtureRecord(id: "execution-after", status: "completed",
                          stepsCompleted: [stepOutcome("step-0", "succeeded")]),
            reason: nil
        )
        #expect(await queue.enqueuedCount() == 4)
        await queue.drain()
    }

    // MARK: BLOCKING 1 — shutdown drains, bounded; crash is reconciled

    /// Production quit stops loops/MCP/context/cognition under a 3s budget and
    /// used NEVER to drain this queue, so an execution that reached terminal
    /// moments before quit left `mission.json` on disk with no memory behind
    /// it — silently. `waitForExecutionMemoryWrites(timeout:)` is the drain, and
    /// it is BOUNDED: a wedged writer must not hold up quit, and an abandoned
    /// drain must SAY so rather than look like success.
    @Test func shutdownDrainIsBoundedAndReportsWhatItAbandoned() async throws {
        let root = try makeTempRoot("shutdown-drain")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = StallingExecutionMemoryWriter()
        let spy = LogSpy()
        let recorder = WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)

        let id = "shutdown-stalled"
        try await seedExecutionMemoryExecution(
            root: root, id: id, title: "Exact output",
            objective: "Return exactly: Workshop live proof passed."
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            measuredTooledLLMStep: { _ in
                WorkshopStepLLMCompletion(
                    model: "gpt-5.6-sol", text: "Workshop live proof passed.", providerCallCount: 1
                )
            },
            isEnabled: { true },
            executionMemory: recorder
        )
        await executor.drainOnce()

        // The write is stalled. The shutdown drain must give up ON TIME…
        let started = Date()
        let drained = await executor.waitForExecutionMemoryWrites(timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        #expect(drained == false, "a stalled write must be reported as abandoned, never as drained")
        #expect(elapsed < StallingExecutionMemoryWriter.hangCapSeconds / 4,
                "shutdown drain took \(elapsed)s — it is not bounded")
        #expect(await writer.completed == 0)

        // …and when the store IS responsive, the same call actually drains,
        // which is the case that makes the wiring worth having.
        await writer.release()
        #expect(await executor.waitForExecutionMemoryWrites(timeout: 30) == true)
        #expect(await writer.completed == 1)
        #expect(spy.contains("remembered execution \(id)"))
    }

    /// The crash half: nothing drains, because the process died. At next launch
    /// the terminal record on disk has no memory row, and before this fix
    /// nothing ever went back for it.
    @Test func startupReconciliationRewritesAMemoryLostToACrash() async throws {
        let root = try makeTempRoot("reconcile-crash")
        defer { try? FileManager.default.removeItem(at: root) }

        // "Previous process": runs the execution to terminal with NO recorder
        // wired — exactly the on-disk state a crash mid-write leaves behind.
        let id = "crash-lost-memory"
        try await seedExecutionMemoryExecution(
            root: root, id: id, title: "Exact output",
            objective: "Return exactly: Workshop live proof passed."
        )
        let crashed = WorkshopExecutorLoop(
            root: root,
            measuredTooledLLMStep: { _ in
                WorkshopStepLLMCompletion(
                    model: "gpt-5.6-sol", text: "Workshop live proof passed.", providerCallCount: 1
                )
            },
            isEnabled: { true }
        )
        await crashed.drainOnce()

        // "Next launch": same root, a working recorder.
        let writer = FakeExecutionMemoryWriter()
        let spy = LogSpy()
        let relaunched = WorkshopExecutorLoop(
            root: root,
            isEnabled: { true },
            executionMemory: WorkshopExecutionMemoryRecorder(writer: writer, log: spy.sink)
        )
        let reconciled = await relaunched.reconcileMissedExecutionMemories()
        await relaunched.waitForExecutionMemoryWrites()

        #expect(reconciled == 1)
        let written = await writer.written
        #expect(written.count == 1)
        #expect(written.first?.source == "\(WorkshopExecutionMemory.sourcePrefix)\(id)")
        #expect(written.first?.content.contains("Workshop execution \"Exact output\" completed.") == true)

        // IDEMPOTENT: a second launch must not mint a second memory for the
        // same execution — the fake now reports `source` the way SQLite does.
        let again = await relaunched.reconcileMissedExecutionMemories()
        await relaunched.waitForExecutionMemoryWrites()
        #expect(again == 0)
        #expect(await writer.written.count == 1)
    }

    /// The scan is BOUNDED — it does not re-read the whole execution history on
    /// every launch. An execution last touched outside the window is not
    /// reconciled, and neither is anything past `maxRecords`.
    @Test func reconciliationOnlyLooksAtARecentBoundedWindow() async throws {
        let root = try makeTempRoot("reconcile-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "ancient-execution"
        try await seedExecutionMemoryExecution(
            root: root, id: id, title: "Exact output",
            objective: "Return exactly: Workshop live proof passed."
        )
        let first = WorkshopExecutorLoop(
            root: root,
            measuredTooledLLMStep: { _ in
                WorkshopStepLLMCompletion(
                    model: "gpt-5.6-sol", text: "Workshop live proof passed.", providerCallCount: 1
                )
            },
            isEnabled: { true }
        )
        await first.drainOnce()

        // Age the execution dir past the default 7-day window.
        let dir = root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: dir.path
        )

        let writer = FakeExecutionMemoryWriter()
        let relaunched = WorkshopExecutorLoop(
            root: root,
            isEnabled: { true },
            executionMemory: WorkshopExecutionMemoryRecorder(writer: writer, log: { _, _ in })
        )
        #expect(await relaunched.reconcileMissedExecutionMemories() == 0, "outside the window")
        // …and the same record IS picked up when the window covers it, so the
        // zero above is the window's doing and not a broken scan.
        #expect(await relaunched.reconcileMissedExecutionMemories(within: 60 * 24 * 3600) == 1)
        // maxRecords is the other bound.
        #expect(await relaunched.reconcileMissedExecutionMemories(
            within: 60 * 24 * 3600, maxRecords: 0
        ) == 0)
        await relaunched.waitForExecutionMemoryWrites()
    }

    @Test func executorOnATempRootWiresNoWriterByDefault() async throws {
        // The hermetic guarantee: an executor that is NOT on the default data
        // root must never reach `SwiftNativeMemoryV2.shared`. Proven by the
        // absence of any execution dir side effect — the run completes normally
        // with no injected recorder and no crash from an unwired store.
        let root = try makeTempRoot("no-default-writer")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "no-writer"
        try await seedExecutionMemoryExecution(
            root: root, id: id, title: "Exact output",
            objective: "Return exactly: Workshop live proof passed."
        )
        let executor = WorkshopExecutorLoop(
            root: root,
            measuredTooledLLMStep: { _ in
                WorkshopStepLLMCompletion(
                    model: "gpt-5.6-sol", text: "Workshop live proof passed.", providerCallCount: 1
                )
            },
            isEnabled: { true }
        )
        await executor.drainOnce()
        let persistence = SwiftNativePersistenceCore()
        let raw = await persistence.readJSON(
            ExecutionRecordFile.resolve(
                in: root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)),
            defaultValue: .null
        )
        guard case .object(let object) = raw else {
            Issue.record("execution record missing")
            return
        }
        #expect(object["status"] == .string("completed"))
        // No memory store was created under the temp root.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("memory").path))
    }
}

// MARK: - Local seeding helper

@discardableResult
private func seedExecutionMemoryExecution(
    root: URL,
    id: String,
    title: String,
    objective: String,
    planJSON: String = """
    [{"id": "step-1", "description": "produce the exact output", "tool_or_action": "chat.synthesize", "args": {"prompt": "Return exactly: Workshop live proof passed."}, "autonomy": "auto"}]
    """
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
        status: "queued",
        plan: SwiftNativeWorkshopRunner.parsePlanSteps(planParsed),
        stepsCompleted: [],
        receiptsDir: receipts.path,
        triggerSource: "manual",
        trustRequired: "none",
        expectedOutputs: [],
        currentStepId: "",
        updatedAt: nowStr,
        result: .null,
        rerunCount: 0
    )
    try await persistence.writeJSON(record.toJSON(), to: ExecutionRecordFile.canonicalPath(in: dir))
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
