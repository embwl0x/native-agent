import EngineRuntime
import ChatTurnRuntime
import ChatSessionWork
import AppToolRuntime
import MultimodalTTS
import SwiftUI
import AppKit
import NativeAgentShared
import Transcripts
// Blueprint: | `ChatView+Conversation.swift` | `ChatView`: Transcript, composer, search and cross-surface observation |

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
                    // Selection reports errors through state, so verify the identity moved before claiming navigation succeeded.
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

    private func receiveTurnNotice(_ note: Notification) {
        guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
        // Scope notices to their active conversation; global notices remain visible.
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

    /// An unread conversation is not empty; wait for its first read before deciding to show a greeting.
    var transcriptRead: Bool {
        let id = appModel.activeChatSessionId
        guard !id.isEmpty else { return true }
        // Draw rows only after grouping is ready.
        return appModel.engine.transcripts.hasCachedTranscript(for: id)
            && (appModel.chatMessages.isEmpty || !appModel.engine.transcripts.groups(for: id).isEmpty)
    }

    @ViewBuilder
    var chatColumn: some View {
        VStack(spacing: 0) {
            chatRoom
                .preparesTranscriptGroups(appModel.activeChatSessionId)
                .safeAreaInset(edge: .top, spacing: 0) { chatHeader }
                .overlay(alignment: .bottomTrailing) { latestPillOverlay }
                .onChange(of: transcriptLatestRequest) { _, _ in
                    guard chatPageIsVisible else { return }
                    transcriptHandle.goToLatest()
                }
                .onChange(of: appModel.isBusy) { _, isBusy in
                    guard chatPageIsVisible else { return }
                    if !isBusy { turnNoticeToasts.dismissAll() }
                }
                .onChange(of: appModel.activeChatSessionId) {
                    turnNoticeToasts.dismissAll()
                }
                .onChange(of: appModel.chatMessages.first?.id) { _, _ in
                    primeAutoReadForCurrentSessionIfNeeded()
                }
                // Read full chat state for global notices; conversation rows arrive through the store.
                .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
                    guard let completedSessionId = note.object as? String else {
                        Task { await appModel.loadChatState() }
                        return
                    }
                    if completedSessionId != appModel.activeChatSessionId {
                        Task { await appModel.followMovedAnchorInSimple() }
                    }
                }
                .modifier(TranscriptChangeRefresh(appModel: appModel))
                .onReceive(
                    NotificationCenter.default.publisher(for: .nativeAgentTurnNotice)
                        // Hop to main before touching the toast center because stream consumption runs in the background.
                        .receive(on: DispatchQueue.main)
                ) { note in
                    receiveTurnNotice(note)
                }
                // Quiet offscreen reads must not load shared state, prime auto-read or move the transcript.
                .liveTask {
                    await appModel.loadChatState()
                    primeAutoReadForCurrentSessionIfNeeded()
                    transcriptLatestRequest &+= 1
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: NativeAgentSpacing.xs) {
                    if let toast = toasts.current {
                        NoticePill(text: toast)
                            .padding(.horizontal)
                            .transition(NativeAgentMotion.fade)
                            .accessibilityIdentifier("chat.composer.bottom-toast")
                    }

                    let screenCaptureAllowed = appModel.engine.trust.policy?.multimodalPolicy?.screen_capture == true
                    let activeSessionIsRunning = appModel.isBusy || appModel.isChatStreaming

                    // Share one glass container so tray and composer fuse at the room's width.
                    GlassEffectContainer(spacing: ChatComposerTray.gap * 2) {
                        VStack(spacing: 0) {
                            ChatComposerTray(
                                attachments: pendingAttachments,
                                onRemoveAttachment: { id in pendingAttachments.removeAll { $0.id == id } },
                                otherRunning: appModel.otherRunningChatSessionIDs,
                                routes: runningSessionRoutes,
                                onGoTo: goToRunningSession,
                                onStop: { appModel.stopChatStream(sessionId: $0) }
                            )

                            // Keep draft observation in the input child so keystrokes cannot invalidate the transcript.
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
                                isCapturing: isCapturing,
                                // Wait for routing writes to settle before sending.
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
                            // Publish card height only to the optional Latest inset reader so unrelated hosts remain untouched.
                            .environment(turnCardClearanceStore)
                            .environment(composerCardState)
                        }
                        // Overlay the working card in the composer's glass container so it can fuse without resizing the viewport.
                        .overlay(alignment: .top) {
                            ChatTurnCardInset(store: turnCardClearanceStore)
                                .alignmentGuide(.top) { $0[.bottom] }
                        }
                    }
                    // Grow the composer upward within the reply column so its lower edge stays fixed.
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
                // Exclude the reading viewport from mood tint to preserve readability.
                .moodTintProseGuard(
                    columnWidth: NativeAgentShellLayout.roomColumn,
                    leadingInset: NativeAgentShellLayout.roomLeadingInset
                )
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
        .contentShape(Rectangle())
        // Hidden chat must publish no commands; callback guards also reject stale scene actions.
        .focusedSceneValue(\.chatCommandActions, chatPageIsVisible ? ChatFocusedCommandActions(
            send: { if chatPageIsVisible { send() } },
            attach: { if chatPageIsVisible { attachFromClipboardOrPickFile() } },
            toggleVoice: { if chatPageIsVisible { toggleVoice() } },
            focusComposer: { if chatPageIsVisible { inputFocused = true } },
            focusTranscriptSearch: { if chatPageIsVisible { transcriptHandle.showFind() } },
            findNext: { if chatPageIsVisible { transcriptHandle.findNext() } },
            findPrevious: { if chatPageIsVisible { transcriptHandle.findPrevious() } }
        ) : nil)
    }

    /// The conversation as one document under the header; it scrolls beneath the composer glass, which it keeps clear by its bottom inset.
    @ViewBuilder
    private var chatRoom: some View {
        let sessionID = appModel.activeChatSessionId
        if !transcriptRead {
            // The room's group preparation fills this until the first groups land.
            Color.clear
        } else if appModel.chatMessages.isEmpty {
            Group {
                switch appModel.engine.providers.readiness {
                case .loading:
                    ProgressView("Checking providers…").frame(minHeight: 360)
                case .unavailable(let reason):
                    NativeEmptyState(title: "Providers unavailable", detail: reason)
                        .frame(minHeight: 360)
                case .needsConnection:
                    // Require a provider before inviting a send.
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
                    // Group greeting and composer visually; arriving messages move the greeting upward while the composer settles at
                    // the bottom.
                    .containerRelativeFrame(.vertical, alignment: .bottom)
                    .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
            .frame(maxWidth: NativeAgentShellLayout.roomColumn)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        } else {
            TranscriptDocumentView(
                sessionID: sessionID,
                groups: appModel.engine.transcripts.groups(for: sessionID),
                cardsByRow: TranscriptReadout(messages: appModel.chatMessages).cardsByRow,
                exchanges: appModel.engine.contactThreads.otherRooms.filter { $0.sessionID != sessionID },
                showsTrouble: ChatTurnFailure.read(appModel.chatMessages) != nil,
                streamingMessageID: appModel.engine.turns.streamingBubbleIds[sessionID],
                bottomInset: turnCardClearanceStore.clearance,
                handle: transcriptHandle
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .environment(\.inlineCardAction) { [inlineCards, appModel] card, action in
                inlineCards.handle(card: card, action: action, appModel: appModel)
            }
            .environment(\.transcriptOpenSettings) { [inlineCards] in inlineCards.openPage(.settings) }
            .safeAreaInset(edge: .top) {
                if case .unavailable(let reason) = appModel.engine.transcripts.transcriptReadStatus(for: sessionID) {
                    Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }

    /// The room's header and inbox strip; the turn notice lane anchors under it.
    private var chatHeader: some View {
        VStack(spacing: 0) {
            InboxStripContainer(sessionID: appModel.activeChatSessionId, interactionBinding: inlineCards) { notes in
                // Keep posture in the composer so the header does not duplicate status.
                ShellRoomHeader(
                    name: appModel.agentDisplayName,
                    status: shellStatus,
                    onNewChat: inSimple
                        ? { Task { await appModel.newChatSession() } }
                        : nil,
                    notes: notes,
                    work: inSimple ? nil : WorkPaneHeaderButton()
                )
                .background {
                    if !inSimple {
                        ShellSheet()
                            .ignoresSafeArea(edges: .top)
                    }
                }
            }
            .environment(appModel)
    }
        // Present the shared notice lane only while chat is in front.
        .anchorPreference(key: NoticeLaneRoomKey.self, value: .bounds) {
            chatPageIsVisible ? NoticeLaneRoom(anchor: $0, notices: turnNoticeToasts) : nil
        }
    }
}

/// Observe the conversation file so writes from every surface appear as they land.
private struct TranscriptChangeRefresh: ViewModifier {
    let appModel: AppModel

    func body(content: Content) -> some View {
        // Project the shared store so every surface's committed rows appear immediately.
        content.task(id: "transcript:\(appModel.activeChatSessionId)") {
            let sessionId = appModel.activeChatSessionId
            await appModel.engine.transcripts.watchChanges(sessionID: sessionId) {
                await appModel.readActiveTranscript(sessionId: sessionId)
            }
        }
        // Show cross-surface work already running when a conversation opens, not just new local turns.
        .task { OtherDoorTurns.shared.start(appModel) }
        .onChange(of: appModel.activeChatSessionId, initial: true) { _, sessionId in
            OtherDoorTurns.shared.show(sessionId, appModel)
        }
    }
}
