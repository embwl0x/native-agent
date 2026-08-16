// DetachedChatPanelView — the focused chat surface hosted inside a
// DetachedChatPanel (free-floating window for a single session).
//
// Deliberately narrower than the main ChatView: no session sidebar, model
// picker, persona switcher, file-access toggle, context bar, or slash-command
// help. It does include the same practical composer affordances the user expects:
// growing text input, voice input, screen capture, and file/image attachment.
// It reuses the main chat's render components (ChatMessageListView →
// MessageBubble/ToolPillView/ToolCallGroup/InlineApprovalCard) so message
// styling stays consistent across surfaces.
//
// Binds to AppModel's per-session storage (Phase 0): reads
// `appModel.chatMessages(for: sessionId)` and sends via
// `appModel.sendChat(_, sessionId:)`. Because that storage is a tracked
// @Observable dict, deltas streamed into this session's slot — even while
// the main window shows a different session — re-render here live.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NativeAgentCore
import PersistenceCore

struct DetachedChatPanelView: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    // chat-smoothness phase 6: respect Reduce Motion on the typing-chip fade.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The detached panel is hosted by AppKit, NOT by the SwiftUI Scene that
    // applies the app's dark-mode preference — so without this it rendered in
    // the OS appearance while the main window was dark (User, 2026-07-25).
    // Same @AppStorage key the main Window/Settings scenes read, so a live
    // toggle repaints open panels too.
    @AppStorage("nativeagent.darkMode") private var preferDarkAppearance = false

    @State private var didInitialLoad = false
    // True while the bottom anchor spacer is realized by the LazyVStack —
    // a free "user is at/near the bottom" sentinel (same trick as ChatView's
    // scroll coordinator; no geometry plumbing). Drives resize re-pinning.
    @State private var bottomAnchorVisible = true
    // Resize settle state (round 3): re-pinning on EVERY geometry tick made
    // scrollTo fight the live reflow — the round-2 "scroll flies around"
    // regression. One burst = snapshot was-at-bottom on the first tick, then
    // a debounced single re-pin after the size stops changing.
    @State private var resizeBurstToken = 0
    @State private var resizeWasAtBottom = false
    @State private var resizeSettleTask: Task<Void, Never>?
    // Render-cost audit F1 — streaming-delta scroll throttle.
    //
    // `.onChange(of: messages.last?.content)` fires on every coalesced delta
    // (~14 Hz for the whole turn, `chatStreamCoalesceSeconds = 0.07`), and each
    // one forced a LazyVStack realization/measurement pass toward the bottom
    // anchor. The main window has solved this since chat-smoothness phase 1;
    // the panel just never got the coordinator. Same type, same call shape as
    // `ChatView+SessionActions.swift:72-80`.
    //
    // THROTTLE ONLY — no behavior change. The coordinator's `autoFollow` gate
    // is a no-op here on purpose: nothing in this panel ever calls
    // `disarmFollow()`, so it stays `true` for the panel's whole life and the
    // guard always passes. Adding the user-disarm (the other half of F1) fixes
    // a real UX defect but is a behavior change, held as a separate NEEDS-USER
    // item. What lands here is strictly "same scrolls, at most ~6 Hz instead of
    // ~14 Hz" — the 0.16 s non-animated floor in `scrollToBottom`.
    @State private var scrollCoordinator = ChatScrollCoordinator()
    @State private var isCapturing = false
    @State private var toastMessage: String?
    @State private var voiceInput = VoiceInputController()
    @State private var voiceDraftBeforeListening = ""
    @FocusState private var inputFocused: Bool

    // H5 (gpt-5.5 review, 2026-07-09): same treatment as ChatView's composer —
    // in-progress text lives in view-local @State, so a keystroke here no
    // longer writes the observable `chatDrafts` dict and re-renders every view
    // observing it (the main window's session list among them). Committed back
    // at the points where it must survive this panel: send-clear and window
    // close. The panel's session is immutable, so there's no switch case.
    @State private var panelDraft = ""

    private var draft: String {
        get { panelDraft }
        nonmutating set { panelDraft = newValue }
    }

    private var draftBinding: Binding<String> {
        Binding(get: { panelDraft }, set: { panelDraft = $0 })
    }

    private var pendingAttachments: [MultimodalAttachment] {
        get { appModel.chatPendingAttachments[sessionId] ?? [] }
        nonmutating set { appModel.chatPendingAttachments[sessionId] = newValue }
    }

    private var messages: [ChatMessage] {
        appModel.chatMessages(for: sessionId)
    }

    private var loadStatus: AppModel.PanelRefreshStatus? {
        appModel.detachedChatRefreshStatus[sessionId]
    }

    private var contextReceiptStatus: AppModel.PanelRefreshStatus? {
        appModel.detachedChatContextReceiptRefreshStatus[sessionId]
    }

    private var loadPresentation: AppModel.CompactReadPresentationState {
        AppModel.compactReadPresentationState(hasContent: !messages.isEmpty, status: loadStatus)
    }

    private var isBusy: Bool {
        appModel.isSessionBusy(sessionId)
    }

    private var screenCaptureAllowed: Bool {
        appModel.trustPolicy?.multimodalPolicy?.screen_capture == true
    }

    private var sessionTitle: String {
        appModel.chatSessions.first(where: { $0.id == sessionId })?.displayTitle ?? "Chat"
    }

    private var personaName: String {
        // Her real name (persona profile), not the chatPersona style
        // quick-switch which reads "Custom"/"AI".
        appModel.agentDisplayName
    }

    var body: some View {
        VStack(spacing: 0) {
            messageScrollback
            Divider()
            inputBar
        }
        .frame(minWidth: 380, minHeight: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferDarkAppearance ? .dark : nil)
        .task(id: sessionId) {
            // Load history into the per-session slot on first appearance.
            // task(id:) re-fires if the panel is somehow rebound to a new
            // session, but in practice sessionId is immutable per panel.
            guard !didInitialLoad else { return }
            didInitialLoad = true
            // H5: adopt whatever draft this session had (typed in the main
            // window or a previous panel) into the view-local state.
            panelDraft = appModel.chatDraft(for: sessionId)
            await appModel.loadDetachedSessionMessages(sessionId)
            inputFocused = true
        }
        // Telegram, Slack, iOS, bridge, and local turns all converge on the
        // canonical transcript. Watch that exact file while this panel is
        // mounted so every surface appears live without an idle refresh loop.
        .task(id: "detached-transcript:\(sessionId)") {
            guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
                return
            }
            let transcript = PersistenceCore.defaultDataRoot()
                .appendingPathComponent("chat/messages", isDirectory: true)
                .appendingPathComponent("\(safeSessionId).jsonl")
            await ViewFileRefreshTask.run(
                paths: [transcript],
                debounceDelay: .milliseconds(100)
            ) {
                await appModel.refreshDetachedChatMessagesAfterTurn(sessionId: sessionId)
            }
        }
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
            // F1: invalidate any scroll scheduled against the now-dead proxy
            // (same contract as `ChatView.swift:1032`).
            scrollCoordinator.markViewDisappeared()
            // H5: hand the uncommitted draft back so closing the panel never
            // eats typed text (the main window adopts it on session switch).
            appModel.commitChatDraft(panelDraft, sessionId: sessionId)
        }
    }

    // MARK: - Scrollback

    private var messageScrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if loadPresentation == .stale {
                        Label("History refresh failed; showing last known messages.", systemImage: "exclamationmark.triangle.fill")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.yellow)
                    }
                    if let receiptWarning = AppModel.detachedContextReceiptWarning(
                        history: loadPresentation,
                        receiptStatus: contextReceiptStatus
                    ) {
                        Label(receiptWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.yellow)
                    }
                    if messages.isEmpty {
                        detachedEmptyState
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        // Reuse the main chat's grouped render path so tool
                        // pills, approval cards, and bubbles look identical.
                        ChatMessageListView(messages: messages, sessionId: sessionId, isStreaming: isBusy)
                    }
                    // phase 6: scoped fade for the detached typing chip (mirrors
                    // the main-list pattern) so it doesn't pop in/out.
                    let showDetachedTyping = isBusy && (messages.last?.role != "assistant"
                        || (messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
                    ZStack {
                        if showDetachedTyping {
                            TypingIndicator(personaName: appModel.agentDisplayName)
                                .transition(.opacity)
                        }
                    }
                    .animation(
                        NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                        value: showDetachedTyping)
                    Color.clear.frame(height: 1).id(detachedBottomAnchor)
                        // Inside the LazyVStack this spacer is only realized
                        // when the viewport is at/near the bottom, so its
                        // appearance is the "pinned to bottom" signal.
                        .onAppear { bottomAnchorVisible = true }
                        .onDisappear { bottomAnchorVisible = false }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // phase 6: bubble entrance is driven by the append seam's
                // withAnimation (appendChatMessage) — no list-level animation
                // key here, so wholesale replaces stay instant.
            }
            // Anchor the INITIAL offset only (User, 2026-07-25 round 2). The
            // first-round blanket .defaultScrollAnchor(.bottom) fixed opening
            // at the top but re-anchored on EVERY content-size change too:
            // hovering a bubble inserts its timestamp row
            // (ChatMessageListView:919) → height change → re-pin → the view
            // "pops up from the bottom"; a live window resize reflows every
            // LazyVStack row per frame → re-pin per frame → scroll thrown
            // across the conversation. Scoping to .initialOffset keeps the
            // open-at-bottom win while size changes leave the offset alone
            // (mid-list hover now nudges only content BELOW the hovered
            // bubble, same as the main window). Resize-while-at-bottom is
            // re-pinned explicitly below via the bottom sentinel. macOS 14
            // fallback keeps the blanket anchor — open-at-bottom is the
            // bigger win and User runs 26.x.
            // Empty/placeholder states anchor to the TOP: the anchor also
            // aligns content SHORTER than the viewport, and a lone empty-state
            // card shoved to the bottom of a 600pt panel reads as broken.
            .modifier(DetachedScrollAnchorModifier(isEmpty: messages.isEmpty))
            // Messages-style resize: if the user was at the bottom when the
            // resize STARTED, snap the latest message back to the composer
            // once the size settles; if they'd scrolled up to read history,
            // leave their place alone. Deliberately debounced — a per-tick
            // scrollTo mid-drag fights the LazyVStack reflow and throws the
            // scroll around (round-2 failure). The was-at-bottom snapshot is
            // taken on the burst's FIRST tick because shrinking the viewport
            // can push the sentinel spacer out of realization mid-drag.
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size) {
                        if resizeSettleTask == nil {
                            resizeWasAtBottom = bottomAnchorVisible
                        }
                        resizeBurstToken += 1
                        let token = resizeBurstToken
                        resizeSettleTask?.cancel()
                        resizeSettleTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            // A newer tick superseded this one (its own task
                            // owns the settle) — bail without touching state.
                            guard token == resizeBurstToken else { return }
                            if resizeWasAtBottom {
                                proxy.scrollTo(detachedBottomAnchor, anchor: .bottom)
                            }
                            resizeSettleTask = nil
                        }
                    }
                }
            )
            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(detachedBottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: messages.last?.content) {
                // Follow streaming deltas to the bottom — coalesced (F1). The
                // message-COUNT path above stays immediate and animated: an
                // append is one event, not a 14 Hz stream, and deferring it
                // would be a visible timing change on bubble entrance.
                scrollCoordinator.scrollToBottom(
                    proxy,
                    bottomAnchor: detachedBottomAnchor,
                    animated: false,
                    delay: 0
                )
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
                // Public-era honesty copy (2026-08-01): the headline used to be
                // a list of internal endpoint names. Plain sentence first, what
                // to try second, endpoint names last in a smaller line that
                // also carries the full list as a tooltip.
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
            }
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Detached session")
                .font(NativeAgentFont.section)
            Text("Messages you send here go to “\(sessionTitle)”. This window stays open and pinned until you close it.")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { att in
                            DetachedAttachmentChip(attachment: att) {
                                pendingAttachments.removeAll { $0.id == att.id }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            if isBusy {
                DetachedThinkingRow(
                    personaName: appModel.agentDisplayName,
                    onStop: { appModel.stopChatStream(sessionId: sessionId) }
                )
            }

            ChatQueuedTurnsView(sessionId: sessionId, isBusy: isBusy)

            if let toastMessage {
                Text(toastMessage)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    toggleVoice()
                } label: {
                    Image(systemName: voiceInput.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(voiceInput.isListening ? Color.red : Color.primary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(voiceInput.isListening ? "Stop listening" : "Voice input")
                .accessibilityLabel(voiceInput.isListening ? "Stop listening" : "Voice input")

                Button {
                    captureScreen()
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(screenCaptureAllowed ? "Show agent my screen" : "Enable screen capture in Trust -> Multimodal Capabilities")
                .accessibilityLabel("Show agent my screen")
                .disabled(isBusy || isCapturing || !screenCaptureAllowed)

                ZStack(alignment: .topTrailing) {
                    Button {
                        attachFromClipboardOrPickFile()
                    } label: {
                        Image(systemName: "paperclip")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Attach image or file")
                    .accessibilityLabel("Attach image or file")

                    if !pendingAttachments.isEmpty {
                        Text("\(pendingAttachments.count)")
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(NativeAgentBrand.accent, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }

                TextField(
                    voiceInput.isListening ? "" : "Message \(personaName)…",
                    text: draftBinding,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .fixedSize(horizontal: false, vertical: true)
                .focused($inputFocused)
                .foregroundStyle(voiceInput.isListening ? .secondary : .primary)
                .italic(voiceInput.isListening)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))
                .onSubmit(send)
                .onChange(of: voiceInput.transcript) { _, newVal in
                    if !newVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        draft = composeVoiceDraft(newVal)
                    }
                }

                if isBusy {
                    Button {
                        appModel.stopChatStream(sessionId: sessionId)
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop generation")
                }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(isBusy ? "Queue message to send next" : "Send message")
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(NativeAgentMotion.snappy, value: draft)
        .animation(NativeAgentMotion.snappy, value: pendingAttachments.count)
        .focusedSceneValue(\.chatCommandActions, ChatFocusedCommandActions(
            send: send,
            attach: attachFromClipboardOrPickFile,
            toggleVoice: toggleVoice,
            focusComposer: { inputFocused = true }
        ))
    }

    private var canSend: Bool {
        !isCapturing
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !isCapturing, (!text.isEmpty || !attachments.isEmpty) else { return }
        Task { @MainActor in
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
                draft = ""
                appModel.commitChatDraft("", sessionId: sessionId)
                pendingAttachments = []
            case .rejected(let message):
                showToast(message)
            }
        }
    }

    private func toggleVoice() {
        if voiceInput.isListening {
            Task { @MainActor in
                let final = await voiceInput.stopListening()
                if final.isEmpty {
                    draft = voiceDraftBeforeListening
                    showToast("No speech detected")
                } else {
                    draft = composeVoiceDraft(final)
                }
                voiceDraftBeforeListening = ""
            }
        } else {
            voiceInput.errorMessage = nil
            showToast("Checking microphone...")
            Task {
                let granted = await voiceInput.requestPermission()
                guard granted else {
                    showToast(voiceInput.errorMessage ?? "Microphone or speech permission denied.")
                    return
                }
                voiceDraftBeforeListening = draft
                voiceInput.startListening()
                if let msg = voiceInput.errorMessage, !voiceInput.isListening {
                    showToast(msg)
                } else if voiceInput.isListening {
                    showToast("Listening")
                }
            }
        }
    }

    private func captureScreen() {
        guard !isCapturing else { return }
        guard screenCaptureAllowed else {
            showToast("Enable screen capture in Trust -> Multimodal Capabilities")
            return
        }
        guard !isBusy else {
            showToast("Chat is already running in this session")
            return
        }
        let capturedDraft = draft
        let capturedAttachments = pendingAttachments
        let capturedAttachmentIds = Set(capturedAttachments.map(\.id))
        let prompt = capturedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Look at this screenshot and tell me what you see."
            : capturedDraft
        isCapturing = true
        showToast("Capturing screen...")
        Task {
            defer { isCapturing = false }
            do {
                let capture = try await Task.detached(priority: .userInitiated) {
                    try await NativeScreenCapture.captureImageBase64()
                }.value
                let mb = Double(capture.byteSize) / (1024.0 * 1024.0)
                showToast(String(format: "Sending screenshot (%.1f MB)...", mb))
                let attachment = MultimodalAttachment(
                    type: "image",
                    base64: capture.base64,
                    mime: capture.mime,
                    name: capture.name,
                    byteSize: capture.byteSize
                )
                let acceptance = await appModel.startChatTurnForSession(
                    prompt,
                    attachments: capturedAttachments + [attachment],
                    sessionId: sessionId
                )
                switch acceptance {
                case .accepted, .queued:
                    let currentAttachmentIds = Set(pendingAttachments.map(\.id))
                    guard draft == capturedDraft,
                          currentAttachmentIds == capturedAttachmentIds
                    else { return }
                    draft = ""
                    appModel.commitChatDraft("", sessionId: sessionId)
                    pendingAttachments = []
                case .rejected(let message):
                    showToast(message)
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func composeVoiceDraft(_ transcript: String) -> String {
        let base = voiceDraftBeforeListening.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return spoken }
        if spoken.isEmpty { return base }
        return "\(base) \(spoken)"
    }

    private func attachFromClipboardOrPickFile() {
        if clipboardHasImage() {
            if let att = pasteImageFromClipboard() {
                pendingAttachments.append(att)
                showToast("Image pasted from clipboard")
                return
            }
            showToast("Clipboard image could not be pasted; choose a file instead")
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .text, .data]
        panel.prompt = "Attach"
        panel.message = "Choose an image or document to attach to your chat."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            attachLocalFile(url)
        }
    }

    private func attachLocalFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard let attachmentInfo = detachedChatAttachmentTypeAndMime(forExtension: ext) else {
            showToast("Unsupported file type: \(ext.isEmpty ? "(no extension)" : ext)")
            return
        }
        if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = attrs.fileSize, size > 10_000_000 {
            showToast("File too large (limit: 10 MB): \(url.lastPathComponent)")
            return
        }
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                try? Data(contentsOf: url)
            }.value
            guard let data else {
                showToast("Couldn't read file: \(url.lastPathComponent)")
                return
            }
            let att = MultimodalAttachment(
                type: attachmentInfo.type,
                base64: data.base64EncodedString(),
                mime: attachmentInfo.mime,
                name: url.lastPathComponent,
                byteSize: data.count
            )
            appModel.chatPendingAttachments[sessionId, default: []].append(att)
            showToast("Attached \(url.lastPathComponent)")
        }
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
}

private let detachedBottomAnchor = "detached-chat-bottom-anchor"

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

// Scopes the scroll anchor to the initial offset on macOS 15+ so content-size
// changes (hover timestamp, live resize reflow) never re-anchor the viewport.
// The .alignment role keeps short conversations sitting by the composer.
// macOS 14 lacks ScrollAnchorRole, so it falls back to the blanket anchor.
private struct DetachedScrollAnchorModifier: ViewModifier {
    let isEmpty: Bool

    func body(content: Content) -> some View {
        let anchor: UnitPoint = isEmpty ? .top : .bottom
        if #available(macOS 15.0, *) {
            content
                .defaultScrollAnchor(anchor, for: .initialOffset)
                .defaultScrollAnchor(anchor, for: .alignment)
        } else {
            content
                .defaultScrollAnchor(anchor)
        }
    }
}

private struct DetachedThinkingRow: View {
    var personaName: String
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("\(personaName) is thinking")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Stop", systemImage: "stop.fill", action: onStop)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func detachedChatAttachmentTypeAndMime(forExtension ext: String) -> (type: String, mime: String)? {
    switch ext {
    case "png": return ("image", "image/png")
    case "jpg", "jpeg": return ("image", "image/jpeg")
    case "heic": return ("image", "image/heic")
    case "webp": return ("image", "image/webp")
    case "gif": return ("image", "image/gif")
    case "pdf": return ("file", "application/pdf")
    case "docx": return ("file", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    case "txt", "md": return ("file", "text/plain")
    default: return nil
    }
}

private struct DetachedAttachmentChip: View {
    var attachment: MultimodalAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.type == "image" ? "photo" : "doc")
                .font(.caption2)
            Text(attachment.name ?? (attachment.type == "image" ? "image" : "file"))
                .font(.caption2)
                .lineLimit(1)
            if attachment.byteSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button { onRemove() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
