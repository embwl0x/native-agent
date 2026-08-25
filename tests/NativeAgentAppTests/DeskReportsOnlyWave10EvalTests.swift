import Foundation
import ChatOrchestration
import NotificationInbox
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Wave 10 closes remaining Desk report-only claims with real owner paths:
// mounted refresh coordination, the persisted inbox, the durable run ledger,
// and Desk's gated mutation router.  These are deliberately not source or
// appearance probes; each proof writes/receives canonical state, then observes
// a fresh reader or mounted AppModel boundary.
//
// Covered rows:
// - desk.reloader.startPathsLatch
// - desk.reloader.watchPathDirectoryCreate
// - desk.inbox.laneLabelCounts
// - desk.inbox.emptyStateCrossLanePointer
// - desk.inbox.effectiveActions
// - desk.runs.emptyStateSilentZero
// - desk.control.toolbar.refresh
// - desk.action.surfacePin

private func wave10DeskRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskReportsOnlyWave10-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func wave10InboxRows(_ inbox: LiveNotificationInbox) async throws -> [InboxItemRecord] {
    let decoder = JSONDecoder()
    return try await inbox.rows().map { row in
        try decoder.decode(InboxItemRecord.self, from: row.serializedData(pretty: false))
    }
}

/// Desk mutations use the same lazy-tool authority as an agent turn.  This
/// fixture supplies a unique session and its durable loadout so the test
/// reaches the Desk status writer rather than stopping at missing_session_id.
private struct Wave10SessionAuthorizedDeskRouter: DeskToolInvoking {
    let router: DeskToolDispatchRouter
    let sessionID: String

    func run(tool: String, input: [String: JSONValue]) async throws -> JSONValue {
        var authorizedInput = input
        authorizedInput["session_id"] = .string(sessionID)
        return try await router.run(tool: tool, input: authorizedInput)
    }
}

@MainActor
private final class Wave10ReloadProbe {
    private(set) var count = 0
    func reload() { count += 1 }
}

@Suite("Desk reports-only wave 10 behavior", .serialized)
struct DeskReportsOnlyWave10EvalTests {
    @MainActor
    private func waitForReload(
        _ probe: Wave10ReloadProbe,
        count: Int,
        deadline: Duration = .seconds(3)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        while clock.now - started < deadline {
            if probe.count >= count { return probe.count == count }
            try await Task.sleep(for: .milliseconds(10))
        }
        return probe.count == count
    }

    @Test("a reactivated mounted Desk drops its old root and reloads only for its replacement canonical path")
    @MainActor func reloaderRebindsAfterTheDeskChangesRoots() async throws {
        let root = try wave10DeskRoot("rebind")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("one/desk_ops.jsonl")
        let newPath = root.appendingPathComponent("two/desk_ops.jsonl")
        let probe = Wave10ReloadProbe()
        let reloader = DeskLiveReloader(
            debounceDelay: .milliseconds(1), visibilityResolver: { true })
        defer { reloader.stop() }

        reloader.activate(paths: [oldPath]) { probe.reload() }
        #expect(try await waitForReload(probe, count: 1))
        reloader.deactivate()
        reloader.activate(paths: [newPath]) { probe.reload() }
        #expect(try await waitForReload(probe, count: 2))

        // A stale StoreChangeBus event is what an alternate/recovered runtime
        // leaves behind.  It must not reload the newly mounted Desk.
        StoreChangeBus.shared.emit(.init(store: .desk, path: oldPath))
        try await Task.sleep(for: .milliseconds(80))
        #expect(probe.count == 2)

        StoreChangeBus.shared.emit(.init(store: .desk, path: newPath))
        #expect(try await waitForReload(probe, count: 3))
    }

    @Test("the mounted reloader prepares a blank store parent before receiving its first exact store event")
    @MainActor func reloaderArmsBlankStoreParentsBeforeTheFirstMutation() async throws {
        let root = try wave10DeskRoot("blank-parent")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("new-desk/ops/desk_ops.jsonl")
        let probe = Wave10ReloadProbe()
        let reloader = DeskLiveReloader(
            debounceDelay: .milliseconds(1), visibilityResolver: { true })
        defer { reloader.stop() }

        reloader.activate(paths: [path]) { probe.reload() }
        #expect(try await waitForReload(probe, count: 1))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: path.deletingLastPathComponent().path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        StoreChangeBus.shared.emit(.init(store: .desk, path: path))
        #expect(try await waitForReload(probe, count: 2))
    }

    @Test("a malformed live-store parent fails closed with an error instead of arming a watcher that can never fire")
    @MainActor func reloaderSurfacesUnwatchableParent() throws {
        let root = try wave10DeskRoot("malformed-parent")
        defer { try? FileManager.default.removeItem(at: root) }
        let parentFile = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: parentFile)
        let reloader = DeskLiveReloader(visibilityResolver: { true })
        defer { reloader.stop() }

        let error = reloader.activate(paths: [parentFile.appendingPathComponent("desk_ops.jsonl")]) {}
        #expect(error?.contains("Desk live updates are unavailable") == true)
        #expect(reloader.configurationError == error)
    }

    @Test("the toolbar refresh receipt remains visible when its generation loses to newer Desk data")
    func supersededToolbarRefreshHasAnHonestReceipt() {
        let accepted = DeskRefreshPresentation.receipt(accepted: true)
        let superseded = DeskRefreshPresentation.receipt(accepted: false)
        #expect(accepted.text == "Desk refreshed.")
        #expect(!accepted.isError)
        #expect(superseded.text.contains("superseded by newer Desk data"))
        #expect(!superseded.isError)
    }

    @Test("Inbox lane counts use the persisted unread default-visible population on both sides of the lane boundary")
    func inboxLaneCountsShareOneDurablePopulation() async throws {
        let root = try wave10DeskRoot("inbox-counts")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = LiveNotificationInbox(path: NativeClient.visibleNotificationInboxPath(dataRoot: root))
        for (id, source, status) in [
            ("for-you-unread", "trigger:morning_brief", "unread"),
            ("for-you-read", "trigger:morning_brief", "read"),
            ("system-unread", "heartbeat", "unread"),
            ("system-archived", "heartbeat", "archived"),
        ] {
            try await inbox.appendUnique(.object([
                "id": .string(id), "created_at": .string("2026-08-24T12:00:00Z"),
                "source": .string(source), "severity": .string("info"),
                "title": .string(id), "summary": .string("stored card"),
                "status": .string(status), "actions": .array([]),
            ]), id: id)
        }

        let rows = try await wave10InboxRows(inbox)
        #expect(InboxLanePresentation.unreadVisibleCount(in: .forYou, items: rows) == 1)
        #expect(InboxLanePresentation.unreadVisibleCount(in: .system, items: rows) == 1)
        #expect(InboxReviewGroupSelection.displayItems(
            items: rows, lane: .system, showAll: false, groupFilter: nil
        ).map(\.id) == ["system-unread"])
    }

    @Test("a terminal Inbox action survives a fresh reader and cannot inflate the other-lane pointer")
    func archivedInboxCardStopsCountingBeforeAndAfterRelaunch() async throws {
        let root = try wave10DeskRoot("inbox-terminal")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = NativeClient.visibleNotificationInboxPath(dataRoot: root)
        let inbox = LiveNotificationInbox(path: path)
        try await inbox.appendUnique(.object([
            "id": .string("system-card"), "created_at": .string("2026-08-24T12:00:00Z"),
            "source": .string("heartbeat"), "severity": .string("info"),
            "title": .string("System card"), "summary": .string("must settle"),
            "status": .string("unread"), "actions": .array([]),
        ]), id: "system-card")
        // This is the mounted NativeClient action, not the lower-level store
        // helper: the reader and writer must share its injected data root.
        try await NativeClient(baseURL: "", dataRootOverride: root)
            .inboxAction("system-card", action: "archive")

        let relaunched = LiveNotificationInbox(path: path)
        let rows = try await wave10InboxRows(relaunched)
        let card = try #require(rows.first)
        #expect(card.status == "archived")
        #expect(InboxLanePresentation.unreadVisibleCount(in: .system, items: rows) == 0)
        #expect(InboxReviewGroupSelection.displayItems(
            items: rows, lane: .system, showAll: false, groupFilter: nil
        ).isEmpty)
        #expect(InboxReviewGroupSelection.displayItems(
            items: rows, lane: .system, showAll: true, groupFilter: nil
        ).map(\.id) == ["system-card"])
    }

    @Test("a real Inbox action refuses an unresolved Act without rewriting its canonical card")
    func unresolvedInboxActLeavesThePersistedCardUntouched() async throws {
        let root = try wave10DeskRoot("inbox-refusal")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = NativeClient.visibleNotificationInboxPath(dataRoot: root)
        let inbox = LiveNotificationInbox(path: path)
        try await inbox.appendUnique(.object([
            "id": .string("proactive-unresolved"), "created_at": .string("2026-08-24T12:00:00Z"),
            "source": .string("proactive_autonomy:unmapped"), "severity": .string("actionable"),
            "title": .string("Opportunity"), "summary": .string("Needs a real route."),
            "status": .string("unread"), "actions": .array([]),
        ]), id: "proactive-unresolved")
        let storedCard = try #require((try await wave10InboxRows(inbox)).first)
        #expect(storedCard.effectiveActions.map(\.id) == ["view", "archive", "dismiss"])
        let bytesBefore = try Data(contentsOf: path)
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        await #expect(throws: (any Error).self) {
            try await client.inboxAction("proactive-unresolved", action: "act")
        }
        #expect(try Data(contentsOf: path) == bytesBefore)
        #expect((try await wave10InboxRows(LiveNotificationInbox(path: path))).first?.isUnread == true)
    }

    @Test("Diagnostics refresh preserves last-good runs and mounts an unavailable state for a corrupt durable ledger")
    @MainActor func corruptRunsLedgerDoesNotBecomeANoRunsClaim() async throws {
        let root = try wave10DeskRoot("runs-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        await RunLedger.append(
            id: "last-good", kind: "mission", status: "failed", error: "proof failure",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), dataRoot: root)
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await model.refreshForSidebarItem(.diagnostics)
        #expect(model.runs.map(\.id) == ["last-good"])

        let path = root.appendingPathComponent("runs/runs.json")
        let corrupt = Data("{not-a-run-ledger".utf8)
        try corrupt.write(to: path)
        await model.refreshForSidebarItem(.diagnostics)
        #expect(model.runs.map(\.id) == ["last-good"])
        #expect(model.panelStaleNotice(for: .diagnostics) != nil)
        #expect(try Data(contentsOf: path) == corrupt)

        // Relaunch has no last-good in memory, but must still visibly say the
        // read failed instead of treating corruption as a quiet, empty ledger.
        let relaunched = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await relaunched.refreshForSidebarItem(.diagnostics)
        #expect(relaunched.runs.isEmpty)
        #expect(relaunched.panelStaleNotice(for: .diagnostics)?.contains("Nothing has loaded") == true)
        let presentation = RunsPresentation.state(
            runs: relaunched.runs,
            staleNotice: relaunched.panelStaleNotice(for: .diagnostics)
        )
        guard case .unavailable(let notice) = presentation else {
            Issue.record("corrupt cold relaunch rendered a runs state instead of unavailable")
            return
        }
        #expect(notice == relaunched.panelStaleNotice(for: .diagnostics))
    }

    @Test("Desk status actions carry the Desk surface through the gated router, persist once, and a bad handle cannot manufacture a second operation")
    func deskStatusActionPersistsAcrossRelaunchAndRefusesUnknownTarget() async throws {
        let root = try wave10DeskRoot("desk-status")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .plan, project: "Wave 10", title: "Persist status")
        let sessionID = "desk-wave10-status-\(UUID().uuidString)"
        try await ActiveToolsStore(dataRoot: root).addLoaded(
            sessionId: sessionID,
            names: ["desk_set_status"]
        )
        let router = Wave10SessionAuthorizedDeskRouter(
            router: DeskToolDispatchRouter(dataRoot: root),
            sessionID: sessionID
        )
        let updated = await DeskActionRunner.perform(
            .setStatus(handle: item.handle, status: .flag), via: router)
        #expect(updated.ok)
        let relaunched = SwiftNativeDeskStore(dataRoot: root)
        #expect(try await relaunched.liveState().items.first { $0.handle == item.handle }?.status == .flag)
        let operationsBeforeRefusal = try await SwiftNativePersistenceCore().readJSONL(relaunched.opsPath).count

        let refused = await DeskActionRunner.perform(
            .setStatus(handle: "desk_missing", status: .done), via: router)
        #expect(!refused.ok)
        #expect(try await SwiftNativePersistenceCore().readJSONL(relaunched.opsPath).count == operationsBeforeRefusal)
    }
}
