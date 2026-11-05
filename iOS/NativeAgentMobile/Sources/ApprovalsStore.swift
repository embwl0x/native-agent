import Combine
import Foundation
import NativeAgentShared
import Observation
import SwiftUI
// Blueprint: | `ApprovalsStore.swift` | Signed approval decisions and refresh state; the Mac's routed alert is the phone's only approval alert |

enum ApprovalDecisionRoute: Equatable {
    case approve
    case reject
    case cancel
}

/// Warn only for real asynchronous handoff uncertainty; healthy iCloud delivery needs no persistent warning.
enum ApprovalBannerPresentation {
    static let pendingDecisionMessage =
        "Decision unconfirmed. Reconnect, then refresh to check the result. If still pending, retry the decision."

}

// MARK: - Store

@MainActor
final class ApprovalsStore: ObservableObject {
    var approvals: [PendingApproval] { iCloudSyncEngine.shared.approvals }
    @Published var bannerError: String? = nil
    @Published var bannerWarning: String? = nil
    /// Do not serialize distinct approval decisions.
    @Published private(set) var decidingApprovalIDs = Set<String>()
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

    func refresh(pairingStore: PairingStore) async {
        guard pairingStore.usesICloudTransport else {
            bannerWarning = nil
            bannerError = "Pair to view"
            return
        }
        await iCloudSyncEngine.shared.refreshApprovalsSnapshot()
        applySyncedApprovalsFromSnapshot()
    }

    func applySyncedApprovalsFromSnapshot() {
        guard iCloudSyncEngine.shared.approvalsSnapshotLoaded else { return }
        bannerWarning = nil
        bannerError = iCloudSyncEngine.shared.snapshotHealth.damageSentence(for: ["approvals.json"])
    }

    // MARK: - Decide

    @discardableResult
    func decide(id: String, decision: ApprovalDecisionRoute, pairingStore: PairingStore) async -> Result<Void, Error>? {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, decidingApprovalIDs.insert(clean).inserted else { return nil }
        defer { decidingApprovalIDs.remove(clean) }
        guard pairingStore.usesICloudTransport else {
            bannerError = "Pair to view"
            return .failure(SyncError.notSetup)
        }
        do {
            switch decision {
            case .approve:
                _ = try await iCloudSyncEngine.shared.approveApproval(id: id)
            case .cancel:
                _ = try await iCloudSyncEngine.shared.cancelApproval(id: id)
            case .reject:
                _ = try await iCloudSyncEngine.shared.rejectApproval(id: id)
            }
            applySyncedApprovalsFromSnapshot()
            return .success(())
        } catch {
            if case SyncError.responseUnconfirmed = error {
                await refresh(pairingStore: pairingStore)
                bannerWarning = ApprovalBannerPresentation.pendingDecisionMessage
                bannerError = nil
            } else {
                bannerWarning = nil
                bannerError = error.localizedDescription
            }
            return .failure(error)
        }
    }
}
