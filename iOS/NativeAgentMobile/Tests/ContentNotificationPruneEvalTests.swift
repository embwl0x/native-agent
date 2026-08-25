import Foundation
import XCTest
@testable import NativeAgentMobile

/// Executable fence for `ios.screens / ios.content.notificationPrune`.
///
/// The delivered-notification list is a hermetic stand-in for the system
/// center. It includes every former source-prefix shape plus a future source,
/// so snapshot reconciliation cannot leave a stale alert or badge behind.
final class ContentNotificationPruneEvalTests: XCTestCase {
    func test_snapshotPruningRemovesResolvedAndUnboundNativeAgentAlerts() {
        let result = NativeAgentActivityNotificationCleaner.pruningResult(
            activeInboxItems: [item("active-1"), item("active-2"), item("resolved-1", status: "read")],
            deliveredNotifications: [
                notification("active-alert", info: ["itemId": "active-1", "source": "inbox"]),
                notification("resolved-alert", info: ["itemId": "resolved-1", "source": "inbox"]),
                notification("scheduler", info: ["source": "scheduler_job_ran"]),
                notification("proactive", info: ["source": "proactive_autonomy"]),
                notification("proactive-child", info: ["source": "proactive_autonomy:idea-1"]),
                notification("maintenance", info: ["source": "autonomy_maintenance:cleanup"]),
                notification("future-publisher", info: ["source": "new_mac_publisher"]),
                notification("nested-resolved", info: ["nativeagent": ["itemId": "resolved-2", "source": "inbox"]]),
                notification("other-app", info: ["unrelated": "value"]),
            ]
        )

        XCTAssertEqual(result.badgeCount, 2)
        XCTAssertEqual(
            Set(result.notificationIDsToRemove),
            [
                "resolved-alert", "scheduler", "proactive", "proactive-child",
                "maintenance", "future-publisher", "nested-resolved",
            ]
        )
        XCTAssertFalse(result.notificationIDsToRemove.contains("active-alert"))
        XCTAssertFalse(result.notificationIDsToRemove.contains("other-app"))
    }

    private func notification(
        _ identifier: String,
        info: [String: Any]
    ) -> NativeAgentActivityNotificationCleaner.DeliveredNotification {
        .init(
            identifier: identifier,
            userInfo: Dictionary(uniqueKeysWithValues: info.map { (AnyHashable($0.key), $0.value) })
        )
    }

    private func item(_ id: String, status: String = "unread") -> InboxItemRecord {
        InboxItemRecord(
            id: id,
            created_at: "2026-08-24T00:00:00Z",
            source: "eval",
            severity: "important",
            title: "Inbox item \(id)",
            summary: "Current snapshot item",
            detail: nil,
            relatedWorkshopExecutionId: nil,
            related_approval_id: nil,
            related_paths: nil,
            related_groups: nil,
            actions: [],
            status: status,
            read_at: status == "unread" ? nil : "2026-08-24T01:00:00Z"
        )
    }
}
