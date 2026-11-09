import Combine
import Foundation
import NativeAgentShared
import Observation
import SwiftUI
// Blueprint: | `ApprovalsStore.swift` | Synced approvals and their snapshot's health; an approval is decided on its card, its matter's Inbox row; the Mac's routed alert is the phone's only approval alert |

// MARK: - Store

@MainActor
final class ApprovalsStore: ObservableObject {
    var approvals: [ApprovalRequest] { iCloudSyncEngine.shared.approvals }
    @Published var bannerError: String? = nil
    var isVisible = false

    init() {
        observeSnapshotAvailability()
    }

    private func observeSnapshotAvailability() {
        let loaded = withObservationTracking {
            iCloudSyncEngine.shared.approvalsSnapshotLoaded
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSnapshotAvailability()
            }
        }
        // Seed from availability: the first successful delivery can leave the observed rows unchanged at [].
        if loaded { applySyncedApprovalsFromSnapshot() }
    }

    // MARK: - Fetch

    func applySyncedApprovalsFromSnapshot() {
        guard iCloudSyncEngine.shared.approvalsSnapshotLoaded else { return }
        bannerError = iCloudSyncEngine.shared.snapshotHealth.damageSentence(for: ["approvals.json"])
    }
}
