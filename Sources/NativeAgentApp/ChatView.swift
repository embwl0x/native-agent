import EngineRuntime
import ChatTurnRuntime
import ChatSessionWork
import AppToolRuntime
import MultimodalTTS
import SwiftUI
import AppKit
import NativeAgentShared
import Transcripts
import ToolRegistry
import ProviderRouting
import CoreGraphics
import ScreenVision
import UniformTypeIdentifiers
import MemoryV2
import PersistenceCore
// Blueprint: | `ChatView.swift` | `ChatView`: conversation state and mounted lifecycle; `ChatTurnNoticePresentation`; stale-panel notice leaves |

enum ChatTurnNoticeDestination: Equatable {
    case chatTop
    case globalWarning
    case globalInfo
}

enum ChatTurnNoticePresentation {
    static func destination(for kind: String) -> ChatTurnNoticeDestination {
        // Reconnect notices clear with the turn's own notice lane.
        if kind == "provider_retry" {
            return .chatTop
        }
        if kind.contains("timeout") {
            return .globalWarning
        }
        return .globalInfo
    }
}

/// Owns message, tail-content and turn-end observation without invalidating the chat root.
struct ChatReadAloudObserver: View {
    @Environment(AppModel.self) private var appModel
    var onChanged: () -> Void

    private var turnIsBusy: Bool {
        appModel.engine.turns.busySessions.contains(appModel.activeChatSessionId)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: appModel.chatMessages.count) {
                if !turnIsBusy { onChanged() }
            }
            .onChange(of: appModel.chatMessages.last?.content) {
                if !turnIsBusy { onChanged() }
            }
            .onChange(of: turnIsBusy) {
                if !turnIsBusy { onChanged() }
            }
    }
}

struct ChatView: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    /// Mounted chat uses page visibility to suspend input, commands and visual work.
    @Environment(\.chatPageIsVisible) var chatPageIsVisible
    /// Simple view shows this page without its conversation list (as its
    /// profile is seeded), Work pane or new-chat button (SimpleViewMode).
    @Environment(\.layoutProfile) var layoutProfile
    var inSimple: Bool { layoutProfile == SimpleViewMode.simple }
    /// ⌘0: the conversations column goes with the rail (WorkPane.swift).
    @AppStorage(WorkPaneState.sidebarsHiddenKey) var sidebarsHidden = false
    /// The Work pane beside the chat; main window only, so never in Simple.
    @AppStorage(WorkPaneState.openKey) var workPaneOpen = false
    /// The conversation list's travelling selection bar (ChatView+ShellColumn).
    /// Open controls only; cards belong to the engine transcript projection.
    @State var inlineCards = InlineInteractionChatBinding()
    var draft: ChatComposerDraft { appModel.composerDraft(for: appModel.activeChatSessionId) }

    var draftSessionId: String {
        get { draft.sessionId }
    }
    var draftEditedAt: Date {
        get { draft.editedAt }
    }

    var text: String {
        get { draft.text }
        nonmutating set { draft.edit(newValue) }
    }
    var pendingAttachments: [MultimodalAttachment] {
        get { appModel.chatPendingAttachments[appModel.activeChatSessionId] ?? [] }
        nonmutating set { appModel.chatPendingAttachments[appModel.activeChatSessionId] = newValue }
    }

    @State var sessionSearch = ""
    // One rename target shared by the row editor and its context menu.
    @State var renamingSessionId: String? = nil
    let bottomAnchor = "chat-bottom-anchor"
    @State var turnCardClearanceStore = ChatTurnCardClearance()
    /// Owns the open card drawn above the scroll view and both insets.
    @State var composerCardState = ComposerShellState()
    /// True only for the copy of this page a quiet read mounts offscreen.
    @Environment(\.quietOffscreenRead) var quietOffscreenRead

    @State var voiceInput = VoiceInputCapture.forChat()
    @State var voiceDraftBeforeListening = ""
    @State var voiceDraftRevision: UInt64 = 0
    /// Dictation writes are fenced to the conversation where recognition started.
    @State var voiceSessionId = ""
    /// Every endDictation invalidates pending permission-prompt starts, including on page changes.
    @State var voiceGeneration = 0
    @State var voiceOutput = VoiceOutputController.forChat()
    @AppStorage("voiceAutoRead") var voiceAutoRead = false
    @State var isCapturing = false
    @State var toasts = ChatToastQueue()
    // Slow-turn advisories belong to this conversation: a dedicated center
    // lets a session switch or a finished turn clear them without touching
    // app-wide toasts. Both draw in the one notice lane (NoticeLaneRoomKey).
    @StateObject var turnNoticeToasts = SystemToastCenter()
    // Refocus the text field after slash-command insertion.
    @FocusState var inputFocused: Bool
    @State var transcriptSearch = MacChatTranscriptSearchController()
    @State var transcriptLatestRequest = 0
    /// Held until send acceptance returns to prevent duplicate submissions of the retained draft.
    @State var isSubmittingSend = false
    @State var showTranscriptSearch = false
    @State var transcriptSearchFocusRequest: UInt = 0
    // The state gate is separate from the SwiftUI binding so dismissal and a
    // destructive button action cannot race into duplicate clears.
    @State var clearConfirmation = ChatClearConfirmationState()
    @State var scrollCoordinator = ChatScrollFollow()
    @State var sidebarProjectionCache = ChatSidebarProjectionCache()
    /// Per-session cursor prevents a tab switch from overwriting the marker
    /// for a response that is still arriving in another conversation.
    @State var lastAutoReadMessageIds: [String: String] = [:]
    /// A session is primed from its already-loaded transcript once. Until then
    /// auto-read must not mistake old history for a newly appended reply.
    @State var autoReadPrimedSessionIds: Set<String> = []
    /// Fences overlapping "Go to" tasks. A route may need to refresh the
    /// session index before selection; an older click must not resume after a
    /// newer click and become the newest AppModel selection request.
    @State var runningSessionNavigationGeneration: UInt = 0

    var clearConfirmationBinding: Binding<Bool> {
        Binding(
            get: { clearConfirmation.isPresented },
            set: { isPresented in
                if isPresented {
                    clearConfirmation.request(sessionId: appModel.activeChatSessionId)
                } else {
                    clearConfirmation.cancel()
                }
            }
        )
    }

    var activeSession: ChatSession? {
        appModel.engine.transcripts.sessions.first { $0.id == appModel.activeChatSessionId }
    }

    // Hash session order in place without allocating an ID array or joined string.
    var chatSessionIdsFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(appModel.engine.transcripts.sessions.count)
        for session in appModel.engine.transcripts.sessions {
            hasher.combine(session.id)
        }
        return hasher.finalize()
    }

    var body: some View {
        HStack(spacing: 0) {
            if !shellColumnBlocks.isEmpty && !sidebarsHidden { shellConversationsColumn }
            chatColumn
                // The chat gives the pane its width down to this floor (the
                // detached window's); past it the pane narrows instead.
                .frame(minWidth: 380)
                .modifier(ChatAttachmentDropTarget(
                    isEnabled: chatPageIsVisible,
                    contentTypes: ChatAttachmentTypeResolver.attachmentContentTypes + chatSessionDropTypes,
                    onDrop: { providers in
                        let attachments = providers.filter { provider in
                            ChatAttachmentTypeResolver.attachmentContentTypes.contains {
                                provider.hasItemConformingToTypeIdentifier($0.identifier)
                            }
                        }
                        guard !attachments.isEmpty else {
                            return handlePinnedSessionDrop(providers: providers)
                        }
                        handleDrop(providers: attachments)
                        return true
                    }
                ))
            if !inSimple && workPaneOpen {
                WorkPane()
                    .layoutPriority(1)
                    .transition(NativeAgentMotion.fade)
            }
            // The offscreen copy a quiet read mounts never opens the pane.
            if !inSimple && !quietOffscreenRead { WorkPaneAutoOpen() }
            ChatReadAloudObserver(onChanged: speakLatestAssistantIfReady)
        }
        .navigationTitle("Chat")
        .task(id: appModel.engine.dataRoot) {
            await appModel.engine.transcripts.watchNavigation()
        }
        // Where a card's setup opens: the connector sheet, or in Simple view
        // the floating glass panel (SimpleSetupPanel.swift).
        .inlineCardSetup(inlineCards)
        .liveOnAppear {
            prunePinnedSessions()
            Task { await appModel.engine.transcripts.reclaimContinuations(for: appModel.activeChatSessionId) }
            // Focus the composer after the window chooses its initial responder.
            DispatchQueue.main.async { if chatPageIsVisible { inputFocused = true } }
        }
        // Only the live composer registers its shell; quiet reads share the
        // session draft owner without taking the mounted shell's place.
        .liveOnAppear {
            QuietSelfAdmin.shared.attach(cards: composerCardState)
        }
        .onDisappear {
            QuietSelfAdmin.shared.detachComposer(cards: composerCardState)
            endDictation()
        }
        // Page changes dismiss composer cards and end dictation even while Chat stays mounted.
        .onChange(of: chatPageIsVisible) { _, visible in
            if !visible { composerCardState.dismiss() }
            guard !visible else {
                refreshTranscriptSearchIfPresented()
                // Coming BACK is the "the control closed" signal for the
                // controls that are pages rather than sheets: a card that sent
                // the person to Providers asks its owner, now, whether the
                // thing is done — and fails honestly if it is not.
                Task { await inlineCards.verifyOnReturn() }
                return
            }
            endDictation()
        }
        .liveTask {
            // First-run: agent greets the user once a provider is connected.
            // Idempotent + self-gating; safe to call from multiple triggers.
            await appModel.maybeSendFirstRunGreeting()
        }
        .onChange(of: appModel.activeChatSessionId) { _, newSessionId in
            composerCardState.dismiss()
            endDictation()
            Task { await appModel.engine.transcripts.reclaimContinuations(for: newSessionId) }
            Task { await appModel.maybeSendFirstRunGreeting() }
        }
        // A link that names a message (a miss's history locator) lands on it
        // through the transcript search's own selection, paging and scroll.
        .onChange(of: appModel.pendingChatMessageID, initial: true) { _, messageID in
            guard let messageID else { return }
            appModel.pendingChatMessageID = nil
            openTranscriptSearch()
            transcriptSearch.reveal(messageID: messageID)
        }
        .onChange(of: appModel.chatProvider) {
            // Catches the case where the user skipped the provider step at
            // onboarding and connected an LLM later in Settings.
            Task { await appModel.maybeSendFirstRunGreeting() }
        }
        .onChange(of: chatSessionIdsFingerprint) {
            prunePinnedSessions()
            // A rename target that left the list (archived/deleted/refreshed
            // away) must not leave a phantom editor pointed at a dead id.
            if let id = renamingSessionId,
               !appModel.engine.transcripts.sessions.contains(where: { $0.id == id }) {
                renamingSessionId = nil
            }
        }
        // Read-aloud failures (trust denied / not configured / auth rejected)
        // land in voiceOutput.errorMessage, which nothing else reads — surface
        // them as a toast. Cleared after showing so a repeat failure re-fires.
        .onChange(of: voiceOutput.errorMessage) {
            if let msg = voiceOutput.errorMessage {
                showToast(msg)
                voiceOutput.errorMessage = nil
            }
        }
    }

}

/// Labels retained panel data after refresh failure; dictionary observation stays in this leaf.
struct PanelStaleNoticeView: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let notice = appModel.panelStaleNotice(for: item) {
            StalePanelNotice(text: notice)
        }
    }
}

struct StalePanelNotice: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stale data. \(text)")
        .help(text)
    }
}
