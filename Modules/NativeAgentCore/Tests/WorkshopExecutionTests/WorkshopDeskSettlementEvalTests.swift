import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// Coverage ledger, two rows:
//
//   workshop.executor.terminalDeskSettlement  (store-write, state-lifecycle leak / stale UI)
//   workshop.deskTask.submitter               (public-api, state-lifecycle leak)
//
// Both are twin-write surfaces with NO reconciler that notices a missing twin:
//   * `reconcileTerminalDeskSettlements` exists so a crash between the terminal
//     CAS and the event sink cannot leave a zombie Desk card. If it stops
//     running — or its dedupe key over-matches — a finished execution's Desk
//     card never settles and the Desk shows work in flight that ended days ago.
//     Nothing counts unsettled terminals.
//   * `WorkshopDirectedTaskSubmitter.submit` is the one call that creates a
//     DeskItem and an execution together. If the two writes diverge the Desk
//     shows a task with no run, or a run with no card.

private func deskEvalRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopDeskEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private struct DeskEvalPlanner: WorkshopPlannerLLM {
    let directProviderCallCountPerInvocation: Int? = 1
    func availableConnectorActions() async -> [JSONValue] { [] }
    func runCodex(
        prompt: String, surface: String, timeoutSeconds: Int
    ) async throws -> (model: String, output: String) {
        throw WorkshopExecutionError.plannerFailure("desk-eval: no provider")
    }
}

/// Write one TERMINAL execution record straight to disk — the crash-shaped
/// state this reconcile pass exists for: canonical record settled, derived
/// Desk/receipt settlement never ran.
private func seedTerminalExecution(
    root: URL,
    id: String,
    deskHandle: String?,
    status: String = "completed",
    result: JSONValue = .string("the produced answer")
) async throws {
    let dir = root.appendingPathComponent("workshop/executions/\(id)", isDirectory: true)
    let receipts = dir.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let stamp = SwiftNativeWorkshopRunner.isoTimestamp(Date())
    var record = WorkshopExecutionRecord(
        id: id, title: "terminal-\(id)", objective: "settle me", createdAt: stamp,
        status: status, plan: [], stepsCompleted: [], receiptsDir: receipts.path,
        triggerSource: "manual", trustRequired: "none", expectedOutputs: [],
        currentStepId: "", updatedAt: stamp, result: result, rerunCount: 0
    )
    record.deskHandle = deskHandle
    try await SwiftNativePersistenceCore().writeJSON(
        record.toJSON(), to: ExecutionRecordFile.canonicalPath(in: dir))
}

private func receipts(root: URL) async -> [WorkshopDirectedTaskReceipt] {
    let path = root
        .appendingPathComponent("workshop", isDirectory: true)
        .appendingPathComponent("receipts.jsonl")
    let rows = (try? await SwiftNativePersistenceCore().readJSONL(path)) ?? []
    return rows.compactMap(WorkshopDirectedTaskReceipt.fromJSON)
}

// MARK: - workshop.executor.terminalDeskSettlement

@Suite("EVAL workshop.executor.terminalDeskSettlement")
struct WorkshopTerminalDeskSettlementEvalSuite {

    /// One drain pass settles a terminal execution that carries a Desk handle:
    /// exactly one receipt, and the Desk card leaves the in-flight state. A
    /// SECOND pass must add nothing — the pass runs on every tick, so a dedupe
    /// key that stops matching turns it into an unbounded receipt writer.
    @Test func drainSettlesTerminalOnceAndIsIdempotent() async throws {
        let root = try deskEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(
            kind: .project, project: "Workshop", title: "settle me", summary: "objective")
        _ = try await store.setStatus(item.handle, status: .now)
        try await seedTerminalExecution(root: root, id: "term-1", deskHandle: item.handle)

        let executor = WorkshopExecutorLoop(root: root)
        await executor.drainOnce()

        let afterFirst = await receipts(root: root)
        #expect(afterFirst.count == 1)
        let receipt = try #require(afterFirst.first)
        #expect(receipt.executionId == "term-1")
        #expect(receipt.handle == item.handle)
        #expect(receipt.status == "completed")
        #expect(receipt.summary.isEmpty == false, "an empty summary is an unreadable card")

        await executor.drainOnce()
        let afterSecond = await receipts(root: root)
        #expect(afterSecond.count == 1, "settlement must be idempotent across drain passes")
        #expect(afterSecond == afterFirst)

        // The Desk card must no longer read as work in flight.
        let state = try await store.liveState()
        let settled = try #require(state.items.first { $0.handle == item.handle })
        #expect(settled.status != .now, "a finished execution must not leave a `now` Desk card")
        #expect(settled.notes.contains { $0.text.contains("completed") })
    }

    /// A terminal execution with NO Desk handle has no card to settle: the
    /// receipt feed is handle-keyed, so writing a handle-less row would poison
    /// every downstream aggregate.
    @Test func terminalWithoutDeskHandleAppendsNothing() async throws {
        let root = try deskEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedTerminalExecution(root: root, id: "term-nohandle", deskHandle: nil)
        try await seedTerminalExecution(root: root, id: "term-blank", deskHandle: "   ")

        await WorkshopExecutorLoop(root: root).drainOnce()
        #expect(await receipts(root: root).isEmpty)
    }

    /// Non-terminal records are NOT settled — settling a running execution
    /// would close its Desk card while the work is still going.
    @Test func nonTerminalRecordIsNotSettled() async throws {
        let root = try deskEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(
            kind: .project, project: "Workshop", title: "in flight", summary: "objective")
        _ = try await store.setStatus(item.handle, status: .now)
        try await seedTerminalExecution(
            root: root, id: "term-running", deskHandle: item.handle, status: "blocked_on_approval")

        await WorkshopExecutorLoop(root: root).drainOnce()
        #expect(await receipts(root: root).isEmpty)
        let state = try await store.liveState()
        #expect(state.items.first { $0.handle == item.handle }?.status == .now)
    }

    /// A cancelled and a failed terminal both settle, and each carries its own
    /// status forward — a settlement that collapsed every terminal to
    /// "completed" would read as success on the Desk.
    @Test func cancelledAndFailedTerminalsCarryTheirOwnStatus() async throws {
        let root = try deskEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let cancelled = try await store.createItem(
            kind: .project, project: "Workshop", title: "cancelled", summary: "o")
        let failed = try await store.createItem(
            kind: .project, project: "Workshop", title: "failed", summary: "o")
        try await seedTerminalExecution(
            root: root, id: "term-cancel", deskHandle: cancelled.handle,
            status: "cancelled", result: .null)
        try await seedTerminalExecution(
            root: root, id: "term-fail", deskHandle: failed.handle,
            status: "failed", result: .null)

        await WorkshopExecutorLoop(root: root).drainOnce()
        let rows = await receipts(root: root)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.status)) == ["cancelled", "failed"])

        let state = try await store.liveState()
        #expect(state.items.first { $0.handle == cancelled.handle }?.status == .canceled)
        #expect(state.items.first { $0.handle == failed.handle }?.status == .blocked)
    }
}

// MARK: - workshop.deskTask.submitter

@Suite("EVAL workshop.deskTask.submitter")
struct WorkshopDirectedTaskSubmitterEvalSuite {

    /// The happy path must land BOTH twins and cross-link them: one Desk item,
    /// one execution record, the item's trace ref pointing at the execution id,
    /// and the execution's `deskHandle` pointing back at the item.
    @Test func submitLandsBothTwinsCrossLinked() async throws {
        let root = try deskEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true, root: root,
            persistence: SwiftNativePersistenceCore(), planner: DeskEvalPlanner())
        let submitter = WorkshopDirectedTaskSubmitter(dataRoot: root, runner: runner)

        let result = try await submitter.submit(
            spec: WorkshopExecutionSpec(title: "directed", objective: "do the thing"))

        // Twin 1: exactly one Desk item.
        let store = SwiftNativeDeskStore(dataRoot: root)
        let state = try await store.liveState()
        let items = state.items.filter { $0.project == "Workshop" }
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.handle == result.deskItem.handle)
        #expect(item.status == .now)

        // Twin 2: exactly one execution record, cross-linked both ways.
        let all = await runner.listAll()
        #expect(all.count == 1)
        let record = try #require(all.first)
        #expect(record.id == result.executionId)
        #expect(record.deskHandle == item.handle)
        #expect(record.status == "queued")
        #expect(FileManager.default.fileExists(
            atPath: runner.executionRecordPath(result.executionId).path))

        // The Desk side carries the execution id as a trace ref.
        let traceIds = item.refs.compactMap { ref -> String? in
            if case .trace(let id, let kind) = ref.kind, kind == "workshop_execution" { return id }
            return nil
        }
        #expect(traceIds == [result.executionId])
    }

    /// A REFUSED submit must not leave a silently-in-flight card. The shipped
    /// behaviour keeps the DeskItem and marks it BLOCKED with the refusal
    /// reason (rather than deleting it), and writes NO execution record. Both
    /// halves are asserted: an orphan card in `now` with no run behind it is
    /// the divergence this row is about.
    ///
    /// NOTE: the ledger's proposed eval says "leaves NO orphan DeskItem
    /// behind". The code does leave one — deliberately, blocked and annotated.
    /// This eval pins the ACTUAL contract (visible refusal, no phantom run);
    /// see the returned notes for the divergence.
    @Test func refusedSubmitLeavesABlockedCardAndNoExecution() async throws {
        let root = try deskEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true, root: root,
            persistence: SwiftNativePersistenceCore(), planner: DeskEvalPlanner())
        let submitter = WorkshopDirectedTaskSubmitter(dataRoot: root, runner: runner)

        // Whitespace-only objective → the runner's `missing_objective` refusal,
        // raised AFTER the Desk item is created: the exact divergence window.
        await #expect(throws: WorkshopExecutionError.self) {
            _ = try await submitter.submit(
                spec: WorkshopExecutionSpec(title: "doomed", objective: "   \n "))
        }

        let state = try await SwiftNativeDeskStore(dataRoot: root).liveState()
        let items = state.items.filter { $0.project == "Workshop" }
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.status == .blocked, "a refused submit must not leave a `now` card")
        #expect((item.blockedReason ?? "").isEmpty == false, "the refusal must be readable")
        #expect(item.notes.contains { $0.text.contains("refused") })

        // And NO execution twin exists.
        #expect(await runner.listAll().isEmpty)
    }
}
