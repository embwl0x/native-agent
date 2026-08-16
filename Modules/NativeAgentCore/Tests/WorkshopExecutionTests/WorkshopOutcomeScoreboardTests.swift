import Testing
import Foundation
@testable import WorkshopExecution
import PersistenceCore

// MEASURE leg (north-star, 2026-06-15): the execution outcome scoreboard.
// Tests the PURE aggregator core over synthetic samples (deterministic, no
// I/O, no clock) plus the record→sample parser against real execution timestamp
// format.

private func sample(
    _ id: String, created: Date, updated: Date? = nil, status: String,
    total: Int = 3, completed: Int = 0, rerun: Int = 0, triggerSource: String = "manual",
    wasStub: Bool = false
) -> WorkshopOutcomeSample {
    WorkshopOutcomeSample(
        id: id, createdAt: created, updatedAt: updated ?? created, status: status,
        totalSteps: total, completedSteps: completed, rerunCount: rerun,
        triggerSource: triggerSource, wasStub: wasStub
    )
}

// A fixed Monday-anchored week so bucketing is reproducible.
private let wkA = WorkshopOutcomeScoreboard.weekStart(of: Date(timeIntervalSince1970: 1_780_000_000))

@Suite("WorkshopOutcomeScoreboard: pure aggregator")
struct WorkshopOutcomeScoreboardPureSuite {

    @Test
    func directedTaskReceiptPreservesDeskIdentity() throws {
        let receipt = WorkshopDirectedTaskReceipt(
            handle: "desk_abc",
            executionId: "exec_123",
            status: "completed",
            summary: "done",
            createdAt: "2026-07-11T12:00:00Z",
            completedAt: "2026-07-11T12:02:00Z",
            totalSteps: 3,
            completedSteps: 3,
            rerunCount: 1,
            triggerSource: "manual",
            wasStub: false
        )
        let roundTrip = try #require(WorkshopDirectedTaskReceipt.fromJSON(receipt.toJSON()))
        #expect(roundTrip == receipt)
        let outcome = try #require(WorkshopOutcomeScoreboard.sample(from: roundTrip))
        #expect(outcome.id == "exec_123")
        #expect(outcome.deskHandle == "desk_abc")
        #expect(outcome.wallSeconds == 120)
    }

    @Test
    func emptyReturnsEmpty() {
        #expect(WorkshopOutcomeScoreboard.weekly(from: []).isEmpty)
    }

    @Test
    func medianOddEvenEmpty() {
        #expect(WorkshopOutcomeScoreboard.median([3, 1, 2]) == 2)        // odd
        #expect(WorkshopOutcomeScoreboard.median([1, 2, 3, 4]) == 2.5)   // even → mean of middles
        #expect(WorkshopOutcomeScoreboard.median([]) == 0)               // empty
    }

    @Test
    func singleWeekMixedStatuses() {
        let c = wkA.addingTimeInterval(3600)  // +1h, inside wkA
        let samples = [
            sample("s1", created: c, updated: c.addingTimeInterval(100), status: "completed", total: 4, completed: 4, rerun: 2),
            sample("s2", created: c, updated: c.addingTimeInterval(200), status: "completed", total: 2, completed: 2, rerun: 0),
            sample("s3", created: c, updated: c.addingTimeInterval(50),  status: "failed",    total: 5, completed: 1, rerun: 1),
            sample("s4", created: c, updated: c.addingTimeInterval(10),  status: "cancelled", total: 3, completed: 0, rerun: 0),
            // non-terminal: counts toward total but NOT terminal/completionRate/wall.
            sample("s5", created: c, updated: c.addingTimeInterval(9999), status: "running",  total: 8, completed: 1, rerun: 0),
        ]
        let weeks = WorkshopOutcomeScoreboard.weekly(from: samples)
        #expect(weeks.count == 1)
        let w = weeks[0]
        #expect(w.weekStart == wkA)
        #expect(w.total == 5)
        #expect(w.terminal == 4)
        #expect(w.completed == 2)
        #expect(w.failed == 1)
        #expect(w.cancelled == 1)
        #expect(w.completionRate == 0.5)                 // 2 completed / 4 terminal
        #expect(w.medianTotalSteps == 4)                 // [2,3,4,5,8] → 4
        #expect(w.medianCompletedSteps == 1)             // [0,1,1,2,4] → 1
        #expect(w.medianWallSeconds == 75)               // terminal walls [10,50,100,200] → (50+100)/2
        #expect(w.medianRerunCount == 0)                 // [0,0,0,1,2] → 0
    }

    @Test
    func allRunningWeekHasZeroCompletionRateNotNaN() {
        let c = wkA.addingTimeInterval(60)
        let weeks = WorkshopOutcomeScoreboard.weekly(from: [
            sample("r1", created: c, status: "running"),
            sample("r2", created: c, status: "queued"),
        ])
        #expect(weeks.count == 1)
        #expect(weeks[0].terminal == 0)
        #expect(weeks[0].completionRate == 0)            // guarded: no divide-by-zero NaN
        #expect(weeks[0].medianWallSeconds == 0)         // no terminal Workshop executions
    }

    @Test
    func twoWeeksBucketSeparatelyAndSortAscending() {
        let inA = wkA.addingTimeInterval(3 * 86400)      // +3d, still wkA
        let seedB = wkA.addingTimeInterval(8 * 86400)    // +8d → next week
        let wkB = WorkshopOutcomeScoreboard.weekStart(of: seedB)
        #expect(wkB > wkA)
        let weeks = WorkshopOutcomeScoreboard.weekly(from: [
            sample("b1", created: seedB, status: "failed"),     // out of order on purpose
            sample("a1", created: inA, status: "completed"),
        ])
        #expect(weeks.count == 2)
        #expect(weeks[0].weekStart == wkA)               // ascending
        #expect(weeks[1].weekStart == wkB)
        #expect(weeks[0].completed == 1 && weeks[0].failed == 0)
        #expect(weeks[1].failed == 1 && weeks[1].completed == 0)
    }

    @Test
    func stubRateReflectsPlannerFallbacks() {
        let c = wkA.addingTimeInterval(60)
        let weeks = WorkshopOutcomeScoreboard.weekly(from: [
            sample("a", created: c, status: "completed", wasStub: true),
            sample("b", created: c, status: "completed", wasStub: false),
            sample("d", created: c, status: "failed", wasStub: true),
            sample("e", created: c, status: "completed", wasStub: false),
        ])
        #expect(weeks.count == 1)
        #expect(weeks[0].stubRate == 0.5)   // 2 of 4 plans were stubs
        // No-stub week → 0 (not NaN).
        let clean = WorkshopOutcomeScoreboard.weekly(from: [
            sample("x", created: c, status: "completed", wasStub: false),
        ])
        #expect(clean[0].stubRate == 0)
    }

    @Test
    func onlyTriggerSourceSegmentsOneCohort() {
        let c = wkA.addingTimeInterval(60)
        let samples = [
            sample("g1", created: c, status: "completed", triggerSource: "controlled_eval"),
            sample("g2", created: c, status: "failed",    triggerSource: "controlled_eval"),
            sample("u1", created: c, status: "completed", triggerSource: "manual"),
            sample("u2", created: c, status: "completed", triggerSource: "trigger:inbox"),
        ]
        // Unfiltered: all 4.
        #expect(WorkshopOutcomeScoreboard.weekly(from: samples)[0].total == 4)
        // Selected cohort only: 2 (1 completed of 2 terminal → 50%).
        let selected = WorkshopOutcomeScoreboard.weekly(from: samples, onlyTriggerSource: "controlled_eval")
        #expect(selected.count == 1)
        #expect(selected[0].total == 2)
        #expect(selected[0].completed == 1)
        #expect(selected[0].completionRate == 0.5)
        // A cohort with no members → empty (not a crash, not all-of-them).
        #expect(WorkshopOutcomeScoreboard.weekly(from: samples, onlyTriggerSource: "nope").isEmpty)
    }

    @Test
    func sameIsoWeekDifferentDaysShareBucket() {
        let mon = wkA.addingTimeInterval(3600)
        let sat = wkA.addingTimeInterval(5 * 86400 + 3600)  // still inside the ISO week
        let weeks = WorkshopOutcomeScoreboard.weekly(from: [
            sample("m", created: mon, status: "completed"),
            sample("s", created: sat, status: "completed"),
        ])
        #expect(weeks.count == 1)
        #expect(weeks[0].total == 2)
    }
}

@Suite("WorkshopOutcomeScoreboard: prompt formatting")
struct WorkshopOutcomeScoreboardFormatSuite {

    @Test
    func emptyWeeksFormatsToEmptyString() {
        #expect(WorkshopOutcomeScoreboard.formatForPrompt([]).isEmpty)
    }

    @Test
    func formatsRecentWeeksWithTrend() {
        let c1 = wkA.addingTimeInterval(3600)
        let c2 = wkA.addingTimeInterval(8 * 86400)  // next ISO week
        // Week A: 1 completed of 2 terminal → 50%. Week B: 2 completed of 2 → 100%.
        let weeks = WorkshopOutcomeScoreboard.weekly(from: [
            sample("a1", created: c1, status: "completed"),
            sample("a2", created: c1, status: "failed"),
            sample("b1", created: c2, status: "completed"),
            sample("b2", created: c2, status: "completed"),
        ])
        let text = WorkshopOutcomeScoreboard.formatForPrompt(weeks)
        #expect(text.contains("Workshop outcomes"))
        #expect(text.contains("(50%)"))            // week A completion rate
        #expect(text.contains("(100%)"))           // week B completion rate
        #expect(text.contains("Trend: completion rate UP"))  // 50% → 100%
        #expect(text.contains("+50 pts"))
    }

    @Test
    func respectsMaxWeeksWindow() {
        // 3 weeks of data, ask for last 2 → only 2 week lines.
        let weeks = (0..<3).map { i -> WeeklyOutcomeStats in
            WeeklyOutcomeStats(
                weekStart: wkA.addingTimeInterval(Double(i) * 7 * 86400),
                total: 1, terminal: 1, completed: 1, failed: 0, cancelled: 0,
                completionRate: 1.0, medianTotalSteps: 3, medianCompletedSteps: 3,
                medianWallSeconds: 30, medianRerunCount: 0
            )
        }
        let text = WorkshopOutcomeScoreboard.formatForPrompt(weeks, maxWeeks: 2)
        let weekLineCount = text.split(separator: "\n").filter { $0.hasPrefix("- week of") }.count
        #expect(weekLineCount == 2)
    }

    @Test
    func nonPositiveMaxWeeksIsSafe() {
        let weeks = WorkshopOutcomeScoreboard.weekly(from: [
            sample("x", created: wkA.addingTimeInterval(60), status: "completed"),
        ])
        #expect(WorkshopOutcomeScoreboard.formatForPrompt(weeks, maxWeeks: 0).isEmpty)
        #expect(WorkshopOutcomeScoreboard.formatForPrompt(weeks, maxWeeks: -3).isEmpty)  // no trap
    }
}

@Suite("WorkshopOutcomeScoreboard: record → sample")
struct WorkshopOutcomeScoreboardParseSuite {

    private func makeRecord(
        created: String, updated: String, status: String, steps: Int,
        completed: Int, rerun: Int
    ) -> WorkshopExecutionRecord {
        let plan = (0..<steps).map {
            WorkshopExecutionStep(id: "step-\($0)", description: "d", toolOrAction: "noop")
        }
        let done: [JSONValue] = (0..<completed).map { .string("step-\($0)") }
        return WorkshopExecutionRecord(
            id: "m1", title: "t", objective: "o", createdAt: created, status: status,
            plan: plan, stepsCompleted: done, receiptsDir: "", triggerSource: "manual",
            trustRequired: "none", expectedOutputs: [], currentStepId: "", updatedAt: updated,
            result: .null, rerunCount: rerun
        )
    }

    @Test
    func parsesWorkshopExecutionTimestampFormatAndMapsFields() {
        // The exact format Workshop executions persist (fractional seconds, +00:00).
        let created = SwiftNativeWorkshopRunner.isoTimestamp(Date(timeIntervalSince1970: 1_780_000_000))
        let updated = SwiftNativeWorkshopRunner.isoTimestamp(Date(timeIntervalSince1970: 1_780_000_100))
        let rec = makeRecord(created: created, updated: updated, status: "completed", steps: 3, completed: 2, rerun: 1)
        let s = WorkshopOutcomeScoreboard.sample(from: rec)
        #expect(s != nil)
        #expect(s?.totalSteps == 3)
        #expect(s?.completedSteps == 2)
        #expect(s?.rerunCount == 1)
        #expect(s?.status == "completed")
        #expect(s?.isCompleted == true)
        #expect(s?.wallSeconds == 100)                   // end-to-end parse + wall calc
    }

    @Test
    func parsesDaemonEraMicrosecondTimestamps() {
        // Real on-disk daemon-era format: 6-digit (microsecond) fraction, which
        // ISO8601DateFormatter.withFractionalSeconds (3-digit only) rejects.
        // The scoreboard must NOT silently drop these (19/21 live queue records
        // are this shape) — gpt-5.5 review regression.
        let rec = makeRecord(
            created: "2026-05-07T10:12:54.380610+00:00",
            updated: "2026-05-07T10:13:54.380610+00:00",  // +60s
            status: "completed", steps: 2, completed: 2, rerun: 0
        )
        let s = WorkshopOutcomeScoreboard.sample(from: rec)
        #expect(s != nil)
        #expect(s?.isCompleted == true)
        #expect(s?.wallSeconds == 60)            // microsecond fraction truncated, wall still correct
        // The pure helper truncates >3-digit fractions, preserving the tz.
        #expect(WorkshopOutcomeScoreboard.truncateFractionToMillis("2026-05-07T10:12:54.380610+00:00")
                == "2026-05-07T10:12:54.380+00:00")
        // A 3-digit (or no) fraction needs no truncation.
        #expect(WorkshopOutcomeScoreboard.truncateFractionToMillis("2026-05-07T10:12:54.380+00:00") == nil)
        #expect(WorkshopOutcomeScoreboard.truncateFractionToMillis("2026-05-07T10:12:54+00:00") == nil)
    }

    @Test
    func unparseableCreatedAtYieldsNil() {
        let rec = makeRecord(created: "not-a-date", updated: "also-bad", status: "failed", steps: 1, completed: 0, rerun: 0)
        #expect(WorkshopOutcomeScoreboard.sample(from: rec) == nil)
    }

    @Test
    func missingUpdatedAtFallsBackToCreated() {
        let created = SwiftNativeWorkshopRunner.isoTimestamp(Date(timeIntervalSince1970: 1_780_000_000))
        let rec = makeRecord(created: created, updated: "", status: "failed", steps: 2, completed: 0, rerun: 0)
        let s = WorkshopOutcomeScoreboard.sample(from: rec)
        #expect(s != nil)
        #expect(s?.wallSeconds == 0)                     // updated unparseable → equals created
    }
}

@Suite("Workshop Desk receipt bridge")
struct WorkshopDeskReceiptBridgeSuite {
    @Test
    func nonTerminalRecordDoesNotWriteReceiptOrMutateDesk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-nonterminal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .project, project: "Workshop", title: "Live task")
        _ = try await store.setStatus(item.handle, status: .now)
        let record = WorkshopExecutionRecord(
            id: "exec-live",
            deskHandle: item.handle,
            title: "Live task",
            objective: "Still working",
            createdAt: "2026-07-11T12:00:00Z",
            status: "running",
            plan: [],
            stepsCompleted: [],
            receiptsDir: "",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: "2026-07-11T12:00:01Z",
            result: .null,
            rerunCount: 0
        )

        await WorkshopDeskReceiptBridge.recordTerminal(record, reason: nil, dataRoot: root)

        let state = try await store.liveState()
        let current = try #require(state.items.first { $0.handle == item.handle })
        #expect(current.status == .now)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("workshop/receipts.jsonl").path))
    }

    @Test
    func terminalReceiptClosesDeskItemAndDeduplicates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(
            kind: .project,
            project: "Workshop",
            title: "Directed task",
            summary: "Do the work"
        )
        _ = try await store.setStatus(item.handle, status: .now)
        let created = "2026-07-11T12:00:00Z"
        let completed = "2026-07-11T12:01:00Z"
        let record = WorkshopExecutionRecord(
            id: "exec_123",
            deskHandle: item.handle,
            title: "Directed task",
            objective: "Do the work",
            createdAt: created,
            status: "completed",
            plan: [WorkshopExecutionStep(id: "step-1", description: "work", toolOrAction: "chat.synthesize")],
            stepsCompleted: [.object(["step_id": .string("step-1"), "status": .string("succeeded")])],
            receiptsDir: "",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: completed,
            result: .string("Finished cleanly"),
            rerunCount: 0,
            verification: WorkshopVerificationRecord(
                status: .satisfied,
                checkedAt: completed,
                methods: ["exact_output"],
                detail: "Declared outcome matched exact local evidence."
            )
        )

        await WorkshopDeskReceiptBridge.recordTerminal(record, reason: nil, dataRoot: root)
        await WorkshopDeskReceiptBridge.recordTerminal(record, reason: nil, dataRoot: root)

        let state = try await store.liveState()
        let closed = try #require(state.items.first { $0.handle == item.handle })
        #expect(closed.status == .done)
        #expect(closed.summary == "Finished cleanly")
        #expect(closed.notes.filter { $0.text == "[completed] Finished cleanly" }.count == 1)

        let rows = try await SwiftNativePersistenceCore().readJSONL(
            root.appendingPathComponent("workshop/receipts.jsonl")
        ).compactMap(WorkshopDirectedTaskReceipt.fromJSON)
        #expect(rows.count == 1)
        #expect(rows[0].handle == item.handle)
        #expect(rows[0].executionId == "exec_123")
    }

    @Test
    func unverifiedCompletionKeepsDeskCommitmentOpenWithoutModelJudgment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-unverified-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(
            kind: .project,
            project: "Workshop",
            title: "External effect",
            summary: "Do something only the external domain can verify"
        )
        _ = try await store.setStatus(item.handle, status: .now)
        let completed = "2026-07-11T12:01:00Z"
        let record = WorkshopExecutionRecord(
            id: "exec_unverified",
            deskHandle: item.handle,
            title: "External effect",
            objective: "Perform an external effect",
            createdAt: "2026-07-11T12:00:00Z",
            status: "completed",
            plan: [WorkshopExecutionStep(
                id: "step-1",
                description: "external action",
                toolOrAction: "external.action"
            )],
            stepsCompleted: [.object([
                "step_id": .string("step-1"),
                "status": .string("succeeded"),
            ])],
            receiptsDir: "",
            triggerSource: "manual",
            trustRequired: "none",
            expectedOutputs: [],
            currentStepId: "",
            updatedAt: completed,
            result: .string("Tool returned success"),
            rerunCount: 0,
            verification: WorkshopVerificationRecord(
                status: .unverified,
                checkedAt: completed,
                detail: "External domain has no exact verifier."
            )
        )

        await WorkshopDeskReceiptBridge.recordTerminal(record, reason: nil, dataRoot: root)

        let state = try await store.liveState()
        let current = try #require(state.items.first { $0.handle == item.handle })
        #expect(current.status == .blocked)
        #expect(current.waitingOn == "domain verification")
        #expect(current.blockedReason?.contains("remains unverified") == true)
        #expect(current.closedAt == nil)
    }
}
