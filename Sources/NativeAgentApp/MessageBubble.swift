import Foundation
import EngineRuntime
import MultimodalTTS
import Transcripts
import SwiftUI
import AppKit
import NativeAgentShared
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import NativeAgentCore
import ToolExecution
import MemoryV2
import AppToolRuntime
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import TrustCenter
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import StandingBots
import ApprovalInbox
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
import Desk
// Blueprint: | `MessageBubble.swift` | Transcript message bubbles, provenance, streaming settlement, hover and accessible actions |

enum ChatTranscriptPresentation {
    static func hasVisibleText(_ text: some StringProtocol) -> Bool {
        text.contains { !$0.isWhitespace }
    }
}

struct MessageBubble: View {
    var message: ChatMessage
    /// Whether this is the last assistant message in the list (enables Regenerate action)
    var isLastAssistant: Bool = false

    /// Compare every drawn field, including provenance and failure state.
    /// Tool-only metadata belongs to the tool row and does not redraw prose.
    nonisolated static func drawsTheSame(_ l: ChatMessage, _ r: ChatMessage) -> Bool {
        guard l.id == r.id,
              l.role == r.role,
              l.createdAt == r.createdAt,
              l.sessionId == r.sessionId,
              l.source == r.source,
              l.content == r.content
        else { return false }
        guard let lm = l.metadata else { return r.metadata == nil }
        guard let rm = r.metadata else { return false }
        return lm.origin == rm.origin
            && lm.error == rm.error
            && lm.partial == rm.partial
            && lm.cancelled == rm.cancelled
            && lm.model == rm.model
            && lm.requestedModel == rm.requestedModel
            && lm.reasoningEffort == rm.reasoningEffort
            && lm.fileAccessMode == rm.fileAccessMode
            && lm.attachments == rm.attachments
            && lm.workingCommentaryChars == rm.workingCommentaryChars
            && lm.providerRefusal == rm.providerRefusal
            && lm.providerRefusalDraft == rm.providerRefusalDraft
            && lm.envelope == rm.envelope
    }

    /// The mind a reply ran on — model / effort / access — said on hover
    /// beside its time, never in the reading line.
    /// Each recorded field stands on its own; a model that was only asked
    /// for says so rather than passing as the one that ran.
    nonisolated static func brainLine(_ metadata: ChatMessageMetadata?) -> String? {
        guard let metadata else { return nil }
        let model = metadata.model ?? metadata.requestedModel.map { "requested \($0)" }
        let fields = [model, metadata.reasoningEffort, metadata.fileAccessMode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return fields.isEmpty ? nil : fields.joined(separator: " / ")
    }

    @State private var voiceOutput = VoiceOutputController.sharedMessagePlayback
    @Environment(AppModel.self) private var appModel
    /// True in the offscreen copy a quiet page read mounts. Nothing here is on
    /// anybody's screen, so nothing here may claim a render the person made.
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @Environment(\.troubleCardOwnsRetry) private var troubleCardOwnsRetry
    @Environment(\.readingPlace) private var readingPlace
    /// Set when a retry of this failed turn could repeat a real action.
    @State private var retryConfirmation: ChatTurnFailure?
    @State private var showJSONSheet = false
    @State private var bubbleToast: String? = nil
    @State private var isHovered = false
    /// The hover bar hangs below the row's own frame, so the pointer on it is
    /// tracked separately.
    @State private var isBarHovered = false
    private var showsHoverBar: Bool { isHovered || isBarHovered }
    /// Working commentary starts folded unless the reader is in this reply at settlement.
    @State private var commentaryExpanded = false
    /// Holds the stream for one frame so settlement can swap in an animated transaction.
    @State private var holdsLive = false
    /// Text length the paced reveal last came to rest at: the stream settles
    /// only once every word has been shown, so no tail pops in at the end.
    @State private var revealedLength = -1

    /// Only the last assistant row of its own nonterminal streaming session is live.
    private var isLiveReply: Bool {
        guard isLastAssistant, message.role == "assistant" else { return false }
        let sessionId = message.sessionId ?? appModel.activeChatSessionId
        let turns = appModel.engine.turns
        // The live reply is the turn's own row. When a turn starts, the
        // previous reply is still the last one for a moment; it must not flip
        // into the typing view, collapse and re-reveal.
        if let live = turns.streamingBubbleIds[sessionId], live != message.id { return false }
        return turns.isStreaming(sessionId)
            && turns.lifecycle(for: sessionId)?.presentation.isTerminal != true
    }

    private var normalizedRole: String {
        message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var isUser: Bool { normalizedRole == "user" }
    private var speechOwnerID: String {
        "message:\(message.sessionId ?? "unknown"):\(message.id)"
    }
    private var isReadingThisMessage: Bool {
        voiceOutput.isSpeaking(ownerID: speechOwnerID)
    }

    private var messageProvenance: MacChatMessageProvenance? {
        MacChatMessageProvenance.make(
            role: message.role,
            source: message.source,
            origin: message.metadata?.origin
        )
    }
    private var userCorners: RectangleCornerRadii { NativeAgentShellLayout.userBubbleCorners }

    /// Recorded provenance authorizes bridge presentation; quoted routing prefixes confer no origin.
    private var isBridgeRouted: Bool {
        ChatShellConversationRow.isBridgeRouted(message.metadata?.origin)
    }

    private var isPeerBridgeMessage: Bool {
        // Peers and helpers both speak in the person's seat only by transport.
        isUser && ["agent-bridge", "bot"].contains(message.metadata?.origin?.surface?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    private var bridgeTag: String? {
        guard isUser, isBridgeRouted, !isPeerBridgeMessage else { return nil }
        return ChatShellConversationRow.bridgeAgentTag(message.content)
    }

    private var isBridgeMessage: Bool { bridgeTag != nil || isPeerBridgeMessage }

    /// Which side of the room this message sits on. Only the human's own
    /// words take the right.
    private var seatsRight: Bool { isUser && !isBridgeMessage }

    /// A bridge message renders on the left and QUIETER than her replies:
    /// smaller, secondary, and with no bubble behind it, so it reads as
    /// traffic passing through the room rather than as either voice in it.
    private var isQuietBridge: Bool { isBridgeMessage }

    private var displayContent: String {
        TranscriptSearch.visibleText(of: message)
    }

    var body: some View {
        // Fold completion envelopes only for recorded bridge origins, never for a person's quoted prefix.
        if isUser, isBridgeRouted, ChatShellEnvelope.isEnvelope(message.content, envelope: message.metadata?.envelope) {
            ShellEnvelopeRow(content: message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            bubbleBody
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        let _ = RenderAudit.bump("bubble.body")
        // Partition attachments once per bubble pass; visible-text checks avoid copying the growing reply.
        let attachments = ChatAttachmentPresentation.partition(
            message.metadata?.attachments ?? []
        )
        let hasVisibleContent = ChatTranscriptPresentation.hasVisibleText(displayContent)
        let timestamp = UserDisplayFormatters.chatTimestamp(message.createdAt)
        let bubbleHPad: CGFloat = seatsRight ? 16 : 0
        HStack(alignment: .bottom, spacing: NativeAgentSpacing.sm) {
            if seatsRight { Spacer(minLength: 60) }

            VStack(alignment: seatsRight ? .trailing : .leading, spacing: NativeAgentSpacing.xs) {
                if let bridgeTag {
                    Text(bridgeTag)
                        .font(ShellType.labelSemibold)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityLabel("From \(bridgeTag), through the bridge")
                }
                // Nonlocal user rows carry durable origin labels from the closed provenance label set.
                if isUser, bridgeTag == nil, let provenance = messageProvenance {
                    HStack(spacing: NativeAgentSpacing.xs) {
                        Image(systemName: provenance.symbol)
                        Text(provenance.label)
                    }
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(provenance.isAutomated ? Color.orange : Color.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Message origin: \(provenance.label)")
                }

                // Message content bubble
                VStack(alignment: seatsRight ? .trailing : .leading, spacing: NativeAgentSpacing.sm) {
                    // A live reply mounts its paced text while still empty, so
                    // the first words pace in instead of arriving as a mount.
                    if hasVisibleContent || isLiveReply {
                        renderedMessageText
                    } else if attachments.localImages.isEmpty && attachments.chips.isEmpty {
                        Text(" ")
                    }
                    ForEach(attachments.localImages, id: \.id) { attachment in
                        MessageLocalImageAttachmentView(attachment: attachment)
                    }
                    ForEach(attachments.chips, id: \.id) { attachment in
                        MessageAttachmentChipView(attachment: attachment)
                    }
                }
                    .font(isQuietBridge ? ShellType.label : ShellType.body)
                    .textSelection(.enabled)
                    .lineSpacing(bubbleLineSpacing)
                    .padding(.horizontal, bubbleHPad)
                    .padding(.vertical, seatsRight ? 12 : NativeAgentSpacing.xs)
                    .modifier(UserBubbleSurface(seatsRight: seatsRight, corners: userCorners))
                    // The cap comes after the fill so the bubble hugs short
                    // text; the padding is added back so long text still
                    // wraps at the same width.
                    .frame(
                        maxWidth: (seatsRight
                                ? NativeAgentShellLayout.userBubbleMaxWidth
                                : NativeAgentShellLayout.replyMaxWidth)
                            + 2 * bubbleHPad,
                        alignment: seatsRight ? .trailing : .leading
                    )
                    .foregroundStyle(isQuietBridge ? NativeAgentShell.secondary : NativeAgentShell.text)
                    .contextMenu {
                        Button {
                            ChatClipboard.copy(ChatMarkdownCache.plainText(message.content))
                            showBubbleToast("Copied")
                        } label: { Label("Copy text", systemImage: "doc.on.doc") }

                        Button {
                            ChatClipboard.copy(ChatExport.messageMarkdown(message))
                            showBubbleToast("Copied as Markdown")
                        } label: { Label("Copy as Markdown", systemImage: "doc.richtext") }

                        if !isUser {
                            Button {
                                toggleReadAloud()
                            } label: {
                                Label(isReadingThisMessage ? "Stop reading" : "Read aloud", systemImage: isReadingThisMessage ? "speaker.slash" : "speaker.wave.2")
                            }
                        }

                        if !isUser && isLastAssistant && message.metadata?.providerRefusal != true {
                            Button {
                                requestRetry()
                            } label: {
                                Label("Regenerate response", systemImage: "arrow.clockwise")
                            }
                        }

                        Divider()

                        Button {
                            Task {
                                showBubbleToast(await appModel.addMemoryFact(message.content).userMessage)
                            }
                        } label: { Label("Remember this", systemImage: "brain") }

                        Divider()

                        Button { showJSONSheet = true } label: {
                            Label("Show message data", systemImage: "curlybraces")
                        }
                    }
                // The room's trouble card carries Retry for a failed turn; the
                // bubble keeps it for a stopped turn and in detached panels.
                if !isUser, isLastAssistant,
                   !(troubleCardOwnsRetry && ChatShellTroubleState.isFailed(message)),
                   (message.metadata?.providerRefusalDraft == true
                    || (message.metadata?.providerRefusal != true && messageNeedsRetry)) {
                    Button {
                        requestRetry()
                    } label: {
                        Label(message.metadata?.providerRefusalDraft == true ? "Retry draft" : "Try again", systemImage: "arrow.clockwise")
                            .font(NativeAgentFont.label)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Bubble-local toast
                if let bt = bubbleToast {
                    NoticePill(text: bt)
                        .transition(NativeAgentMotion.reveal())
                }

            }
            // Hover stays layout-neutral: actions overlay bottom padding and the gap below, never prose.
            .overlay(alignment: seatsRight ? .bottomTrailing : .bottomLeading) {
                if showsHoverBar {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        if seatsRight { hoverTimestamp(timestamp) }
                        hoverBar
                            // The bar hangs below the row's own hover region;
                            // holding it keeps it.
                            .onHover { hovering in
                                withAnimation(NativeAgentMotion.quick) { isBarHovered = hovering }
                            }
                        if !seatsRight { hoverTimestamp(timestamp) }
                    }
                    .offset(y: NativeAgentShellLayout.hoverBarStrip - NativeAgentShellLayout.hoverBarOverlap)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .frame(
                maxWidth: NativeAgentShellLayout.roomColumn,
                alignment: seatsRight ? .trailing : .leading
            )
            .sheet(isPresented: $showJSONSheet) { MessageJSONSheet(message: message) }
            // Extend the column's hit region through the hanging bar so its buttons remain reachable.
            .contentShape(HoverBarReach(below: NativeAgentShellLayout.hoverBarStrip - NativeAgentShellLayout.hoverBarOverlap))
            .onHover { hovering in
                withAnimation(NativeAgentMotion.quick) { isHovered = hovering }
            }

            if !seatsRight { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: seatsRight ? .trailing : .leading)
        // The hover bar hangs over the top edge of the next row; draw this
        // row above its neighbours while it shows.
        .zIndex(showsHoverBar ? 1 : 0)
        .animation(NativeAgentMotion.quick, value: bubbleToast)
        .modifier(MessageBubbleAccessibilityActions(
            isUser: isUser,
            isLastAssistant: isLastAssistant && message.metadata?.providerRefusal != true,
            onCopy: {
                ChatClipboard.copy(ChatMarkdownCache.plainText(message.content))
                showBubbleToast("Copied")
            },
            onReadAloud: toggleReadAloud,
            onRegenerate: {
                requestRetry()
            }
        ))
        .modifier(FailedTurnRetryConfirmation(
            failure: $retryConfirmation,
            onRetry: { Task { await appModel.regenerateAssistantMessage(message) } },
            onContinue: { Task { await appModel.continueFailedTurn(message) } }
        ))
        .onAppear { emitFirstRenderIfNeeded() }
        .onChange(of: hasVisibleContent) { emitFirstRenderIfNeeded() }
        // Read-aloud failures (trust denied / not configured / auth rejected)
        // land in voiceOutput.errorMessage, which nothing else reads — surface
        // them in the bubble toast. Cleared after showing so a repeat failure
        // re-fires.
        .onChange(of: voiceOutput.errorMessage) {
            if let msg = voiceOutput.consumeError(ownerID: speechOwnerID) {
                showBubbleToast(msg)
            }
        }
    }

    /// Time and brain use the shell's readable secondary color and yield to the bubble toast.
    private func hoverTimestamp(_ timestamp: String) -> some View {
        Text([timestamp, isUser ? nil : Self.brainLine(message.metadata)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(ShellType.caption)
            .lineLimit(1)
            .foregroundStyle(NativeAgentShell.secondary)
            .opacity(bubbleToast == nil ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// The per-message actions, overlaid on the message's bottom edge.
    private var hoverBar: some View {
        BubbleHoverBar(
            message: message,
            isLastAssistant: isLastAssistant && message.metadata?.providerRefusal != true,
            onCopy: {
                ChatClipboard.copy(ChatMarkdownCache.plainText(message.content))
                showBubbleToast("Copied")
            },
            onRegenerate: {
                requestRetry()
            },
            onReadAloud: {
                toggleReadAloud()
            }
        )
    }

    private func showBubbleToast(_ text: String) {
        withAnimation(NativeAgentMotion.standard) { bubbleToast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(NativeAgentMotion.standard) { bubbleToast = nil }
        }
    }

    private func toggleReadAloud() {
        if isReadingThisMessage {
            voiceOutput.stop()
            return
        }
        Task {
            await voiceOutput.speak(
                text: message.content,
                policy: appModel.engine.trust.policy, loadPolicy: { try await appModel.engine.trust.load() },
                ownerID: speechOwnerID
            )
        }
    }

    private func emitFirstRenderIfNeeded() {
        // Offscreen quiet reads cannot consume the person’s first-render receipt.
        guard !quietOffscreenRead else { return }
        Task { [message, isLastAssistant, activeSessionID = appModel.activeChatSessionId] in
            await TurnFirstRenderRegistry.shared.observeFirstRender(
                role: message.role,
                content: message.content,
                isLastAssistant: isLastAssistant,
                messageSessionID: message.sessionId,
                messageTurnID: message.metadata?.turnTraceId,
                activeSessionID: activeSessionID,
                observedBy: "NativeAgentApp.MessageBubble"
            )
        }
    }

    @ViewBuilder
    private var renderedMessageText: some View {
        // Every reply keeps one structure, so a reply that stops being the
        // last does not remount or crossfade when the next turn starts;
        // `isLiveReply` checks eligibility before observing streaming state.
        if message.role == "assistant" {
            // Stream, settled prose and folded notes crossfade at the incoming phase's size.
            let live = isLiveReply || holdsLive
            let split: (commentary: String?, answer: String) = live ? (nil, "") : workingCommentarySplit
            let phase = live ? 0 : (split.commentary == nil ? 1 : 2)
            ChatCrossfadeStack(current: phase) {
                if live {
                    // Keep the reply width fixed while its edge grows.
                    PacedStreamingText(text: displayContent, inline: ChatInlineMarkdown(ChatRichContentParser.inline), isVisible: chatPageIsVisible) {
                        revealedLength = displayContent.utf8.count
                        if !isLiveReply { settle() }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutValue(key: ChatCrossfadePhase.self, value: 0)
                        .transition(NativeAgentMotion.replyDissolve)
                } else if let commentary = split.commentary {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                        workingCommentaryFold(commentary)
                        settledContent(split.answer)
                    }
                    .layoutValue(key: ChatCrossfadePhase.self, value: 2)
                    .zIndex(2)
                    .transition(NativeAgentMotion.replyDissolve)
                } else {
                    settledContent(split.answer)
                        .layoutValue(key: ChatCrossfadePhase.self, value: 1)
                        .zIndex(1)
                        .transition(NativeAgentMotion.replyDissolve)
                }
            }
            .onChange(of: isLiveReply, initial: true) { _, now in
                if now {
                    holdsLive = true
                } else if holdsLive, !chatPageIsVisible || revealedLength >= displayContent.utf8.count {
                    settle()
                }
            }
        } else {
            let split = workingCommentarySplit
            if let commentary = split.commentary {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    workingCommentaryFold(commentary)
                    settledContent(split.answer)
                }
            } else {
                settledContent(split.answer)
            }
        }
    }

    /// The stream hands over to settled prose, once, in one eased crossfade.
    private func settle() {
        guard holdsLive else { return }
        if readingPlace?.isReading(message.id) == true { commentaryExpanded = true }
        withAnimation(NativeAgentMotion.arrive) { holdsLive = false }
    }

    /// Where the working commentary ends and the answer begins, per the
    /// engine's recorded offset. Anything that does not line up exactly (a
    /// bridge-stripped body, a bad offset, an empty half) falls back to the
    /// whole reply, unfolded.
    private var workingCommentarySplit: (commentary: String?, answer: String) {
        let text = displayContent
        guard message.role == "assistant",
              text == message.content,
              let offset = message.metadata?.workingCommentaryChars,
              offset > 0, offset < text.count
        else { return (nil, text) }
        let cut = text.index(text.startIndex, offsetBy: offset)
        let commentary = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commentary.isEmpty, !answer.isEmpty else { return (nil, text) }
        return (commentary, answer)
    }

    @ViewBuilder
    private func workingCommentaryFold(_ commentary: String) -> some View {
        ChatActivityRow(title: "Working notes", isExpanded: $commentaryExpanded) {
            proseText(commentary)
        }
    }

    private func settledContent(_ content: String) -> some View {
        ChatPreparedContent(text: content, lineSpacing: bubbleLineSpacing, seatsRight: seatsRight)
    }

    private var bubbleLineSpacing: CGFloat { isUser ? 2 : NativeAgentShellLayout.replyLineSpacing }

    private func proseText(_ text: String) -> some View {
        ChatPreparedContent(text: text, lineSpacing: bubbleLineSpacing, proseOnly: true)
    }

    /// Every retry and Regenerate on this bubble asks the one gate first: a
    /// failed turn that acted, or whose outcome is unknown, is confirmed
    /// before it runs again.
    private func requestRetry() {
        if let failure = ChatTurnFailure.retryNeedsConfirmation(for: message, in: appModel.engine.transcripts.messages(for: message.sessionId ?? appModel.activeChatSessionId)) {
            retryConfirmation = failure
        } else {
            Task { await appModel.regenerateAssistantMessage(message) }
        }
    }

    private var messageNeedsRetry: Bool {
        ChatShellTroubleState.isFailed(message) || message.metadata?.cancelled == true
    }
}

/// Equatable call sites suppress unchanged row bodies using every drawn field.
extension MessageBubble: Equatable {
    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.isLastAssistant == rhs.isLastAssistant
            && drawsTheSame(lhs.message, rhs.message)
    }
}

/// Stable accessible actions mirror the hover bar and preserve assistant-only eligibility.
private struct MessageBubbleAccessibilityActions: ViewModifier {
    let isUser: Bool
    let isLastAssistant: Bool
    let onCopy: () -> Void
    let onReadAloud: () -> Void
    let onRegenerate: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isUser {
            content
                .accessibilityAction(named: "Copy message", onCopy)
        } else if isLastAssistant {
            assistantActions(content)
                .accessibilityAction(named: "Regenerate response", onRegenerate)
        } else {
            assistantActions(content)
        }
    }

    private func assistantActions(_ content: Content) -> some View {
        content
            .accessibilityAction(named: "Copy message", onCopy)
            .accessibilityAction(named: "Read message aloud", onReadAloud)
    }
}

private struct UserBubbleSurface: ViewModifier {
    let seatsRight: Bool
    let corners: RectangleCornerRadii

    func body(content: Content) -> some View {
        if seatsRight {
            content.houseSurface(in: UnevenRoundedRectangle(cornerRadii: corners, style: .continuous))
        } else {
            content
        }
    }
}

/// The message's hit region extended down by the distance its hover bar hangs.
private struct HoverBarReach: Shape {
    let below: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + max(0, below)))
    }
}
