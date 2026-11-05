import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `ChatBubbleViews.swift` | Inline approvals in the conversation: which are pending here, and the card that decides one |

// MARK: - Inline chat approvals
// Mac-selected turn IDs bind approvals to transcript provenance using exact session and request time relative to turn start.

enum ConversationApprovals {
    /// Approvals may outlive their turn linkage, so unresolved decisions remain reachable in this conversation.
    static func pendingApprovals(
        sessionId: String?,
        approvals: [ApprovalRequest]
    ) -> [ApprovalRequest] {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else { return [] }
        return approvals.filter {
            $0.chatOriginSessionId == sessionId
                && ($0.outcome == .pending || $0.outcome == .unresolved || $0.executionFailed || $0.isExpired)
        }
    }

    /// Failed and expired outcomes belong beside their turn; they must not appear as decisions still owed.
    static func waitsOnYou(_ approval: ApprovalRequest) -> Bool {
        approval.outcome == .pending
    }

    static func canDecideOnPhone(_ approval: ApprovalRequest) -> Bool {
        ActivityScreenPresentation.canDecideRemotely(action: approval.action)
    }
}

struct InlineChatApprovalCard: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var approvalsStore: ApprovalsStore
    @ObservedObject private var bridge = iCloudBridge.shared
    let approval: ApprovalRequest

    private var isDeciding: Bool { approvalsStore.decidingApprovalIDs.contains(approval.id) }
    @State private var decisionStatusText: String?
    @State private var decisionStatusIsError = false

    private var canDecide: Bool { ConversationApprovals.canDecideOnPhone(approval) }
    private var pending: Bool { approval.outcome == .pending }

    private var canSendDecision: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.deviceIsOffline != true
    }

    private var riskWords: String? {
        switch approval.risk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "low", "none": return nil
        case let risk: return "\(risk.capitalized) risk"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if pending { AliveStatusDot(state: .waiting).scaleEffect(0.75) }
                Text(pending ? (canDecide ? "I need your OK" : "\(iCloudSyncEngine.shared.agentDisplayName)’s decision") : approval.decisionSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AlivePalette.secondary)
                if let riskWords {
                    Text("· \(riskWords)")
                        .font(.caption)
                        .foregroundStyle(AlivePalette.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(ApprovalText.title(approval))
                .font(.body.weight(.semibold))
                .foregroundStyle(AlivePalette.text)
                .lineLimit(2)
            if let reason = ApprovalText.reason(approval), !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PayloadPreview(approval: approval, maxLines: 4)
            if let summary = approval.expirationGuidance(agentName: iCloudSyncEngine.shared.agentDisplayName) ?? approval.executionSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            }
            if let decisionStatusText {
                Text(decisionStatusText)
                    .font(.footnote)
                    .foregroundStyle(decisionStatusIsError ? Color.red : AlivePalette.secondary)
            }
            if pending && !canDecide {
                Text(ApprovalText.agentDecision)
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            }
            HStack(spacing: 10) {
                if pending && canDecide {
                    Button {
                        decide(approve: true)
                    } label: {
                        Text("Approve")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 30)
                            .fixedSize()
                    }
                    .alivePrimaryButton()
                    .disabled(isDeciding || !canSendDecision)

                    Button {
                        decide(approve: false)
                    } label: {
                        Text("Deny")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 30)
                            .fixedSize()
                    }
                    .aliveSecondaryButton()
                    .disabled(isDeciding || !canSendDecision)
                }
                if isDeciding {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button {
                    NativeAgentNotificationLaunchIntent.stage(screen: "approvals")
                    NotificationCenter.default.post(
                        name: .nativeagentOpenActivity,
                        object: nil,
                        userInfo: ["screen": "approvals"]
                    )
                } label: {
                    Text("In Activity")
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDeciding)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        // roomColumn already bounds transcript width; do not add another cap.
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard(radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pending ? "Approval needed" : approval.decisionSummary) for \(ApprovalText.title(approval))")
    }

    private func decide(approve: Bool) {
        guard pending, canDecide, canSendDecision, !isDeciding else { return }
        #if DEBUG
        // The -chatSampleExtras fixture is for screenshots only; never send it.
        if approval.id == "sample-approval" { return }
        #endif
        decisionStatusText = nil
        decisionStatusIsError = false
        let id = approval.id
        Task { @MainActor in
            do {
                guard let result = await approvalsStore.decide(id: id, decision: approve ? .approve : .reject,
                    pairingStore: pairingStore) else { return }
                try result.get()
                if approve {
                    SystemToastCenter.shared.push(success: "Approval approved")
                } else {
                    SystemToastCenter.shared.push(info: "Approval denied")
                }
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
            } catch {
                if case SyncError.responseUnconfirmed = error {
                    decisionStatusIsError = false
                    decisionStatusText = "Decision sent; waiting for the Mac to publish the result."
                } else {
                    decisionStatusIsError = true
                    decisionStatusText = error.localizedDescription
                }
            }
        }
    }
}
