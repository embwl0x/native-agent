import SwiftUI
import Combine
import NativeAgentShared
// Blueprint: | `MacActionReceipts.swift` | Mac Tools receipt identities, original retry values and approval reconciliation |

enum RemoteActionState: String, Equatable {
    case waiting = "waiting"
    case running = "running"
    case waitingApproval = "waiting approval"
    case approvalResolved = "approval resolved"
    case ranOnMac = "ran on Mac"
    case failed = "failed"
    case unconfirmed = "not confirmed"

}
enum RemoteActionKind: Equatable {
    case notify(title: String, message: String)
    case volume(Int)
    case spotlight(String)

    var privilege: PhoneMacControlAction {
        switch self {
        case .notify: .notification
        case .volume: .volume
        case .spotlight: .spotlight
        }
    }
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
    var operationID: UUID

    init(kind: RemoteActionKind, title: String, subtitle: String, state: RemoteActionState, detail: String, operation: UUID) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.detail = detail
        self.createdAt = Date()
        self.updatedAt = Date()
        self.operationID = operation
    }
}

/// Never trim waiting-approval receipts: they are the user's route from an interrupted Mac action to Activity.
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
    func start(_ kind: RemoteActionKind, title: String, subtitle: String, operation: UUID) -> UUID {
        let card = RemoteActionCard(
            kind: kind,
            title: title,
            subtitle: subtitle,
            state: .waiting,
            detail: "Queued for Mac", operation: operation
        )
        actions.insert(card, at: 0)
        trimOrdinaryActions()
        return card.id
    }

    func bind(_ id: UUID, to operation: UUID) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].operationID = operation
    }

    func read(operation: UUID) async -> FaceActOutcome {
        await iCloudSyncEngine.shared.refreshApprovalsSnapshot()
        guard let card = actions.first(where: { $0.operationID == operation }) else {
            return .init(words: "The original receipt is unavailable; its effect remains unconfirmed.", effects: .unknown)
        }
        if let id = card.approvalID, let approval = iCloudSyncEngine.shared.approvals.first(where: { $0.id == id }) {
            var outcome = approvalOutcome(approval, card: card)
            outcome.accepted = !outcome.unresolved
            return outcome
        }
        return .init(words: card.detail, effects: card.state == .ranOnMac ? .known : .unknown, accepted: card.state == .ranOnMac)
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
        let waiting = actions.filter { $0.state == .waitingApproval }
        for card in waiting {
            guard let id = card.approvalID, let approval = approvals.first(where: { $0.id == id }),
                  let index = actions.firstIndex(where: { $0.id == card.id }) else { continue }
            let outcome = approvalOutcome(approval, card: card)
            guard !outcome.unresolved else { continue }
            actions[index].state = .approvalResolved
            actions[index].detail = outcome.failure?.localizedDescription ?? outcome.words ?? approval.decisionSummary
            actions[index].updatedAt = Date()
            iCloudSyncEngine.shared.pageSessions.page("phone-mac-tools").settle(operation: card.operationID, outcome: outcome)
        }
        trimOrdinaryActions()
    }

    private func approvalOutcome(_ approval: ApprovalRequest, card: RemoteActionCard) -> FaceActOutcome {
        switch approval.outcome {
        case .denied, .expired:
            return .interrupted(WireFailure(code: "mac_control_approval_declined", message: approval.decisionSummary,
                cause: approval.executionSummary, effects: .none))
        case .approved where approval.executionOutcome == "succeeded":
            let committed: [FaceCommittedField]
            switch card.kind {
            case .notify: committed = [.init(id: "title", value: .string("")), .init(id: "message", value: .string(""))]
            case .volume(let percent): committed = [.init(id: "percent", value: .int(Int64(percent)))]
            case .spotlight(let query): committed = [.init(id: "query", value: .string(query))]
            }
            return .init(words: approval.executionSummary ?? "The approved Mac action completed.", effects: .known, accepted: true,
                committed: committed)
        case .approved where approval.executionOutcome == "refused":
            return .interrupted(WireFailure(code: "mac_control_approval_refused", message: approval.decisionSummary,
                cause: approval.executionSummary, effects: .none))
        default:
            return .init(words: approval.decisionSummary + "\n" + (approval.executionSummary ?? "The Mac has not confirmed execution."), effects: .unknown)
        }
    }

    private func trimOrdinaryActions() {
        var ordinaryCount = 0
        actions = actions.sorted { $0.updatedAt > $1.updatedAt }.filter { action in
            if [.waiting, .running, .waitingApproval, .unconfirmed].contains(action.state) { return true }
            ordinaryCount += 1
            return ordinaryCount <= maximumOrdinaryActions
        }
    }
}
