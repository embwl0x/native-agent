import Foundation
import ChatOrchestration
import PersistenceCore
import Testing
import WorkshopExecution
@testable import NativeAgentApp

// Wave 1 converts high-risk `app.desk` REPORTS-ONLY rows into executable
// behavior seams. These tests do not scrape SwiftUI source: each starts at a
// model/action used by DeskView and observes a store transition or the exact
// value the view renders. Negative controls are deliberately included in every
// family so a quiet failure cannot be relabelled as a green result.
//
// Covered rows:
// desk.action.inFlightGuard, desk.action.optimisticRollback,
// desk.action.noticeRow, desk.nag.bellSymbol, desk.board.freshnessChip,
// desk.board.statusPillVocabulary, desk.board.blockerPillNavigation,
// desk.board.finishedCap, desk.board.sequencingPills, desk.execution.benchSlice,
// desk.execution.pillLabel, desk.execution.stepProgress,
// desk.execution.verificationLabel, desk.pursuits.card,
// desk.view.loadErrorBanner.

private func wave1DeskRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskReportsOnlyWave1-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func wave1DeskItem(
    handle: String = "desk_1",
    status: DeskStatus = .now,
    updatedAt: String = "2026-08-01T00:00:00Z",
    pursuit: Pursuit? = nil,
    blockedReason: String? = nil,
    waitingOn: String? = nil
) -> DeskItem {
    DeskItem(
        handle: handle,
        alias: handle.replacingOccurrences(of: "desk_", with: ""),
        kind: .plan,
        status: status,
        project: "Release",
        title: "Prove the Desk",
        openedAt: "2026-08-01T00:00:00Z",
        updatedAt: updatedAt,
        blockedReason: blockedReason,
        waitingOn: waitingOn,
        origin: pursuit == nil ? .owner : .agent,
        pursuit: pursuit)
}

private func wave1Execution(
    _ id: String,
    status: String,
    updatedAt: String = "2026-08-01T00:00:00Z",
    completed: Int = 0,
    verification: WorkshopVerificationRecord? = nil
) throws -> WorkshopExecution.WorkshopExecutionRecord {
    var object: [String: JSONValue] = [
        "id": .string(id),
        "title": .string("Execution \(id)"),
        "objective": .string("Prove Desk presentation"),
        "created_at": .string("2026-08-01T00:00:00Z"),
        "status": .string(status),
        "plan": .array([WorkshopExecutionStep(id: "one", description: "one", toolOrAction: "tool").toJSON()]),
        "steps_completed": .array(Array(repeating: JSONValue.object([:]), count: completed)),
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

private struct Wave1TransportFailure: Error {}

/// Desk mutations are lazy-loaded. The production click carries the current
/// chat session and the session loadout owns permission to invoke the tool;
/// this eval supplies that same authority so a missing session cannot turn an
/// authorization refusal into a passing presentation check.
private struct Wave1SessionAuthorizedDeskRouter: DeskToolInvoking {
    let router: DeskToolDispatchRouter
    let sessionID: String

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        var authorizedInput = input
        authorizedInput["session_id"] = .string(sessionID)
        return try await router.run(tool: tool, input: authorizedInput)
    }
}

private func wave1AuthorizedDeskRouter(dataRoot: URL) async throws -> Wave1SessionAuthorizedDeskRouter {
    let sessionID = "desk-reports-wave1-\(UUID().uuidString)"
    _ = try await ActiveToolsStore(dataRoot: dataRoot).addLoaded(
        sessionId: sessionID,
        names: ["desk_nag_control"]
    )
    return Wave1SessionAuthorizedDeskRouter(
        router: DeskToolDispatchRouter(dataRoot: dataRoot),
        sessionID: sessionID
    )
}

private actor Wave1DeskInvoker: DeskToolInvoking {
    enum Reply { case success, refused, transportFailure }
    let reply: Reply
    init(_ reply: Reply) { self.reply = reply }
    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        switch reply {
        case .success: return .object(["status": .string("ok"), "confirmation": .string("landed")])
        case .refused: return .object(["status": .string("refused"), "reason": .string("not allowed")])
        case .transportFailure: throw Wave1TransportFailure()
        }
    }
}

@Suite("Desk reports-only wave 1 behavior", .serialized)
struct DeskReportsOnlyWave1EvalTests {
    @Test("the shared mutation latch drops a second fire and re-arms on every terminal outcome")
    @MainActor func actionFlightDoesNotStickOrDoubleFire() async {
        let flight = DeskActionFlight()
        let first = flight.begin()
        #expect(first)
        let duplicate = flight.begin()
        #expect(!duplicate, "negative control: a second key press must not start another mutation")
        #expect(flight.isInFlight)
        flight.finish()
        #expect(!flight.isInFlight)
        let rearmed = flight.begin()
        #expect(rearmed, "a refusal/error/success that settled must not leave Desk inert")
        flight.finish()

        for reply in [Wave1DeskInvoker.Reply.success, .refused, .transportFailure] {
            let outcome = await flight.perform(.nagGlobal(on: true), via: Wave1DeskInvoker(reply))
            #expect(outcome != nil)
            #expect(!flight.isInFlight, "every actual action terminal path must re-arm the UI")
        }
    }

    @Test("local action echoes are narrow, and a refusal cannot change canonical Desk state")
    func optimisticPatchAndRefusalStayHonest() async throws {
        let item = wave1DeskItem()
        let stamp = "2026-08-24T12:00:00Z"
        let closed = DeskOptimisticItemPatch.applying(
            .close(handle: item.handle, outcome: "Closed from the desk."), to: [item], timestamp: stamp)
        #expect(closed[0].status == .done)
        #expect(closed[0].closedAt == stamp)
        #expect(closed[0].updatedAt == stamp)

        let refusal = DeskActionOutcome(ok: false, message: "refused")
        #expect(DeskOptimisticItemPatch.reconciled(
            preAction: [item], optimistic: closed, reloaded: closed,
            loadFailed: false, outcome: refusal) == [item],
            "a refused action whose reload still shows the local echo must roll back")
        let success = DeskActionOutcome(ok: true, message: "closed")
        #expect(DeskOptimisticItemPatch.reconciled(
            preAction: [item], optimistic: closed, reloaded: closed,
            loadFailed: true, outcome: success) == closed,
            "negative control: a successful write must not be rolled back solely because refresh failed")

        let untouched = DeskOptimisticItemPatch.applying(.nagGlobal(on: true), to: [item], timestamp: stamp)
        #expect(untouched == [item], "negative control: nag config must not optimistically mutate a Desk row")

        let root = try wave1DeskRoot("refusal")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let persisted = try await store.createItem(kind: .plan, project: "Release", title: "Keep open")
        let refused = await DeskActionRunner.perform(
            .defer_(handle: persisted.handle, until: "someday"),
            via: DeskToolDispatchRouter(dataRoot: root))
        #expect(!refused.ok)
        #expect((try await store.liveState()).items.first { $0.handle == persisted.handle }?.deferUntil == nil)
        #expect(DeskActionPresentation.notice(isError: !refused.ok).tone == .warning)
    }

    @Test("Desk action success and failure notices use opposite, explicit chrome")
    func actionNoticeNeverPaintsARefusalAsSuccess() {
        #expect(DeskActionPresentation.notice(isError: false) == .init(symbol: "checkmark.circle", tone: .success))
        #expect(DeskActionPresentation.notice(isError: true) == .init(symbol: "exclamationmark.triangle", tone: .warning))
        #expect(DeskActionPresentation.notice(isError: true).symbol != DeskActionPresentation.notice(isError: false).symbol)
    }

    @Test("nag icon follows the canonical config written through the real Desk router")
    func nagBellTracksRealStoreState() async throws {
        let root = try wave1DeskRoot("nags")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeskNagConfigStore(dataRoot: root)
        let router = try await wave1AuthorizedDeskRouter(dataRoot: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DeskItemPresentation.nagBellSymbol(config: await store.load(), now: now) == "bell")
        #expect((await DeskActionRunner.perform(.nagGlobal(on: true), via: router)).ok)
        #expect(DeskItemPresentation.nagBellSymbol(config: await store.load(), now: now) == "bell.fill")
        #expect((await DeskActionRunner.perform(.nagMute(until: nil), via: router)).ok)
        #expect(DeskItemPresentation.nagBellSymbol(config: await store.load(), now: now) == "bell.slash")
        let expired = DeskNagConfig(enabled: true, mutedUntil: "2026-01-01")
        #expect(DeskItemPresentation.nagBellSymbol(config: expired, now: now) == "bell.fill",
                "an expired mute must not leave a slashed, silently-disabled bell")
    }

    @Test("freshness never turns malformed or blocked state into a false stale/fresh claim")
    func freshnessUsesAnExplicitUnknownAndStatusAwareStaleRule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let malformed = DeskItemPresentation.freshness(for: wave1DeskItem(updatedAt: "not-a-time"), now: now)
        #expect(malformed == .init(text: "unknown", isStale: false, isKnown: false))

        let old = "2026-12-30T00:00:00Z"
        let stale = DeskItemPresentation.freshness(for: wave1DeskItem(updatedAt: old), now: now)
        #expect(stale.isStale)
        #expect(stale.text.hasSuffix("stale"))
        let blocked = DeskItemPresentation.freshness(for: wave1DeskItem(status: .blocked, updatedAt: old), now: now)
        #expect(!blocked.isStale, "negative control: status-critical blocked work keeps its timestamp, not stale chrome")
        #expect(blocked.text.hasSuffix("ago"))
        let exactSevenDays = now.addingTimeInterval(-7 * 86_400)
        let formatter = ISO8601DateFormatter()
        let atThreshold = DeskItemPresentation.freshness(
            for: wave1DeskItem(updatedAt: formatter.string(from: exactSevenDays)), now: now)
        #expect(atThreshold.isStale, "exactly seven elapsed days is the stated stale boundary")
        let flagged = DeskItemPresentation.freshness(
            for: wave1DeskItem(status: .flag, updatedAt: formatter.string(from: exactSevenDays)), now: now)
        #expect(!flagged.isStale)
    }

    @Test("all persisted Desk status cases have product labels")
    func statusPillsNeverLeakOrOmitVocabulary() {
        let labels = DeskStatus.allCases.map(DeskItemPresentation.statusLabel)
        #expect(labels.count == DeskStatus.allCases.count)
        #expect(!labels.contains(where: { $0.isEmpty || $0.contains("_") }))
        #expect(labels == DeskStatus.allCases.map(\.displayLabel))
        #expect(DeskItemPresentation.statusLabel(.flag) == "needs attention")
        #expect(DeskItemPresentation.statusLabel(.todo) == "to do")
    }

    @Test("a blocker pill is navigable only when the canonical plan resolves a live alias")
    func blockerPillCannotOfferAnUnreachableClick() async throws {
        let root = try wave1DeskRoot("blocker")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let blocker = try await store.createItem(kind: .plan, project: "Release", title: "Build")
        let dependent = try await store.createItem(kind: .plan, project: "Release", title: "Install")
        try await store.setBlockedOn(dependent.handle, blockers: [blocker.handle])
        let state = try await store.liveState()
        let plan = DeskSequencing.compute(state, now: Date(timeIntervalSince1970: 1_800_000_000))
        let aliases = Dictionary(uniqueKeysWithValues: state.items.map { ($0.handle, $0.alias) })
        let itemPlan = try #require(plan.byHandle[dependent.handle])
        let live = try #require(DeskItemPresentation.blockedPill(plan: itemPlan, aliases: aliases))
        #expect(live.targetHandle == blocker.handle)
        #expect(DeskItemPresentation.blockedPill(plan: itemPlan, aliases: [:]) == nil,
                "negative control: a dangling blocker must not draw a clickable pill")
    }

    @Test("finished groups are capped only until an explicit reveal")
    func finishedCapKeepsEveryGroupReachable() {
        let groups = Array(0..<11)
        let collapsed = DeskItemPresentation.visiblePrefix(groups, showingAll: false)
        let revealed = DeskItemPresentation.visiblePrefix(groups, showingAll: true)
        #expect(collapsed.count == 8)
        #expect(revealed == groups)
        #expect(Set(collapsed).isSubset(of: Set(revealed)))
        #expect(DeskFinishedPresentation.sectionCount(groupCount: 3, recentExecutionCount: 2) == 5,
                "the header counts rendered groups plus execution rows, never hidden child rows")
    }

    @Test("execution slicing keeps unknown statuses visible and terminal work recent")
    func executionSliceHasNoSilentDrop() throws {
        let records = [
            try wave1Execution("running", status: "running"),
            try wave1Execution("approval", status: "blocked_on_approval"),
            try wave1Execution("unknown", status: "awaiting_witness"),
            try wave1Execution("done", status: "completed", updatedAt: "2026-08-03T00:00:00Z"),
        ]
        let slice = DeskExecutionPresentation.slice(records)
        #expect(Set(slice.benchIDs) == ["running", "unknown"])
        #expect(slice.approvalIDs == ["approval"])
        #expect(slice.recentDoneIDs == ["done"])
        #expect(DeskExecutionPresentation.pill(for: "awaiting_witness").label == "unknown: awaiting witness")
        let manyTerminal = try (0..<7).map { try wave1Execution("terminal-\($0)", status: "completed", updatedAt: "2026-08-0\($0 + 1)T00:00:00Z") }
        let partition = DeskExecutionPresentation.slice(records + manyTerminal)
        #expect(Set(partition.benchIDs + partition.approvalIDs + partition.recentDoneIDs)
            == Set((records + manyTerminal).map(\.id)), "no terminal execution may vanish after the fifth row")
    }

    @Test("execution labels clamp invalid progress and distinguish verification outcomes")
    func executionLabelsStayTruthfulAtTheEdges() {
        #expect(DeskExecutionPresentation.progress(status: "running", planCount: 2, completedCount: 99) == "step 2 of 2")
        #expect(DeskExecutionPresentation.progress(status: "queued", planCount: 2, completedCount: 0) == nil)
        #expect(DeskExecutionPresentation.verificationLabel(.init(status: .satisfied, checkedAt: "2026-08-01T00:00:00Z", methods: ["exact_output"])) == "verified: exact output")
        #expect(DeskExecutionPresentation.verificationLabel(.init(status: .unverified, checkedAt: "2026-08-01T00:00:00Z")).contains("not independently verified"))
        #expect(DeskExecutionPresentation.verificationLabel(.init(status: .failed, checkedAt: "2026-08-01T00:00:00Z")) == "verification failed")
        #expect(DeskExecutionPresentation.verificationLabel(.init(status: .satisfied, checkedAt: "2026-08-01T00:00:00Z", methods: ["remote_signed_receipt"])) == "verified: remote signed receipt")
    }

    @Test("a pursuit card carries evidence-backed identity and a blocking reason without inventing one")
    func pursuitCardUsesPersistedPursuitAndHoldFacts() throws {
        let pursuit = Pursuit(
            why: "I keep seeing the same verification gap.",
            evidence: PromotionDossier(citations: []),
            doneLooksLike: "The receipt is independently verified.",
            maxSessions: 3,
            abandonCondition: "The evidence stops recurring.",
            privateName: "Receipt truth")
        let blocked = wave1DeskItem(status: .blocked, pursuit: pursuit, blockedReason: "Waiting for the signed build", waitingOn: "User")
        let card = try #require(DeskItemPresentation.pursuitCard(for: blocked))
        #expect(card.title == "Receipt truth")
        #expect(card.sessionLabel == "0/3 sessions")
        #expect(card.holdLabel == "Waiting for the signed build")
        #expect(card.doneLabel.contains("independently verified"))
        #expect(DeskItemPresentation.pursuitCard(for: wave1DeskItem()) == nil,
                "negative control: ordinary work must not render as a self-pursuit")
    }

    @Test("failed or unreadable execution reads remain unavailable instead of becoming an empty bench")
    func laneStateDoesNotTurnReadFailureIntoZero() {
        let unreadable = DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>.classify(
            rows: [], probe: .unreadable("permission denied"), noun: "execution record(s)")
        #expect(unreadable.unavailableReason?.contains("Couldn't read") == true)
        let hiddenRecords = DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>.classify(
            rows: [], probe: .records(2), noun: "execution record(s)")
        #expect(hiddenRecords.unavailableReason?.contains("2 execution record(s) on disk") == true)
        let genuinelyEmpty = DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>.classify(
            rows: [], probe: .empty, noun: "execution record(s)")
        #expect(genuinelyEmpty.unavailableReason == nil)
        #expect(genuinelyEmpty.items.isEmpty)
    }
}
