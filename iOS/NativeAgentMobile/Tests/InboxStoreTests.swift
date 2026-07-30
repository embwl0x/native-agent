import XCTest
@testable import NativeAgentMobile

@MainActor
final class InboxStoreTests: XCTestCase {
    private let knownIDsKey = "NativeAgentMobile.inboxKnownIDs"

    // `override func tearDown()` overrides a nonisolated XCTestCase requirement,
    // so it does NOT inherit this class's @MainActor and can't touch the
    // MainActor-isolated iCloudSyncEngine.shared. The async overload does inherit
    // the isolation.
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: knownIDsKey)
        iCloudSyncEngine.shared.inboxItems = []
        iCloudSyncEngine.shared.inboxSnapshotLoaded = false
        iCloudSyncEngine.shared.syncError = nil
        try await super.tearDown()
    }

    func test_transient_empty_before_first_inbox_snapshot_does_not_clear_known_ids() {
        UserDefaults.standard.set(["card-1", "card-2"], forKey: knownIDsKey)
        let store = InboxStore()
        iCloudSyncEngine.shared.inboxItems = []
        iCloudSyncEngine.shared.inboxSnapshotLoaded = false
        iCloudSyncEngine.shared.syncError = "Inbox snapshot is still downloading from iCloud. Try again in a moment."

        store.applySyncedInboxFromSnapshot(animated: false, notifyNewArrivals: false)

        XCTAssertEqual(store.debugKnownIDs(), ["card-1", "card-2"])
        XCTAssertEqual(Set(UserDefaults.standard.stringArray(forKey: knownIDsKey) ?? []), ["card-1", "card-2"])
    }

    func test_loaded_empty_inbox_snapshot_clears_known_ids() {
        UserDefaults.standard.set(["card-1", "card-2"], forKey: knownIDsKey)
        let store = InboxStore()
        iCloudSyncEngine.shared.inboxItems = []
        iCloudSyncEngine.shared.inboxSnapshotLoaded = true

        store.applySyncedInboxFromSnapshot(animated: false, notifyNewArrivals: false)

        XCTAssertTrue(store.debugKnownIDs().isEmpty)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: knownIDsKey), [])
    }

    func test_unimplemented_reply_wire_action_is_not_presented() {
        let item = InboxItemRecord(
            id: "card-1",
            created_at: "2026-07-12T12:00:00Z",
            source: "proactive_autonomy:test",
            severity: "actionable",
            title: "A thought",
            summary: "Something worth reviewing",
            detail: nil,
            relatedWorkshopExecutionId: nil,
            related_approval_id: nil,
            related_paths: nil,
            related_groups: nil,
            actions: [
                InboxActionRecord(id: "view", label: "View", description: nil),
                InboxActionRecord(id: "reply", label: "Reply", description: nil),
                InboxActionRecord(id: "archive", label: "Archive", description: nil),
            ],
            status: "unread",
            read_at: nil
        )

        XCTAssertEqual(item.presentableActions.map(\.id), ["view", "archive"])
    }
}
