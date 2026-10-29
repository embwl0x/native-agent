import Cognition
import EngineRuntime
import Dispatcher
import ChatTurnRuntime
import ChatSessionWork
import ToolRegistry

// Blueprint: | `DetachedChatPanelView.swift` | `DetachedChatPanelView`: session-bound transcript/composer, search, speech and attachment intake through shared chat owners |
// Detached transcripts and sends stay bound to one session through shared chat owners.

import SwiftUI
import NativeAgentShared
import ScreenVision
import AppKit
import UniformTypeIdentifiers
import NativeAgentCore
import PersistenceCore

struct DetachedChatPanelView: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var didInitialLoad = false
    // Scrolling up disarms follow; returning to the bottom re-arms it.
    @State private var scrollCoordinator = ChatScrollFollow()
    /// Room the transcript lends the floating turn card.
    @State private var cardRoom = ChatTurnCardClearance()
    /// The detached window is a real chat transcript, so it draws real cards.
    /// It used to mount `ChatMessageListView` with no card source at all: a
    /// request that raised "Connect GitHub" in a detached window showed a bare
    /// tool row with nothing to tap, and the same conversation in the main
    /// window showed the card. Window controls, shared transcript projection.
    @State private var inlineCards = InlineInteractionChatBinding()
    @State private var isCapturing = false
    @State private var isRetryingLoad = false
    @State private var toastMessage: String?
    @State private var voiceInput = VoiceInputCapture.forChat()
    @State private var voiceDraftBeforeListening = ""
    @State private var voiceDraftRevision: UInt64 = 0
    /// Ending dictation invalidates pending starts and late transcripts.
    @State private var voiceGeneration = 0
    /// True only between a successful `startListening` and the next end.
    @State private var voiceAcceptsTranscript = false
    @FocusState private var inputFocused: Bool
    @State private var transcriptSearch = MacChatTranscriptSearchController()
    @State private var showTranscriptSearch = false
    @State private var transcriptSearchFocusRequest: UInt = 0
    /// Sends and screenshot sends return the transcript to its latest page.
    @State private var transcriptLatestRequest = 0
    /// Hold the send latch synchronously until acceptance returns to prevent duplicate drafts.
    @State private var isSubmittingSend = false

    private var panelDraft: ChatComposerDraft { appModel.composerDraft(for: sessionId) }

    private var draft: String {
        get { panelDraft.text }
        nonmutating set { panelDraft.edit(newValue) }
    }

    private var pendingAttachments: [MultimodalAttachment] {
        get { appModel.chatPendingAttachments[sessionId] ?? [] }
        nonmutating set { appModel.chatPendingAttachments[sessionId] = newValue }
    }

    private var messages: [ChatMessage] {
        appModel.engine.transcripts.messages(for: sessionId)
    }

    private var loadStatus: AppModel.PanelRefreshStatus? {
        appModel.detachedChatRefreshStatus[sessionId]
    }

    private var loadPresentation: AppModel.CompactReadPresentationState {
        AppModel.compactReadPresentationState(hasContent: !messages.isEmpty, status: loadStatus)
    }

    private var isBusy: Bool {
        appModel.engine.turns.isBusy(sessionId)
    }

    private var screenCaptureAllowed: Bool {
        appModel.engine.trust.policy?.multimodalPolicy?.screen_capture == true
    }

    private var sessionPresentation: DetachedChatSessionPresentation {
        DetachedChatSessionPresentation.resolve(
            sessionId: sessionId,
            sessions: appModel.engine.transcripts.sessions
        )
    }

    private var sessionIsAvailable: Bool {
        sessionPresentation.isAvailable
    }

    /// The conversation's current name, or nil once it is gone.
    private var sessionTitle: String? {
        if case .available(let title) = sessionPresentation { return title }
        return nil
    }

    private var personaName: String {
        // Her real name (persona profile), not the chatPersona style
        // quick-switch which reads "Custom"/"AI".
        appModel.agentDisplayName
    }

    private func openTranscriptSearch() {
        showTranscriptSearch = true
        transcriptSearchFocusRequest &+= 1
        transcriptSearch.replaceSource(messages: messages, sessionID: sessionId,
                                      revision: appModel.engine.transcripts.structureVersion(for: sessionId))
    }

    private func closeTranscriptSearch() {
        showTranscriptSearch = false
    }

    private func findNextTranscriptMatch() {
        guard showTranscriptSearch else {
            openTranscriptSearch()
            return
        }
        _ = transcriptSearch.selectNext()
    }

    private func findPreviousTranscriptMatch() {
        guard showTranscriptSearch else {
            openTranscriptSearch()
            return
        }
        _ = transcriptSearch.selectPrevious()
    }

    private func refreshTranscriptSearchIfPresented() {
        guard showTranscriptSearch else { return }
        transcriptSearch.replaceSource(messages: messages, sessionID: sessionId,
                                      revision: appModel.engine.transcripts.structureVersion(for: sessionId))
    }

    private func refreshTranscriptSearchTailIfPresented() {
        guard showTranscriptSearch else { return }
        transcriptSearch.replaceLastMessage(
            messages.last,
            ordinal: messages.count - 1,
            sessionID: sessionId
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            InboxStripContainer(sessionID: sessionId, interactionBinding: inlineCards) { notes in
                notes
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
            }
            messageScrollback
                // Desk 658.11: the same shared live-turn card as the main window,
                // keyed on THIS window's session. It floats over the transcript's
                // live edge and borrows its room from the transcript's end, so it
                // never resizes the scroll view (TurnCardRoom).
                .overlay(alignment: .bottom) {
                    TurnCardRoom(shows: TurnCardReadout.isVisible(
                        appModel.engine.turns.lifecycle(for: sessionId),
                        sessionId: sessionId,
                        approvals: appModel.engine.approvals.records,
                        parseTimestamp: NativeTimestampFormat.parseISO8601FractionalFirst
                    ), floor: 0, store: cardRoom) {
                        MacChatTurnCardHost(
                            sessionId: sessionId,
                            onStop: { appModel.stopChatStream(sessionId: sessionId) }
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    }
                }
            Divider()
            inputBar
                .disabled(!sessionIsAvailable)
        }
        .frame(minWidth: 380, minHeight: 280)
        .modifier(ChatAttachmentDropTarget(isEnabled: sessionIsAvailable, onDrop: {
            handleDrop($0)
            return true
        }))
        // Fluid glass: the main window's sheet and haze, not an opaque
        // window fill. The haze follows this window's own conversation.
        .background {
            ShellSheet().overlay { WindowHaze(sessionId: sessionId) }
        }
        .preferredColorScheme(AppearanceController.shared.colorScheme)
        .task(id: sessionId) {
            // Load history into the per-session slot on first appearance.
            // task(id:) re-fires if the panel is somehow rebound to a new
            // session, but in practice sessionId is immutable per panel.
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await appModel.loadDetachedSessionMessages(sessionId)
            await appModel.engine.transcripts.reclaimContinuations(for: sessionId)
            inputFocused = true
        }
        // Telegram, Slack, iOS, bridge, and local turns all converge on the
        // canonical transcript. Watch that exact file while this panel is
        // mounted so every surface appears live without an idle refresh loop.
        .task(id: "detached-transcript:\(sessionId)") {
            await appModel.engine.transcripts.watchChanges(sessionID: sessionId) {
                await appModel.refreshDetachedChatMessagesAfterTurn(sessionId: sessionId)
            }
        }
        // AppKit owns the titlebar; pass title changes to the window controller.
        .onChange(of: sessionTitle) { _, title in
            guard let title else { return }
            DetachedChatWindowController.shared.updateTitle(
                sessionId: sessionId,
                title: title
            )
        }
        // Coming BACK to this panel is the "the control closed" signal for the
        // controls that are pages rather than sheets. Chat does this on its
        // page-visibility change; a detached panel has no such change, so a
        // card that sent the person to Trust or Providers stayed `running`
        // here forever. Filtered to THIS panel's window: another window
        // becoming key (Trust itself) must not verify a card the person is
        // still working on.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? DetachedChatPanel)?.sessionId == sessionId else { return }
            Task { await inlineCards.verifyOnReturn() }
        }
        .inlineCardSetup(inlineCards)
        .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
            guard let completedSessionId = note.object as? String,
                  completedSessionId == sessionId
            else { return }
            let alreadyRefreshed = (note.userInfo?["messagesAlreadyRefreshed"] as? Bool) == true
            Task {
                await appModel.refreshDetachedChatMessagesAfterTurn(
                    sessionId: sessionId,
                    messagesAlreadyRefreshed: alreadyRefreshed
                )
            }
        }
        .onDisappear {
            // Closing the panel also cancels dictation awaiting permission.
            endPanelDictation()
        }
        .focusedSceneValue(\.chatCommandActions, ChatFocusedCommandActions(
            send: send,
            attach: attachFromClipboardOrPickFile,
            toggleVoice: toggleVoice,
            focusComposer: { inputFocused = true },
            focusTranscriptSearch: openTranscriptSearch,
            findNext: findNextTranscriptMatch,
            findPrevious: findPreviousTranscriptMatch
        ))
    }

    // MARK: - Scrollback

    private var messageScrollback: some View {
        ScrollViewReader { proxy in
            TranscriptScrollView(coordinator: scrollCoordinator) {
                LazyVStack(alignment: .leading, spacing: NativeAgentShellLayout.transcriptGap) {
                    if loadPresentation == .stale {
                        Label("History refresh failed; showing last known messages.", systemImage: "exclamationmark.triangle.fill")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.yellow)
                    }
                    if !sessionIsAvailable {
                        detachedSessionUnavailableState
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if messages.isEmpty {
                        detachedEmptyState
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        // Reuse the main chat's grouped render path so tool
                        // pills, approval cards, and bubbles look identical.
                        ChatMessageListView(
                            messages: messages,
                            sessionId: sessionId,
                            isStreaming: isBusy,
                            highlightedMessageID: showTranscriptSearch
                                ? transcriptSearch.selectedMessageID
                                : nil,
                            latestRequest: transcriptLatestRequest
                        )
                        .safeAreaInset(edge: .top) {
                            if case .unavailable(let reason) = appModel.engine.transcripts.transcriptReadStatus(for: sessionId) {
                                Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                        .environment(\.inlineCardAction) { [inlineCards, appModel] card, action in
                            inlineCards.handle(card: card, action: action, appModel: appModel)
                        }
                    }
                    // Desk 658.11: the detached typing chip is retired. Turn
                    // progress has exactly one surface now — MacChatTurnCardHost
                    // above the composer — so this window and the main window
                    // show the same one thing instead of stacking two.
                    ChatTranscriptBottomAnchor(anchorID: detachedBottomAnchor, store: cardRoom, margin: 1)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // animateMacChatMutation drives bubble entrance; wholesale
                // replacements stay instant without list-level animation.
            }
            // Anchor the initial transcript at the bottom and empty states at the top.
            .modifier(DetachedScrollAnchorModifier(isEmpty: messages.isEmpty || !sessionIsAvailable))
            .safeAreaInset(edge: .top, spacing: 0) {
                if showTranscriptSearch {
                    MacChatTranscriptSearchBar(
                        controller: transcriptSearch,
                        focusRequest: transcriptSearchFocusRequest,
                        onDismiss: closeTranscriptSearch
                    )
                    .transition(
                        reduceMotion ? NativeAgentMotion.fade : NativeAgentMotion.reveal(anchor: .top)
                    )
                }
            }
            .onChange(of: messages.count) {
                if !showTranscriptSearch, scrollCoordinator.autoFollow {
                    // Auto-follow jumps without animation; the bottom anchor already positions the viewport.
                    proxy.scrollTo(detachedBottomAnchor, anchor: .bottom)
                }
            }
            // Streaming publishes the tail row's box, which feeds the open search bar.
            .followsStreamingTail(
                messageID: messages.last?.id,
                enabled: showTranscriptSearch,
                onChanged: { refreshTranscriptSearchTailIfPresented() }
            )
            // Transcript mutations refresh search even when count and endpoint IDs stay unchanged.
            .onChange(of: appModel.engine.transcripts.structureVersion(for: sessionId)) {
                refreshTranscriptSearchIfPresented()
            }
            .onChange(of: transcriptSearch.selectionRevision) { _, _ in
                guard showTranscriptSearch,
                      let messageID = transcriptSearch.selectedMessageID
                else { return }
                scrollCoordinator.disarmFollow()
                withAnimation(NativeAgentMotion.respecting(
                    NativeAgentMotion.quick,
                    reduceMotion: reduceMotion
                )) {
                    proxy.scrollTo(
                        MacChatTranscriptSearch.scrollTargetID(for: messageID),
                        anchor: .center
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var detachedEmptyState: some View {
        if loadPresentation == .unavailable {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.yellow)
                // Show the failure and recovery before endpoint details.
                Text("This conversation could not be loaded")
                    .font(NativeAgentFont.section)
                Text(DetachedChatLoadFailureCopy.message)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if let technical = DetachedChatLoadFailureCopy.technicalDetail(
                    failedEndpoints: loadStatus?.failedEndpoints ?? []
                ) {
                    Text(technical)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .textSelection(.enabled)
                        .help(technical)
                }
                Button {
                    retryDetachedHistoryLoad()
                } label: {
                    if isRetryingLoad {
                        Label("Trying again…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRetryingLoad)
                .accessibilityHint("Reloads this conversation without changing your draft")
            }
            .accessibilityElement(children: .contain)
        } else if loadPresentation == .loading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
        } else {
            emptyState
        }
    }

    private func retryDetachedHistoryLoad() {
        guard !isRetryingLoad else { return }
        isRetryingLoad = true
        Task { @MainActor in
            await appModel.loadDetachedSessionMessages(sessionId)
            isRetryingLoad = false
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if case let .available(title) = sessionPresentation {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("Detached session")
                    .font(NativeAgentFont.section)
                Text("Messages you send here go to “\(title)”. This window stays open and pinned until you close it.")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var detachedSessionUnavailableState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)
            Text(DetachedChatSessionPresentation.unavailableTitle)
                .font(NativeAgentFont.section)
            Text(DetachedChatSessionPresentation.unavailableDetail)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            DetachedChatSessionPresentation.unavailableTitle
                + ". " + DetachedChatSessionPresentation.unavailableDetail
        )
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { att in
                            AttachmentChip(attachment: att) {
                                pendingAttachments.removeAll { $0.id == att.id }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            ChatQueuedTurnsView(sessionId: sessionId, isBusy: isBusy)

            if let toastMessage {
                NoticePill(text: toastMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(NativeAgentMotion.fade)
            }

            DetachedChatComposer(
                draft: panelDraft,
                sessionId: sessionId,
                placeholder: "Message \(personaName)…",
                voiceInput: voiceInput,
                screenCaptureAllowed: screenCaptureAllowed,
                screenCaptureDisabled: !sessionIsAvailable || isBusy || isCapturing || !screenCaptureAllowed,
                pendingAttachmentCount: pendingAttachments.count,
                isRunning: isBusy,
                hasQueuedTurns: !appModel.engine.turns.queued(for: sessionId).isEmpty,
                isQueuePaused: appModel.engine.turns.isQueuePaused(sessionId),
                sendAllowed: sessionIsAvailable && !isCapturing && !appModel.isSavingChatBrain,
                inputFocused: $inputFocused,
                onToggleVoice: toggleVoice,
                onCaptureScreen: captureScreen,
                onAttach: attachFromClipboardOrPickFile,
                onDrop: handleDrop,
                onStop: { appModel.stopChatStream(sessionId: sessionId) },
                onSend: send,
                onTranscript: { newVal in
                    // Only live dictation may write the recognizer's cumulative transcript.
                    guard voiceAcceptsTranscript else { return }
                    if ChatTranscriptPresentation.hasVisibleText(newVal) {
                        panelDraft.dictate(composeVoiceDraft(newVal), revision: voiceDraftRevision)
                    }
                }
            )

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
            value: pendingAttachments.count
        )
    }

    private func send() {
        guard !isSubmittingSend else { return }
        if voiceAcceptsTranscript {
            Task { @MainActor in if await finishPanelDictation() { send() } }
            return
        }
        guard !appModel.isSavingChatBrain else { return }
        guard ensureSessionIsAvailable() else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capture the draft and edit time so acceptance clears only what was sent.
        let sentDraft = panelDraft.text
        let sentDraftEditedAt = panelDraft.editedAt
        let attachments = pendingAttachments
        guard !isCapturing, (!text.isEmpty || !attachments.isEmpty) else { return }
        // Recognized commands say where they work; other slash text reaches the agent.
        switch ChatSlashCommandRouting.decide(
            text: text,
            supportsDispatch: false
        ) {
        case .unsupportedHere(let command):
            showToast(ChatSlashCommandRouting.unsupportedMessage(command: command))
            return
        case .dispatch, .sendAsMessage:
            break
        }
        isSubmittingSend = true
        Task { @MainActor in
            defer { isSubmittingSend = false }
            let acceptance = await appModel.startChatTurnForSession(
                text,
                attachments: attachments,
                sessionId: sessionId
            )
            switch acceptance {
            case .accepted, .queued:
                guard draft.trimmingCharacters(in: .whitespacesAndNewlines) == text,
                      pendingAttachments == attachments
                else { return }
                appModel.clearChatDraftAfterSend(
                    sentDraft,
                    sessionId: sessionId,
                    editedAt: sentDraftEditedAt
                )
                pendingAttachments = []
                // An accepted send returns to the latest exchange and re-arms follow.
                transcriptLatestRequest &+= 1
                scrollCoordinator.forceFollow()
                // The composer's words are gone; a still-running dictation
                // would write the whole cumulative phrase straight back in.
                endPanelDictation()
            case .rejected(let message):
                showToast(message)
            }
        }
    }

    /// Stop recognition without writing through the composer on send or close.
    private func endPanelDictation() {
        voiceGeneration &+= 1
        voiceAcceptsTranscript = false
        voiceDraftBeforeListening = ""
        guard voiceInput.isListening else { return }
        Task { @MainActor in _ = await voiceInput.stopListeningResult() }
    }

    private func toggleVoice() {
        if voiceInput.isListening {
            Task { @MainActor in _ = await finishPanelDictation() }
        } else {
            guard ensureSessionIsAvailable() else { return }
            let requestedGeneration = voiceGeneration
            Task {
                guard requestedGeneration == voiceGeneration else { return }
                if voiceAcceptsTranscript {
                    guard await finishPanelDictation() else { return }
                }
                let startGeneration = voiceGeneration
                let listening = await ChatAttachmentTypeResolver.beginDictation(
                    voiceInput, draft: panelDraft,
                    isCurrent: { ensureSessionIsAvailable() && startGeneration == voiceGeneration },
                    prepareDraft: { base, revision in
                        voiceDraftBeforeListening = base
                        voiceDraftRevision = revision
                    },
                    showToast: showToast
                )
                if startGeneration == voiceGeneration { voiceAcceptsTranscript = listening }
            }
        }
    }

    private func finishPanelDictation() async -> Bool {
        let stoppedGeneration = voiceGeneration
        return await ChatAttachmentTypeResolver.finishDictation(
            voiceInput, draft: panelDraft, revision: voiceDraftRevision,
            isCurrent: { stoppedGeneration == voiceGeneration },
            base: { voiceDraftBeforeListening }, finished: {
            voiceAcceptsTranscript = false
            voiceDraftBeforeListening = ""
            voiceGeneration &+= 1
        }, attach: { pendingAttachments.append($0) }, showToast: showToast)
    }

    private func captureScreen() {
        if voiceAcceptsTranscript {
            Task { @MainActor in if await finishPanelDictation() { captureScreen() } }
            return
        }
        guard ensureSessionIsAvailable() else { return }
        guard !isCapturing else { return }
        // Screenshot sends share the send latch because admission suspends before marking the session busy.
        guard !isSubmittingSend else { return }
        guard screenCaptureAllowed else {
            showToast("Enable screen capture in Trust → Features → Multimodal")
            return
        }
        guard !isBusy else {
            showToast("Chat is already running in this session")
            return
        }
        let captured = ChatAttachmentTypeResolver.ScreenshotDraft(panelDraft, attachments: pendingAttachments)
        isCapturing = true
        isSubmittingSend = true
        showToast("Capturing screen...")
        Task {
            defer {
                isCapturing = false
                isSubmittingSend = false
            }
            await ChatAttachmentTypeResolver.sendScreenshot(captured, canSubmit: {
                ensureSessionIsAvailable()
            }, submit: { prompt, attachments in
                await appModel.startChatTurnForSession(prompt, attachments: attachments, sessionId: sessionId)
            }, accepted: { acceptedSessionId in
                guard acceptedSessionId == sessionId else { return }
                transcriptLatestRequest &+= 1
                scrollCoordinator.forceFollow()
                if captured.clearIfUnchanged(appModel: appModel, draft: panelDraft, attachments: &pendingAttachments) {
                    endPanelDictation()
                }
            }, showToast: showToast)
        }
    }

    private func composeVoiceDraft(_ transcript: String) -> String {
        ChatAttachmentTypeResolver.voiceDraft(base: voiceDraftBeforeListening, transcript: transcript)
    }

    private func attachFromClipboardOrPickFile() {
        guard ensureSessionIsAvailable() else { return }
        ChatAttachmentTypeResolver.attachFromClipboardOrPickFile(
            appendImage: {
                guard ensureSessionIsAvailable() else { return }
                pendingAttachments.append($0)
            },
            attachFile: attachLocalFile,
            showToast: showToast
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard ensureSessionIsAvailable() else { return }
        ChatAttachmentTypeResolver.attachProviders(
            providers,
            appendImage: {
                guard ensureSessionIsAvailable() else { return }
                pendingAttachments.append($0)
            },
            attachFile: attachLocalFile,
            showToast: showToast
        )
    }

    private func attachLocalFile(_ url: URL) {
        ChatAttachmentTypeResolver.attachLocalFile(
            url,
            to: appModel,
            sessionId: sessionId,
            resolveType: ChatAttachmentTypeResolver.typeAndMime,
            canAttach: ensureSessionIsAvailable,
            showToast: showToast
        )
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    private func ensureSessionIsAvailable() -> Bool {
        guard sessionIsAvailable else {
            showToast(DetachedChatSessionPresentation.unavailableActionMessage)
            return false
        }
        return true
    }
}

private let detachedBottomAnchor = "detached-chat-bottom-anchor"

/// Resolves the fixed destination of a mounted detached panel. The window can
/// outlive a session deletion, so a missing row is an unavailable destination,
/// never a generic chat named "Chat".
enum DetachedChatSessionPresentation: Equatable {
    case available(title: String)
    case unavailable

    static let unavailableTitle = "This chat session is no longer available"
    static let unavailableDetail = "Messages cannot be sent from this window. Close it and choose another conversation in the main app."
    static let unavailableActionMessage = "This chat session is no longer available. Your message was not sent."

    static func resolve(sessionId: String, sessions: [ChatSession]) -> Self {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            return .unavailable
        }
        return .available(title: session.displayTitle)
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// Plain-English copy for the detached panel's load-failure state. Pure strings
// so the wording is unit-testable; the view only decides where to put them.
enum DetachedChatLoadFailureCopy {
    static let message = "Your messages are safe. Check your connection, then close this window and open the chat again."

    /// The internal endpoint names, formatted as a secondary line. Nil when
    /// there is nothing specific to name.
    static func technicalDetail(failedEndpoints: [String]) -> String? {
        let named = failedEndpoints.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !named.isEmpty else { return nil }
        return "Did not respond: " + named.joined(separator: ", ")
    }
}

// Scopes the scroll anchor to the initial offset so content-size changes
// (hover timestamp, live resize reflow) never re-anchor the viewport; growth
// is TranscriptScrollView's. The .alignment role keeps short conversations
// sitting by the composer.
private struct DetachedScrollAnchorModifier: ViewModifier {
    let isEmpty: Bool

    func body(content: Content) -> some View {
        let anchor: UnitPoint = isEmpty ? .top : .bottom
        content
            .defaultScrollAnchor(anchor, for: .initialOffset)
            .defaultScrollAnchor(anchor, for: .alignment)
    }
}

/// Only the composer reads the draft, so keystrokes do not re-render the transcript.
private struct DetachedChatComposer: View {
    let draft: ChatComposerDraft
    let sessionId: String
    let placeholder: String
    let voiceInput: VoiceInputCapture
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let isRunning: Bool
    let hasQueuedTurns: Bool
    let isQueuePaused: Bool
    let sendAllowed: Bool
    @FocusState.Binding var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onToggleVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let onTranscript: (String) -> Void

    var body: some View {
        MacChatComposerControlStrip(
            isListening: voiceInput.isListening,
            screenCaptureAllowed: screenCaptureAllowed,
            screenCaptureDisabled: screenCaptureDisabled,
            pendingAttachmentCount: pendingAttachmentCount,
            isRunning: isRunning,
            hasQueuedTurns: hasQueuedTurns,
            isQueuePaused: isQueuePaused,
            canSend: sendAllowed
                && (ChatTranscriptPresentation.hasVisibleText(draft.text) || pendingAttachmentCount > 0),
            onToggleVoice: onToggleVoice,
            onCaptureScreen: onCaptureScreen,
            onAttach: onAttach,
            onStop: onStop,
            onSend: onSend,
            onFocusRequest: { inputFocused = true },
            isFocused: inputFocused,
            sessionId: sessionId
        ) {
            TextField(
                voiceInput.isListening ? "" : placeholder,
                text: draft.textBinding,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .fixedSize(horizontal: false, vertical: true)
            .focused($inputFocused)
            .shellComposerKeyboardTarget(
                isFocused: inputFocused,
                focus: { inputFocused = true },
                onPaste: onDrop
            )
            .foregroundStyle(voiceInput.isListening ? .secondary : .primary)
            .italic(voiceInput.isListening)
            .onSubmit(onSend)
            .onPasteCommand(of: ChatAttachmentTypeResolver.attachmentContentTypes, perform: onDrop)
            .onChange(of: voiceInput.transcript) { _, newVal in onTranscript(newVal) }
        }
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
            value: draft.text
        )
    }
}
