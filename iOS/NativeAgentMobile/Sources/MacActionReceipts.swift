import SwiftUI
import Combine
import NativeAgentShared
// Blueprint: | `MacActionReceipts.swift` | Mac Tools receipt ledger, approval reconciliation and receipt rows |

enum RemoteActionState: String, Equatable {
    case waiting = "waiting"
    case running = "running"
    case waitingApproval = "waiting approval"
    case approvalResolved = "approval resolved"
    case ranOnMac = "ran on Mac"
    case failed = "failed"

    static func forError(_ error: Error) -> Self {
        if case SyncError.approvalRequired = error {
            return .waitingApproval
        }
        return .failed
    }

}

enum RemoteActionKind: Equatable {
    case notify(title: String, message: String)
    case volume(Int)
    case spotlight(String)
}

enum RemoteActionRetryPresentation {
    static func dispatchDetail(for action: RemoteActionKind, isRetry: Bool) -> String {
        guard isRetry else {
            if case .spotlight = action { return "Searching Mac" }
            return "Sending to Mac"
        }

        switch action {
        case .notify(let title, let message):
            return "Retrying original notification \"\(title)\": \"\(message)\" — not the current composer draft."
        case .volume(let percent):
            return "Retrying original volume target: \(percent)% — not the current slider value."
        case .spotlight(let query):
            return "Retrying original Spotlight search \"\(query)\" — not the current search field."
        }
    }
}

struct RemoteActionCard: Identifiable, Equatable {
    let id: UUID
    var kind: RemoteActionKind
    var title: String
    var subtitle: String
    var state: RemoteActionState
    var detail: String
    var createdAt: Date
    var updatedAt: Date
    var approvalID: String?

    init(kind: RemoteActionKind, title: String, subtitle: String, state: RemoteActionState, detail: String) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.detail = detail
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// App-session receipt ownership for Mac Tools. A waiting approval is the
/// user's only direct breadcrumb from an interrupted remote action to
/// Activity, so ordinary receipt trimming may never evict it.
@MainActor
final class RemoteActionLedger: ObservableObject {
    static let shared = RemoteActionLedger()

    @Published private(set) var actions: [RemoteActionCard] = []
    private let maximumOrdinaryActions = 12

    init() {
        observeApprovals()
    }

    private func observeApprovals() {
        withObservationTracking {
            reconcileApprovals(iCloudSyncEngine.shared.approvals)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeApprovals() }
        }
    }

    @discardableResult
    func start(_ kind: RemoteActionKind, title: String, subtitle: String) -> UUID {
        let card = RemoteActionCard(
            kind: kind,
            title: title,
            subtitle: subtitle,
            state: .waiting,
            detail: "Queued for Mac"
        )
        actions.insert(card, at: 0)
        trimOrdinaryActions()
        return card.id
    }

    func update(_ id: UUID, state: RemoteActionState, detail: String, approvalID: String? = nil) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].state = state
        actions[index].detail = detail
        actions[index].updatedAt = Date()
        actions[index].approvalID = approvalID?.isEmpty == false ? approvalID : nil
        reconcileApprovals(iCloudSyncEngine.shared.approvals)
    }

    private func reconcileApprovals(_ approvals: [ApprovalRequest]) {
        for index in actions.indices where actions[index].state == .waitingApproval {
            guard let id = actions[index].approvalID,
                  let approval = approvals.first(where: { $0.id == id }),
                  ["resolved", "denied", "canceled", "orphaned"]
                    .contains(approval.status.lowercased()) else { continue }
            actions[index].state = .approvalResolved
            actions[index].detail = "Approval \(approval.decision ?? approval.status). Check Activity for the action outcome."
            actions[index].updatedAt = Date()
        }
        trimOrdinaryActions()
    }

    private func trimOrdinaryActions() {
        var ordinaryCount = 0
        actions = actions.sorted { $0.updatedAt > $1.updatedAt }.filter { action in
            if action.state == .waitingApproval, action.approvalID != nil { return true }
            ordinaryCount += 1
            return ordinaryCount <= maximumOrdinaryActions
        }
    }
}

/// One receipt as a row: what ran, its state and age in secondary text, and
/// the next step only when there is one.
struct RemoteActionCardView: View {
    let action: RemoteActionCard
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.body)
                        .foregroundStyle(AlivePalette.text)
                    (Text("\(action.subtitle) · \(action.state.rawValue) · ")
                        + Text(action.updatedAt, format: .relative(presentation: .named)))
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if action.state == .failed {
                    Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                        .labelStyle(.titleOnly)
                        .aliveSecondaryButton()
                }
            }
            Text(action.detail)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if action.state == .waitingApproval {
                Text("Review this approval in Activity.")
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review Approval", systemImage: "checkmark.shield") {
                    NativeAgentNotificationLaunchIntent.stage(screen: "approvals")
                    NotificationCenter.default.post(
                        name: .nativeagentOpenActivity,
                        object: nil,
                        userInfo: ["screen": "approvals"]
                    )
                }
                .labelStyle(.titleOnly)
                .alivePrimaryButton()
            }
        }
        .aliveRow()
    }
}
