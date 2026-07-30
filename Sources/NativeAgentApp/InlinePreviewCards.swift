// Move-only extraction (tightness Wave C) from SidebarFlattenViews.swift

import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore

// MARK: - Inline preview cards

/// Compact approval card with Approve / Deny / View. Mirrors
/// `ApprovalRequestPanel` styling but is sized for an inline preview.
struct InlineApprovalPreviewCard: View {
    @Environment(AppModel.self) private var appModel
    let approval: ApprovalRequest
    var onView: () -> Void

    @State private var isDeciding = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.title.isEmpty ? approval.action : approval.title)
                        .font(NativeAgentFont.section)
                        .lineLimit(1)
                    Text(approval.action)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusBadge(text: approval.risk, status: approval.risk)
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(NativeAgentFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: NativeAgentSpacing.sm) {
                Button {
                    decide("approved")
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
                .disabled(isDeciding)

                Button {
                    decide("denied")
                } label: {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(isDeciding)

                Button {
                    onView()
                } label: {
                    Label("View", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDeciding)

                if isDeciding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.vertical, NativeAgentSpacing.sm)
    }

    private func decide(_ decision: String) {
        isDeciding = true
        errorText = nil
        let id = approval.id
        Task {
            do {
                _ = try await appModel.resolveApproval(id: id, decision: decision)
                if decision == "approved" {
                    await MainActor.run {
                        appModel.systemToasts.push(success: "Approval approved")
                    }
                } else {
                    await MainActor.run {
                        appModel.systemToasts.push(info: "Approval denied")
                    }
                }
                // Refresh the approvals list + health card so the inline
                // preview disappears once the decision lands.
                if let refreshed = try? await appModel.getApprovals() {
                    await MainActor.run { appModel.approvals = refreshed }
                }
                await appModel.loadHealthCard()
            } catch {
                await MainActor.run {
                    errorText = "Failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run { isDeciding = false }
        }
    }
}

/// Compact inbox card with the item's top two non-`view` actions plus a
/// "More →" button that drills into the InboxView for the full surface.
struct InlineInboxPreviewCard: View {
    @Environment(AppModel.self) private var appModel
    let item: InboxItemRecord
    let nativeBaseURL: String
    var onMore: () -> Void

    @State private var runningActionID: String?
    @State private var errorText: String?

    private var topActions: [InboxActionRecord] {
        item.effectiveActions
            .filter { $0.id != "view" && $0.id != "read" }
            .prefix(2)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.sourceIcon)
                    .foregroundStyle(item.severityColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NativeAgentFont.section)
                        .lineLimit(1)
                    Text(item.sourceBadgeLabel)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(item.severityColor)
                }
                Spacer()
                Text(item.severity.uppercased())
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.severityColor, in: Capsule())
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(NativeAgentFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: NativeAgentSpacing.sm) {
                ForEach(topActions, id: \.id) { action in
                    if isPrimary(action.id) {
                        Button {
                            runAction(action.id)
                        } label: {
                            Text(action.label)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.blue)
                        .disabled(runningActionID != nil)
                    } else {
                        Button {
                            runAction(action.id)
                        } label: {
                            Text(action.label)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(runningActionID != nil)
                    }
                }
                Button {
                    onMore()
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(runningActionID != nil)

                if runningActionID != nil {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.vertical, NativeAgentSpacing.sm)
    }

    private func isPrimary(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

    private func runAction(_ actionID: String) {
        runningActionID = actionID
        errorText = nil
        let id = item.id
        Task {
            do {
                try await appModel.inboxAction(id, action: actionID)
            } catch {
                await MainActor.run {
                    errorText = "Action failed: \(error.localizedDescription)"
                    runningActionID = nil
                }
                return
            }
            // Refresh inbox so the preview drops the resolved item.
            if let refreshed = try? await appModel.getInboxItems(unreadOnly: false) {
                await MainActor.run { appModel.inboxItems = refreshed }
            }
            // gpt-5.5 review #3: mirror InboxView's behavior — write the
            // iCloud snapshot after non-`read` actions so the iOS companion
            // doesn't keep showing the stale item until the next sync cycle.
            if actionID != "read" {
                await MacSyncEngine.shared.writeSnapshots()
            }
            await MainActor.run { runningActionID = nil }
        }
    }
}

/// Compact memory-proposal card with Accept / Reject. Calls the same
/// AppModel methods as MemoryProposalReviewPanel.
struct InlineMemoryProposalPreviewCard: View {
    @Environment(AppModel.self) private var appModel
    let proposal: MemoryProposalRecord

    @State private var isDeciding = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory proposal")
                        .font(NativeAgentFont.section)
                    Text(proposal.evidenceSummary)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(proposal.display_text ?? proposal.fact_text)
                .font(NativeAgentFont.body)
                .lineLimit(3)
                .textSelection(.enabled)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: NativeAgentSpacing.sm) {
                Button {
                    decide(approve: true)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.indigo)
                .disabled(isDeciding)

                Button {
                    decide(approve: false)
                } label: {
                    Label("Reject", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(isDeciding)

                if isDeciding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.vertical, NativeAgentSpacing.sm)
    }

    private func decide(approve: Bool) {
        isDeciding = true
        errorText = nil
        let id = proposal.proposal_id
        Task {
            do {
                if approve {
                    _ = try await appModel.approveMemoryProposal(id: id)
                } else {
                    _ = try await appModel.rejectMemoryProposal(id: id, reason: "")
                }
            } catch {
                await MainActor.run {
                    errorText = "Failed: \(error.localizedDescription)"
                    isDeciding = false
                }
                return
            }
            await MainActor.run { isDeciding = false }
        }
    }
}

/// Compact self-improvement card. View-only — actual approve/reject lives in
/// the SelfImprovementView surface because the proposal types fan out into
/// multiple buckets (training, promotion candidates) and the decisions need
/// the full context to be safe.
struct InlineSelfImprovementPreviewCard: View {
    let title: String
    let summary: String
    let tint: Color
    var onView: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(tint)
                Text(title)
                    .font(NativeAgentFont.section)
                    .lineLimit(1)
                Spacer()
            }
            Text(summary)
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: NativeAgentSpacing.sm) {
                Button {
                    onView()
                } label: {
                    Label("View", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.vertical, NativeAgentSpacing.sm)
    }
}
