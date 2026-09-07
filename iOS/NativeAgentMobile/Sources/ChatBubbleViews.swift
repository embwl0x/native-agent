import SwiftUI
import UIKit
import NativeAgentShared

// MARK: - Bubble

struct BubbleView: View {
    let message: ChatMessage
    var streamingHint: String = "Typing"
    // Set when this assistant bubble timed out locally. The accessory resumes
    // observation of the same signed event; it never queues a second turn.
    var isTimedOut: Bool = false
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // Collapsed "N tools used" / "N skills used" summary above the
                // reply once the turn is done (assistant turns only).
                if message.role == .assistant, !message.isStreaming, !message.toolEvents.isEmpty {
                    ToolActivityView(events: message.toolEvents, isLive: false)
                        .padding(.leading, 4)
                }
                if message.isStreaming {
                    if !message.toolEvents.isEmpty, message.text.isEmpty {
                        // She's working through tools — flip through them in one box.
                        ToolActivityView(events: message.toolEvents, isLive: true)
                    } else {
                        HStack(spacing: 8) {
                            PulsingDot(color: NativeAgentPalette.agentAccent, size: 7)
                            Text(message.text.isEmpty ? streamingHint : message.text)
                                .font(AppFont.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 12)
                        .frame(minWidth: 150, maxWidth: 260, minHeight: 40, maxHeight: 40, alignment: .leading)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(NativeAgentPalette.agentAccent.opacity(0.18), lineWidth: 0.8)
                        }
                    }
                } else {
                    VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                        ForEach(imageAttachments) { attachment in
                            AttachmentImagePreview(summary: attachment)
                        }
                        if attachmentCountWithoutPreview > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.fill")
                                Text(attachmentCountWithoutPreview == 1 ? "1 attachment" : "\(attachmentCountWithoutPreview) attachments")
                            }
                            .font(AppFont.tag)
                            .foregroundStyle(message.role == .user ? .white.opacity(0.92) : .secondary)
                        }
                        if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.attachments.isEmpty {
                            Text(message.text.isEmpty ? " " : message.text)
                                .font(AppFont.body)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(
                        message.role == .user
                            ? AnyShapeStyle(NativeAgentPalette.agentGradient)
                            : AnyShapeStyle(Color(.systemGray5)),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(message.role == .user ? .white : .primary)
                }
                // A reply timeout is not proof that the Mac failed. Keep the
                // original correlation alive and let the user resume waiting.
                if isTimedOut, let onRetry {
                    Button(action: onRetry) {
                        Label("Keep waiting", systemImage: "clock.arrow.circlepath")
                            .font(AppFont.tag.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(NativeAgentPalette.agentAccent)
                    .padding(.leading, 4)
                    .accessibilityLabel("Keep waiting for this reply")
                }
            }
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var imageAttachments: [ChatAttachmentSummary] {
        ChatAttachmentPresentation.previewableImages(in: message.attachments)
    }

    private var attachmentCountWithoutPreview: Int {
        ChatAttachmentPresentation.fallbackCount(in: message.attachments)
    }
}

private struct AttachmentImagePreview: View {
    let summary: ChatAttachmentSummary

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
                .accessibilityLabel(summary.name)
        }
    }

    private var image: UIImage? {
        guard let raw = summary.base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = Data(base64Encoded: raw) else {
            return nil
        }
        return UIImage(data: data)
    }
}

// MARK: - Inline chat approvals
//
// Sweep 2026-09-01 item 36. The Mac renders the approval a turn is waiting on
// straight onto that turn's card (MacChatTurnApproval); iOS had zero approval
// references in the whole chat surface, so the phone's only answer to "she is
// blocked on you" was to switch to the Activity tab and hunt for the row.
//
// This adds no store and no authority. It is a pure projection over the
// approvals `iCloudSyncEngine` already publishes, plus a card that dispatches
// through the SAME signed `approveApproval` / `rejectApproval` action the
// Activity tab uses. Activity → Approvals stays the canonical list.

enum MobileChatApprovalProjection {
    /// Approvals this conversation raised and nobody has answered yet.
    ///
    /// Two fences, both evidence-based:
    ///
    /// 1. **Session.** The row must carry this chat's origin session id. An
    ///    approval with no chat origin (a Workshop step, a memory proposal) is
    ///    not a chat approval and never enters a chat bubble.
    /// 2. **Undecided.** Only a pending row is a live question. A decided or
    ///    unreadable row is finished business and belongs to Activity, which
    ///    can show its outcome honestly; a bubble cannot.
    static func pendingApprovals(
        sessionId: String?,
        approvals: [ApprovalRequest]
    ) -> [ApprovalRequest] {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else { return [] }
        return approvals.filter {
            $0.chatOriginSessionId == sessionId
                && $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
                && $0.decision == nil
        }
    }

    /// The turn an inline approval hangs under.
    ///
    /// The Mac fences an approval to a turn by comparing the row's `createdAt`
    /// against that turn's start. The iOS transcript carries no per-message
    /// timestamp at all, so the phone cannot prove which *earlier* turn raised
    /// a given row. The one turn it can prove is the newest assistant turn —
    /// the one in flight or just finished — so the card anchors there and
    /// nowhere else rather than guessing at a bubble it cannot substantiate.
    static func anchorMessageID(in messages: [ChatMessage]) -> UUID? {
        messages.last(where: { $0.role == .assistant })?.id ?? messages.last?.id
    }

    /// A partial approval record must never unlock a remote decision. Same
    /// rule the Activity tab applies — one predicate, one meaning.
    static func canDecideOnPhone(_ approval: ApprovalRequest) -> Bool {
        ActivityScreenPresentation.canDecideRemotely(
            localOnly: approval.localOnly,
            remoteResolvable: approval.remoteResolvable
        )
    }
}

/// One pending approval, rendered on the turn that raised it. Approve / Deny
/// go through `iCloudSyncEngine`'s signed action channel; "In Activity" hands
/// the user to the canonical queue via the existing open-activity intent.
struct InlineChatApprovalCard: View {
    let approval: ApprovalRequest

    @State private var isDeciding = false
    @State private var decisionStatusText: String?
    @State private var decisionStatusIsError = false

    private var canDecide: Bool { MobileChatApprovalProjection.canDecideOnPhone(approval) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs approval")
                        .font(AppFont.section)
                    Text(approval.title.isEmpty ? approval.action : approval.title)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(approval.risk.uppercased())
                    .font(AppFont.tag)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let decisionStatusText {
                Text(decisionStatusText)
                    .font(.caption)
                    .foregroundStyle(decisionStatusIsError ? .red : .orange)
            }
            if !canDecide {
                Label("Review this one on the Mac app", systemImage: "macwindow.badge.exclamationmark")
                    .font(AppFont.label)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if canDecide {
                    Button {
                        decide(approve: true)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(isDeciding)

                    Button {
                        decide(approve: false)
                    } label: {
                        Label("Deny", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(isDeciding)
                }
                Button {
                    NotificationCenter.default.post(
                        name: .nativeagentOpenActivity,
                        object: nil,
                        userInfo: ["screen": "approvals"]
                    )
                } label: {
                    Label("In Activity", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDeciding)

                if isDeciding {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed for \(approval.title.isEmpty ? approval.action : approval.title)")
    }

    private func decide(approve: Bool) {
        isDeciding = true
        decisionStatusText = nil
        decisionStatusIsError = false
        let id = approval.id
        Task { @MainActor in
            do {
                if approve {
                    _ = try await iCloudSyncEngine.shared.approveApproval(id: id)
                    iOSSystemToastCenter.shared.push(success: "Approval approved")
                } else {
                    _ = try await iCloudSyncEngine.shared.rejectApproval(id: id)
                    iOSSystemToastCenter.shared.push(info: "Approval denied")
                }
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
            } catch {
                // A timeout proves only that the phone did not see the answer.
                // Never claim the decision landed.
                decisionStatusIsError = !iCloudSyncEngine.isMacResponseTimeout(error)
                decisionStatusText = iCloudSyncEngine.isMacResponseTimeout(error)
                    ? "Decision sent; waiting for the Mac to publish the result."
                    : error.localizedDescription
            }
            isDeciding = false
        }
    }
}

// MARK: - Tool / skill activity (flip-box + collapsed summary)

/// iOS counterpart to the Mac `ToolCallGroup`. While she's working, `isLive`
/// shows ONE box that flips through tools as they fire. When done, it collapses
/// to "N tools used" / "N skills used" rows, each tappable to expand the names.
struct ToolActivityView: View {
    let events: [ToolEvent]
    let isLive: Bool
    @State private var toolsExpanded = false
    @State private var skillsExpanded = false

    // Skill use is a shared remote-surface presentation taxonomy. The Mac
    // dispatcher catalog remains executable authority; its parity eval keeps
    // this compact iOS projection in lockstep as names evolve.
    private func isSkill(_ e: ToolEvent) -> Bool {
        ToolActivityPresentation.isSkillReaderTool(named: e.name)
    }

    private var ordered: [ToolEvent] { events.sorted { $0.seq < $1.seq } }
    private var skills: [ToolEvent] { ordered.filter(isSkill) }
    private var tools: [ToolEvent] { ordered.filter { !isSkill($0) } }
    private var latest: ToolEvent? { events.max(by: { $0.seq < $1.seq }) }

    var body: some View {
        if isLive { liveBox } else { collapsed }
    }

    private var liveBox: some View {
        HStack(spacing: 8) {
            PulsingDot(color: NativeAgentPalette.agentAccent, size: 7)
            Group {
                if let latest {
                    Text(latest.name)
                        .id(latest.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            .font(AppFont.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 150, maxWidth: 260, minHeight: 40, maxHeight: 40, alignment: .leading)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(NativeAgentPalette.agentAccent.opacity(0.18), lineWidth: 0.8)
        }
        .animation(.easeOut(duration: 0.22), value: latest?.id)
    }

    private var collapsed: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !tools.isEmpty {
                summaryRow(items: tools, noun: "tool",
                           icon: "wrench.and.screwdriver", expanded: $toolsExpanded)
            }
            if !skills.isEmpty {
                summaryRow(items: skills, noun: "skill",
                           icon: "text.book.closed", expanded: $skillsExpanded)
            }
        }
    }

    @ViewBuilder
    private func summaryRow(items: [ToolEvent], noun: String, icon: String,
                            expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                    Text("\(items.count) \(noun)\(items.count == 1 ? "" : "s") used")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue {
                ForEach(items) { e in
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.caption2).foregroundStyle(.tertiary)
                        Text(e.name).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }
}
