import SwiftUI
import UIKit
import NativeAgentShared
import QuickLook
// Blueprint: | `ChatBubbleViews.swift` | Reply and attachment rendering, inline approvals and tool activity |

// MARK: - Bubble

struct BubbleView: View, Equatable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ChatMessage
    var streamingHint: String = "Typing"
    /// A turn another door (the Mac, Telegram) is streaming into this chat.
    /// It paces like her own live reply until its saved answer lands.
    var isLiveTurn = false
    var cardsAvailable = true
    @State private var images: [(summary: ChatAttachmentSummary, image: UIImage)] = []
    @State private var attachmentCountWithoutPreview = 0
    @State private var audioPreview: URL?
    @State private var audioError: String?
    /// How much of the text the paced reveal had caught up with when it last
    /// rested; nil when this bubble never paced (a reply loaded settled).
    @State private var revealedBytes: Int?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.streamingHint == rhs.streamingHint
            && lhs.isLiveTurn == rhs.isLiveTurn
            && lhs.cardsAvailable == rhs.cardsAvailable
    }

    /// The Mac Simple thread: the agent's words are plain large text with
    /// room between the lines, no bubble; the person's own lines are quieter
    /// and smaller, on the same left edge.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if cardsAvailable, let card = message.interaction, let descriptor = message.interactionDescriptor,
                   let session = message.interactionSessionID {
                    MobileInteractionCard(card: card, descriptor: descriptor, sessionID: session)
                }
                ForEach(images, id: \.summary.id) { attachment in
                    AttachmentImagePreview(summary: attachment.summary, image: attachment.image)
                }
                ForEach(message.attachments.filter {
                    $0.type == "audio" && ($0.base64 != nil || $0.utterance?.audioReference == "iphone-recording:\($0.id)")
                }) { attachment in
                    Button("Play recording", systemImage: "waveform") {
                        Task {
                            do {
                                audioPreview = try await Task.detached(priority: .utility) {
                                    if let raw = attachment.base64 {
                                        let recording = MultimodalAttachment(id: attachment.id, type: "audio", base64: raw,
                                            mime: attachment.mime ?? "audio/x-caf")
                                        return try MobileLocalStorage.retainRecording(recording)
                                    }
                                    let url = try MobileLocalStorage.recordingURL(id: attachment.id)
                                    _ = try url.checkResourceIsReachable()
                                    return url
                                }.value
                                audioError = nil
                            } catch { audioError = error.localizedDescription }
                        }
                    }
                }
                if let audioError { Text(audioError).foregroundStyle(.secondary) }
                if attachmentCountWithoutPreview > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.fill")
                        Text(attachmentCountWithoutPreview == 1 ? "1 attachment" : "\(attachmentCountWithoutPreview) attachments")
                    }
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                }
                if message.interaction == nil && (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.attachments.isEmpty) {
                    // One view from the wait to the settled reply: the hint
                    // crossfades to the first paced words, and the streamed
                    // text crossfades to markdown. The stack takes the
                    // incoming phase's size, so nothing stacks while it fades.
                    ChatCrossfadeStack(current: phase) {
                        if phase == 0 {
                            waitingHint
                                .layoutValue(key: ChatCrossfadePhase.self, value: 0)
                                .transition(.opacity)
                        }
                        if phase == 2 {
                            PreparedChatMarkdownView(content: message.text)
                                .layoutValue(key: ChatCrossfadePhase.self, value: 2)
                                .transition(.opacity)
                        } else {
                            plainText
                                .layoutValue(key: ChatCrossfadePhase.self, value: 1)
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: phase)
                }
            }
            if message.role == .assistant, message.completionState == "failed" || message.failureDetail != nil {
                AliveStatusNote(systemImage: "exclamationmark.circle",
                    text: message.failureDetail.map { "Interrupted · \($0)" } ?? "Interrupted")
            }
            // Collapsed "Used N tools" summary sits BELOW the reply once the
            // turn is done, so it never pushes the text down at finish.
            if message.role == .assistant, !message.isStreaming, !message.toolEvents.isEmpty {
                ToolActivityView(events: message.toolEvents, isLive: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, isUser && !dynamicTypeSize.isAccessibilitySize ? 24 : 0)
        .quickLookPreview($audioPreview)
        .task(id: message.attachments) {
            let prepared = await ChatAttachmentPresentation.shared.images(in: message.attachments)
            guard !Task.isCancelled else { return }
            images = prepared
            attachmentCountWithoutPreview = message.attachments.count - prepared.count
        }
    }

    /// 0 waiting for the first words, 1 plain (the live reply, the person's
    /// own lines), 2 a settled reply as markdown.
    private var phase: Int {
        if message.isStreaming || isLiveTurn { return message.text.isEmpty ? 0 : 1 }
        // BubbleView keeps the paced reveal until it catches up, then presents settled markdown.
        if let revealed = revealedBytes, revealed < message.text.utf8.count { return 1 }
        return message.role == .assistant && !message.text.isEmpty ? 2 : 1
    }

    @ViewBuilder
    private var waitingHint: some View {
        if !message.toolEvents.isEmpty {
            // Working through tools — flip through them in one line.
            ToolActivityView(events: message.toolEvents, isLive: true)
        } else {
            HStack(spacing: 10) {
                HazePulse()
                Text(streamingHint)
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(AlivePalette.secondary)
            }
            .frame(minHeight: 32, alignment: .leading)
        }
    }

    /// Her reply streams through the paced reveal (about 80 words a second,
    /// the newest words fading in, finished paragraphs left alone); it is
    /// mounted from the wait on, so the first batch paces too. The person's
    /// own lines are plain text.
    @ViewBuilder
    private var plainText: some View {
        Group {
            if isUser {
                Text(message.text.isEmpty ? " " : message.text)
            } else {
                // The phone's ~1 s batches carry up to ~1,200 characters (up to 4 bytes each).
                PacedStreamingText(text: message.text, maxLagBytes: 4_800, inline: ChatInlineMarkdown(MobileChatMarkdown.inline),
                                   onCaughtUp: { revealedBytes = message.text.utf8.count })
            }
        }
        .font(isUser ? .subheadline : .body)
        .lineSpacing(isUser ? 3 : 6)
        .foregroundStyle(isUser ? AlivePalette.ownLine : AlivePalette.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isUser: Bool { message.role == .user }

}

private struct AttachmentImagePreview: View {
    let summary: ChatAttachmentSummary
    let image: UIImage

    var body: some View {
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

// MARK: - Inline chat approvals
//
// The Mac selects an approval by exact session and request time relative to
// its turn start (lastRequestedAt, or createdAt for a first request). Its
// published turn ID links that selection to transcript provenance on the phone.

enum ConversationApprovals {
    /// Questions, uncertain decisions, expirations and failed executions in this conversation.
    /// Approvals can outlive the turn linkage used to place their cards.
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

    /// A decision still owed. Failed and expired outcomes are history: they
    /// show beside their turn, never pinned to the bottom as waiting on you.
    static func waitsOnYou(_ approval: ApprovalRequest) -> Bool {
        approval.outcome == .pending
    }

    /// Same decision ownership as Activity and the Approvals screen.
    static func canDecideOnPhone(_ approval: ApprovalRequest) -> Bool {
        ActivityScreenPresentation.canDecideRemotely(action: approval.action)
    }
}

/// One Mac-selected turn approval. Approve / Deny
/// go through `ApprovalsStore`; "In Activity" hands
/// the user to the canonical queue via the existing open-activity intent.
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
            // What will be sent, in plain lines, before Approve.
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
        // The transcript column already caps the readable width (roomColumn).
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
                    Text(latest.activity ?? Self.plainName(latest.name))
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
                        Text(e.outcome.map { ToolActivityPresentation.finished(e.name, outcome: $0, detail: e.resultDetail) }
                             ?? Self.plainName(e.name))
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
