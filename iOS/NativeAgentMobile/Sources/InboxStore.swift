import Combine
import Foundation
import NativeAgentShared
import UserNotifications
import SwiftUI
// Blueprint: | `InboxStore.swift` | Inbox refresh and notification permission; the Mac's routed alert is the phone's only inbox alert |

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
