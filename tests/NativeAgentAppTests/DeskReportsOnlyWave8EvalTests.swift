import Foundation
import NotificationInbox
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Wave 8 promotes only executable Desk behavior.  Each proof crosses an
// actual mutation/store boundary and then observes the same presentation model
// used by the app; no source-text or fabricated tool-envelope checks appear
// here.
//
// Covered rows:
// - desk.inbox.detailSheetAutoRead
// - workshop.observatory.veto

private func wave8DeskRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskReportsOnlyWave8-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func wave8InboxItems(_ inbox: LiveNotificationInbox) async throws -> [InboxItemRecord] {
    let decoder = JSONDecoder()
    let rows = try await inbox.rows()
    return try rows.map { row in
        try decoder.decode(InboxItemRecord.self, from: row.serializedData(pretty: false))
    }
}

private func wave8Pursuit() -> Pursuit {
    Pursuit(
        why: "A stable receipt needs an operator decision.",
        evidence: PromotionDossier(citations: [
            .standingView(id: "wave8-standing-view"),
            // The Desk admission gate requires recurrence on distinct calendar
            // days; these are canonical date values, not duplicate timestamps.
            .feltSalience(dates: ["2026-08-23", "2026-08-24"]),
        ]),
        doneLooksLike: "The decision and its rationale are both durable.",
        maxSessions: 3,
        abandonCondition: "The evidence no longer recurs.",
        privateName: "Veto proof"
    )
}

private enum Wave8VetoWriteFailure: Error {
    case denied
}

/// Uses the real file reader and flock, refusing only the final durable append
/// that would make a veto visible. This is the failure boundary a crash or I/O
/// error must leave wholly uncommitted.
private struct Wave8VetoAppendRefusingPersistence: PersistenceCoreProtocol {
    private let base = SwiftNativePersistenceCore()

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await base.readJSON(path, defaultValue: defaultValue)
    }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await base.writeJSON(value, to: path)
    }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await base.appendJSONL(record, to: path)
    }

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await base.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }

    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await base.readJSONL(path)
    }

    func appendJSONLDurable(_ record: JSONValue, to path: URL) async throws {
        throw Wave8VetoWriteFailure.denied
    }
}

@Suite("Desk reports-only wave 8 behavior", .serialized)
struct DeskReportsOnlyWave8EvalTests {
    @Test("opening an Inbox detail marks its real card read once, preserves that receipt, and keeps the card in the rendered lane")
    func detailAutoReadIsIdempotentAndProjectsTheCanonicalCard() async throws {
        let root = try wave8DeskRoot("inbox-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = NativeClient.visibleNotificationInboxPath(dataRoot: root)
        let inbox = LiveNotificationInbox(path: path)
        let id = "wave8-detail-card"
        try await inbox.appendUnique(.object([
            "id": .string(id),
            "created_at": .string("2026-08-24T12:00:00Z"),
            "source": .string("trigger:morning_brief"),
            "severity": .string("info"),
            "title": .string("Morning brief"),
            "summary": .string("One durable card."),
            "status": .string("unread"),
            "actions": .array([]),
        ]), id: id)

        let before = try await wave8InboxItems(inbox)
        #expect(InboxReviewGroupSelection.displayItems(
            items: before, lane: .forYou, showAll: false, groupFilter: nil
        ).map(\.id) == [id])

        // Adverse control: a detail's non-status verb must not silently mark
        // the card read or alter its durable bytes.
        let originalBytes = try Data(contentsOf: path)
        let ignored = await NativeClient.updateVisibleNotificationInboxStatus(
            id: id, action: "view", inboxPath: path)
        #expect(!ignored)
        #expect(try Data(contentsOf: path) == originalBytes)

        let markedRead = await NativeClient.updateVisibleNotificationInboxStatus(
            id: id, action: "read", inboxPath: path)
        #expect(markedRead)
        let firstReadBytes = try Data(contentsOf: path)
        let afterFirstRead = try await wave8InboxItems(inbox)
        let visible = InboxReviewGroupSelection.displayItems(
            items: afterFirstRead, lane: .forYou, showAll: false, groupFilter: nil)
        let card = try #require(visible.first { $0.id == id })
        #expect(!card.isUnread)
        #expect(card.read_at?.isEmpty == false)

        // `.onAppear { onAction("read") }` can fire again after presentation
        // reconstruction.  The second appearance is successful but must not
        // manufacture a newer read receipt or rewrite unrelated inbox bytes.
        let repeatedRead = await NativeClient.updateVisibleNotificationInboxStatus(
            id: id, action: "read", inboxPath: path)
        #expect(repeatedRead)
        #expect(try Data(contentsOf: path) == firstReadBytes)
    }

    @Test("the production veto handler writes to its resolved root and survives relaunch as one canceled pursuit with its rationale")
    func vetoHandlerUsesResolvedRootAndOneDurableOperation() async throws {
        let root = try wave8DeskRoot("veto")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let pursuit = try await store.openPursuit(
            project: "evaluation", title: "Prove the veto", pursuit: wave8Pursuit())

        let initial = try await store.liveState()
        #expect(WorkshopObservatoryModel.build(state: initial, now: Date()).openPursuits
            .contains(where: { $0.handle == pursuit.handle }))

        // This is the production handler constructor CognitionObservatoryView
        // receives from Dependencies.dataRoot, not a test-only router.
        let outcome = await WorkshopObservatoryVetoHandler(dataRoot: root).veto(pursuit.handle)
        #expect(outcome == .completed)

        let relaunched = SwiftNativeDeskStore(dataRoot: root)
        let settled = try await relaunched.liveState()
        let item = try #require(settled.items.first { $0.handle == pursuit.handle })
        #expect(item.status == .canceled)
        #expect(item.notes.contains(where: { $0.text == WorkshopObservatoryVetoHandler.rationale }))
        #expect(!WorkshopObservatoryModel.build(state: settled, now: Date()).openPursuits
            .contains(where: { $0.handle == pursuit.handle }))

        let ops = try await SwiftNativePersistenceCore().readJSONL(relaunched.opsPath)
        #expect(ops.filter { row in
            guard case .object(let object) = row else { return false }
            return object["op"] == .string("veto_pursuit")
        }.count == 1)
    }

    @Test("a durable veto-write failure leaves no partial rationale or cancellation after relaunch")
    func vetoFailureDoesNotLeaveAPartialState() async throws {
        let root = try wave8DeskRoot("veto-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let live = SwiftNativeDeskStore(dataRoot: root)
        let pursuit = try await live.openPursuit(
            project: "evaluation", title: "Remain open", pursuit: wave8Pursuit())
        let refusing = SwiftNativeDeskStore(
            dataRoot: root, persistence: Wave8VetoAppendRefusingPersistence())

        let outcome = await WorkshopObservatoryVetoHandler(store: refusing).veto(pursuit.handle)
        guard case .failed = outcome else {
            Issue.record("expected the injected durable append failure, got \(outcome)")
            return
        }

        let relaunched = SwiftNativeDeskStore(dataRoot: root)
        let state = try await relaunched.liveState()
        let item = try #require(state.items.first { $0.handle == pursuit.handle })
        #expect(!item.status.isTerminal)
        #expect(!item.notes.contains(where: { $0.text == WorkshopObservatoryVetoHandler.rationale }))
        #expect(WorkshopObservatoryModel.build(state: state, now: Date()).openPursuits
            .contains(where: { $0.handle == pursuit.handle }))
    }

    @Test("double-fire creates one veto event and later retries report the already-settled result")
    func vetoHandlerGuardsDoubleFireAndIsIdempotent() async throws {
        let root = try wave8DeskRoot("veto-double-fire")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let pursuit = try await store.openPursuit(
            project: "evaluation", title: "Close once", pursuit: wave8Pursuit())
        let handler = WorkshopObservatoryVetoHandler(dataRoot: root)

        async let first: WorkshopObservatoryVetoHandler.Outcome = handler.veto(pursuit.handle)
        async let second: WorkshopObservatoryVetoHandler.Outcome = handler.veto(pursuit.handle)
        let (firstOutcome, secondOutcome) = await (first, second)
        let outcomes = [firstOutcome, secondOutcome]
        #expect(outcomes.contains(.completed))
        #expect(outcomes.contains(.inFlight) || outcomes.contains(.alreadyVetoed))

        let rows = try await SwiftNativePersistenceCore().readJSONL(store.opsPath)
        #expect(rows.filter { row in
            guard case .object(let object) = row else { return false }
            return object["op"] == .string("veto_pursuit")
        }.count == 1)
        #expect(await handler.veto(pursuit.handle) == .alreadyVetoed)
    }

    // Item 36: Veto lives on the Desk pursuits row now, not in the
    // developer-gated observatory. The control still refuses to exist without
    // its action, still disables only the clicked handle, and still routes into
    // the SAME store mutation the observatory used.
    @Test("the Desk pursuit veto control forwards the visible handle and routes through the same store action")
    @MainActor func deskPursuitVetoControlRoutesThroughTheSameAction() async throws {
        let root = try wave8DeskRoot("veto-desk-row")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let pursuit = try await store.openPursuit(
            project: "evaluation", title: "Desk veto", pursuit: wave8Pursuit())

        var receivedHandle: String?
        let control = DeskPursuitVetoControl(pendingHandles: ["desk-other"]) { handle in
            receivedHandle = handle
        }
        #expect(!control.isDisabled(pursuit.handle))
        #expect(control.isDisabled("desk-other"))
        control.trigger(pursuit.handle)
        #expect(receivedHandle == pursuit.handle)

        // The action the Desk row wires that closure to.
        let outcome = await WorkshopObservatoryVetoHandler(dataRoot: root)
            .veto(try #require(receivedHandle))
        #expect(outcome == .completed)
        #expect(DeskPursuitVetoNotice.receipt(for: outcome).isError == false)
        let reloaded = try await SwiftNativeDeskStore(dataRoot: root).liveState()
        let settled = try #require(reloaded.items.first { $0.handle == pursuit.handle })
        #expect(settled.status == .canceled)
        #expect(settled.notes.contains { $0.text == WorkshopObservatoryVetoHandler.rationale })
    }

    // The score/budget/reason the owner vetoes against come from the SAME pure
    // fold the observatory used, so moving the control did not fork the numbers.
    @Test("the Desk pursuit row shows the score and budget from the observatory's own fold")
    func deskPursuitVetoRationaleMatchesTheObservatoryFold() async throws {
        let root = try wave8DeskRoot("veto-desk-rationale")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let pursuit = try await store.openPursuit(
            project: "evaluation", title: "Desk rationale", pursuit: wave8Pursuit())
        let state = try await store.liveState()
        let item = try #require(state.items.first { $0.handle == pursuit.handle })
        let now = Date()

        let row = try #require(DeskPursuitVetoRationale.row(for: item, now: now))
        #expect(row == WorkshopPursuitRow.from(item: item, now: now))
        #expect(DeskPursuitVetoRationale.budgetLabel(row.budget)
            == "0/\(row.budget?.maxSessions ?? 0) sessions · 0/\(row.budget?.perDayCap ?? 0) today")
        // A pursuit with no decodable score must say nothing, never a fake 0.
        #expect(DeskPursuitVetoRationale.scoreLabel(nil) == nil)
        #expect(DeskPursuitVetoRationale.reasonLabel("chose: it kept coming back") == "it kept coming back")
        #expect(DeskPursuitVetoRationale.reasonLabel(nil) == nil)
    }
}
