import SwiftUI
import UIKit
import NativeAgentShared

// MARK: - Bubble

struct BubbleView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let message: ChatMessage
    var streamingHint: String = "Typing"
    // Set when this assistant bubble timed out locally. The accessory resumes
    // observation of the same signed event; it never queues a second turn.
    var isTimedOut: Bool = false
    var onRetry: (() -> Void)? = nil

    /// The Mac Simple thread: the agent's words are plain large text with
    /// room between the lines, no bubble; the person's own lines are quieter
    /// and smaller, on the same left edge.
    var body: some View {
        let isUser = message.role == .user
        VStack(alignment: .leading, spacing: 6) {
            // Collapsed "N tools used" / "N skills used" summary above the
            // reply once the turn is done (assistant turns only).
            if message.role == .assistant, !message.isStreaming, !message.toolEvents.isEmpty {
                ToolActivityView(events: message.toolEvents, isLive: false)
            }
            if message.isStreaming {
                if !message.toolEvents.isEmpty, message.text.isEmpty {
                    // Working through tools — flip through them in one line.
                    ToolActivityView(events: message.toolEvents, isLive: true)
                } else if message.text.isEmpty {
                    HStack(spacing: 10) {
                        HazePulse()
                        Text(streamingHint)
                            .mobileTypography(.body)
                            .foregroundStyle(AlivePalette.secondary)
                    }
                    .frame(minHeight: 32, alignment: .leading)
                } else {
                    Text(message.text)
                        .mobileTypography(.body)
                        .lineSpacing(6)
                        .foregroundStyle(AlivePalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(imageAttachments) { attachment in
                        AttachmentImagePreview(summary: attachment)
                    }
                    if attachmentCountWithoutPreview > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.fill")
                            Text(attachmentCountWithoutPreview == 1 ? "1 attachment" : "\(attachmentCountWithoutPreview) attachments")
                        }
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                    }
                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.attachments.isEmpty {
                        Text(message.text.isEmpty ? " " : message.text)
                            .font(isUser ? .subheadline : .body)
                            .lineSpacing(isUser ? 3 : 6)
                            .foregroundStyle(isUser ? AlivePalette.secondary : AlivePalette.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // 2026-09-13: "Keep waiting" is gone. Waiting is no longer
            // something the person has to ask for — the phone never stops
            // observing the request it already sent, so there is nothing
            // here to press.
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, isUser && !dynamicTypeSize.isAccessibilitySize ? 24 : 0)
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

    /// Same decision ownership as Activity and the Approvals screen.
    static func canDecideOnPhone(_ approval: ApprovalRequest) -> Bool {
        ActivityScreenPresentation.canDecideRemotely(action: approval.action)
    }
}

/// One pending approval, rendered on the turn that raised it. Approve / Deny
/// go through `iCloudSyncEngine`'s signed action channel; "In Activity" hands
/// the user to the canonical queue via the existing open-activity intent.
struct InlineChatApprovalCard: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var bridge = iCloudBridge.shared
    let approval: ApprovalRequest

    @State private var isDeciding = false
    @State private var decisionStatusText: String?
    @State private var decisionStatusIsError = false

    private var canDecide: Bool { MobileChatApprovalProjection.canDecideOnPhone(approval) }

    private var canSendDecision: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.bridgeStatus != .deviceOffline
    }

    /// Plain words for the risk the Mac assigned, shown only when it is worth
    /// a second look.
    private var riskWords: String? {
        switch approval.risk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "low", "none": return nil
        case let risk: return "\(risk.capitalized) risk"
        }
    }

    /// The approval sits in the thread as content: a card with the "needs
    /// you" light, the question in the agent's words, and two answers.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AliveStatusDot(state: .waiting)
                    .scaleEffect(0.75)
                Text(canDecide ? "I need your OK" : "Agent’s decision")
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
            // What will be sent, in plain lines, before Approve.
            PayloadPreview(approval: approval, maxLines: 4)
            if let decisionStatusText {
                Text(decisionStatusText)
                    .font(.footnote)
                    .foregroundStyle(decisionStatusIsError ? Color.red : AlivePalette.secondary)
            }
            if !canDecide {
                Text(ApprovalText.agentDecision)
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            }
            HStack(spacing: 10) {
                if canDecide {
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
        .frame(maxWidth: 620, alignment: .leading)
        .aliveCard(radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed for \(ApprovalText.title(approval))")
    }

    private func decide(approve: Bool) {
        guard canDecide, canSendDecision, !isDeciding else { return }
        #if DEBUG
        // The -chatSampleExtras fixture is for screenshots only; never send it.
        if approval.id == "sample-approval" { return }
        #endif
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
            HazePulse()
            Group {
                if let latest {
                    Text(Self.plainName(latest.name))
                        .id(latest.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            .font(AppFont.body)
            .foregroundStyle(AlivePalette.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 150, maxWidth: 300, minHeight: 32, maxHeight: 32, alignment: .leading)
        .animation(.easeOut(duration: 0.22), value: latest?.id)
    }

    private var collapsed: some View {
        HStack(alignment: .top, spacing: 16) {
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

    /// The same friendly tool phrases as Mac and Telegram.
    static func plainName(_ raw: String) -> String {
        ToolActivityPresentation.title(raw)
    }

    /// "Used 3 tools ›": one quiet line; tap to see which.
    @ViewBuilder
    private func summaryRow(items: [ToolEvent], noun: String, icon: String,
                            expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text("Used " + AliveWords.count(items.count, noun))
                        .font(.footnote)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                }
                .foregroundStyle(AlivePalette.secondary)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { e in
                        Text(Self.plainName(e.name))
                            .font(.footnote)
                            .foregroundStyle(AlivePalette.secondary)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AlivePalette.divider).frame(width: 1)
                }
            }
        }
    }
}
