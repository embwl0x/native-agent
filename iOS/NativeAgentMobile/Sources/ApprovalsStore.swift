import Combine
import Foundation
import NativeAgentShared
import UserNotifications
import SwiftUI
// Blueprint: | `ApprovalsStore.swift` | Signed approval decisions, refresh state and pending-arrival notifications |

/// A card's decision selects its signed Mac action.
enum ApprovalDecisionRoute: Equatable {
    case approve
    case reject
    case cancel
}

/// The warning slot is reserved for a real asynchronous handoff. A healthy
/// snapshot does not need a persistent warning just because it arrived through
/// iCloud.
enum ApprovalBannerPresentation {
    static let pendingDecisionMessage =
        "Decision unconfirmed. Reconnect, then refresh to check the result. If still pending, retry the decision."

}

/// Pure notification policy for approval snapshots. Keeping the policy apart
/// from `UNUserNotificationCenter` makes the cold-load, visibility, and burst
/// rules executable without asking the system to present a notification.
enum ApprovalPendingNotificationPresentation {
    static let individualNotificationLimit = 3

    struct Plan: Equatable {
        let individualApprovalIDs: [String]
        let summaryCount: Int?

        static let none = Plan(individualApprovalIDs: [], summaryCount: nil)
    }

    static func plan(
        hasLoadedApprovals: Bool,
        isVisible: Bool,
        pendingIDs: [String],
        notifiedIDs: Set<String>
    ) -> Plan {
        guard hasLoadedApprovals, !isVisible else { return .none }

        var newIDs: [String] = []
        var seenIDs = Set<String>()
        for id in pendingIDs where !notifiedIDs.contains(id) && seenIDs.insert(id).inserted {
            newIDs.append(id)
        }

        guard !newIDs.isEmpty else { return .none }
        if newIDs.count > individualNotificationLimit {
            return Plan(individualApprovalIDs: [], summaryCount: newIDs.count)
        }
        return Plan(individualApprovalIDs: newIDs, summaryCount: nil)
    }
}

// MARK: - Store

@MainActor
final class ApprovalsStore: ObservableObject {
    var approvals: [PendingApproval] { iCloudSyncEngine.shared.approvals }
    @Published var bannerError: String? = nil
    @Published var bannerWarning: String? = nil
    /// Distinct approval decisions may be sent together.
    @Published private(set) var decidingApprovalIDs = Set<String>()
    var isVisible = false
    private var hasLoadedApprovals = false
    private var notifiedPendingIDs = Set<String>()

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

    func applySyncedApprovalsFromSnapshot(notifyNewPending: Bool = true) {
        if notifyNewPending {
            notifyForNewPendingApprovals(approvals)
        } else {
            rememberPendingApprovals(approvals)
        }
        bannerWarning = nil
        bannerError = nil
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

    private func rememberPendingApprovals(_ next: [PendingApproval]) {
        let pendingIDs = Set(next.filter { $0.outcome == .pending }.map(\.id))
        notifiedPendingIDs.formUnion(pendingIDs)
        hasLoadedApprovals = true
    }

    private func notifyForNewPendingApprovals(_ next: [PendingApproval]) {
        let pending = next.filter { $0.outcome == .pending }
        let pendingIDs = pending.map(\.id)
        defer {
            notifiedPendingIDs.formUnion(pendingIDs)
            hasLoadedApprovals = true
        }

        let plan = ApprovalPendingNotificationPresentation.plan(
            hasLoadedApprovals: hasLoadedApprovals,
            isVisible: isVisible,
            pendingIDs: pendingIDs,
            notifiedIDs: notifiedPendingIDs
        )
        for id in plan.individualApprovalIDs {
            guard let approval = pending.first(where: { $0.id == id }) else { continue }
            fireApprovalNotification(approval)
        }
        if let summaryCount = plan.summaryCount {
            fireApprovalSummaryNotification(count: summaryCount)
        }
    }

    private func fireApprovalNotification(_ approval: PendingApproval) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = "NativeAgent approval needed"
            content.body = ApprovalText.title(approval)
            content.sound = .default
            var userInfo = ["screen": "activity", "source": "approval", "approvalId": approval.id]
            let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
            userInfo["eventId"] = eventID
            content.userInfo = userInfo
            _ = try? await NativeAgentNotificationEventGate.add(
                content: content, eventID: eventID, trigger: nil, center: center
            )
        }
    }

    private func fireApprovalSummaryNotification(count: Int) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = "NativeAgent approvals needed"
            content.body = "\(count) new actions are waiting for review."
            content.sound = .default
            content.userInfo = ["screen": "activity", "source": "approval_summary"]
            do {
                let request = UNNotificationRequest(identifier: "nativeagent.approval.summary.\(UUID().uuidString)",
                    content: try await CommunicationNotification.decorate(content), trigger: nil)
                try await center.add(request)
            } catch {
                NSLog("[NativeAgentMobile] Approval summary notification failed: %@", error.localizedDescription)
            }
        }
    }
}
