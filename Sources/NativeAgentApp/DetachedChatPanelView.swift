import Cognition
import EngineRuntime
import Dispatcher
import ChatTurnRuntime
import ChatSessionWork
import ToolRegistry

// Blueprint: | `DetachedChatPanelView.swift` | `DetachedChatPanelView`: session transcript/composer through shared owners |

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
    /// Find, Latest and the at-end signal for this panel's document.
    @State private var transcriptHandle = TranscriptDocumentHandle()
    /// The turn card's height over the document's end; the document keeps its last line above it.
    @State private var turnCardHeight: CGFloat = 0
    /// Read cards from the shared transcript so detached conversations expose the same actionable controls.
    @State private var inlineCards = InlineInteractionChatBinding()
    @State private var isCapturing = false
    @State private var isRetryingLoad = false
    @State private var toastMessage: String?
    @State private var voiceInput = VoiceInputCapture.forChat()
    @State private var voiceDraftBeforeListening = ""
    @State private var voiceDraftRevision: UInt64 = 0
    /// Ending dictation must invalidate pending starts and late transcripts.
    @State private var voiceGeneration = 0
    @State private var voiceAcceptsTranscript = false
    @FocusState private var inputFocused: Bool
    /// Hold the send latch synchronously across acceptance to prevent duplicate drafts.
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

    private var sessionTitle: String? {
        if case .available(let title) = sessionPresentation { return title }
        return nil
    }

    private var personaName: String {
        // Use the canonical persona name; chatPersona names a style rather than the agent.
        appModel.agentDisplayName
    }

    var body: some View {
        VStack(spacing: 0) {
            InboxStripContainer(sessionID: sessionId, interactionBinding: inlineCards) { notes in
                notes
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
            }
            messageScrollback
                .preparesTranscriptGroups(sessionId)
                // The shared turn card floats over the document's end; its height is the document's bottom inset.
                .overlay(alignment: .bottom) { turnCard }
            Divider()
            inputBar
                .disabled(!sessionIsAvailable)
        }
        .frame(minWidth: 380, minHeight: 280)
        .modifier(ChatAttachmentDropTarget(isEnabled: sessionIsAvailable, onDrop: {
            handleDrop($0)
            return true
        }))
        .background {
            ShellSheet().overlay { WindowHaze(sessionId: sessionId) }
        }
        .preferredColorScheme(AppearanceController.shared.colorScheme)
        .task(id: sessionId) {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await appModel.loadDetachedSessionMessages(sessionId)
            await appModel.engine.transcripts.reclaimContinuations(for: sessionId)
            inputFocused = true
        }
        // Watch this session's canonical transcript so remote and local turns appear without idle polling.
        .task(id: "detached-transcript:\(sessionId)") {
            await appModel.engine.transcripts.watchChanges(sessionID: sessionId) {
                await appModel.readDetachedTranscript(sessionId: sessionId)
            }
        }
        .onChange(of: sessionTitle) { _, title in
            guard let title else { return }
            DetachedChatWindowController.shared.updateTitle(
                sessionId: sessionId,
                title: title
            )
        }
        // Reverify page-backed cards only when this panel regains focus; another window becoming key does not mean its control closed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? DetachedChatPanel)?.sessionId == sessionId else { return }
            Task { await inlineCards.verifyOnReturn() }
        }
        .inlineCardSetup(inlineCards)
        .onDisappear {
            endPanelDictation()
        }
        .focusedSceneValue(\.chatCommandActions, ChatFocusedCommandActions(
            send: send,
            attach: attachFromClipboardOrPickFile,
            toggleVoice: toggleVoice,
            focusComposer: { inputFocused = true },
            focusTranscriptSearch: { transcriptHandle.showFind() },
            findNext: { transcriptHandle.findNext() },
            findPrevious: { transcriptHandle.findPrevious() }
        ))
    }

    // MARK: - Scrollback

    /// The session as one document; a panel whose session is gone, empty or still loading shows that state instead.
    @ViewBuilder
    private var messageScrollback: some View {
        if !sessionIsAvailable {
            detachedSessionUnavailableState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if messages.isEmpty {
            detachedEmptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TranscriptDocumentView(
                sessionID: sessionId,
                groups: appModel.engine.transcripts.groups(for: sessionId),
                cardsByRow: TranscriptReadout(messages: messages).cardsByRow,
                exchanges: appModel.engine.contactThreads.otherRooms.filter { $0.sessionID != sessionId },
                showsTrouble: ChatTurnFailure.read(messages) != nil,
                streamingMessageID: appModel.engine.turns.streamingBubbleIds[sessionId],
                bottomInset: turnCardHeight,
                handle: transcriptHandle
            )
            .environment(\.inlineCardAction) { [inlineCards, appModel] card, action in
                inlineCards.handle(card: card, action: action, appModel: appModel)
            }
            .environment(\.transcriptOpenSettings) { [inlineCards] in inlineCards.openPage(.settings) }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    if loadPresentation == .stale {
                        Label("History refresh failed; showing last known messages.", systemImage: "exclamationmark.triangle.fill")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.yellow)
                    }
                    if case .unavailable(let reason) = appModel.engine.transcripts.transcriptReadStatus(for: sessionId) {
                        Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            }
        }
    }

    /// This session's turn card, faded in and out; its measured height (zero when hidden) is the document's bottom inset.
    private var turnCard: some View {
        let shows = TurnCardReadout.isVisible(
            appModel.engine.turns.lifecycle(for: sessionId),
            sessionId: sessionId,
            approvals: appModel.engine.approvals.records,
            parseTimestamp: NativeTimestampFormat.parseISO8601FractionalFirst
        )
        return ZStack(alignment: .bottom) {
            if shows {
                MacChatTurnCardHost(
                    sessionId: sessionId,
                    onStop: { appModel.stopChatStream(sessionId: sessionId) }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .fixedSize(horizontal: false, vertical: true)
                .transition(NativeAgentMotion.fade)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { turnCardHeight = $0 }
        .animation(NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion), value: shows)
    }

    @ViewBuilder
    private var detachedEmptyState: some View {
        if loadPresentation == .unavailable {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.yellow)
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
                sendAllowed: sessionIsAvailable && !isCapturing && !appModel.isSavingChatBrain,
                inputFocused: $inputFocused,
                onToggleVoice: toggleVoice,
                onCaptureScreen: captureScreen,
                onAttach: attachFromClipboardOrPickFile,
                onDrop: handleDrop,
                onStop: { appModel.stopChatStream(sessionId: sessionId) },
                onSend: send,
                onTranscript: { newVal in
                    // Only live dictation may replace the draft with its cumulative transcript.
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
        // Capture draft identity and edit time so acceptance clears only what was sent.
        let sentDraft = panelDraft.text
        let sentDraftEditedAt = panelDraft.editedAt
        let attachments = pendingAttachments
        guard !isCapturing, (!text.isEmpty || !attachments.isEmpty) else { return }
        switch ChatSlashCommandRouting.decide(
            text: text,
            supportsDispatch: false
        ) {
        case .unsupportedHere(let command):
            showToast(ChatSlashCommandRouting.unsupportedMessage(command: command))
            return
        case .unknownCommand(let command):
            showToast(ChatSlashCommandRouting.unknownMessage(command: command))
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
            case .accepted:
                guard draft.trimmingCharacters(in: .whitespacesAndNewlines) == text,
                      pendingAttachments == attachments
                else { return }
                appModel.clearChatDraftAfterSend(
                    sentDraft,
                    sessionId: sessionId,
                    editedAt: sentDraftEditedAt
                )
                pendingAttachments = []
                transcriptHandle.goToLatest()
                // Stop dictation after sending so its cumulative transcript cannot refill the cleared composer.
                endPanelDictation()
            case .rejected(let message):
                showToast(message)
            }
        }
    }

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
        // Share the send latch: screenshot admission suspends before the session is marked busy.
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
                transcriptHandle.goToLatest()
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

/// A panel can outlive its session; a missing row is unavailable, never a generic Chat destination.
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

// Keep load-failure copy independent of the view's placement decisions.
enum DetachedChatLoadFailureCopy {
    static let message = "Your messages are safe. Check your connection, then close this window and open the chat again."

    static func technicalDetail(failedEndpoints: [String]) -> String? {
        let named = failedEndpoints.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !named.isEmpty else { return nil }
        return "Did not respond: " + named.joined(separator: ", ")
    }
}

/// Only the composer reads the draft so keystrokes do not redraw the transcript.
private struct DetachedChatComposer: View {
    let draft: ChatComposerDraft
    let sessionId: String
    let placeholder: String
    let voiceInput: VoiceInputCapture
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let isRunning: Bool
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
