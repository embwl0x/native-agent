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
        // Clear reconnect notices with their turn's own lane so unrelated notices survive.
        if kind == "provider_retry" {
            return .chatTop
        }
        if kind.contains("timeout") {
            return .globalWarning
        }
        return .globalInfo
    }
}

/// Confine message and lifecycle observation here so updates cannot invalidate the chat root.
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
    /// Suspend hidden-page input, commands and visual work.
    @Environment(\.chatPageIsVisible) var chatPageIsVisible
    /// Simple's seeded profile omits the conversation list, Work pane and new-chat button.
    @Environment(\.layoutProfile) var layoutProfile
    var inSimple: Bool { layoutProfile == SimpleViewMode.simple }
    @AppStorage(WorkPaneState.sidebarsHiddenKey) var sidebarsHidden = false
    /// The Work pane belongs only to main chat, never Simple.
    @AppStorage(WorkPaneState.openKey) var workPaneOpen = false
    /// Keep open-control selection separate from engine-owned transcript cards.
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
    // Share one rename target between the editor and context menu so they cannot race.
    @State var renamingSessionId: String? = nil
    @State var turnCardClearanceStore = ChatTurnCardClearance()
    /// Share one open-card owner across drawing and insets.
    @State var composerCardState = ComposerShellState()
    /// Quiet reads must be distinguishable from the mounted live page.
    @Environment(\.quietOffscreenRead) var quietOffscreenRead

    @State var voiceInput = VoiceInputCapture.forChat()
    @State var voiceDraftBeforeListening = ""
    @State var voiceDraftRevision: UInt64 = 0
    /// Fence dictation writes to the conversation where recognition started.
    @State var voiceSessionId = ""
    /// Ending dictation must invalidate permission-prompt starts even across page changes.
    @State var voiceGeneration = 0
    @State var voiceOutput = VoiceOutputController.forChat()
    @AppStorage("voiceAutoRead") var voiceAutoRead = false
    @State var isCapturing = false
    @State var toasts = ChatToastQueue()
    // Keep slow-turn notices session-local so switching or settling cannot clear app-wide feedback.
    @StateObject var turnNoticeToasts = SystemToastCenter()
    @FocusState var inputFocused: Bool
    @State var transcriptLatestRequest = 0
    @State var transcriptHandle = TranscriptDocumentHandle()
    /// Retain the send latch through acceptance to prevent duplicate submissions of the held draft.
    @State var isSubmittingSend = false
    // Separate the state gate from the binding so dismissal and the destructive action cannot race into duplicate clears.
    @State var clearConfirmation = ChatClearConfirmationState()
    @State var sidebarProjectionCache = ChatSidebarProjectionCache()
    /// Use per-session cursors so tab switches cannot overwrite another conversation's arriving-response marker.
    @State var lastAutoReadMessageIds: [String: String] = [:]
    /// Prime from loaded history once so auto-read cannot mistake old replies for new arrivals.
    @State var autoReadPrimedSessionIds: Set<String> = []
    /// Fence navigation tasks so an older suspended click cannot overtake the latest selection.
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

    // Hash in place to avoid allocating an ID array or joined string.
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
            if !appModel.engine.layout.availability.contentNames("chat", profile: layoutProfile).isEmpty && !sidebarsHidden {
                shellConversationsColumn(appModel.engine.layout.availability)
            }
            chatColumn
                // Keep the detached window's minimum width as the chat floor; below it, the Work pane yields space.
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
            // Offscreen quiet reads must not open the Work pane.
            if !inSimple && !quietOffscreenRead { WorkPaneAutoOpen() }
            ChatReadAloudObserver(onChanged: speakLatestAssistantIfReady)
        }
        .navigationTitle("Chat")
        .task(id: appModel.engine.dataRoot) {
            await appModel.engine.transcripts.watchNavigation()
        }
        // Use the surface's existing setup presentation so a card opens in the correct host.
        .inlineCardSetup(inlineCards)
        .liveOnAppear {
            prunePinnedSessions()
            Task { await appModel.engine.transcripts.reclaimContinuations(for: appModel.activeChatSessionId) }
            // Wait for the initial responder before focusing the composer.
            DispatchQueue.main.async { if chatPageIsVisible { inputFocused = true } }
        }
        // Register only the live shell so quiet reads cannot replace its shared composer registration.
        .liveOnAppear {
            QuietSelfAdmin.shared.attach(cards: composerCardState)
        }
        .onDisappear {
            QuietSelfAdmin.shared.detachComposer(cards: composerCardState)
            endDictation()
        }
        // Dismiss cards and stop dictation on page changes even while Chat remains mounted.
        .onChange(of: chatPageIsVisible) { _, visible in
            if !visible { composerCardState.dismiss() }
            guard !visible else {
                // Recheck setup on page return because page-based controls have no sheet dismissal callback.
                Task { await inlineCards.verifyOnReturn() }
                return
            }
            endDictation()
        }
        .liveTask {
            // Greeting triggers must remain idempotent and self-gating.
            await appModel.maybeSendFirstRunGreeting()
        }
        .onChange(of: appModel.activeChatSessionId) { _, newSessionId in
            composerCardState.dismiss()
            endDictation()
            Task { await appModel.engine.transcripts.reclaimContinuations(for: newSessionId) }
            Task { await appModel.maybeSendFirstRunGreeting() }
        }
        // The document centres a message locator, or holds it until that message arrives.
        .onChange(of: appModel.pendingChatMessageID, initial: true) { _, messageID in
            guard let messageID else { return }
            appModel.pendingChatMessageID = nil
            transcriptHandle.reveal(messageID: messageID)
        }
        .onChange(of: appModel.chatProvider) {
            // Observe later provider connections so skipped onboarding cannot suppress the greeting.
            Task { await appModel.maybeSendFirstRunGreeting() }
        }
        .onChange(of: chatSessionIdsFingerprint) {
            prunePinnedSessions()
            // Clear rename targets that leave the list so no editor points at a dead identity.
            if let id = renamingSessionId,
               !appModel.engine.transcripts.sessions.contains(where: { $0.id == id }) {
                renamingSessionId = nil
            }
        }
        // Surface read-aloud failures from voiceOutput and clear after display so repeated failures can notify again.
        .onChange(of: voiceOutput.errorMessage) {
            if let msg = voiceOutput.errorMessage {
                showToast(msg)
                voiceOutput.errorMessage = nil
            }
        }
    }

}

/// Keep retained-data failure observation in this leaf so it cannot invalidate the chat root.
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
