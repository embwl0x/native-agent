// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI

import UIKit
import Speech
import PhotosUI
import NativeAgentShared

// MARK: - View

struct ChatView: View {
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore
    // PERF-2026-08-05: `@Observable` — this view body reads only `isListening`,
    // `isStarting`, `transcript`, `statusText`, `error` and `lastFinalTranscript`,
    // so the ~45Hz `audioLevel` tap write no longer invalidates the chat screen.
    @Environment(VoiceInputController.self) private var voiceInput
    @EnvironmentObject private var voiceOutput: VoiceOutputController
    @Environment(\.scenePhase) private var scenePhase
    // chat-smoothness phase 6: respect Reduce Motion on the bubble entrance.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: ChatStore
    @StateObject private var sync = iCloudSyncEngine.shared
    /// The iPhone is a member of the **Chat** group, so its model is the Mac's
    /// resolved Chat choice, delivered in the synced surface preferences
    /// (`adoptSurfaceModelPreferenceFromSync`). Empty until that snapshot
    /// arrives — and empty is sent as NO override, so the Mac resolves the turn
    /// (2026-09-13: no model id chosen on the phone).
    @AppStorage(HazeColor.key) private var hazeColorRaw = HazeColor.defaultValue.rawValue
    @AppStorage("chatModel") private var selectedModel = ""
    @AppStorage("chatReasoningEffort") private var selectedReasoningEffort = "high"
    @AppStorage("chatFastMode") private var selectedFastMode = false
    // U5 ABA guard (gpt-5.5 review, 2026-07-09): each pick bumps its
    // generation; a failed round-trip only reverts if ITS generation is still
    // current. A value-equality check alone can't tell "still my pick" from
    // "user moved away and back while I was in flight."
    @AppStorage("chatSurfaceSelectionGeneration") private var surfaceSelectionGeneration = 0
    /// True once the Mac's own Chat choice has been adopted on this device. Until
    /// then the phone has nothing of its own to send (2026-09-13 review).
    @AppStorage("chatModelHydratedFromMac") private var hasHydratedModelFromMac = false
    // A snapshot is eventually consistent with the configure request. Keep a
    // freshly chosen set of runtime controls on screen until that snapshot
    // acknowledges the same selection instead of letting an older Mac value
    // immediately overwrite it.
    @AppStorage("chatSurfaceSelectionAwaitingSync") private var surfaceSelectionAwaitingSync = false
    @AppStorage("chatFileAccess") private var selectedFileAccess = "auto"
    @AppStorage("chatProviderId") private var selectedProviderId = ""
    @State private var inputText = ""
    @State private var showsChatSetup = false
    @State private var showsConfiguration = false
    @State private var inboxDetailItem: InboxItemRecord?
    @State private var inboxGroup: InboxRelatedGroup?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var composerIsFocused: Bool
    @State private var scrollScheduler = ChatScrollScheduler()
    @State private var lastScrollAt = Date.distantPast
    @State private var autoFollowChat = true
    @State private var showLatestButton = false
    @State private var iCloudReplyObserverID: UUID?
    @State private var iCloudRejectionObserverID: UUID?
    @State private var iCloudResyncObserverID: UUID?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pendingPhotos: [PendingPhotoAttachment] = []
    @State private var isLoadingPhotos = false
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var photoLoadGeneration = 0
    @State private var suppressNextEmptyPhotoSelection = false
    @State private var closingPinnedSessionIDs: Set<String> = []
    /// 2026-09-06: the session dictation was started in (nil = not dictating).
    /// The recognizer keeps running across a session switch and its final
    /// transcript used to land in whatever composer was selected when the user
    /// let go, i.e. in the wrong conversation. A switch ends dictation and
    /// drops what it heard. Keyed, not the raw id, so the main session's nil id
    /// is still distinguishable from "no dictation in flight".
    @State private var dictationSessionKey: String?

    private let maxPendingPhotos = 4
    /// No model ids are named on the phone (2026-09-13). Rows and their order
    /// come from the Mac's catalog snapshot (`sync.providers`), which is already
    /// priority-ordered there, so an empty preference list means "take the
    /// provider's own first row" — and a model retired on the Mac disappears
    /// here the moment the snapshot lands, with nothing to keep in step.
    static let preferredModelIDs: [String] = []
    // CloudKitDeviceTransport caps the complete encoded BridgeMessage at
    // 800 KiB. Base64 expands image bytes by roughly one third, so reserve
    // ample room for JSON, text, signatures, and controls and keep the
    // aggregate raw photo payload below 520 KiB.
    static let cloudKitPhotoPayloadBudgetBytes = MobileChatAttachmentPreparation.payloadBudgetBytes

    private var agentDisplayName: String {
        sync.agentDisplayName
    }

    private var composerPlaceholder: String {
        // Before any name is known the fallback is the product, not the agent.
        return agentDisplayName == NativeAgentIdentity.displayName(nil) ? "Message…" : "Message \(agentDisplayName)…"
    }

    // Process-local visual fixture: no transcript/cache writes and no transport sends.
    private var isChatSample: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-chatSample")
        #else
        false
        #endif
    }

    private var visibleMessages: [ChatMessage] {
        #if DEBUG
        if isChatSample {
            var messages = [
                ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, role: .user,
                            text: "Can we keep tomorrow's plan simple?"),
                ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, role: .assistant,
                            text: "Start with a quiet morning and one focused task. Leave the afternoon open for a walk."),
                ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, role: .user,
                            text: "A walk after lunch sounds good."),
                ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, role: .assistant,
                            text: "That leaves room to breathe. What would you like to focus on first?"),
                ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, role: .user,
                            text: "I'll finish the outline in the morning, then take the afternoon outside.")
            ]
            let extras = ProcessInfo.processInfo.arguments.contains("-chatSampleExtras")
            if extras {
                messages[3] = ChatMessage(id: messages[3].id, role: .assistant, text: messages[3].text,
                                          toolEvents: [ToolEvent(name: "calendar_read", seq: 1),
                                                       ToolEvent(name: "weather_forecast", seq: 2),
                                                       ToolEvent(name: "read_skill", seq: 3)])
            }
            if ProcessInfo.processInfo.arguments.contains("-chatSampleStreaming") {
                messages.append(ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                                            role: .assistant, text: extras ? "" : "Writing the next step…", isStreaming: true,
                                            toolEvents: extras ? [ToolEvent(name: "calendar_read", seq: 1)] : []))
            }
            return messages
        }
        #endif
        return store.messages
    }

    /// A quiet door, in the agent's own voice: one serif line, one sentence,
    /// and one action only when there is something to do.
    private var chatEmptyState: some View {
        let copy: (title: String, line: String) = transcriptNotSynced
            ? ("Not here yet", "This conversation is still on your Mac. I'll bring it over when it syncs.")
            : !pairingStore.isPaired ? ("I live on your Mac", "Connect this iPhone and I can talk with you from anywhere.")
            : bridgeClient.bridgeStatus == .offline ? ("Out of reach for now", AliveConnection.noICloud + ". When it's back, so am I.")
            : ("I'm here", "Ask me anything, or tell me what you're working on.")
        return VStack(spacing: 12) {
            Text(copy.title)
                .font(.system(.title, design: .serif))
                .foregroundStyle(AlivePalette.text)
                .accessibilityAddTraits(.isHeader)
            Text(copy.line)
                .font(.body)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !pairingStore.isPaired {
                Button { showsChatSetup = true } label: {
                    Text("Connect this iPhone")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 36)
                }
                .alivePrimaryButton()
                .padding(.top, 10)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(24)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity)
    }

    private var chatSessionTabs: [ChatSessionTab] {
        ChatSessionTabProjection.make(
            mainSessionID: effectiveMainSessionID,
            mainTitle: mainSessionTitle,
            pinnedSessions: sync.pinnedChatSessions,
            anchorSession: anchorSession
        )
    }

    /// An explicitly opened history thread gets a temporary, non-closable
    /// tab beside main. Opening history never changes the Mac's pin list.
    private var anchorSession: ChatSession? {
        guard let selectedID = store.selectedSessionID,
              selectedID != effectiveMainSessionID,
              !sync.pinnedChatSessions.contains(where: { $0.id == selectedID }) else { return nil }
        return sync.sessions.first(where: { $0.id == selectedID && $0.archived != true })
    }

    /// The pinned ids the strip actually shows: the Mac's pinned snapshot plus
    /// the derived anchor tab. The externally-removed-pin reconciler judges
    /// against this, not the raw snapshot, or it would bounce an anchor
    /// selection straight back to the main tab.
    private var visiblePinnedSessionIDs: Set<String> {
        var ids = Set(sync.pinnedChatSessions.map(\.id))
        if let anchorSession { ids.insert(anchorSession.id) }
        return ids
    }

    /// 2026-09-06: the Mac publishes a bounded set of transcripts. A session the
    /// phone can select that falls outside that set has a session row carrying a
    /// message count but no transcript, and rendering it as "No messages yet"
    /// claimed a conversation was empty when the phone simply never received it.
    private var transcriptNotSynced: Bool {
        guard let sessionID = store.selectedSessionID ?? effectiveMainSessionID,
              sync.transcriptRead(for: sessionID) == .unavailable else { return false }
        return (sync.sessions.first { $0.id == sessionID }?.messageCount ?? 0) > 0
    }

    private var showsChatSessionTabs: Bool {
        store.selectedSessionID != effectiveMainSessionID
            || anchorSession != nil || sync.pinnedChatSessions.contains(where: { $0.archived != true })
    }

    /// Sweep 2026-09-01 item 36 — the pending approvals raised by the chat on
    /// screen, rendered inline on the turn that raised them. Pure read of the
    /// approvals `iCloudSyncEngine` already publishes for the Activity tab; no
    /// second store, no second refresh loop.
    private var inlineChatApprovals: [ApprovalRequest] {
        #if DEBUG
        if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleExtras") {
            return [ApprovalRequest(id: "sample-approval", title: "Add a calendar block",
                                    action: "calendar_create", risk: "medium",
                                    reason: "Tomorrow 9–11 AM, “Outline”, on your personal calendar.",
                                    status: "pending",
                                    payloadPreview: #"{"input":{"calendar":"Personal","title":"Outline","eventId":"evt_77"}}"#,
                                    localOnly: false, remoteResolvable: true),
                    ApprovalRequest(id: "sample-approval-hygiene", title: "",
                                    action: "self_improvement.apply", risk: "medium",
                                    reason: "[run_memory_hygiene] Run memory hygiene to consolidate duplicates and clear test-derived noise before it settles into long-term memory.",
                                    status: "pending", localOnly: true, remoteResolvable: false)]
        }
        #endif
        return MobileChatApprovalProjection.pendingApprovals(
            sessionId: store.selectedSessionID,
            approvals: sync.approvals
        )
    }

    /// Cards raised in another thread and mirrored into this conversation for
    /// User; their buttons answer the original through the signed inbox action.
    private var inlineChatCards: [InboxItemRecord] {
        guard let session = store.selectedSessionID, !session.isEmpty else { return [] }
        return sync.inboxItems.filter {
            $0.source == "interaction" && $0.chat_session_id == session
                && !["archived", "dismissed"].contains($0.status)
        }
    }

    private var inlineApprovalAnchorID: UUID? {
        guard !inlineChatApprovals.isEmpty || !inlineChatCards.isEmpty else { return nil }
        return MobileChatApprovalProjection.anchorMessageID(in: visibleMessages)
    }

    @ViewBuilder
    private var inlinePendingCards: some View {
        ForEach(inlineChatApprovals) { approval in
            InlineChatApprovalCard(approval: approval)
        }
        ForEach(inlineChatCards) { item in
            InboxCardRow(item: item, onAction: { action in
                Task {
                    do {
                        _ = try await sync.inboxAction(itemId: item.id, actionId: action)
                    } catch {
                        store.errorBanner = error.localizedDescription
                    }
                }
            }, onView: { inboxDetailItem = item })
        }
    }

    private var queuedTurns: [QueuedChatSend] {
        #if DEBUG
        if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleExtras") {
            return ["Also remind me to call Sam", "And pick a walking route"].map {
                QueuedChatSend(id: UUID(), sessionID: nil, text: $0, controls: runtimeControls,
                               attachments: [], createdAt: Date())
            }
        }
        #endif
        return store.queuedSendsForSelectedSession
    }

    private var selectedChatSessionTabID: String {
        guard let selected = store.selectedSessionID else { return "ios-main" }
        if selected == effectiveMainSessionID { return "ios-main" }
        return selected
    }

    private var effectiveMainSessionID: String? {
        store.mainSessionID ?? sync.chatAnchor?.cleanSessionId
    }

    private var mainSessionTitle: String {
        guard let mainID = effectiveMainSessionID,
              let session = sync.sessions.first(where: { $0.id == mainID }) else {
            return "iPhone"
        }
        return cleanTabTitle(session.displayTitle, fallback: "iPhone")
    }

    private var runtimeControls: ChatRuntimeControls {
        ChatRuntimeControls(
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            serviceTier: selectedFastMode ? "priority" : "default",
            fileAccess: ChatRuntimeControlPresentation.normalizedFileAccessID(selectedFileAccess),
            providerId: providerId(for: selectedModel)
        )
    }

    var body: some View {
        chatBody
            .onChange(of: sync.surfaceModels) { _, _ in
                adoptSurfaceModelPreferenceFromSync()
            }
            // 2026-09-06: this fires on a version change as well as a row
            // change, because both live in the one published value. A cleared
            // chat republished with a newer version but the same (empty) rows
            // is a real delivery, and it used to be invisible here.
            .onChange(of: sync.chatTranscripts) { _, _ in
                applyPublishedTranscriptToVisibleSession()
            }
            .onChange(of: sync.sessions) { _, _ in
                reconcilePublishedChatSessions()
            }
            .onChange(of: sync.pinnedChatSessions) { _, _ in
                reconcilePublishedChatSessions()
            }
            // Main follows the conversation User is in, including while already open.
            .onChange(of: sync.chatAnchor) { _, _ in
                adoptConversationAnchorIfNeeded()
            }
            .onChange(of: hasComposerDraft) { _, hasDraft in
                if !hasDraft { adoptMainSessionFromSnapshots(afterClearingDraft: true) }
            }
            .onChange(of: composerIsFocused) { _, focused in
                if !focused { adoptMainSessionFromSnapshots() }
            }
            .onChange(of: store.queuedSends.map(\.id)) { _, _ in
                adoptMainSessionFromSnapshots(afterClearingDraft: true)
            }
            .onChange(of: store.isLoading) { _, isLoading in
                if !isLoading {
                    reconcilePublishedChatSessions()
                }
            }
    }

    private var chatBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // E8: an outage on THIS phone gets named as such. Without it
                // every local failure funnelled into a Mac-blaming message.
                if let offline = bridgeClient.offlineBannerMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                        Text(offline).font(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.14))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                }

                if let error = store.errorBanner {
                    MobileChatIssueBanner(
                        message: error,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red,
                        dismissLabel: "Dismiss chat error",
                        onDismiss: { store.dismissErrorBanner() }
                    )
                }

                // Voice input error banner
                if let voiceErr = voiceInput.error {
                    MobileChatIssueBanner(
                        message: voiceErr,
                        systemImage: "mic.slash.fill",
                        tint: .orange,
                        dismissLabel: "Dismiss voice input error",
                        action: voiceErr.localizedCaseInsensitiveContains("permission")
                            || voiceErr.localizedCaseInsensitiveContains("settings")
                            ? ("Open Settings", { voiceInput.openSettings() })
                            : nil,
                        onDismiss: { voiceInput.error = nil }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let speechErr = voiceOutput.error {
                    MobileChatIssueBanner(
                        message: speechErr,
                        systemImage: "speaker.slash.fill",
                        tint: .orange,
                        dismissLabel: "Dismiss spoken reply error",
                        onDismiss: { voiceOutput.error = nil }
                    )
                }

                runtimeControlsBar
                if showsChatSessionTabs {
                    chatSessionTabsBar
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        if visibleMessages.isEmpty && inlineChatApprovals.isEmpty && inlineChatCards.isEmpty {
                            chatEmptyState
                                .containerRelativeFrame(.vertical)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 26) {
	                                ForEach(visibleMessages) { msg in
	                                    BubbleView(
	                                        message: msg,
	                                        streamingHint: store.streamingHint(for: msg),
	                                        isTimedOut: store.isTimedOut(msg),
	                                        onRetry: { store.retry(messageId: msg.id, client: bridgeClient) }
	                                    )
	                                    .id(msg.id.uuidString)
	                                    // phase 6: entrance animates ONLY when the
	                                    // append seam (ChatStore.send) supplies a
	                                    // transaction; removals and wholesale
	                                    // replaces (snapshot merge, session switch)
	                                    // are .identity → instant.
	                                    .transition(.asymmetric(
	                                        insertion: .opacity.combined(with: .offset(y: 8)),
	                                        removal: .identity))
                                        // 2026-09-13 (first-failure pass): an
                                        // aged-out request was never started,
                                        // so the honest offer is to send it —
                                        // and only on this tap.
                                        if store.isExpiredRequest(msg) {
                                            Button("Send now") {
                                                store.sendNow(messageId: msg.id, client: bridgeClient)
                                            }
                                            .disabled(store.isLoading || store.isSwitchingSession)
                                        }
                                        if !msg.isStreaming,
                                           let failed = store.queuedSendsForSelectedSession.first(where: { $0.placeholderID == msg.id }) {
                                            Button("Retry send") {
                                                store.sendQueuedNow(failed.id, client: bridgeClient)
                                            }
                                            .disabled(store.isLoading || store.isSwitchingSession)
                                        }
	                                    // Sweep 2026-09-01 item 36: the approval
	                                    // this turn is waiting on renders right
	                                    // here instead of only in the Activity
	                                    // tab. Activity stays canonical.
	                                    if msg.id == inlineApprovalAnchorID {
                                            inlinePendingCards
	                                    }
	                                }
                                if inlineApprovalAnchorID == nil {
                                    inlinePendingCards
                                }
                                // Reaching the bottom by hand is following again:
                                // the Latest button goes away on its own.
                                Color.clear.frame(height: 1)
                                    .onAppear {
                                        let follow = ChatFollowPresentation.followLatest()
                                        autoFollowChat = follow.autoFollow
                                        showLatestButton = follow.showsLatest
                                    }
                            }
                            .frame(maxWidth: NativeAgentMobileTheme.Layout.roomColumn)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                        }
                    }
                    // The transcript softens out under the composer and the tab bar.
                    .aliveBottomFade(room: AliveChatRoom(store: store))
                    // The scroll view owns the inset: SwiftUI measures every composer
                    // row and subtracts it from the keyboard-adjusted viewport.
                    .safeAreaInset(edge: .bottom, spacing: NativeAgentMobileTheme.Spacing.md) {
                        VStack(alignment: .trailing, spacing: 8) {
                            // Only while scrolled up, and above the composer, never on it.
                            if showLatestButton {
                                Button {
                                    let follow = ChatFollowPresentation.followLatest()
                                    autoFollowChat = follow.autoFollow
                                    showLatestButton = follow.showsLatest
                                    scheduleScrollToBottom(proxy, animated: true, delayMilliseconds: 0, force: true)
                                } label: {
                                    Label("Latest", systemImage: "arrow.down")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(AlivePalette.text)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 36)
                                        .aliveGlass(in: Capsule(), interactive: true)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, NativeAgentMobileTheme.Spacing.lg)
                                .transition(.opacity)
                            }
                            MobileGlassContainer { composerBar }
                                .padding(.horizontal, NativeAgentMobileTheme.Spacing.lg)
                                .padding(.bottom, NativeAgentMobileTheme.Spacing.sm)
                        }
                        .animation(.easeOut(duration: 0.18), value: showLatestButton)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height - $0.safeAreaInsets.bottom } action: { _ in
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    // 2026-05-09 fix: keyboard would not dismiss when the user tapped
                    // off the textfield.  scrollDismissesKeyboard(.interactively)
                    // makes the keyboard slide down as the scroll view drags it
                    // off-screen (matches Messages.app feel); the tap-anywhere
                    // gesture below is the explicit dismiss-on-tap fallback.
                    .scrollDismissesKeyboard(.interactively)
                    .contentShape(Rectangle())
	                    .onTapGesture {
                        // Resign first responder on the focused TextField.
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8).onChanged { drag in
                            if drag.translation.height > 0, store.isLoading || !store.messages.isEmpty {
                                let follow = ChatFollowPresentation.userScrolledAway()
                                autoFollowChat = follow.autoFollow
                                showLatestButton = follow.showsLatest
                            }
                        }
                    )
                    .onAppear {
                        let follow = ChatFollowPresentation.followLatest()
                        autoFollowChat = follow.autoFollow
                        showLatestButton = follow.showsLatest
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 120, force: true)
                    }
                    .onChange(of: store.messages.count) {
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: store.messages.last?.text) {
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 16)
                    }
                    .onChange(of: store.messages.last?.isStreaming) {
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: store.isLoading) {
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    // B2: a straggler reply landed after its bubble timed out —
                    // force-scroll to it even if the user had scrolled away.
                    .onChange(of: store.scrollToBottomTick) {
                        scheduleScrollToBottom(proxy, animated: true, delayMilliseconds: 0, force: true)
                    }
                    // session-switch scroll fix 2026-05-23: parity with Mac.
                    // selectedSessionID flips on tab tap (user-intent moment)
                    // — reset autoFollow + scroll so the new session lands at
                    // bottom instead of leaving a blank chrome / stale scroll
                    // position. The blank symptom was: tap pinned tab,
                    // ScrollView empties + retains old scroll offset, new
                    // session's messages load async and arrive below the
                    // visible area; user has to manually scroll.
                    .onChange(of: store.selectedSessionID) {
                        let follow = ChatFollowPresentation.followLatest()
                        autoFollowChat = follow.autoFollow
                        showLatestButton = follow.showsLatest
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 80, force: true)
                    }
                    // Belt-and-suspenders: when the first message id changes
                    // the messages array has actually swapped (post-load),
                    // not just been emptied. Force one more scroll with
                    // enough delay for the LazyVStack to lay out the new
                    // content so we land on the real bottom.
                    .onChange(of: store.messages.first?.id) {
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 120, force: true)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                        scheduleScrollToBottom(proxy, animated: false, force: true)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                        scheduleScrollToBottom(proxy, animated: false, force: true)
                    }
                }

            }
            .background { AliveChatRoom(store: store) }
            // The serif header carries the name and every chat action, so the
            // bar has nothing left to draw. The title stays for VoiceOver and
            // the app switcher.
            .navigationTitle(agentDisplayName)
            .toolbar(.hidden, for: .navigationBar)
            .tint(AlivePalette.text)
            .animation(AppMotion.snappy, value: voiceInput.isListening)
            // Sweep R4 C11.3: iCloudSyncEngine.syncError was published and read
            // by nothing. Render-only — no retry, no new sync work.
            .macSyncErrorBanner()
            .sheet(item: $inboxDetailItem, onDismiss: { inboxGroup = nil }) { item in
                if let inboxGroup {
                    InboxView(initialGroup: inboxGroup)
                } else {
                    InboxDetailSheet(item: item, allItems: sync.inboxItems, onOpenGroup: { group in
                        inboxGroup = group
                    }) {
                        inboxDetailItem = nil
                    }
                }
            }
            .sheet(isPresented: $showsChatSetup) {
                PairingView(onSkip: { showsChatSetup = false }, onPaired: { showsChatSetup = false })
            }
            .sheet(isPresented: $showsConfiguration) {
                NavigationStack {
                    ScrollView { configurationControls }
                        .mobileReadingScreen()
                        .navigationTitle("Chat options")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { showsConfiguration = false } }
                        .hazeTinted()
                }
                // Five rows: a half sheet, where the room's haze fills the view.
                .presentationDetents([.medium, .large])
            }
            .task {
                #if DEBUG
                if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleModel") {
                    showsConfiguration = true
                }
                if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleToast") {
                    iOSSystemToastCenter.shared.push(success: "Approved. I'll add it now.", autoDismissAfter: nil)
                }
                if isChatSample && ProcessInfo.processInfo.arguments.contains("-chatSampleKeyboard") {
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-chatSampleDraft"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                        inputText = ProcessInfo.processInfo.arguments[index + 1]
                    }
                    await Task.yield()
                    composerIsFocused = true
                }
                #endif
            }
            // N5 fix (R18): subscribe to iCloud replies so assistant messages
            // arrive asynchronously when in iCloud pairing mode.
            // observeICloudReplies is a no-op in HTTP mode (useICloud=false guard).
            .onAppear {
                // 2026-09-06: a reply push must not alert on top of an answer
                // the user is already reading. This is the only place that
                // knows a chat surface is on screen.
                ChatStore.visibleStore = store
                adoptMainSessionFromSnapshots()
                if MobileQuickAskRoute.consume() { composerIsFocused = true }
                consumeNotifiedChatSessionIfNeeded()
                // 2026-09-13 review: local model state left over from an older
                // build is CLEARED before anything can be sent, not kept until a
                // catalog happens to arrive. Waiting for a snapshot meant an
                // early or offline send transmitted a stale override and the Mac
                // honoured it. The phone hydrates only from the Mac's synced
                // choice; until that lands it sends no override at all.
                clearLegacyLocalModelStateIfNeeded()
                adoptSurfaceModelPreferenceFromSync()
                importSharedItems()
                // Wire TTS callback into store
                store.onReply = { [voiceOutput] text in
                    voiceOutput.speak(text)
                }
                // 2026-09-06: every session change ends dictation, wired once
                // here instead of at each switch call site — New Chat, a
                // removed pin and the conversation anchor all bypassed the
                // per-call-site stop and delivered the transcript into the
                // wrong conversation.
                store.onSessionChange = { [voiceInput, origin = $dictationSessionKey] in
                    guard voiceInput.isListening || voiceInput.isStarting
                        || origin.wrappedValue != nil else { return }
                    origin.wrappedValue = nil
                    voiceInput.stop()
                }
                if iCloudReplyObserverID == nil {
                    iCloudReplyObserverID = bridgeClient.observeICloudReplies { msg in
                        Task { @MainActor in
                            store.receiveICloudReply(msg)
                        }
                    }
                }
                if iCloudRejectionObserverID == nil {
                    iCloudRejectionObserverID = bridgeClient.observeICloudReplyRejections { rejection in
                        Task { @MainActor in
                            store.receiveICloudRejection(rejection)
                        }
                    }
                }
                // Phase 14e-iCloud HMAC self-heal: subscribe to signature_invalid_resync
                // hints so a stale-secret event triggers a refresh + replay instead
                // of the silent-drop behavior the action channel already avoids.
                store.pendingRetryClient = bridgeClient
                store.pairingStoreRef = pairingStore
                if iCloudResyncObserverID == nil {
                    iCloudResyncObserverID = bridgeClient.observeICloudResyncHints { hint in
                        Task { @MainActor in
                            store.receiveICloudResyncHint(hint, client: bridgeClient)
                        }
                    }
                }
                // 2026-09-13: an unfinished exchange from a previous launch
                // goes back to being watched here. Observation only — the
                // signed request already crossed the bridge and is never sent
                // a second time.
                store.resumeObservingPendingExchanges(using: bridgeClient)
                _ = NativeAgentDeepLinkSendHook.deliverPending(
                    to: store,
                    client: bridgeClient,
                    controls: runtimeControls
                )
                Task {
                    await bridgeClient.pollICloudRepliesNow()
                    await sync.refreshProviderControlsSnapshot()
                    await sync.refreshChatSessionListSnapshot()
                    adoptMainSessionFromSnapshots()
                    reconcileExternallyRemovedPinnedSession(
                        afterPinnedIDs: visiblePinnedSessionIDs
                    )
                    adoptConversationAnchorIfNeeded()
                    store.refresh(using: bridgeClient, fallbackMessages: currentSnapshotMessages())
                    await MainActor.run { seedProviderIfNeeded() }
                }
                // PATCH-2026-05-11: foreground-refresh — pull latest history on appear.
            }
            // PATCH-2026-05-11: foreground-refresh — pull latest history when app foregrounds.
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    if MobileQuickAskRoute.consume() { composerIsFocused = true }
                    importSharedItems()
                    store.resumeObservingPendingExchanges(using: bridgeClient)
                    Task {
                        await bridgeClient.pollICloudRepliesNow()
                        await sync.refreshChatSessionListSnapshot()
                        adoptMainSessionFromSnapshots()
                        reconcileExternallyRemovedPinnedSession(
                            afterPinnedIDs: visiblePinnedSessionIDs
                        )
                        adoptConversationAnchorIfNeeded()
                        store.refresh(using: bridgeClient, fallbackMessages: currentSnapshotMessages())
                    }
                }
            }
            .onDisappear {
                if ChatStore.visibleStore === store { ChatStore.visibleStore = nil }
                guard !store.hasPendingICloudReplies && !store.isLoading else { return }
                bridgeClient.removeICloudReplyObserver(iCloudReplyObserverID)
                bridgeClient.removeICloudReplyRejectionObserver(iCloudRejectionObserverID)
                bridgeClient.removeICloudResyncHintObserver(iCloudResyncObserverID)
                iCloudReplyObserverID = nil
                iCloudRejectionObserverID = nil
                iCloudResyncObserverID = nil
            }
            .onChange(of: store.isSwitchingSession) { _, switching in
                if !switching { importSharedItems() }
            }
            .onChange(of: agentDisplayName) { _, _ in rememberShareAgentName() }
            // 2026-09-06: a reply notification names the conversation it came
            // from. Consume it here too — onAppear only fires when the chat
            // surface was not already mounted.
            .onReceive(NotificationCenter.default.publisher(for: .nativeagentOpenActivity)) { _ in
                consumeNotifiedChatSessionIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: MobileQuickAskRoute.notification)) { _ in
                if MobileQuickAskRoute.consume() { composerIsFocused = true }
            }
            // 2026-09-06: a notification that arrived mid-load kept its intent
            // rather than losing it. Retry the moment the load releases.
            .onChange(of: store.isSwitchingSession) { _, switching in
                guard !switching else { return }
                consumeNotifiedChatSessionIfNeeded()
                adoptMainSessionFromSnapshots()
            }
            // Simulator/process-argument test hook. The release target exposes
            // no URL scheme that can inject a real agent turn.
            .onReceive(NotificationCenter.default.publisher(for: .nativeagentDeepLinkSend)) { _ in
                _ = NativeAgentDeepLinkSendHook.deliverPending(
                    to: store,
                    client: bridgeClient,
                    controls: runtimeControls
                )
            }
            // Append transcript to input field when user releases mic button
            .onChange(of: voiceInput.lastFinalTranscript) { _, newValue in
                guard !newValue.isEmpty else { return }
                // 2026-09-06: only the conversation the user dictated into
                // receives the words.
                guard let origin = dictationSessionKey,
                      origin == store.queueSessionKey(store.selectedSessionID) else { return }
                if inputText.isEmpty {
                    inputText = newValue
                } else {
                    inputText += " " + newValue
                }
            }
            .onChange(of: selectedPhotoItems) { previousItems, items in
                if items.isEmpty && suppressNextEmptyPhotoSelection {
                    suppressNextEmptyPhotoSelection = false
                    return
                }
                loadPhotoAttachments(items, previousItems: previousItems)
            }
        }
    }

    // MARK: - Composer

    private var composerBar: some View {
        VStack(spacing: 8) {
            if voiceInput.isListening || voiceInput.isStarting {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(NativeAgentPalette.agentAccent)
                    Text(voiceInput.transcript.isEmpty ? (voiceInput.statusText ?? "Listening") : voiceInput.transcript)
                        .font(AppFont.body.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .frame(height: 28)
                .padding(.horizontal, 4)
            }
            if !pendingPhotos.isEmpty || isLoadingPhotos {
                pendingPhotoStrip
            }
            if !queuedTurns.isEmpty {
                queuedSendStrip
            }

            let a11y = dynamicTypeSize.isAccessibilitySize
            let layout = a11y
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 2))
            layout {
                if !a11y { photosPickerButton }
                TextField(composerPlaceholder, text: Binding(
                    get: { inputText },
                    set: { inputText = $0 }
                ), prompt: Text(composerPlaceholder).foregroundStyle(AlivePalette.secondary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($composerIsFocused)
                    .mobileTypography(.body)
                    .lineLimit(a11y ? 1...8 : 1...5)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .submitLabel(.send)
                    .onSubmit { submitMessage() }
                    .disabled(store.isSwitchingSession)

            HStack(spacing: 2) {
                if a11y { photosPickerButton; Spacer(minLength: 8) }
                micButton
                    .disabled(store.isSwitchingSession)

                if store.isLoading || (isChatSample && visibleMessages.last?.isStreaming == true) {
                    Button {
                        guard !isChatSample else { return }
                        store.stop(client: bridgeClient)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AlivePalette.text)
                            .frame(width: 36, height: 36)
                            .background(NativeAgentMobileTheme.Colors.softFill, in: Circle())
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Stop generation")
                } else {

                Button {
                    submitMessage()
                } label: {
                    let active = canSend && !store.isSwitchingSession
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(active ? Color.white : AlivePalette.secondary)
                        .frame(width: 36, height: 36)
                        .background {
                            Circle().fill(active
                                ? HazeColor(stored: hazeColorRaw).control(dark: true, labelled: true)
                                : NativeAgentMobileTheme.Colors.softFill)
                            // phase 6: send-control micro-feedback — fade the
                            // enabled/sending fills instead of popping. Bound to
                            // the two discrete state flags (canSend/isLoading),
                            // not content. reduceMotion → nil (instant swap).
                            .animation(
                                AppMotion.respecting(AppMotion.snappy, reduceMotion: reduceMotion),
                                value: active)
                        }
                        .frame(width: 44, height: 44)
                }
                .disabled(!canSend || store.isSwitchingSession)
                .accessibilityLabel("Send message")
                }
            }
            }
        }
        .foregroundStyle(AlivePalette.text)
        .hazeTinted()
        // One floating glass capsule: the functional layer, over the thread.
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .aliveGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true)
        .overlay {
            PhoneThinkingLight(correlationIDs: Set(store.pendingICloudPlaceholders.keys))
        }
        .frame(maxWidth: NativeAgentMobileTheme.Layout.roomColumn)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingPhotos.isEmpty
    }

    private var hasComposerDraft: Bool {
        !inputText.isEmpty || !pendingPhotos.isEmpty
            || !selectedPhotoItems.isEmpty || isLoadingPhotos
    }

    private var queuedSendStrip: some View {
        let turns = queuedTurns
        let next = turns[0]
        let primaryAction = QueuedSendStripAction.resolve(
            id: next.id,
            isLoading: store.isLoading
        )
        // One line: what waits, its preview, and ONE menu for what to do with
        // it (send, remove, and the rest of the queue when there is more).
        return HStack(spacing: 10) {
            Text(store.isSelectedQueuePaused ? "Paused" : turns.count > 1 ? "Next of \(turns.count)" : "Next")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize()

            Text(next.preview)
                .font(.footnote)
                .foregroundStyle(AlivePalette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    primaryAction.apply(
                        onSteer: { store.sendQueuedNow($0, client: bridgeClient) },
                        onSend: { store.resumeQueuedSends(startingWith: $0) }
                    )
                } label: {
                    Label(primaryAction.primaryTitle, systemImage: "arrow.up")
                }
                Button(role: .destructive) {
                    store.removeQueuedSend(next.id)
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
                if turns.count > 1 {
                    Section(AliveWords.count(turns.count, "message") + " waiting") {
                        ForEach(Array(turns.enumerated().dropFirst()), id: \.element.id) { index, queued in
                            let action = QueuedSendStripAction.resolve(
                                id: queued.id,
                                isLoading: store.isLoading
                            )
                            Button {
                                action.apply(
                                    onSteer: { store.sendQueuedNow($0, client: bridgeClient) },
                                    onSend: { store.resumeQueuedSends(startingWith: $0) }
                                )
                            } label: {
                                Label(action.menuTitle(position: index + 1, preview: queued.preview), systemImage: "arrow.up")
                            }
                            Button(role: .destructive) {
                                store.removeQueuedSend(queued.id)
                            } label: {
                                Label("Remove \(index + 1): \(queued.preview)", systemImage: "xmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AlivePalette.text)
                    .frame(width: 30, height: 30)
                    .background(AlivePalette.fill, in: Circle())
                    .overlay(Circle().strokeBorder(AlivePalette.rim, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Queued message actions")
        }
        .padding(.leading, 12)
        .padding(.trailing, 0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AlivePalette.divider).frame(height: 1).padding(.horizontal, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send-next queue, \(turns.count) queued")
    }

    private var pendingPhotoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isLoadingPhotos {
                    Label("Loading photos", systemImage: "photo")
                        .font(AppFont.tag)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(AlivePalette.fill, in: Capsule())
                }
                ForEach(pendingPhotos) { photo in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                            .accessibilityLabel("Attached photo")
                        Button {
                            photoLoadTask?.cancel()
                            photoLoadGeneration += 1
                            isLoadingPhotos = false
                            let removal = PendingPhotoPresentation.removing(photo.id, from: pendingPhotos)
                            pendingPhotos = removal.photos
                            if removal.clearsPicker {
                                selectedPhotoItems = []
                            }
                            suppressNextEmptyPhotoSelection = removal.suppressesNextEmptySelection
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.58))
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                .contentShape(Rectangle())
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove attached photo")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Runtime controls

    private var chatSessionTabsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(chatSessionTabs) { tab in
                    let selected = tab.id == selectedChatSessionTabID
                    ZStack(alignment: .trailing) {
                        Button {
                            selectChatSessionTab(tab)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.systemImage)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(tab.title)
                                    .font(.footnote.weight(selected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(selected ? AlivePalette.text : AlivePalette.secondary)
                            .padding(.leading, 12)
                            .padding(.trailing, tab.closableSessionID == nil ? 12 : 30)
                            .frame(width: tab.kind == .main ? 112 : 156, height: 34)
                            .background(selected ? AlivePalette.fill : Color.clear, in: Capsule())
                            .overlay { if selected { Capsule().strokeBorder(AlivePalette.rim, lineWidth: 1) } }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            ChatSessionTabPresentation.isSelectionDisabled(
                                isSwitchingSession: store.isSwitchingSession,
                                isClosingSession: tab.sessionID.map { closingPinnedSessionIDs.contains($0) } ?? false
                            )
                        )
                        .opacity(store.isSwitchingSession && !selected ? 0.55 : 1)
                        .accessibilityLabel(tab.title)

                        // Real pins only. The derived anchor tab has no pin to
                        // remove, so it gets no close control.
                        if let sessionID = tab.closableSessionID {
                            Button {
                                closePinnedChatSession(sessionID)
                            } label: {
                                if closingPinnedSessionIDs.contains(sessionID) {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 32)
                                        .contentShape(Rectangle())
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 4)
                            .disabled(
                                store.isLoading || store.isSwitchingSession
                                    || closingPinnedSessionIDs.contains(sessionID)
                            )
                            .accessibilityLabel("Close \(tab.title) tab")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .frame(height: 42)
    }

    /// PhotosPicker's label is an escaping @Sendable closure, so it cannot
    /// reference the MainActor-isolated `isLoadingPhotos` directly. Reading it
    /// into a local `Bool` (a Sendable value) before building the label means
    /// the closure captures the value, not `self`.
    private var photosPickerButton: some View {
        let loading = isLoadingPhotos
        let retainedOutsidePicker = pendingPhotos.filter { photo in
            !selectedPhotoItems.contains { $0 == photo.pickerItem }
        }.count
        return PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, maxPendingPhotos - retainedOutsidePicker),
            matching: .images
        ) {
            Image(systemName: loading ? "hourglass" : "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AlivePalette.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(store.isLoading || store.isSwitchingSession || loading || pendingPhotos.count == maxPendingPhotos)
        .accessibilityLabel("Add photos")
    }

    /// The Mac Simple header: the agent's name in serif with its light, and
    /// one line under it saying what it is doing (or why the Mac is away).
    private var runtimeControlsBar: some View {
        let online = isChatSample || bridgeClient.bridgeStatus == .online
        // The kit's door, at the same height as every tab: when the Mac is
        // away the line under the name becomes its status (the chip keeps its
        // full 44pt target).
        return AlivePageHeader(title: agentDisplayName, line: agentDoing.text,
                               dot: online ? agentDoing.dot : .away, showsStatus: !isChatSample) {
            chatActionsMenu
        }
        .padding(.horizontal, AliveMetrics.pageInset + 4)
        .padding(.top, AliveMetrics.rootTop)
        .padding(.bottom, 6)
    }

    /// What the agent is doing, in the Mac's words.
    private var agentDoing: (text: String, dot: AliveStatusDot.State) {
        if store.isLoading || (isChatSample && visibleMessages.last?.isStreaming == true) {
            let replying = visibleMessages.last.map { $0.role == .assistant && $0.isStreaming && !$0.text.isEmpty } ?? false
            return (replying ? "Replying…" : "Thinking…", .working)
        }
        if !inlineChatApprovals.isEmpty { return ("Waiting on you", .waiting) }
        return ("Here", .here)
    }

    private var configurationControls: some View {
            VStack(alignment: .leading, spacing: 0) {
                Menu {
                    ForEach(selectableProviders) { provider in
                        Button {
                            selectProvider(provider.provider_id)
                        } label: {
                            Label(provider.display_name, systemImage: provider.provider_id == selectedProviderId ? "checkmark" : "server.rack")
                        }
                    }
                } label: {
                    controlPill("Provider", title: isChatSample ? "Anthropic · extended workspace" : providerLabel(selectedProviderId))
                }

                AliveDivider()
                Menu {
                    ForEach(availableModelIDs, id: \.self) { model in
                        Button {
                            // Optimistic set, then confirm against the Mac. If the
                            // iCloud round-trip fails the pick used to stay on screen
                            // until a later snapshot silently reverted it; now we undo
                            // it here and say why.
                            let previous = selectedModel
                            let previousEffort = selectedReasoningEffort
                            let previousFastMode = selectedFastMode
                            let previousProvider = selectedProviderId
                            selectedModel = model
                            reconcileExecutionControlsForSelectedModel()
                            let requestedProvider = selectedProviderId
                            let requestedEffort = selectedReasoningEffort
                            let myGeneration = beginSurfaceSelectionUpdate()
                            Task {
                                let result = await ChatRuntimeControlPresentation.execute(
                                    defaults: .standard,
                                    previous: .init(providerID: previousProvider, model: previous, reasoningEffort: previousEffort, fastMode: previousFastMode),
                                    requested: .init(providerID: requestedProvider, model: model, reasoningEffort: requestedEffort, fastMode: selectedFastMode),
                                    requestGeneration: myGeneration
                                ) { requested in
                                    let receipt = try await sync.configureSurfaceSelection(
                                        surface: "ios",
                                        providerId: requested.providerID,
                                        model: requested.model,
                                        reasoningEffort: requested.reasoningEffort,
                                        serviceTier: requested.fastMode ? "priority" : "default"
                                    )
                                    adoptCanonicalSurfaceSelection(receipt, requestGeneration: myGeneration)
                                }
                                if let restored = result.restored {
                                    // Only undo if no NEWER pick happened while this
                                    // round-trip was in flight — generation, not value:
                                    // the user may have moved away and back (ABA).
                                    selectedModel = restored.model
                                    selectedReasoningEffort = restored.reasoningEffort
                                    selectedFastMode = restored.fastMode
                                    selectedProviderId = restored.providerID
                                }
                                if let error = result.error {
                                    finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                                    iOSSystemToastCenter.shared.push(
                                        error: "Couldn't switch to \(modelLabel(model)): \(error.localizedDescription)"
                                    )
                                }
                            }
                        } label: {
                            Label(modelLabel(model), systemImage: selectedModel == model ? "checkmark" : "cpu")
                        }
                    }
                    Divider()
                    Button {
                        Task {
                            await ChatRuntimeControlPresentation.refreshModels(
                                refresh: { await sync.refreshProviderControlsSnapshot() },
                                presentError: { iOSSystemToastCenter.shared.push(error: $0) }
                            )
                        }
                    } label: {
                        Label("Refresh Models", systemImage: "arrow.clockwise")
                    }
                } label: {
                    controlPill("Model", title: isChatSample ? "Claude Fable 5.1 · extended context" : modelLabel(selectedModel))
                }

                AliveDivider()
                Menu {
                    ForEach(reasoningOptions, id: \.id) { option in
                        Button {
                            let previousModel = selectedModel
                            let previous = selectedReasoningEffort
                            let previousFastMode = selectedFastMode
                            let previousProvider = selectedProviderId
                            selectedReasoningEffort = option.id
                            let requestedModel = selectedModel
                            let requestedProvider = selectedProviderId
                            let requestedServiceTier = selectedFastMode ? "priority" : "default"
                            let myGeneration = beginSurfaceSelectionUpdate()
                            Task {
                                do {
                                    let receipt = try await sync.configureSurfaceSelection(
                                        surface: "ios",
                                        providerId: requestedProvider,
                                        model: requestedModel,
                                        reasoningEffort: option.id,
                                        serviceTier: requestedServiceTier
                                    )
                                    adoptCanonicalSurfaceSelection(receipt, requestGeneration: myGeneration)
                                } catch {
                                    finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                                    // Generation, not value (ABA) — see model menu above.
                                    if let restored = ChatRuntimeControlPresentation.rollback(
                                        currentGeneration: surfaceSelectionGeneration,
                                        requestGeneration: myGeneration,
                                        previous: .init(providerID: previousProvider, model: previousModel, reasoningEffort: previous, fastMode: previousFastMode)
                                    ) {
                                        selectedModel = restored.model
                                        selectedReasoningEffort = restored.reasoningEffort
                                        selectedFastMode = restored.fastMode
                                        selectedProviderId = restored.providerID
                                    }
                                    iOSSystemToastCenter.shared.push(
                                        error: "Couldn't set reasoning to \(option.label): \(error.localizedDescription)"
                                    )
                                }
                            }
                        } label: {
                            Label(option.label, systemImage: selectedReasoningEffort == option.id ? "checkmark" : "brain")
                        }
                    }
                } label: {
                    controlPill("Thinking", title: reasoningLabel(selectedReasoningEffort))
                }

                AliveDivider()
                Menu {
                    Button { setFastMode(false) } label: {
                        Label("Normal", systemImage: selectedFastMode ? "circle" : "checkmark")
                    }
                    Button { setFastMode(true) } label: {
                        Label("Fast", systemImage: selectedFastMode ? "checkmark" : "bolt.fill")
                    }
                    .disabled(!selectedModelSupportsFast)
                } label: {
                    controlPill(
                        "Speed",
                        title: ChatRuntimeControlPresentation.processingModeTitle(fastMode: selectedFastMode)
                    )
                }
                .accessibilityLabel("Processing mode: \(selectedFastMode ? "Fast" : "Normal")")

                AliveDivider()
                Menu {
                    ForEach(fileAccessOptions, id: \.id) { option in
                        Button {
                            selectedFileAccess = option.id
                        } label: {
                            Label(option.label, systemImage: selectedFileAccess == option.id ? "checkmark" : option.icon)
                        }
                    }
                } label: {
                    controlPill("File access", title: fileAccessLabel(selectedFileAccess))
                }
            }
            .aliveCard()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        .tint(AlivePalette.text)
        // Seed the provider pill off this small subview rather than the main
        // `body` chain — adding another modifier to body tips its expression
        // past the Swift type-checker's complexity budget (build timeout).
        // seedProviderIfNeeded() is idempotent, so repeated fires are safe.
        .onChange(of: sync.providers) { _, _ in
            seedProviderIfNeeded()
        }
    }

    /// One row of the options card: what it is on the left, the current
    /// choice on the right. The whole row opens its menu.
    private func controlPill(_ label: String, title: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(AlivePalette.text)
            Spacer(minLength: 8)
            Text(title)
                .font(.body)
                .foregroundStyle(AlivePalette.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AlivePalette.secondary)
        }
        .aliveRow()
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var selectableProviders: [ProviderInfo] {
        sync.providers
            .filter { $0.auth_status.state == "ready" }
            .sorted { $0.display_name.localizedCaseInsensitiveCompare($1.display_name) == .orderedAscending }
    }

    private func providerLabel(_ id: String) -> String {
        let full = sync.providers.first(where: { $0.provider_id == id })?.display_name
            ?? (id.isEmpty ? "Provider" : id)
        // Pill label only: drop the parenthetical auth flavor ("Anthropic
        // (OAuth / Setup-Token)" → "Anthropic"). The menu items keep the
        // full display_name so auth variants stay distinguishable there.
        if let paren = full.range(of: " (") {
            return String(full[..<paren.lowerBound])
        }
        return full
    }

    private var availableModelIDs: [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        if let provider = sync.providers.first(where: { $0.provider_id == selectedProviderId }) {
            for model in provider.models where !model.id.isEmpty && seen.insert(model.id).inserted {
                ids.append(model.id)
            }
        }
        if !selectedModel.isEmpty, seen.insert(selectedModel).inserted {
            ids.insert(selectedModel, at: 0)
        }
        return ids.sorted { lhs, rhs in
            if lhs == selectedModel { return true }
            if rhs == selectedModel { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func selectProvider(_ id: String) {
        let previousProvider = selectedProviderId
        let previousModel = selectedModel
        let previousEffort = selectedReasoningEffort
        let previousFastMode = selectedFastMode
        guard let selected = ChatRuntimeControlPresentation.selectionForProvider(
            providerID: id,
            current: .init(providerID: previousProvider, model: previousModel, reasoningEffort: previousEffort, fastMode: previousFastMode),
            providers: sync.providers,
            preferredModels: Self.preferredModelIDs
        ) else {
            iOSSystemToastCenter.shared.push(error: "That provider is not ready on the Mac.")
            return
        }
        selectedProviderId = selected.providerID
        selectedModel = selected.model
        selectedReasoningEffort = selected.reasoningEffort
        selectedFastMode = selected.fastMode
        let requestedModel = selectedModel
        let requestedEffort = selectedReasoningEffort
        let requestedFastMode = selectedFastMode
        let myGeneration = beginSurfaceSelectionUpdate()
        Task {
            let result = await ChatRuntimeControlPresentation.execute(
                defaults: .standard,
                previous: .init(providerID: previousProvider, model: previousModel, reasoningEffort: previousEffort, fastMode: previousFastMode),
                requested: .init(providerID: id, model: requestedModel, reasoningEffort: requestedEffort, fastMode: requestedFastMode),
                requestGeneration: myGeneration
            ) { requested in
                let receipt = try await sync.configureSurfaceSelection(
                    surface: "ios",
                    providerId: requested.providerID,
                    model: requested.model,
                    reasoningEffort: requested.reasoningEffort,
                    serviceTier: requested.fastMode ? "priority" : "default"
                )
                adoptCanonicalSurfaceSelection(receipt, requestGeneration: myGeneration)
            }
            if let restored = result.restored {
                    selectedProviderId = restored.providerID
                    selectedModel = restored.model
                    selectedReasoningEffort = restored.reasoningEffort
                    selectedFastMode = restored.fastMode
            }
            if let error = result.error {
                finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                iOSSystemToastCenter.shared.push(
                    error: "Couldn't switch provider: \(error.localizedDescription)"
                )
            }
        }
    }

    private func setFastMode(_ enabled: Bool) {
        guard enabled != selectedFastMode else { return }
        guard !enabled || selectedModelSupportsFast else {
            iOSSystemToastCenter.shared.push(error: "Fast mode is not available for \(modelLabel(selectedModel)).")
            return
        }
        let previous = ChatRuntimeControlPresentation.Selection(
            providerID: selectedProviderId,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            fastMode: selectedFastMode
        )
        selectedFastMode = enabled
        let requested = ChatRuntimeControlPresentation.Selection(
            providerID: selectedProviderId,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            fastMode: enabled
        )
        let myGeneration = beginSurfaceSelectionUpdate()
        Task {
            do {
                let receipt = try await sync.configureSurfaceSelection(
                    surface: "ios",
                    providerId: requested.providerID,
                    model: requested.model,
                    reasoningEffort: requested.reasoningEffort,
                    serviceTier: requested.fastMode ? "priority" : "default"
                )
                adoptCanonicalSurfaceSelection(receipt, requestGeneration: myGeneration)
            } catch {
                finishSurfaceSelectionFailure(requestGeneration: myGeneration)
                if let restored = ChatRuntimeControlPresentation.rollback(
                    currentGeneration: surfaceSelectionGeneration,
                    requestGeneration: myGeneration,
                    previous: previous
                ) {
                    selectedProviderId = restored.providerID
                    selectedModel = restored.model
                    selectedReasoningEffort = restored.reasoningEffort
                    selectedFastMode = restored.fastMode
                }
                iOSSystemToastCenter.shared.push(
                    error: "Couldn't change processing mode: \(error.localizedDescription)"
                )
            }
        }
    }

    private func seedProviderIfNeeded() {
        adoptSurfaceModelPreferenceFromSync()
    }

    /// The phone holds no model of its own. Anything in local storage that the
    /// Mac has not just told us about is a leftover from a build that did, and it
    /// goes before a turn can carry it. Runs once per install generation.
    private func clearLegacyLocalModelStateIfNeeded() {
        if !hasHydratedModelFromMac, sync.surfaceModels["ios"] == nil, !selectedModel.isEmpty {
            selectedModel = ""
            selectedProviderId = ""
        }
    }

    private func adoptSurfaceModelPreferenceFromSync() {
        guard let preference = sync.surfaceModels["ios"] else { return }
        let resolution = ChatSurfaceModelPreferenceAdoption.resolve(
            current: .init(
                providerID: selectedProviderId,
                model: selectedModel,
                reasoningEffort: selectedReasoningEffort,
                fastMode: selectedFastMode
            ),
            preference: preference,
            awaitingAcknowledgement: surfaceSelectionAwaitingSync,
            selectableProviderIDs: Set(selectableProviders.map(\.provider_id))
        )
        surfaceSelectionAwaitingSync = resolution.awaitingAcknowledgement
        hasHydratedModelFromMac = true
        guard resolution.selection != .init(
            providerID: selectedProviderId,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            fastMode: selectedFastMode
        ) else { return }
        selectedProviderId = resolution.selection.providerID
        selectedModel = resolution.selection.model
        selectedReasoningEffort = resolution.selection.reasoningEffort
        selectedFastMode = resolution.selection.fastMode
        reconcileExecutionControlsForSelectedModel()
    }

    private func beginSurfaceSelectionUpdate() -> Int {
        surfaceSelectionGeneration += 1
        surfaceSelectionAwaitingSync = true
        return surfaceSelectionGeneration
    }

    private func adoptCanonicalSurfaceSelection(_ receipt: MobileSurfaceSelectionReceipt, requestGeneration: Int) {
        guard let selection = ChatRuntimeControlPresentation.acceptReceipt(
            receipt, defaults: .standard, requestGeneration: requestGeneration
        ) else { return }
        selectedProviderId = selection.providerID
        selectedModel = selection.model
        selectedReasoningEffort = selection.reasoningEffort
        selectedFastMode = selection.fastMode
        // Keep stale projections fenced until this exact canonical tuple is
        // observed. The matching snapshot may already have arrived mid-await.
        hasHydratedModelFromMac = true
        surfaceSelectionAwaitingSync = true
        adoptSurfaceModelPreferenceFromSync()
    }

    private func finishSurfaceSelectionFailure(requestGeneration: Int) {
        guard surfaceSelectionGeneration == requestGeneration else { return }
        surfaceSelectionAwaitingSync = false
    }

    private var reasoningOptions: [(id: String, label: String)] {
        let all = [
            ("none", "None"),
            ("low", "Low"),
            ("medium", "Medium"),
            ("high", "High"),
            ("xhigh", "XHigh"),
            ("max", "Max"),
            ("ultra", "Ultra")
        ]
        guard let supported = selectedModelInfo?.supported_reasoning_efforts,
              !supported.isEmpty else { return Array(all.prefix(4)) }
        return all.filter { supported.contains($0.0) }
    }

    private var selectedModelInfo: ProviderModelInfo? {
        sync.providers
            .first(where: { $0.provider_id == selectedProviderId })?
            .models
            .first(where: { $0.id == selectedModel })
    }

    private var selectedModelSupportsFast: Bool {
        selectedModelInfo?.supports_fast == true
    }

    private func reconcileExecutionControlsForSelectedModel() {
        let reconciled = ChatRuntimeControlPresentation.reconciled(
            model: selectedModel,
            provider: sync.providers.first(where: { $0.provider_id == selectedProviderId }),
            selectedEffort: selectedReasoningEffort,
            selectedFastMode: selectedFastMode
        )
        selectedReasoningEffort = reconciled.effort
        selectedFastMode = reconciled.fastMode
    }

    private var fileAccessOptions: [(id: String, label: String, icon: String)] {
        [
            ("auto", "Auto", "wand.and.stars"),
            ("read_only", "Read only", "eye"),
            ("workspace", "Workspace", "folder"),
            ("full", "Full Mac", "bolt.trianglebadge.exclamationmark")
        ]
    }

    private func modelLabel(_ id: String) -> String {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No pick of its own yet: the Mac's Chat choice is what this turn
            // will run on, and the phone says so rather than naming a model.
            return sync.providers.isEmpty ? "Waiting for the Mac's choice" : "Same as Mac"
        }
        return sync.providers
            .flatMap(\.models)
            .first(where: { $0.id == id })?
            .name ?? id
    }

    private func cleanTabTitle(_ title: String, fallback: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }

    /// 2026-09-06: a tapped reply notification carries the session that
    /// answered. Open that conversation instead of leaving the user on
    /// whichever chat happened to be selected.
    private func consumeNotifiedChatSessionIfNeeded() {
        // 2026-09-06: `switchSession` refuses silently while another session
        // load is in flight, and the intent had already been consumed by then
        // — the tap landed on whichever chat happened to be selected. Hold the
        // intent until the load finishes; the isSwitchingSession watcher below
        // calls back in.
        guard !store.isSwitchingSession else { return }
        guard let sessionID = MobileNotifiedChatSessionIntent.consume() else { return }
        // 2026-09-06: the notification chose this conversation even when it was
        // already the selected one, and the note is what stops the
        // externally-removed-pin reconciler from reading its absence from the
        // pinned snapshot as a pin the Mac took away and bouncing the user back
        // to the main chat. Note first; only the redundant load is skipped.
        if sessionID == effectiveMainSessionID {
            MobileChatSelectionIntent.followMain()
        } else {
            MobileChatSelectionIntent.noteNotifiedSelection(sessionID)
        }
        guard sessionID != store.selectedSessionID else { return }
        store.switchSession(
            to: sessionID,
            using: bridgeClient,
            fallbackMessages: snapshotMessages(for: sessionID)
        )
    }

    private func adoptMainSessionFromSnapshots(afterClearingDraft: Bool = false) {
        let isInitialBinding = store.selectedSessionID == nil
            && !MobileChatSelectionIntent.userChoseThisLaunch
        guard !store.isSwitchingSession,
              !hasComposerDraft || isInitialBinding,
              !composerIsFocused || afterClearingDraft || isInitialBinding,
              !isInitialBinding || (!store.isLoading && store.pendingSendArgs.isEmpty),
              // Switching cancels the send task. Keep accepted drafts here
              // until their exact-session handoff has crossed the transport.
              !store.queuedSends.contains(where: {
                  $0.sessionID == store.selectedSessionID
                      && (!isInitialBinding || $0.preparedMessage != nil || $0.placeholderID != nil)
              }),
              let anchorID = sync.chatAnchor?.cleanSessionId,
              sync.sessions.contains(where: { $0.id == anchorID && $0.archived != true }) else { return }
        store.replaceMainSessionID(anchorID)
        guard !MobileChatSelectionIntent.userChoseThisLaunch,
              store.selectedSessionID != anchorID else { return }
        if isInitialBinding {
            store.migrateQueuedSends(from: nil, to: anchorID)
        }
        store.switchSession(to: anchorID, using: bridgeClient,
                            fallbackMessages: snapshotMessages(for: anchorID))
    }

    /// Rows to show while a real read is in flight. 2026-09-06: still nil for an
    /// empty transcript — this is a fallback provider, and only the store's
    /// apply path is allowed to treat an empty publication as authority.
    private func snapshotMessages(for sessionID: String?) -> [ChatMessage]? {
        let mapped = sync.transcriptRead(for: sessionID).messages
        return mapped.isEmpty ? nil : mapped
    }

    private func currentSnapshotMessages() -> [ChatMessage]? {
        snapshotMessages(for: store.selectedSessionID ?? effectiveMainSessionID)
    }

    private func reconcilePublishedChatSessions() {
        store.acknowledgePublishedSessions(Set(sync.sessions.map(\.id)))
        adoptMainSessionFromSnapshots()
        reconcileExternallyRemovedPinnedSession(
            afterPinnedIDs: visiblePinnedSessionIDs
        )
    }

    private func applyPublishedTranscriptToVisibleSession() {
        // 2026-09-06: hand the store the read itself. The empty case used to be
        // dropped here, so a chat cleared on the Mac published its empty
        // transcript and the phone silently ignored it.
        let sessionID = store.selectedSessionID ?? effectiveMainSessionID
        store.applyMacTranscriptRead(sync.transcriptRead(for: sessionID), sessionID: sessionID)
    }

    private func reconcileExternallyRemovedPinnedSession(afterPinnedIDs: Set<String>) {
        guard ChatStore.shouldReturnToMainSession(
            selectedSessionID: store.selectedSessionID,
            mainSessionID: effectiveMainSessionID,
            availablePinnedSessionIDs: afterPinnedIDs,
            locallyCreatedSessionID: store.locallyCreatedSessionID,
            explicitlySelectedSessionID: MobileChatSelectionIntent.notifiedSessionID
        ) else { return }
        store.switchToMainSession(
            using: bridgeClient,
            fallbackMessages: snapshotMessages(for: effectiveMainSessionID)
        )
    }

    /// History is an explicit destination; main continuously follows the Mac.
    private func adoptConversationAnchorIfNeeded() {
        adoptMainSessionFromSnapshots()
    }

    private func selectChatSessionTab(_ tab: ChatSessionTab) {
        let follow = ChatFollowPresentation.followLatest()
        autoFollowChat = follow.autoFollow
        showLatestButton = follow.showsLatest
        switch tab.kind {
        case .main:
            MobileChatSelectionIntent.followMain()
            adoptMainSessionFromSnapshots()
            store.switchToMainSession(using: bridgeClient, fallbackMessages: snapshotMessages(for: tab.sessionID ?? effectiveMainSessionID))
        case .pinned, .anchor:
            guard let sessionID = tab.sessionID else { return }
            MobileChatSelectionIntent.noteNotifiedSelection(sessionID)
            store.switchSession(to: sessionID, using: bridgeClient, fallbackMessages: snapshotMessages(for: sessionID))
        }
    }

    private func closePinnedChatSession(_ sessionID: String) {
        guard closingPinnedSessionIDs.insert(sessionID).inserted else { return }
        Task { @MainActor in
            defer { closingPinnedSessionIDs.remove(sessionID) }
            do {
                do {
                    _ = try await sync.unpinChatSession(sessionId: sessionID)
                } catch SyncError.timeout {
                    // Unconfirmed, not failed: the Mac may not have picked it
                    // up yet. The same request (same message ID) re-checks or
                    // resends, and closing a tab twice is harmless.
                    _ = try await sync.unpinChatSession(sessionId: sessionID)
                }
                // The Mac response is the authority receipt. Remove the
                // mirrored row immediately; the snapshot/KVS write performed
                // before that response will then converge the durable mirror.
                // 2026-09-06: this is a write of the session-list state, so it
                // invalidates the reads already in flight — otherwise a
                // session-list read that started before the unpin completes
                // after it and puts the closed tab straight back.
                sync.chatSessionListRefreshGeneration &+= 1
                sync.pinnedChatSessions.removeAll { $0.id == sessionID }
                if store.selectedSessionID == sessionID {
                    MobileChatSelectionIntent.followMain()
                    adoptMainSessionFromSnapshots()
                    store.switchToMainSession(
                        using: bridgeClient,
                        fallbackMessages: snapshotMessages(for: effectiveMainSessionID)
                    )
                }
            } catch SyncError.timeout {
                // Still unconfirmed. The request stays queued for the Mac and
                // the next pinned-list snapshot drops the tab once it lands;
                // there is nothing for the person to do yet.
            } catch {
                store.errorBanner = "Couldn't close that tab — try again."
            }
        }
    }

    private func providerId(for modelId: String) -> String {
        let activeChatProvider = sync.trustPolicy?.providerPolicy?.activePerSurface?["ios"]
            ?? sync.trustPolicy?.providerPolicy?.activePerSurface?["chat"]
        return ChatRuntimeControlPresentation.providerID(
            selectedProviderID: selectedProviderId,
            activeProviderID: activeChatProvider,
            model: modelId,
            providers: sync.providers
        )
    }

    private func reasoningLabel(_ id: String) -> String {
        reasoningOptions.first(where: { $0.id == id })?.label ?? "Thinking"
    }

    private func fileAccessLabel(_ id: String) -> String {
        let normalized = ChatRuntimeControlPresentation.normalizedFileAccessID(id)
        return fileAccessOptions.first(where: { $0.id == normalized })?.label ?? "Auto"
    }

    private func fileAccessIcon(_ id: String) -> String {
        let normalized = ChatRuntimeControlPresentation.normalizedFileAccessID(id)
        return fileAccessOptions.first(where: { $0.id == normalized })?.icon ?? "wand.and.stars"
    }

    // MARK: - Mic button

    private var micButton: some View {
        let micActive = voiceInput.isListening || voiceInput.isStarting
        return Button {
            if micActive {
                voiceInput.stop()
            } else {
                // Starting to talk ends her talking: playback stops before the
                // microphone opens, so she is not speaking into her own input
                // (2026-09-13).
                voiceOutput.stop()
                dictationSessionKey = store.queueSessionKey(store.selectedSessionID)
                Task { await voiceInput.start() }
            }
        } label: {
            let haze = HazeColor(stored: hazeColorRaw).control(dark: true, labelled: true)
            ZStack {
                if micActive {
                    Circle()
                        .strokeBorder(haze.opacity(0.5), lineWidth: 2)
                        .frame(width: 42, height: 42)
                        .scaleEffect(1.08)
                        .animation(AppMotion.pulse, value: micActive)
                }

                Circle()
                    .fill(micActive ? haze : Color.clear)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "mic")
                            .font(.system(size: 17, weight: micActive ? .semibold : .regular))
                            .symbolVariant(micActive ? .fill : .none)
                            .foregroundStyle(micActive ? Color.white : AlivePalette.secondary)
                    }
                    .animation(AppMotion.snappy, value: micActive)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(micActive ? "Stop dictation" : "Start dictation")
    }

    // MARK: - Chat actions

    /// One glass control for everything the chat can do besides talk: a new
    /// conversation, another answer, spoken replies and the options sheet.
    /// Sweep R4 C11.4's connection state lives in the status line beside it.
    private var chatActionsMenu: some View {
        Menu {
            Menu("History", systemImage: "clock") {
                ForEach(sync.sessions.filter { $0.archived != true && $0.id != effectiveMainSessionID }) { session in
                    Button(session.displayTitle) {
                        MobileChatSelectionIntent.noteNotifiedSelection(session.id)
                        store.switchSession(to: session.id, using: bridgeClient,
                                            fallbackMessages: snapshotMessages(for: session.id))
                    }
                }
            }
            .disabled(store.isSwitchingSession)

            // A new-session action must never be blocked by an in-flight turn
            // on the session we're leaving: a stuck "working" turn would also
            // freeze the one control that recovers it. startNewSession()
            // cancels the in-flight send and resets isLoading.
            Button {
                store.startNewSession()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .disabled(store.isSwitchingSession)

            // No reply yet, nothing to answer again: no dead item.
            if store.messages.contains(where: { $0.role == .assistant }) {
                Button {
                    store.regenerateLast(client: bridgeClient, controls: runtimeControls)
                } label: {
                    Label("Answer again", systemImage: "arrow.clockwise")
                }
                .disabled(!store.canRegenerateLast)
                .accessibilityLabel("Regenerate last response")
                .accessibilityHint("Asks the agent to answer the latest message again")
            }

            Toggle(isOn: Binding(
                get: { voiceOutput.enabled },
                set: { voiceOutput.setEnabled($0) }
            )) {
                Label("Speak replies", systemImage: "speaker.wave.2")
            }
            .accessibilityLabel(voiceOutput.enabled ? "Disable spoken replies" : "Enable spoken replies")

            Divider()

            Button {
                showsConfiguration = true
            } label: {
                Label("Chat options", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("Chat options: provider, model and processing")
        } label: {
            AliveTitleControlLabel(systemImage: "ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat actions")
        .accessibilityHint("New chat, answer again, spoken replies and chat options")
    }

    // MARK: - Send

    private func submitMessage() {
        guard !isChatSample else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingPhotos.map(\.attachment)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let sendText = text.isEmpty
            ? (attachments.count == 1 ? "Look at this photo." : "Look at these photos.")
            : text
        let disposition = store.send(text: sendText, client: bridgeClient, controls: runtimeControls, attachments: attachments)
        guard disposition != .rejected else { return }
        let follow = ChatFollowPresentation.followLatest()
        autoFollowChat = follow.autoFollow
        showLatestButton = follow.showsLatest
        inputText = ""
        pendingPhotos = []
        selectedPhotoItems = []
    }

    private func loadPhotoAttachments(_ items: [PhotosPickerItem], previousItems: [PhotosPickerItem]) {
        photoLoadTask?.cancel()
        photoLoadGeneration += 1
        let generation = photoLoadGeneration
        pendingPhotos.removeAll { photo in
            previousItems.contains { $0 == photo.pickerItem }
                && !items.contains { $0 == photo.pickerItem }
        }
        guard !items.isEmpty else {
            isLoadingPhotos = false
            return
        }
        isLoadingPhotos = true
        let existingPhotoBytes = pendingPhotos.reduce(0) { $0 + $1.attachment.byteSize }
        let newItems = items.filter { item in !pendingPhotos.contains { $0.pickerItem == item } }
        guard !newItems.isEmpty else {
            isLoadingPhotos = false
            return
        }
        let selectedItems = Array(newItems.prefix(max(0, maxPendingPhotos - pendingPhotos.count)))
        photoLoadTask = Task {
            var loaded: [PendingPhotoAttachment] = []
            var skippedCount = newItems.count - selectedItems.count
            var remainingBudget = max(0, Self.cloudKitPhotoPayloadBudgetBytes - existingPhotoBytes)
            for (index, item) in selectedItems.enumerated() {
                if Task.isCancelled { return }
                do {
                    let remainingCount = selectedItems.count - index
                    let photoBudget = Self.perPhotoBudget(
                        remainingBytes: remainingBudget,
                        remainingCount: remainingCount
                    )
                    guard let sourceData = try await item.loadTransferable(type: Data.self),
                          let sourceImage = UIImage(data: sourceData),
                          photoBudget > 0,
                          let jpeg = Self.preparedJPEGData(
                            from: sourceImage,
                            maxBytes: photoBudget
                          ),
                          let thumbnail = UIImage(data: jpeg)
                    else {
                        skippedCount += 1
                        continue
                    }
                    remainingBudget -= jpeg.count

                    let id = UUID().uuidString
                    let attachment = MultimodalAttachment(
                        id: id,
                        type: "image",
                        base64: jpeg.base64EncodedString(),
                        mime: "image/jpeg",
                        name: "iphone-photo-\(index + 1).jpg",
                        byteSize: jpeg.count
                    )
                    loaded.append(PendingPhotoAttachment(id: id, attachment: attachment, thumbnail: thumbnail, pickerItem: item))
                } catch {
                    await MainActor.run {
                        store.errorBanner = "Photo could not be loaded: \(error.localizedDescription)"
                    }
                }
            }
            await MainActor.run {
                guard generation == photoLoadGeneration, !Task.isCancelled else { return }
                pendingPhotos.append(contentsOf: loaded)
                isLoadingPhotos = false
                if let message = PhotosPickerLoadPresentation.message(
                    loadedCount: loaded.count,
                    skippedCount: skippedCount
                ) {
                    store.errorBanner = message
                }
                if loaded.isEmpty {
                    suppressNextEmptyPhotoSelection = !selectedPhotoItems.isEmpty
                    selectedPhotoItems = []
                }
            }
        }
    }

    static func perPhotoBudget(remainingBytes: Int, remainingCount: Int) -> Int {
        guard remainingBytes > 0, remainingCount > 0 else { return 0 }
        return remainingBytes / remainingCount
    }

    static func preparedJPEGData(
        from image: UIImage,
        maxDimension: CGFloat = 1400,
        maxBytes: Int = cloudKitPhotoPayloadBudgetBytes
    ) -> Data? {
        MobileChatAttachmentPreparation.preparedJPEGData(from: image, maxDimension: maxDimension, maxBytes: maxBytes)
    }

    private func importSharedItems() {
        rememberShareAgentName()
        store.importSharedItems(controls: runtimeControls)
    }

    private func rememberShareAgentName() {
        do { try SharedChatInbox.rememberAgentName(agentDisplayName) }
        catch { store.errorBanner = "Sharing is unavailable: \(error.localizedDescription)" }
    }

    private func scheduleScrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool = false,
        delayMilliseconds: Int = 30,
        force: Bool = false
    ) {
        guard !visibleMessages.isEmpty else { return }
        guard force || autoFollowChat else { return }
        guard let targetID = visibleMessages.last?.id else { return }
        guard let serial = scrollScheduler.schedule(
            targetID: targetID.uuidString,
            animated: animated,
            force: force
        ) else { return }
        let elapsed = Date().timeIntervalSince(lastScrollAt)
        let minimumInterval = animated ? 0.12 : 0.09
        let effectiveDelayMs = max(delayMilliseconds, Int(max(0, minimumInterval - elapsed) * 1000))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(effectiveDelayMs)) {
            guard let currentTargetID = scrollScheduler.complete(
                serial: serial,
                messagesAreAvailable: !visibleMessages.isEmpty
            ) else { return }
            lastScrollAt = Date()
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(currentTargetID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(currentTargetID, anchor: .bottom)
            }
        }
    }
}

/// One readable, reachable presentation for transient chat failures. Error
/// copy can be much longer than the happy-path composer controls (especially
/// permission guidance), so actions sit on their own row instead of competing
/// with the message for horizontal space on compact iPhones or at large text
/// sizes. The close control keeps the platform's minimum touch target and an
/// outcome-specific VoiceOver label.
private struct MobileChatIssueBanner: View {
    let message: String
    let systemImage: String
    let tint: Color
    let dismissLabel: String
    var action: (title: String, handler: () -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissLabel)
            }

            if let action {
                Button(action.title, action: action.handler)
                    .font(.callout.weight(.semibold))
                    .padding(.leading, 28)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14))
        .accessibilityElement(children: .contain)
    }
}
