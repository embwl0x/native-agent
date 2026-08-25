import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// Coverage ledger: `workshop.outcomeScoreboard.weeklyOutcomeStats`
// (WorkshopExecution+OutcomeScoreboard.swift, `SwiftNativeWorkshopRunner.weeklyOutcomeStats`).
//
// SILENT-FAILURE CLASS: silent zero. This is the disk-reading assembler behind
// the weekly self-improvement prompt. Its receipt path is derived by
// `executionRecordsRoot.deletingLastPathComponent().deletingLastPathComponent()`
// — a two-level walk back up from `<root>/workshop/executions`. Any change to
// `executionRecordsRoot` silently repoints it, `readJSONL` swallows the miss,
// and the prompt gets an empty (or half-empty) scoreboard that reads as
// "no work this week". The PURE helpers around it are fully tested, which is
// exactly what makes the gap easy to miss: the aggregator is green while the
// assembler reads the wrong directory.
//
// The eval therefore drives the ASSEMBLER on a non-default root and asserts
// BOTH lanes land: receipt-backed (canonical) and record-fallback (migration).
// A dedicated negative control proves the receipt-lane assertion has teeth.

private func statsEvalRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopStatsEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// One fixed ISO week so bucketing is deterministic.
private let weekCreated = "2026-07-13T09:00:00Z"
private let receiptCompleted = "2026-07-13T09:02:00Z"   // 120s wall
private let recordUpdated = "2026-07-13T09:10:00Z"      // 600s wall

private func writeRecord(
    root: URL,
    id: String,
    status: String,
    planSteps: Int,
    rerunCount: Int,
    deskHandle: String?,
    triggerSource: String = "manual",
    plannerFallback: Bool = false
) async throws {
    let dir = root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var record = WorkshopExecutionRecord(
        id: id, title: id, objective: "o", createdAt: weekCreated, status: status,
        plan: (0..<planSteps).map {
            WorkshopExecutionStep(id: "step-\($0)", description: "d", toolOrAction: "chat.synthesize")
        },
        stepsCompleted: [], receiptsDir: dir.appendingPathComponent("receipts").path,
        triggerSource: triggerSource, trustRequired: "none", expectedOutputs: [],
        currentStepId: "", updatedAt: recordUpdated, result: .null, rerunCount: rerunCount
    )
    record.deskHandle = deskHandle
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(record.toJSON(), to: ExecutionRecordFile.canonicalPath(in: dir))
    if plannerFallback {
        try await persistence.appendJSONL(
            .object([
                "event": .string("planner_fallback"),
                "reason": .string("eval"),
                "ts": .string(weekCreated),
            ]),
            to: dir.appendingPathComponent("timeline.jsonl"))
    }
}

private func writeReceipt(
    to path: URL,
    executionId: String,
    handle: String,
    status: String,
    totalSteps: Int,
    completedSteps: Int,
    rerunCount: Int,
    triggerSource: String = "manual"
) async throws {
    let receipt = WorkshopDirectedTaskReceipt(
        handle: handle, executionId: executionId, status: status, summary: "s",
        createdAt: weekCreated, completedAt: receiptCompleted,
        totalSteps: totalSteps, completedSteps: completedSteps, rerunCount: rerunCount,
        triggerSource: triggerSource, wasStub: false
    )
    try await SwiftNativePersistenceCore().appendJSONL(receipt.toJSON(), to: path)
}

/// `<root>/workshop/receipts.jsonl` — the path the assembler must derive.
private func canonicalReceiptPath(root: URL) -> URL {
    root.appendingPathComponent("workshop", isDirectory: true)
        .appendingPathComponent("receipts.jsonl")
}

/// Seed the two-lane fixture: execution `a` is receipt-backed (record says
/// FAILED, receipt says COMPLETED — deliberately divergent so the lane that
/// won is observable), execution `b` is record-only with a planner_fallback.
private func seedTwoLaneWeek(root: URL, receiptPath: URL) async throws {
    try await writeRecord(root: root, id: "a", status: "failed", planSteps: 2,
                          rerunCount: 0, deskHandle: "desk_a")
    try await writeReceipt(to: receiptPath, executionId: "a", handle: "desk_a",
                           status: "completed", totalSteps: 4, completedSteps: 4, rerunCount: 7)
    try await writeRecord(root: root, id: "b", status: "completed", planSteps: 1,
                          rerunCount: 0, deskHandle: nil, plannerFallback: true)
}

private func makeStatsRunner(root: URL) -> SwiftNativeWorkshopRunner {
    SwiftNativeWorkshopRunner(
        executorAvailable: true, root: root, persistence: SwiftNativePersistenceCore())
}

@Suite("EVAL workshop.outcomeScoreboard.weeklyOutcomeStats")
struct WorkshopWeeklyOutcomeStatsEvalSuite {

    /// Both lanes land for a NON-DEFAULT root, and the receipt lane WINS where
    /// it exists. If the two-level path walk regresses, `a` falls back to its
    /// record (status failed, rerunCount 0) and every assertion below moves.
    @Test func bothLanesLandAndTheReceiptLaneWins() async throws {
        let root = try statsEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedTwoLaneWeek(root: root, receiptPath: canonicalReceiptPath(root: root))

        let weeks = await makeStatsRunner(root: root).weeklyOutcomeStats()
        #expect(weeks.count == 1, "both executions sit in one ISO week")
        let week = try #require(weeks.first)

        #expect(week.total == 2)
        #expect(week.terminal == 2)
        // `a` is COMPLETED only via its receipt; its record says failed.
        #expect(week.completed == 2, "the receipt lane must override the record status")
        #expect(week.failed == 0)
        #expect(week.completionRate == 1.0)
        // rerunCount 7 comes from the RECEIPT, 0 from the record → median 3.5.
        #expect(week.medianRerunCount == 3.5, "receipt fields must reach the aggregate")
        // totalSteps 4 (receipt) and 1 (record plan) → median 2.5.
        #expect(week.medianTotalSteps == 2.5)
        // wall 120s (receipt) and 600s (record) → median 360.
        #expect(week.medianWallSeconds == 360)
        // `b` has no receipt, so its stub flag is derived from ITS timeline.
        #expect(week.stubRate == 0.5, "record-fallback samples must derive wasStub from the timeline")
    }

    /// NEGATIVE CONTROL for the assertion above — the mutation, expressed as a
    /// fixture instead of an edit to production. Identical seed, receipts
    /// written ONE directory too high (`<root>/receipts.jsonl`, which is what a
    /// one-level walk would produce). The assembler must then see only records,
    /// and the numbers must MOVE. This is what proves the previous test is
    /// actually reading the receipt feed and not just agreeing by accident.
    @Test func receiptsAtTheWrongDepthAreNotPickedUp() async throws {
        let root = try statsEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedTwoLaneWeek(
            root: root, receiptPath: root.appendingPathComponent("receipts.jsonl"))

        let weeks = await makeStatsRunner(root: root).weeklyOutcomeStats()
        let week = try #require(weeks.first)
        #expect(week.total == 2)
        #expect(week.completed == 1, "record lane only")
        #expect(week.failed == 1)
        #expect(week.medianRerunCount == 0)
        #expect(week.completionRate == 0.5)
    }

    /// An empty root must produce an EMPTY aggregate, never a fabricated week —
    /// and a root with work must never produce an empty one. This is the
    /// silent-zero boundary the weekly prompt reads as "no work this week".
    @Test func emptyRootIsEmptyAndSeededRootIsNot() async throws {
        let empty = try statsEvalRoot()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(await makeStatsRunner(root: empty).weeklyOutcomeStats().isEmpty)

        let seeded = try statsEvalRoot()
        defer { try? FileManager.default.removeItem(at: seeded) }
        try await seedTwoLaneWeek(root: seeded, receiptPath: canonicalReceiptPath(root: seeded))
        #expect(await makeStatsRunner(root: seeded).weeklyOutcomeStats().isEmpty == false)
    }

    /// The cohort filter must scope BOTH lanes — a filter that only reached the
    /// record lane would quietly drop every directed task from a cohort view.
    @Test func triggerSourceFilterScopesBothLanes() async throws {
        let root = try statsEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receiptPath = canonicalReceiptPath(root: root)
        try await writeRecord(root: root, id: "sched", status: "failed", planSteps: 2,
                              rerunCount: 0, deskHandle: "desk_s", triggerSource: "manual")
        // Receipt-backed, and the RECEIPT is what carries the cohort.
        try await writeReceipt(to: receiptPath, executionId: "sched", handle: "desk_s",
                               status: "completed", totalSteps: 2, completedSteps: 2,
                               rerunCount: 0, triggerSource: "trigger:nightly")
        try await writeRecord(root: root, id: "manual", status: "completed", planSteps: 1,
                              rerunCount: 0, deskHandle: nil, triggerSource: "manual")

        let runner = makeStatsRunner(root: root)
        #expect(await runner.weeklyOutcomeStats().first?.total == 2)

        let scheduled = await runner.weeklyOutcomeStats(onlyTriggerSource: "trigger:nightly")
        #expect(scheduled.first?.total == 1)
        #expect(scheduled.first?.completed == 1)

        let manual = await runner.weeklyOutcomeStats(onlyTriggerSource: "manual")
        #expect(manual.first?.total == 1)

        #expect(await runner.weeklyOutcomeStats(onlyTriggerSource: "nope").isEmpty)
    }
}
