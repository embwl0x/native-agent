import Foundation
import ChatOrchestration
import PersistenceCore
import Testing
import WorkshopExecution
@testable import NativeAgentApp

// Wave 2 deliberately exercises the canonical Desk writes first, then the
// value-only presentation facts DeskView consumes.  It never proves a row by
// scanning source text: every assertion has a store transition or a persisted
// execution-shaped record behind it.

private func deskBehaviorRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskBehaviorWave2-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Desk mutations are lazy tools. The real chat turn injects its session id
/// and the loadout owns the authorization; this direct router eval supplies
/// that same authority explicitly instead of treating a missing session as a
/// successful Desk click.
private struct SessionAuthorizedDeskRouter: DeskToolInvoking {
    let router: DeskToolDispatchRouter
    let sessionID: String

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        var authorizedInput = input
        authorizedInput["session_id"] = .string(sessionID)
        return try await router.run(tool: tool, input: authorizedInput)
    }
}

private func deskBehaviorRouter(dataRoot: URL) async throws -> SessionAuthorizedDeskRouter {
    let sessionID = "desk-behavior-eval-\(UUID().uuidString)"
    let activeTools = ActiveToolsStore(dataRoot: dataRoot)
    _ = try await activeTools.addLoaded(
        sessionId: sessionID,
        names: ["desk_note", "desk_defer", "desk_close"]
    )
    return SessionAuthorizedDeskRouter(
        router: DeskToolDispatchRouter(dataRoot: dataRoot),
        sessionID: sessionID
    )
}

private func executionRecord(
    id: String,
    status: String,
    updatedAt: String,
    stepsCompleted: Int = 0,
    verification: WorkshopVerificationRecord? = nil
) throws -> WorkshopExecution.WorkshopExecutionRecord {
    var object: [String: JSONValue] = [
        "id": .string(id),
        "title": .string("Execution \(id)"),
        "objective": .string("Prove visible receipt truth"),
        "created_at": .string("2026-08-01T00:00:00Z"),
        "status": .string(status),
        "plan": .array([
            WorkshopExecutionStep(id: "one", description: "one", toolOrAction: "tool").toJSON(),
            WorkshopExecutionStep(id: "two", description: "two", toolOrAction: "tool").toJSON(),
        ]),
        "steps_completed": .array((0..<stepsCompleted).map { _ in .object([:]) }),
        "receipts_dir": .string("/tmp/receipts"),
        "trigger_source": .string("eval"),
        "trust_required": .string("read"),
        "expected_outputs": .array([]),
        "current_step_id": .string("one"),
        "updated_at": .string(updatedAt),
        "result": .null,
        "rerun_count": .int(0),
    ]
    if let verification { object["verification"] = verification.toJSON() }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(
        WorkshopExecution.WorkshopExecutionRecord.self,
        from: Data(try JSONValue.object(object).serialize(pretty: false).utf8))
}

@Suite("Desk behavior wave 2", .serialized)
struct DeskBehaviorWave2EvalTests {
    @Test("real Desk actions preserve the receipt outcome and durable state")
    func realDeskActionsSettleAgainstTheCanonicalStore() async throws {
        let root = try deskBehaviorRoot("actions")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .plan, project: "Release", title: "Ship proof")
        let router = try await deskBehaviorRouter(dataRoot: root)

        let note = await DeskActionRunner.perform(
            .note(handle: item.handle, text: "receipt came from a Desk click"), via: router)
        #expect(note.ok)
        let parked = await DeskActionRunner.perform(
            .defer_(handle: item.handle, until: "2030-01-01"), via: router)
        #expect(parked.ok)
        let closed = await DeskActionRunner.perform(
            .close(handle: item.handle, outcome: DeskQuickAction.deskCloseOutcome), via: router)
        #expect(closed.ok)

        let persisted = try #require((try await store.liveState()).items.first { $0.handle == item.handle })
        #expect(persisted.notes.last?.text == "receipt came from a Desk click")
        #expect(persisted.deferUntil == "2030-01-01")
        #expect(persisted.status == .done)
        #expect(DeskActionPresentation.notice(isError: !closed.ok).symbol == "checkmark.circle")
    }

    @Test("a refused Desk action stays a failure receipt and cannot mutate the stored row")
    func refusedDeskActionDoesNotMasqueradeAsSuccess() async throws {
        let root = try deskBehaviorRoot("refusal")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .plan, project: "Release", title: "Keep honest")

        let router = try await deskBehaviorRouter(dataRoot: root)
        let refused = await DeskActionRunner.perform(
            .defer_(handle: item.handle, until: "later maybe"),
            via: router)
        #expect(!refused.ok)
        #expect(DeskActionPresentation.notice(isError: !refused.ok).symbol == "exclamationmark.triangle")
        #expect((try await store.liveState()).items.first { $0.handle == item.handle }?.deferUntil == nil)
    }

    @Test("sequencing follows actual blocker, completion, and park writes")
    func sequencingFollowsCanonicalDeskWrites() async throws {
        let root = try deskBehaviorRoot("sequencing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let prerequisite = try await store.createItem(kind: .plan, project: "Release", title: "Build")
        let dependent = try await store.createItem(kind: .plan, project: "Release", title: "Install")
        try await store.setBlockedOn(dependent.handle, blockers: [prerequisite.handle])
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var plan = DeskSequencing.compute(try await store.liveState(), now: now)
        #expect(plan.byHandle[dependent.handle]?.effectiveBlockers == [prerequisite.handle])
        #expect(plan.byHandle[dependent.handle]?.isReady == false)

        try await store.setStatus(prerequisite.handle, status: .done)
        plan = DeskSequencing.compute(try await store.liveState(), now: now)
        #expect(plan.byHandle[dependent.handle]?.effectiveBlockers.isEmpty == true)
        #expect(plan.byHandle[dependent.handle]?.isReady == true)

        try await store.setDeferUntil(dependent.handle, until: "2030-01-01")
        plan = DeskSequencing.compute(try await store.liveState(), now: now)
        #expect(plan.byHandle[dependent.handle]?.isDeferred == true)
        #expect(plan.byHandle[dependent.handle]?.isReady == false)
    }

    @Test("execution presentation partitions every persisted status and makes unknown explicit")
    func executionPresentationIsTotalAndHumanReadable() throws {
        let satisfied = WorkshopVerificationRecord(
            status: .satisfied,
            checkedAt: "2026-08-01T00:00:00Z",
            methods: ["exact_output", "file_bytes"])
        let records = [
            try executionRecord(id: "queued", status: "queued", updatedAt: "2026-08-01T01:00:00Z"),
            try executionRecord(id: "running", status: "running", updatedAt: "2026-08-01T02:00:00Z", stepsCompleted: 9),
            try executionRecord(id: "approval", status: "blocked_on_approval", updatedAt: "2026-08-01T03:00:00Z"),
            try executionRecord(id: "completed", status: "completed", updatedAt: "2026-08-01T04:00:00Z", verification: satisfied),
            try executionRecord(id: "future", status: "awaiting_remote_witness", updatedAt: "2026-08-01T05:00:00Z"),
        ]

        let slice = DeskExecutionPresentation.slice(records)
        let displayed = Set(slice.benchIDs + slice.approvalIDs + slice.recentDoneIDs)
        #expect(displayed == Set(records.map(\.id)))
        #expect(slice.benchIDs.contains("future"))
        #expect(DeskExecutionPresentation.pill(for: "awaiting_remote_witness").label == "unknown: awaiting remote witness")
        #expect(DeskExecutionPresentation.progress(status: "running", planCount: 2, completedCount: 9) == "step 2 of 2")
        #expect(DeskExecutionPresentation.progress(status: "completed", planCount: 2, completedCount: 1) == nil)
        #expect(DeskExecutionPresentation.verificationLabel(satisfied) == "verified: exact output + file bytes")
        #expect(DeskExecutionPresentation.verificationLabel(WorkshopVerificationRecord(
            status: .unverified, checkedAt: "2026-08-01T00:00:00Z"
        )).contains("not independently verified"))
    }

    @Test("Desk item labels and nag icon follow persisted states, not raw wire values")
    func deskItemPresentationUsesCanonicalState() async throws {
        let root = try deskBehaviorRoot("nags")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeskNagConfigStore(dataRoot: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DeskItemPresentation.statusLabel(.todo) == "to do")
        #expect(DeskItemPresentation.statusLabel(.flag) == "needs attention")
        #expect(DeskItemPresentation.statusLabel(.canceled) == "cancelled")
        #expect(DeskItemPresentation.nagBellSymbol(config: await store.load(), now: now) == "bell")

        let enabled = try await store.update { $0.settingGlobal(true) }
        #expect(DeskItemPresentation.nagBellSymbol(config: enabled, now: now) == "bell.fill")
        let muted = try await store.update { $0.muted(until: nil) }
        #expect(DeskItemPresentation.nagBellSymbol(config: muted, now: now) == "bell.slash")
    }

    @Test("blocker navigation, finished capping, and palette actions all use live Desk membership")
    func deskNavigationPresentationUsesLiveState() async throws {
        let root = try deskBehaviorRoot("navigation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let blocker = try await store.createItem(kind: .plan, project: "Release", title: "Build")
        let dependent = try await store.createItem(kind: .plan, project: "Release", title: "Install")
        try await store.setBlockedOn(dependent.handle, blockers: [blocker.handle])
        var state = try await store.liveState()
        let plan = DeskSequencing.compute(state, now: Date(timeIntervalSince1970: 1_800_000_000))
        let aliases = Dictionary(uniqueKeysWithValues: state.items.map { ($0.handle, $0.alias) })
        let dependentPlan = try #require(plan.byHandle[dependent.handle])
        let pill = try #require(DeskItemPresentation.blockedPill(
            plan: dependentPlan, aliases: aliases))
        #expect(pill.targetHandle == blocker.handle)
        #expect(pill.text.contains(blocker.alias))

        for number in 0..<9 {
            let item = try await store.createItem(kind: .plan, project: "Release", title: "Finished \(number)")
            try await store.setStatus(item.handle, status: .done)
        }
        state = try await store.liveState()
        let finished = state.items.filter(\.status.isTerminal)
        #expect(DeskItemPresentation.visiblePrefix(finished, showingAll: false).count == 8)
        #expect(DeskItemPresentation.visiblePrefix(finished, showingAll: true).count == finished.count)
        #expect(DeskItemPresentation.paletteTargetIsActionable(
            dependent.handle,
            activeHandles: Set(state.items.filter { !$0.status.isTerminal }.map(\.handle))))
        #expect(!DeskItemPresentation.paletteTargetIsActionable(
            finished[0].handle,
            activeHandles: Set(state.items.filter { !$0.status.isTerminal }.map(\.handle))))
    }

    // app.desk / desk.board.sequencingPills
    @Test("sequencing pills project the live graph in stable order with bounded actionable blockers")
    func sequencingPillsUseOneLivePlanAndKeepDegradedDatesHonest() async throws {
        let root = try deskBehaviorRoot("sequencing-pills")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let parent = try await store.createItem(kind: .plan, project: "Release", title: "Release train")
        let completedChild = try await store.createItem(
            kind: .plan, project: "Release", title: "Closed prerequisite", parent: parent.handle
        )
        try await store.setStatus(completedChild.handle, status: .done)

        var blockers: [DeskItem] = []
        for number in 0..<4 {
            blockers.append(try await store.createItem(
                kind: .plan, project: "Release", title: "Blocker \(number)"
            ))
        }
        let dependent = try await store.createItem(kind: .plan, project: "Release", title: "Dependent")
        try await store.setBlockedOn(dependent.handle, blockers: blockers.map(\.handle))

        let parked = try await store.createItem(kind: .plan, project: "Release", title: "Parked")
        try await store.setDeferUntil(parked.handle, until: "2030-01-01")

        let cycleA = try await store.createItem(kind: .plan, project: "Release", title: "Cycle A")
        let cycleB = try await store.createItem(kind: .plan, project: "Release", title: "Cycle B")
        try await store.setBlockedOn(cycleA.handle, blockers: [cycleB.handle])
        await #expect(throws: (any Error).self) {
            try await store.setBlockedOn(cycleB.handle, blockers: [cycleA.handle])
        }

        let state = try await store.liveState()
        let plan = DeskSequencing.compute(state, now: now)
        let aliases = Dictionary(uniqueKeysWithValues: state.items.map { ($0.handle, $0.alias) })
        func pills(for handle: String) throws -> [DeskSequencingPillPresentation.Pill] {
            let item = try #require(state.items.first { $0.handle == handle })
            let itemPlan = try #require(plan.byHandle[handle])
            return DeskSequencingPillPresentation.pills(
                item: item,
                itemPlan: itemPlan,
                isNextUp: plan.nextUp.contains(handle),
                aliases: aliases
            )
        }

        let parentPills = try pills(for: parent.handle)
        let parentRollup = try #require(parentPills.first)
        #expect(parentRollup == .init(kind: .rollup, text: "1/1 closed", targetHandle: nil))

        let blockedPills = try pills(for: dependent.handle)
        let blocked = try #require(blockedPills.first { $0.kind == .blocked })
        #expect(blocked.targetHandle == blockers[0].handle)
        #expect(blocked.text == "waiting on \(blockers[0].alias), \(blockers[1].alias), \(blockers[2].alias) +1")

        let parkedPills = try pills(for: parked.handle)
        #expect(parkedPills.contains(.init(kind: .deferred, text: "until 2030-01-01", targetHandle: nil)))

        let cycleItem = try #require(state.items.first { $0.handle == cycleA.handle })
        let cyclePills = DeskSequencingPillPresentation.pills(
            item: cycleItem,
            itemPlan: .init(
                handle: cycleA.handle,
                effectiveBlockers: [cycleB.handle],
                blockedByCycle: true
            ),
            isNextUp: false,
            aliases: aliases
        )
        #expect(cyclePills.contains(.init(kind: .cycle, text: "⚠ these block each other", targetHandle: nil)))

        let nextHandle = try #require(plan.nextUp.first)
        let nextPills = try pills(for: nextHandle)
        #expect(nextPills.contains(.init(kind: .nextUp, text: "start here", targetHandle: nil)))

        var missingDeferredDate = try #require(state.items.first { $0.handle == parked.handle })
        missingDeferredDate.deferUntil = nil
        let malformedDeferred = DeskSequencingPillPresentation.pills(
            item: missingDeferredDate,
            itemPlan: try #require(plan.byHandle[parked.handle]),
            isNextUp: false,
            aliases: aliases
        )
        #expect(malformedDeferred.contains(
            .init(kind: .deferred, text: "deferred; date unavailable", targetHandle: nil)
        ))
    }

    @Test("GitHub summary attention and load failure text do not hide their underlying facts")
    func summaryAndErrorPresentationRemainBoundedAndExplicit() async throws {
        let root = try deskBehaviorRoot("summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let blocked = try await store.createItem(kind: .gh, project: "NativeAgent", title: "Blocked")
        let waiting = try await store.createItem(kind: .gh, project: "NativeAgent", title: "Waiting")
        let quiet = try await store.createItem(kind: .gh, project: "NativeAgent", title: "Quiet")
        try await store.setStatus(blocked.handle, status: .blocked)
        try await store.setStatus(waiting.handle, status: .watch, waitingOn: "maintainer")
        let items = (try await store.liveState()).items.filter {
            [blocked.handle, waiting.handle, quiet.handle].contains($0.handle)
        }
        #expect(DeskItemPresentation.githubProjectNeedsEyes(items) == 2)
        let detail = String(repeating: "unavailable ", count: 80)
        #expect(DeskItemPresentation.boundedLoadFailure(detail).count == 240)
    }
}
