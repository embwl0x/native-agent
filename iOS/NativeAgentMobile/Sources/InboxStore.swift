import Combine
import Foundation
import NativeAgentShared
import UserNotifications
import SwiftUI
// Blueprint: | `InboxStore.swift` | Inbox refresh/actions and notification permission; the Mac's routed alert is the phone's only inbox alert |

// MARK: - Store

@MainActor
final class InboxStore: ObservableObject {
    var items: [InboxItemRecord] { iCloudSyncEngine.shared.inboxItems }
    @Published var isLoading = false
    @Published var bannerError: String? = nil

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

    func applySyncedInboxFromSnapshot() {
        NSLog("[InboxStore] refresh via iCloud fetched=%d", iCloudSyncEngine.shared.inboxItems.count)
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

    // MARK: - Notification permission (the Mac's pushes need it)

    func requestNotificationAuthorization() {
        // Use async notification APIs: iOS calls completion handlers off-main, violating closures inferred here as MainActor.
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                NSLog("[InboxStore] notification authorization granted=%@", granted ? "true" : "false")
            } catch {
                NSLog("[InboxStore] notification authorization error: %@", error.localizedDescription)
            }
        }
    }
}
