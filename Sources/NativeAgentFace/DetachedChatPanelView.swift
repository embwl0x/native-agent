import Foundation
import SwiftUI
import NativeAgentShared
import AppKit
// Blueprint: | `DetachedChatPanelView.swift` | `DetachedChatPanelView`: session transcript/composer through shared owners |



struct DetachedChatPanelView: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var didInitialLoad = false
    /// Find, Latest and the at-end signal for this panel's document.
    @State private var transcriptHandle = TranscriptDocumentHandle()
    /// The turn card's height over the document's end; the document keeps its last line above it.
    @State private var turnCardHeight: CGFloat = 0
    /// The app's one presenter of a card's own control: the sheet or panel it opens shows over this panel too.
    private var inlineCards: CardControls { CardControls.shared }
    @State private var isCapturing = false
    @State private var isRetryingLoad = false
    @State private var toastMessage: String?
    @State private var voiceInput = FaceVoiceInput()
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

    private var pendingAttachments: [FaceAttachment] {
        get { appModel.chatPendingAttachments[sessionId] ?? [] }
        nonmutating set { appModel.chatPendingAttachments[sessionId] = newValue }
    }

    private var conversationState: FaceReadState? {
        appModel.face.slot(.conversation(session: sessionId)).select("state", as: ConversationFace.self) { $0?.state }
    }

    private var knownEmpty: Bool? {
        let id = sessionId
        return appModel.face.slot(.sessions).select("empty:\(id)", as: SessionListFace.self) {
            guard let value = $0, value.allIDs.contains(id) else { return nil }
            return value.emptyIDs.contains(id)
        }
    }

    private var isBusy: Bool {
        appModel.turnPart("isBusy", for: sessionId) { $0?.isBusy == true }
    }

    private var screenCaptureAllowed: Bool {
        appModel.settingsScreenCaptureEnabled == true
    }

    private var sessionPresentation: DetachedChatSessionPresentation {
        let presentation = appModel.face.slot(.session(sessionId)).select("detachedSession", as: SessionRowFace.self) { row in
            guard let row else { return DetachedChatSessionPresentation.waiting }
            return row.isPresent ? .available(title: row.title) : .unavailable
        }
        return presentation
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
            InboxStripContainer { notes in
                notes
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
            }
            messageScrollback
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
            inputFocused = true
        }
        .modifier(FaceObservation(demand: .key(.conversation(session: sessionId))))
        .modifier(FaceDictationObservation(input: voiceInput))
        .onChange(of: sessionTitle, initial: true) { _, title in
            guard let title else { return }
            DetachedChatWindowController.shared.updateTitle(
                sessionId: sessionId,
                title: title
            )
        }
        .inlineCardSetup(inlineCards, sessionID: sessionId)
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
            detachedSessionUnavailableState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch conversationState {
            case .ready?:
                if knownEmpty == true { emptyState.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { document }
            case .unavailable(let failure)?:
                VStack(spacing: 8) {
                    Text(failure.localizedDescription).textSelection(.enabled).foregroundStyle(.red)
                    Button(isRetryingLoad ? "Reading conversation…" : "Try reading again") { retryDetachedHistoryLoad() }
                        .disabled(isRetryingLoad)
                    document
                }
            case .waiting(let on)?: document.overlay { ProgressView("Waiting on " + on + "…") }
            case nil: document
            }
        }
    }

    private var document: some View {
        TranscriptDocumentView(sessionID: sessionId, bottomInset: turnCardHeight, handle: transcriptHandle)
            .environment(\.transcriptOpenSettings) { [inlineCards] in inlineCards.openPage(.settings) }
    }

    /// This session's turn card, faded in and out; its measured height (zero when hidden) is the document's bottom inset.
    private var turnCard: some View {
        let shows = appModel.turnPart("hasCard", for: sessionId) { $0?.card != nil }
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
            Text(sessionPresentation == .waiting ? "Waiting on this conversation…" : DetachedChatSessionPresentation.unavailableTitle)
                .font(NativeAgentFont.section)
            Text(sessionPresentation == .waiting ? "Close this window to cancel waiting." : DetachedChatSessionPresentation.unavailableDetail)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            sessionPresentation == .waiting ? "Waiting on this conversation. Close this window to cancel waiting."
                : DetachedChatSessionPresentation.unavailableTitle + ". " + DetachedChatSessionPresentation.unavailableDetail
        )
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 8) {
            MacChatOtherSessionsBanner(sessionID: sessionId)
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments, id: \.id) { att in
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
                sendAllowed: sessionIsAvailable && !isCapturing && !appModel.providerSavingChatBrain,
                inputFocused: $inputFocused,
                onToggleVoice: toggleVoice,
                onDiscardVoice: discardPanelDictation,
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
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Capture draft identity and edit time so acceptance clears only what was sent.
        let sentDraft = panelDraft.text
        let sentDraftEditedAt = panelDraft.editedAt
        let revision = panelDraft.manualEditRevision
        let attachments = pendingAttachments
        guard !isCapturing, (!text.isEmpty || !attachments.isEmpty) else { return }
        switch ChatSlashCommandRouting.decide(text: text, supportsDispatch: false) {
        case .unsupportedHere(let command): showToast(ChatSlashCommandRouting.unsupportedMessage(command: command)); return
        case .unknownCommand(let command): showToast(ChatSlashCommandRouting.unknownMessage(command: command)); return
        case .sendAsMessage: break
        case .dispatch: showToast("Open the main chat window to use slash commands."); return
        }
        isSubmittingSend = true
        Task { @MainActor in
            defer { isSubmittingSend = false }
            let acceptance = await appModel.startChatTurnForSession(
                text,
                attachments: attachments,
                sessionId: sessionId, composerRevision: revision
            )
            switch acceptance {
            case .accepted:
                guard draft.trimmingCharacters(in: .whitespacesAndNewlines) == text,
                      panelDraft.editedAt == sentDraftEditedAt, panelDraft.manualEditRevision == revision,
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
        voiceInput.discardListening()
    }

    private func discardPanelDictation() {
        if voiceAcceptsTranscript, panelDraft.manualEditRevision == voiceDraftRevision {
            panelDraft.edit(voiceDraftBeforeListening)
        }
        endPanelDictation()
    }

    private func toggleVoice() {
        if voiceInput.isStarting { discardPanelDictation(); return }
        if voiceInput.isListening {
            Task { @MainActor in _ = await finishPanelDictation() }
        } else {
            let requestedGeneration = voiceGeneration
            Task {
                guard requestedGeneration == voiceGeneration else { return }
                if voiceAcceptsTranscript {
                    guard await finishPanelDictation() else { return }
                }
                let startGeneration = voiceGeneration
                let listening = await ChatAttachmentTypeResolver.beginDictation(
                    voiceInput, client: appModel.client, draft: panelDraft,
                    isCurrent: { startGeneration == voiceGeneration },
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
        guard !isCapturing else { return }
        // Share the send latch: screenshot admission suspends before the session is marked busy.
        guard !isSubmittingSend else { return }
        let captured = ChatAttachmentTypeResolver.ScreenshotDraft(panelDraft, attachments: pendingAttachments)
        isCapturing = true
        isSubmittingSend = true
        showToast("Capturing screen...")
        Task {
            defer {
                isCapturing = false
                isSubmittingSend = false
            }
            await ChatAttachmentTypeResolver.sendScreenshot(captured, client: appModel.client, expectedSelection: nil, canSubmit: {
                true
            }, submit: { prompt, attachments in
                await appModel.startChatTurnForSession(prompt, attachments: attachments, sessionId: sessionId, composerRevision: captured.revision)
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
        ChatAttachmentTypeResolver.attachFromClipboardOrPickFile(
            appModel: appModel, session: sessionId,
            appendImage: {
                pendingAttachments.append($0)
            },
            attachFile: attachLocalFile,
            showToast: showToast
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        ChatAttachmentTypeResolver.attachProviders(
            providers, appModel: appModel, session: sessionId,
            appendImage: {
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
            showToast: showToast
        )
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

}

enum DetachedChatSessionPresentation: Equatable {
    case available(title: String)
    case waiting
    case unavailable

    static let unavailableTitle = "This chat session is no longer available"
    static let unavailableDetail = "Messages cannot be sent from this window. Close it and choose another conversation in the main app."
    static let unavailableActionMessage = "This chat session is no longer available. Your message was not sent."

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Only the composer reads the draft so keystrokes do not redraw the transcript.
private struct DetachedChatComposer: View {
    let draft: ChatComposerDraft
    let sessionId: String
    let placeholder: String
    let voiceInput: FaceVoiceInput
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let isRunning: Bool
    let sendAllowed: Bool
    @FocusState.Binding var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onToggleVoice: () -> Void
    let onDiscardVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let onTranscript: (String) -> Void

    var body: some View {
        MacChatComposerControlStrip(
            isListening: voiceInput.isListening || voiceInput.isStarting,
            isStopping: voiceInput.isStopping,
            screenCaptureAllowed: screenCaptureAllowed,
            screenCaptureDisabled: screenCaptureDisabled,
            pendingAttachmentCount: pendingAttachmentCount,
            isRunning: isRunning,
            canSend: { sendAllowed && (draft.hasVisibleText || pendingAttachmentCount > 0) },
            onToggleVoice: onToggleVoice,
            onDiscardVoice: onDiscardVoice,
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
            .accessibilityIdentifier(FaceComposerFocus.identifier(session: sessionId))
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
            .onPasteCommand(of: [.fileURL, .image], perform: onDrop)
            .onChange(of: voiceInput.transcript) { _, newVal in onTranscript(newVal) }
        }
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
            value: draft.text
        )
    }
}
