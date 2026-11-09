import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatView+Conversation.swift` | Conversation, read availability, composer and cross-surface observation |

extension ChatView {
    private func goToRunningSession(_ sessionId: String) {
        runningSessionNavigationGeneration &+= 1
        let generation = runningSessionNavigationGeneration
        Task { @MainActor in
            await appModel.selectChatSession(id: sessionId)
            let navigated = appModel.activeChatSessionId == sessionId
            guard runningSessionNavigationGeneration == generation else { return }
            if !navigated {
                showToast(appModel.statusText)
            }
        }
    }

    @ViewBuilder
    var chatColumn: some View {
        VStack(spacing: 0) {
            chatRoom
                .safeAreaInset(edge: .top, spacing: 0) { chatHeader }
                .overlay(alignment: .bottomTrailing) { latestPillOverlay }
                .onChange(of: transcriptLatestRequest) { _, _ in
                    guard chatPageIsVisible else { return }
                    transcriptHandle.goToLatest()
                }
                // Quiet offscreen reads must not load shared state, prime auto-read or move the transcript.
                .liveTask {
                    await appModel.loadChatState()
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

                    let screenCaptureAllowed = appModel.settingsScreenCaptureEnabled == true
                    let activeSessionIsRunning = appModel.isBusy || appModel.isChatStreaming

                    // Share one glass container so tray and composer fuse at the room's width.
                    GlassEffectContainer(spacing: ChatComposerTray.gap * 2) {
                        VStack(spacing: 0) {
                            ChatComposerTray(
                                attachments: pendingAttachments,
                                onRemoveAttachment: { id in pendingAttachments.removeAll { $0.id == id } },
                                onGoTo: goToRunningSession
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
                                isRoutingSaving: isSavingComposerChoice,
                                inputFocused: $inputFocused,
                                onToggleVoice: toggleVoice,
                                onDiscardVoice: discardDictation,
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
        // Inset chrome must not widen the column beyond the space the shell gives it.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    /// One room for every chat: changing chat is an edit to its document, which opens at the end.
    private var chatRoom: some View {
        ChatTranscriptRoom(sessionID: appModel.activeChatSessionId, clearance: turnCardClearanceStore, handle: transcriptHandle)
    }

    /// The room's header and inbox strip; the turn notice lane anchors under it.
    private var chatHeader: some View {
        VStack(spacing: 0) {
            InboxStripContainer { notes in
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
    }
}

/// Only the transcript room observes conversation availability and empty-state membership.
private struct ChatTranscriptRoom: View {
    let sessionID: String
    let clearance: ChatTurnCardClearance
    let handle: TranscriptDocumentHandle
    @Environment(AppModel.self) private var appModel
    @State private var isRetrying = false
    private var inlineCards: CardControls { CardControls.shared }
    private var state: FaceReadState? {
        appModel.face.slot(.conversation(session: sessionID)).select("state", as: ConversationFace.self) { $0?.state }
    }
    private var knownEmpty: Bool? {
        let id = sessionID
        return appModel.face.slot(.sessions).select("empty:\(sessionID)", as: SessionListFace.self) {
            guard let value = $0, value.allIDs.contains(id) else { return nil }
            return value.emptyIDs.contains(id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sessionID.isEmpty, let issue = appModel.chatRestoreIssue {
                Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button(isRetrying ? "Opening conversation…" : "Try opening again") {
                    guard !isRetrying else { return }
                    isRetrying = true
                    Task {
                        defer { isRetrying = false }
                        await appModel.loadChatState()
                    }
                }
                .disabled(isRetrying)
            } else {
                if case .unavailable(let failure)? = state {
                    Text(failure.localizedDescription).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button(isRetrying ? "Reading conversation…" : "Try reading again") {
                        guard !isRetrying else { return }
                        isRetrying = true
                        Task {
                            defer { isRetrying = false }
                            await appModel.refreshChatFace(.session(sessionID))
                        }
                    }
                    .disabled(isRetrying)
                }
                // One place for the document, so a change of read state never rebuilds it.
                if case .ready? = state, knownEmpty == true {
                    emptyRoom
                } else {
                    document
                        .overlay {
                            if case .waiting(let on)? = state { ProgressView("Waiting on " + on + "…") }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FaceObservation(demand: sessionID.isEmpty ? nil : .key(.conversation(session: sessionID))))
    }

    private var document: some View {
        TranscriptDocumentView(sessionID: sessionID, bottomInset: clearance.clearance, handle: handle)
            .ignoresSafeArea(.container, edges: .bottom)
            .environment(\.transcriptOpenSettings) { [inlineCards, appModel] in
                do { try inlineCards.openPage(.settings) }
                catch { appModel.setFailureStatus(error, action: "open Settings") }
            }
    }

    private var emptyRoom: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    switch appModel.providerReadiness {
                    case .loading: ProgressView("Checking providers…")
                    case .unavailable(let reason): NativeEmptyState(title: "Providers unavailable", detail: reason)
                    case .needsConnection:
                        ChatProviderConnectEmptyState {
                            do { try inlineCards.openPage(.providers) }
                            catch { appModel.setFailureStatus(error, action: "open Providers") }
                        }
                    case .ready:
                        ShellEmptyRoom(personaName: appModel.agentDisplayName) { suggestion in
                            ChatEmptyStateSuggestionAction.apply(suggestion, model: appModel, activeSessionID: sessionID)
                        }
                    }
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottom)
            }
        }
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .frame(maxWidth: NativeAgentShellLayout.roomColumn)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
