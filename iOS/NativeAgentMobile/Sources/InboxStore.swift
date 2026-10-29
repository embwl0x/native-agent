import Combine
import Foundation
import NativeAgentShared
import UserNotifications
import SwiftUI
// Blueprint: | `InboxStore.swift` | Inbox refresh/actions, known arrivals and local notification policy |

// MARK: - Store

@MainActor
final class InboxStore: ObservableObject {
    var items: [InboxItemRecord] { iCloudSyncEngine.shared.inboxItems }
    @Published var isLoading = false
    @Published var bannerError: String? = nil

    // Known IDs from previous fetch — used for new-card detection
    private var knownIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "NativeAgentMobile.inboxKnownIDs") ?? [])
    // Whether we are currently on the Inbox tab (caller sets this)
    var isVisible: Bool = false

    // MARK: - Fetch

    func refresh(pairingStore: PairingStore) async {
        isLoading = true
        defer { isLoading = false }
        guard pairingStore.usesICloudTransport else {
            bannerError = "Pair to view"
            return
        }
        await iCloudSyncEngine.shared.refreshInboxSnapshot()
        applySyncedInboxFromSnapshot()
    }

    func applySyncedInboxFromSnapshot(notifyNewArrivals: Bool = true) {
        let fetched = iCloudSyncEngine.shared.inboxItems
        NSLog("[InboxStore] refresh via iCloud fetched=%d", fetched.count)
        applyFetchedItems(fetched, notifyNewArrivals: notifyNewArrivals)
        bannerError = iCloudSyncEngine.shared.syncError
    }

    // MARK: - Actions

    func performAction(id: String, actionID: String, pairingStore: PairingStore) async {
        guard pairingStore.usesICloudTransport else { bannerError = "Pair to view"; return }
        do {
            let response = try await iCloudSyncEngine.shared.inboxAction(itemId: id, actionId: actionID)
            openInteraction(response, id: id, actionID: actionID)
            applySyncedInboxFromSnapshot()
        } catch {
            bannerError = "Failed: \(error.localizedDescription)"
        }
    }

    private func openInteraction(_ response: [String: String], id: String, actionID: String) {
        guard id.hasPrefix("interaction:"), actionID == "act", let session = response["sessionID"] else { return }
        NativeAgentNotificationLaunchIntent.stage(screen: "chat", sessionID: session)
        NotificationCenter.default.post(name: .nativeagentOpenActivity, object: nil, userInfo: ["screen": "chat"])
    }

    func applyFetchedItems(
        _ fetched: [InboxItemRecord],
        notifyNewArrivals: Bool = true
    ) {
        let fetchedUnread = fetched.filter { $0.isUnread }

        // Suppress cold-launch notifications; summarize large arrival batches.
        let fetchedIDs = Set(fetchedUnread.map { $0.id })
        let newIDs = fetchedIDs.subtracting(knownIDs)
        NSLog("[InboxStore] apply fetched=%d unread=%d known=%d new=%d visible=%@", fetched.count, fetchedUnread.count, knownIDs.count, newIDs.count, isVisible ? "true" : "false")
        let notificationPlan: InboxLocalNotificationPlan
        if notifyNewArrivals && !knownIDs.isEmpty && !newIDs.isEmpty {
            notificationPlan = InboxNotificationBurstPresentation.plan(
                newUnreadItems: fetchedUnread.filter { newIDs.contains($0.id) },
                isInboxVisible: isVisible
            )
        } else {
            notificationPlan = .none
        }
        knownIDs = fetchedIDs
        UserDefaults.standard.set(Array(Array(fetchedIDs).sorted().suffix(500)), forKey: "NativeAgentMobile.inboxKnownIDs")

        scheduleLocalNotifications(notificationPlan)
    }

    // MARK: - Local notifications

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                NSLog("[InboxStore] notification authorization error: %@", error.localizedDescription)
            }
            NSLog("[InboxStore] notification authorization granted=%@", granted ? "true" : "false")
        }
    }

    private func scheduleLocalNotifications(_ plan: InboxLocalNotificationPlan) {
        switch plan {
        case .none:
            return
        case .items(let items):
            for item in items {
                Self.fireLocalNotification(for: item)
            }
        case .summary(let newUnreadCount):
            Self.fireBatchNotification(newUnreadCount: newUnreadCount)
        }
    }

    private static func fireLocalNotification(for item: InboxItemRecord) {
        var userInfo = [
            "itemId": item.id,
            "source": item.source,
            "screen": "activity"
        ]
        if let approvalID = item.related_approval_id, !approvalID.isEmpty {
            userInfo.removeValue(forKey: "itemId")
            userInfo["approvalId"] = approvalID
        }
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        userInfo["eventId"] = eventID

        Task.detached {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.summary
            content.sound = .default
            content.userInfo = userInfo
            do {
                let added = try await NativeAgentNotificationEventGate.add(
                    content: content,
                    eventID: eventID,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
                NSLog("[InboxStore] notification %@ for %@ event=%@",
                      added ? "scheduled" : "deduplicated", item.id, eventID)
            } catch {
                NSLog("[InboxStore] notification add failed for %@: %@", item.id, error.localizedDescription)
            }
        }
    }

    private static func fireBatchNotification(newUnreadCount: Int) {
        Task.detached {
            let content = UNMutableNotificationContent()
            content.title = "NativeAgent Inbox"
            content.body = "\(newUnreadCount) new Inbox items are ready to review."
            content.sound = .default
            content.userInfo = ["screen": "activity", "source": "inbox_batch"]
            do {
                let request = UNNotificationRequest(
                    identifier: "nativeagent.inbox.batch.\(UUID().uuidString)",
                    content: try await CommunicationNotification.decorate(content),
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
                try await UNUserNotificationCenter.current().add(request)
                NSLog("[InboxStore] scheduled batch notification for %d cards", newUnreadCount)
            } catch {
                NSLog("[InboxStore] batch notification add failed: %@", error.localizedDescription)
            }
        }
    }
}
