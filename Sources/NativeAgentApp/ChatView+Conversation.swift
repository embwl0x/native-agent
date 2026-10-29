import EngineRuntime
import ChatTurnRuntime
import ChatSessionWork
import AppToolRuntime
import MultimodalTTS
import SwiftUI
import AppKit
import NativeAgentShared
import Transcripts
// Blueprint: | `ChatView+Conversation.swift` | `ChatView`: transcript viewport, composer, search/navigation and cross-door turn observation; existing quiet and visibility gates |

extension ChatView {
    private func runningSessionRoutes(_ sessionIds: [String]) -> [MacChatRunningSessionRoute] {
        MacChatRunningSessionRoute.routes(
            sessionIds: sessionIds,
            sessions: appModel.engine.transcripts.sessions
        )
    }

    private func goToRunningSession(_ sessionId: String) {
        runningSessionNavigationGeneration &+= 1
        let generation = runningSessionNavigationGeneration
        Task { @MainActor in
            let navigated = await MacChatRunningSessionNavigation.navigate(
                sessionId: sessionId,
                sessions: { appModel.engine.transcripts.sessions },
                refresh: { await appModel.refreshChatSessionIndex() },
                select: { session in
                    await appModel.selectChatSession(session)
                    // The selector intentionally reports errors through state
                    // rather than throws. Verify the identity actually moved
                    // before claiming this navigation succeeded.
                    return appModel.activeChatSessionId == session.id
                },
                isCurrentIntent: {
                    runningSessionNavigationGeneration == generation
                }
            )
            guard runningSessionNavigationGeneration == generation else { return }
            if !navigated {
                appModel.statusText = "Running chat is not available in the session index yet"
                showToast("Couldn’t open that running chat. Try again in a moment.")
            }
        }
    }

    func openTranscriptSearch() {
        showTranscriptSearch = true
        transcriptSearchFocusRequest &+= 1
        transcriptSearch.replaceSource(
            messages: appModel.chatMessages,
            sessionID: appModel.activeChatSessionId,
            revision: appModel.engine.transcripts.structureVersion(for: appModel.activeChatSessionId)
        )
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

    func refreshTranscriptSearchIfPresented() {
        guard showTranscriptSearch, chatPageIsVisible else { return }
        transcriptSearch.replaceSource(
            messages: appModel.chatMessages,
            sessionID: appModel.activeChatSessionId,
            revision: appModel.engine.transcripts.structureVersion(for: appModel.activeChatSessionId)
        )
    }

    func refreshTranscriptSearchTailIfPresented() {
        guard showTranscriptSearch, chatPageIsVisible else { return }
        transcriptSearch.replaceLastMessage(
            appModel.chatMessages.last,
            ordinal: appModel.chatMessages.count - 1,
            sessionID: appModel.activeChatSessionId
        )
    }

    private func receiveTurnNotice(_ note: Notification) {
        guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
        // Session-scoped notices require the active conversation; unscoped notices remain visible.
        if let noticeSession = note.userInfo?["sessionId"] as? String,
           !noticeSession.isEmpty,
           noticeSession != appModel.activeChatSessionId {
            return
        }
        let kind = (note.userInfo?["kind"] as? String) ?? ""
        switch ChatTurnNoticePresentation.destination(for: kind) {
        case .chatTop:
            if chatPageIsVisible { pushChatTopNotice(text, kind: kind) }
        case .globalWarning:
            appModel.systemToasts.push(warn: text)
        case .globalInfo:
            appModel.systemToasts.push(info: text, autoDismissAfter: 6)
        }
    }

    /// A conversation still being read is not an empty one: until its first
    /// read lands, it shows nothing rather than a greeting it does not have.
    var transcriptRead: Bool {
        let id = appModel.activeChatSessionId
        guard !id.isEmpty else { return true }
        // Read, and grouped: its rows are ready to draw (grouping lands after the read).
        return appModel.engine.transcripts.hasCachedTranscript(for: id)
            && (appModel.chatMessages.isEmpty || !appModel.engine.transcripts.groups(for: id).isEmpty)
    }

    @ViewBuilder
    var chatColumn: some View {
        VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    TranscriptScrollView(
                        coordinator: scrollCoordinator,
                        isActive: chatPageIsVisible,
                        // Paged back to an earlier page, its bottom is not the
                        // live one: ask for the latest page, which clears the
                        // anchor and scrolls there, or replies would stream in
                        // off the page.
                        onRearm: { if scrollCoordinator.transcriptPagedBack { transcriptLatestRequest &+= 1 } }
                    ) {
                        VStack(alignment: .leading, spacing: NativeAgentShellLayout.transcriptGap) {
                            if !transcriptRead {
                                // Nothing to draw yet; the grouping the list would start runs here.
                                Color.clear.frame(height: 1)
                                    .task(id: "\(appModel.activeChatSessionId)|\(appModel.engine.transcripts.structureVersion(for: appModel.activeChatSessionId))") {
                                        await appModel.engine.transcripts.prepareGroups(for: appModel.activeChatSessionId)
                                    }
                            } else if appModel.chatMessages.isEmpty {
                                switch appModel.engine.providers.readiness {
                                case .loading:
                                    ProgressView("Checking providers…").frame(minHeight: 360)
                                case .unavailable(let reason):
                                    NativeEmptyState(title: "Providers unavailable", detail: reason)
                                        .frame(minHeight: 360)
                                case .needsConnection:
                                    // Require a provider before inviting a message.
                                    ChatProviderConnectEmptyState {
                                        inlineCards.openPage(.providers)
                                    }
                                    .frame(minHeight: 360)
                                case .ready:
                                    ShellEmptyRoom(
                                        personaName: appModel.agentDisplayName,
                                        onSuggestion: { suggestion in
                                            ChatEmptyStateSuggestionAction.apply(
                                                suggestion,
                                                model: appModel,
                                                activeSessionID: appModel.activeChatSessionId
                                            )
                                        }
                                    )
                                    // The greeting sits low in the room so
                                    // the composer reads as part of the
                                    // same group; the first message pushes
                                    // it up and the composer settles to the
                                    // bottom on its own.
                                    .containerRelativeFrame(.vertical, alignment: .bottom)
                                    .padding(.bottom, 24)
                                }
                            } else {
                                // Main and detached chat share the exact grouped
                                // transcript owner, including search row IDs and
                                // selected-result highlighting.
                                transcriptList
                                    .environment(\.troubleCardOwnsRetry, true)
                                // Failure cards state provable effects and offer recovery.
                                if let tail = ChatTurnFailure.read(appModel.chatMessages) {
                                    ShellTroubleCard(
                                        message: tail.message,
                                        failure: tail.failure,
                                        showsStuckLink: ChatShellTroubleState
                                            .showsStuckLink(appModel.chatMessages),
                                        onRetry: {
                                            Task { await appModel.regenerateAssistantMessage(tail.message) }
                                        },
                                        onContinue: {
                                            Task { await appModel.continueFailedTurn(tail.message) }
                                        },
                                        onOpenSettings: {
                                            inlineCards.openPage(.settings)
                                        }
                                    )
                                }
                            }
                            // The scroll target, and the gap above whatever
                            // floats below. It has to be INSIDE the scroll
                            // target, which padding below the anchor would not
                            // be. Its height is the spacer's own business —
                            // see ChatTranscriptBottomAnchor.
                            ChatTranscriptBottomAnchor(anchorID: bottomAnchor, store: turnCardClearanceStore)
                        }
                        .focusSection()
                        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                        .padding(.top, 18)
                        // Keep the readable column centered in the room.
                        .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
                        .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
                        .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
                        .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
                    }
                    // Each session owns its scroll view and starts at the bottom on first layout.
                    // Built once its conversation is read, so its first frame is
                    // already the whole chat at the bottom, never a placeholder swapped out.
                    .id(appModel.activeChatSessionId + (transcriptRead ? "" : "#reading"))
                    .onAppear { scrollMoveLog("transcript.mount session=%@ rows=%ld", String(appModel.activeChatSessionId.suffix(12)), appModel.chatMessages.count) }
                    .transition(NativeAgentMotion.fadeIn)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                    // roomTopChrome reserves the header inset and masks prose before it reaches the header.
                    .roomTopChrome {
                        VStack(spacing: 0) {
                            // The header receives unread inbox notes as one capsule.
                            InboxStripContainer(sessionID: appModel.activeChatSessionId, interactionBinding: inlineCards) { notes in
                                // One name and status dot; the posture line belongs to the composer.
                                ShellRoomHeader(
                                    name: appModel.agentDisplayName,
                                    status: shellStatus,
                                    onNewChat: inSimple
                                        ? { Task { await appModel.newChatSession() } }
                                        : nil,
                                    notes: notes,
                                    work: inSimple ? nil : WorkPaneHeaderButton()
                                )
                                // Advanced extends the room's sheet through the title strip; Simple uses its haze.
                                .background {
                                    if !inSimple {
                                        ShellSheet()
                                            .ignoresSafeArea(edges: .top)
                                    }
                                }
                            }
                            .environment(appModel)
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
                        // The one notice lane hangs under this chrome while
                        // the chat is in front (ContentView draws it).
                        .anchorPreference(key: NoticeLaneRoomKey.self, value: .bounds) {
                            chatPageIsVisible ? NoticeLaneRoom(anchor: $0, notices: turnNoticeToasts) : nil
                        }
                    }
                    .overlay(alignment: .bottomTrailing) { latestPillOverlay }
                    .onChange(of: transcriptLatestRequest) { _, _ in
                        guard chatPageIsVisible else { return }
                        scrollCoordinator.followFromLiveEdge()
                    }
                    .onChange(of: appModel.isBusy) { _, isBusy in
                        guard chatPageIsVisible else { return }
                        if !isBusy { turnNoticeToasts.dismissAll() }
                    }
                    .onChange(of: appModel.activeChatSessionId) {
                        showTranscriptSearch = false
                        transcriptSearch.reset(for: appModel.activeChatSessionId)
                        turnNoticeToasts.dismissAll()
                        scrollCoordinator.followFromLiveEdge()
                    }
                    .onChange(of: appModel.chatMessages.first?.id) { _, _ in
                        primeAutoReadForCurrentSessionIfNeeded()
                    }
                    // Layout growth above owns follow, including late wraps,
                    // images and card resizing. Only an open search needs to
                    // observe every text publication independently of layout.
                    .followsStreamingTail(
                        messageID: appModel.chatMessages.last?.id,
                        enabled: showTranscriptSearch && chatPageIsVisible,
                        onChanged: { refreshTranscriptSearchTailIfPresented() }
                    )
                    // Structural revisions refresh search for interior rewrites as well as tail changes.
                    .onChange(of: appModel.engine.transcripts.structureVersion(for: appModel.activeChatSessionId)) { _, _ in
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
                    // Refresh completed active-session messages; unscoped notices require full chat state.
                    .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
                        guard let completedSessionId = note.object as? String else {
                            Task { await appModel.loadChatState() }
                            return
                        }
                        guard completedSessionId == appModel.activeChatSessionId else {
                            Task { await appModel.followMovedAnchorInSimple() }
                            return
                        }
                        // A local turn that already landed its disk snapshot says
                        // so in userInfo; skip the duplicate whole-transcript read
                        // (remote turns and failed local refreshes never set it).
                        let alreadyRefreshed = (note.userInfo?["messagesAlreadyRefreshed"] as? Bool) == true
                        Task {
                            await appModel.refreshChatMessagesAfterTurn(
                                sessionId: completedSessionId,
                                messagesAlreadyRefreshed: alreadyRefreshed)
                        }
                    }
                    .modifier(TranscriptChangeRefresh(appModel: appModel))
                    .onReceive(
                        NotificationCenter.default.publisher(for: .nativeAgentTurnNotice)
                            // Posted from the stream-consumer background task —
                            // hop to main before touching the toast center.
                            .receive(on: DispatchQueue.main)
                    ) { note in
                        receiveTurnNotice(note)
                    }
                    // Quiet offscreen reads must not load shared chat state, prime auto-read or move the transcript.
                    .liveTask {
                        await appModel.loadChatState()
                        primeAutoReadForCurrentSessionIfNeeded()
                        transcriptLatestRequest &+= 1
                    }
                .safeAreaInset(edge: .bottom, spacing: 0) {

                VStack(spacing: NativeAgentSpacing.xs) {
                    // Toast
                    if let toast = toasts.current {
                        NoticePill(text: toast)
                            .padding(.horizontal)
                            .transition(NativeAgentMotion.fade)
                            .accessibilityIdentifier("chat.composer.bottom-toast")
                    }

                    let screenCaptureAllowed = appModel.engine.trust.policy?.multimodalPolicy?.screen_capture == true
                    let activeSessionIsRunning = appModel.isBusy || appModel.isChatStreaming

                    // One glass container lets the tray and composer fuse and morph at the room's width.
                    GlassEffectContainer(spacing: ChatComposerTray.gap * 2) {
                        VStack(spacing: 0) {
                            ChatComposerTray(
                                sessionId: appModel.activeChatSessionId,
                                isBusy: activeSessionIsRunning,
                                attachments: pendingAttachments,
                                onRemoveAttachment: { id in pendingAttachments.removeAll { $0.id == id } },
                                otherRunning: appModel.otherRunningChatSessionIDs,
                                routes: runningSessionRoutes,
                                onGoTo: goToRunningSession,
                                onStop: { appModel.stopChatStream(sessionId: $0) }
                            )

                            // Draft observation stays in the input child so keystrokes do not invalidate the transcript.
                            ChatComposerInput(
                                draft: draft,
                                placeholder: shellComposerPlaceholder,
                                isActive: chatPageIsVisible,
                                recipient: inSimple ? appModel.agentAddressName : nil,
                                voiceInput: voiceInput,
                                voiceSessionId: voiceSessionId,
                                activeSessionId: appModel.activeChatSessionId,
                                screenCaptureAllowed: screenCaptureAllowed,
                                screenCaptureDisabled: activeSessionIsRunning || isCapturing || !screenCaptureAllowed,
                                pendingAttachmentCount: pendingAttachments.count,
                                hasPendingAttachments: !pendingAttachments.isEmpty,
                                isRunning: activeSessionIsRunning,
                                hasQueuedTurns: !appModel.engine.turns.queued(for: appModel.activeChatSessionId).isEmpty,
                                isQueuePaused: appModel.engine.turns.isQueuePaused(appModel.activeChatSessionId),
                                isCapturing: isCapturing,
                                // Sending waits for the routing write to settle.
                                isRoutingSaving: appModel.isSavingChatBrain,
                                inputFocused: $inputFocused,
                                onToggleVoice: toggleVoice,
                                onCaptureScreen: captureScreen,
                                onAttach: attachFromClipboardOrPickFile,
                                onStop: { appModel.stopChatStream() },
                                onSend: send,
                                onSlashCommand: { handleSlashCommand($0) },
                                onDrop: { handleDrop(providers: $0) },
                                composeVoiceDraft: { composeVoiceDraft($0) }
                            )
                            // The composer publishes an open card's height here so the
                            // Latest pill can clear it. Optional in the environment, so
                            // the detached panel and the snapshot hosts are untouched.
                            .environment(turnCardClearanceStore)
                            .environment(composerCardState)
                        }
                        // Her working card rises out of the composer's own glass, like
                        // the tray: one container, so the two fuse and it materializes
                        // from the composer instead of fading in on its own. It floats
                        // (an overlay), so it never resizes the viewport (TurnCardRoom).
                        .overlay(alignment: .top) {
                            ChatTurnCardInset(store: turnCardClearanceStore)
                                .alignmentGuide(.top) { $0[.bottom] }
                        }
                    }
                    // Align the composer to the reply column; its input grows upward to five lines.
                    .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
                    .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
                    .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
                    .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
                    .padding(.bottom, 24)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    turnCardClearanceStore.measuredComposerHeight = height
                }
                }
                // Exclude the reading viewport between header and composer from the window's warm tint.
                .moodTintProseGuard(
                    columnWidth: NativeAgentShellLayout.roomColumn,
                    leadingInset: NativeAgentShellLayout.roomLeadingInset
                )
                }

        }
        .confirmationDialog(
            "Clear all messages in this session?",
            isPresented: clearConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Clear Messages", role: .destructive) {
                guard let sessionId = clearConfirmation.consumeConfirmation() else { return }
                Task { await appModel.clearActiveChatMessages(sessionId: sessionId) }
            }
            Button("Cancel", role: .cancel) {
                clearConfirmation.cancel()
            }
        }
        // The window's sheet (ShellFrame) is the ground.
        .contentShape(Rectangle())
        // Hidden chat publishes no commands; callback guards also reject stale scene actions.
        .focusedSceneValue(\.chatCommandActions, chatPageIsVisible ? ChatFocusedCommandActions(
            send: { if chatPageIsVisible { send() } },
            attach: { if chatPageIsVisible { attachFromClipboardOrPickFile() } },
            toggleVoice: { if chatPageIsVisible { toggleVoice() } },
            focusComposer: { if chatPageIsVisible { inputFocused = true } },
            focusTranscriptSearch: { if chatPageIsVisible { openTranscriptSearch() } },
            findNext: { if chatPageIsVisible { findNextTranscriptMatch() } },
            findPrevious: { if chatPageIsVisible { findPreviousTranscriptMatch() } }
        ) : nil)
    }

}

/// Any row written to the open chat from another door (Telegram, the phone,
/// an agent, a contact's reply) shows as it lands, not on the next turn.
private struct TranscriptChangeRefresh: ViewModifier {
    let appModel: AppModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .nativeAgentChatTranscriptDidChange)
            .receive(on: DispatchQueue.main)) { note in
            guard let changed = note.object as? String, changed == appModel.activeChatSessionId else { return }
            Task { await appModel.refreshChatMessagesAfterTurn(sessionId: changed) }
        }
        // ...and while a turn from another door is working, the card says so,
        // including one already running when a conversation is opened.
        .task { OtherDoorTurns.shared.start(appModel) }
        .onChange(of: appModel.activeChatSessionId, initial: true) { _, sessionId in
            OtherDoorTurns.shared.show(sessionId, appModel)
        }
    }
}
