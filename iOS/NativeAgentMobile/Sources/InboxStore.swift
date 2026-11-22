import Combine
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `InboxStore.swift` | Inbox refresh; the Mac's routed alert is the phone's only inbox alert |

// MARK: - Store

@MainActor
final class InboxStore: ObservableObject {
    var items: [InboxItemRecord] { iCloudSyncEngine.shared.inboxItems }
    @Published var isLoading = false

    // MARK: - Fetch

    func refresh(pairingStore: PairingStore) async {
        isLoading = true
        defer { isLoading = false }
        guard pairingStore.usesICloudTransport else { return }
        await iCloudSyncEngine.shared.refreshInboxSnapshot()
        applySyncedInboxFromSnapshot()
    }

    func applySyncedInboxFromSnapshot() {
        NSLog("[InboxStore] refresh via iCloud fetched=%d", iCloudSyncEngine.shared.inboxItems.count)
    }
}
