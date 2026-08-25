import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.inbox.localNotificationBurstCap`.
///
/// An iCloud publisher can release an entire batch at once. The notification
/// safety cap must retain the batch in the badge/known-ID ledger and send one
/// summary instead of silently notifying nothing.
@MainActor
final class InboxLocalNotificationBurstCapEvalTests: XCTestCase {
    private let knownIDsKey = "NativeAgentMobile.inboxKnownIDs"

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: knownIDsKey)
        try await super.tearDown()
    }

    private func item(_ id: String) -> InboxItemRecord {
        InboxItemRecord(
            id: id,
            created_at: "2026-08-24T12:00:00Z",
            source: "proactive_autonomy:test",
            severity: "actionable",
            title: "Review \(id)",
            summary: "New Inbox item",
            detail: nil,
            relatedWorkshopExecutionId: nil,
            related_approval_id: nil,
            related_paths: nil,
            related_groups: nil,
            actions: [],
            status: "unread",
            read_at: nil
        )
    }

    func test_belowBurstThresholdSchedulesAtMostTheIndividualCapAndRetainsTheBadgeLedger() {
        UserDefaults.standard.set(["seen"], forKey: knownIDsKey)
        var scheduled: [(InboxLocalNotificationPlan, Int)] = []
        let store = InboxStore { plan, badgeCount in scheduled.append((plan, badgeCount)) }
        let fetched = [item("seen")] + (1...7).map { item("new-\($0)") }

        store.applyFetchedItems(fetched, animated: false)

        guard case .items(let items) = try! XCTUnwrap(scheduled.first?.0) else {
            return XCTFail("a below-threshold arrival should schedule individual notifications")
        }
        XCTAssertEqual(items.map(\.id), ["new-1", "new-2", "new-3"])
        XCTAssertEqual(scheduled.first?.1, 8)
        XCTAssertEqual(store.tabBadge, "8")
        XCTAssertEqual(store.debugKnownIDs(), Set(fetched.map(\.id)))
    }

    func test_burstSchedulesOneSummaryAndStillRecordsEveryArrivalForTheBadge() {
        UserDefaults.standard.set(["seen"], forKey: knownIDsKey)
        var scheduled: [(InboxLocalNotificationPlan, Int)] = []
        let store = InboxStore { plan, badgeCount in scheduled.append((plan, badgeCount)) }
        let fetched = [item("seen")] + (1...8).map { item("batch-\($0)") }

        store.applyFetchedItems(fetched, animated: false)

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled.first?.0, .summary(newUnreadCount: 8))
        XCTAssertEqual(scheduled.first?.1, 9)
        XCTAssertEqual(store.tabBadge, "9")
        XCTAssertEqual(store.debugKnownIDs(), Set(fetched.map(\.id)))
    }
}
