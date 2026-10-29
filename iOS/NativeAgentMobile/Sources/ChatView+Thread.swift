import SwiftUI
import UIKit
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView+Thread.swift` | Transcript rendering, scrolling and SwiftUI hooks on ChatView |

extension ChatView {
    private var otherRoomRows: [String: [OtherRoomExchange]] {
        guard let session = store.selectedSessionID ?? store.mainSessionID,
              let transcript = sync.chatTranscripts[session] else { return [:] }
        let shown = Set(visibleMessages.map { $0.id.uuidString.lowercased() })
        return OtherRoomExchange.anchored(transcript.otherRooms, to: transcript.records.compactMap { row in
            guard shown.contains(row.id.lowercased()), let at = UserDisplayFormatters.parseISOTimestamp(row.createdAt) else { return nil }
            return (id: row.id.lowercased(), at: at)
        })
    }

    private func exchangeRows(_ events: [OtherRoomExchange]) -> some View {
        ForEach(events) { event in
            NavigationLink { MobileAgentThreadView(id: event.contactID) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                    Text(event.subtitle).foregroundStyle(.secondary)
                }.font(.callout).lineLimit(1)
            }.buttonStyle(.plain).id("other-room:" + event.id)
        }
    }

    // Process-local visual fixture: no transcript/cache writes and no transport sends.
    var isChatSample: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-chatSample")
        #else
        false
        #endif
    }

    var visibleMessages: [ChatMessage] {
        #if DEBUG
        if isChatSample {
            var messages = [
                ChatMessage(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)), role: .user,
                            text: "Can we keep tomorrow's plan simple?"),
                ChatMessage(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)), role: .assistant,
                            text: "Start with a quiet morning and one focused task. Leave the afternoon open for a walk."),
                ChatMessage(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3)), role: .user,
                            text: "A walk after lunch sounds good."),
                ChatMessage(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4)), role: .assistant,
                            text: "That leaves room to breathe. What would you like to focus on first?"),
                ChatMessage(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5)), role: .user,
                            text: "I'll finish the outline in the morning, then take the afternoon outside.")
            ]
            let extras = ProcessInfo.processInfo.arguments.contains("-chatSampleExtras")
            if extras, let index = messages.firstIndex(where: { $0.id == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4)) }) {
                messages[index] = ChatMessage(id: messages[index].id, role: .assistant, text: messages[index].text,
                                          toolEvents: [ToolEvent(name: "mac_calendar_list_upcoming", seq: 1),
                                                       ToolEvent(name: "weather_forecast", seq: 2),
                                                       ToolEvent(name: "read_skill", seq: 3)])
            }
            if ProcessInfo.processInfo.arguments.contains("-chatSampleStreaming") {
                messages.append(ChatMessage(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6)),
                                            role: .assistant, text: extras ? "" : "Writing the next step…", isStreaming: true,
                                            toolEvents: extras ? [ToolEvent(name: "mac_calendar_list_upcoming", seq: 1)] : []))
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
            : bridgeClient.connection.transport.state == .broken ? ("Out of reach for now", AliveConnection.line(bridgeClient.connection))
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

    /// A missing bounded transcript is unavailable, not an empty conversation.
    private var transcriptNotSynced: Bool {
        guard let sessionID = store.selectedSessionID ?? effectiveMainSessionID,
              sync.transcriptRead(for: sessionID) == .unavailable else { return false }
        return (sync.sessions.first { $0.id == sessionID }?.messageCount ?? 0) > 0
    }

    private var transcriptReadError: String? {
        let sessionID = store.selectedSessionID ?? effectiveMainSessionID
        return sessionID.flatMap { sync.chatTranscripts[$0]?.readError }
    }

    /// Pending approvals read the shared sync projection and appear on their turn.
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
        return ConversationApprovals.pendingApprovals(
            sessionId: store.selectedSessionID,
            approvals: sync.approvals
        )
    }

    /// Cards raised in another thread and mirrored into this conversation for
    /// User; their buttons answer the original through the signed inbox action.
    private var inlineChatCards: [InboxItemRecord] {
        guard let session = store.selectedSessionID, !session.isEmpty else { return [] }
        let interactions = Set(visibleMessages.compactMap { $0.interaction.map { "interaction:\($0.id)" } })
        return sync.inboxItems.filter { item in
            item.source == "interaction" && item.chat_session_id == session
                && !["archived", "dismissed"].contains(item.status)
                && !interactions.contains(item.id)
        }
    }

    @ViewBuilder
    private func inlinePendingCards(approvals: [ApprovalRequest], cards: [InboxItemRecord]) -> some View {
        ForEach(approvals) { approval in
            InlineChatApprovalCard(approval: approval)
        }
        ForEach(cards) { item in
            InboxCardRow(item: item, onAction: { action in
                Task {
                    do {
                        _ = try await sync.inboxAction(itemId: item.id, actionId: action)
                    } catch {
                        store.errorBanner = error.localizedDescription
                    }
                }
            }, onView: { inboxDetailID = item.id })
        }
    }

    var chatBody: some View {
        let approvals = inlineChatApprovals
        let retriesByPlaceholder = Dictionary(store.queuedSendsForSelectedSession.compactMap { send in
            send.placeholderID.map { ($0, send) }
        }, uniquingKeysWith: { first, _ in first })
        var lastAssistantByTurnID: [String: UUID] = [:]
        for message in visibleMessages where message.role == .assistant {
            if let turnID = message.turnID { lastAssistantByTurnID[turnID] = message.id }
        }
        let approvalsByAnchor = Dictionary(grouping: approvals) {
            $0.chatOriginTurnId.flatMap { lastAssistantByTurnID[$0] }
        }
        let cards = inlineChatCards
        let cardAnchor = cards.isEmpty ? nil : visibleMessages.last(where: { $0.role == .assistant })?.id ?? visibleMessages.last?.id
        let exchanges = otherRoomRows
        return NavigationStack {
            VStack(spacing: 0) {
                // One banner lane: the newest notice shows, the rest wait
                // behind a count instead of stacking down the screen.
                MobileChatBannerLane(banners: chatBanners)
                if let reason = transcriptReadError {
                    Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                runtimeControlsBar
                if showsChatSessionTabs {
                    chatSessionTabsBar
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        if visibleMessages.isEmpty && approvals.isEmpty && cards.isEmpty {
                            chatEmptyState
                                .containerRelativeFrame(.vertical)
                        } else {
                            // The paged transcript uses eager row heights to hold its bottom anchor through settlement.
                            VStack(alignment: .leading, spacing: 26) {
                                if store.canLoadOlderHistory {
                                    Button(store.isLoadingHistory ? "Loading earlier messages…" : "Load earlier messages") {
                                        Task { await store.loadOlderHistory() }
                                    }
                                    .disabled(store.isLoadingHistory)
                                    .frame(maxWidth: .infinity)
                                }
	                                ForEach(visibleMessages) { msg in
                                        exchangeRows(exchanges[msg.id.uuidString.lowercased()] ?? [])
	                                    BubbleView(
	                                        message: msg,
	                                        streamingHint: store.streamingHint(for: msg),
	                                        isLiveTurn: store.liveTurnBubbles.values.contains(msg.id),
                                            cardsAvailable: transcriptReadError == nil
	                                    )
                                        .equatable()
	                                    .id(msg.id.uuidString)
                                        // Only appends animate; removals and replacements are instant.
	                                    .transition(.asymmetric(
	                                        insertion: .opacity.combined(with: .offset(y: 8)),
	                                        removal: .identity))
                                        // An expired request starts only on this explicit send.
                                        if store.isExpiredRequest(msg) {
                                            Button("Send now") {
                                                store.sendNow(messageId: msg.id, client: bridgeClient)
                                            }
                                            .disabled(store.isLoading || store.isSwitchingSession)
                                        }
                                        if msg.text.hasSuffix(ChatStore.snapshotTruncationMarker) {
                                            Button("Show the whole message") {
                                                Task { await store.loadWholeMessage(msg.id) }
                                            }
                                            .disabled(store.isLoadingHistory)
                                        }
                                        if !msg.isStreaming,
                                           let failed = retriesByPlaceholder[msg.id] {
                                            Button("Retry send") {
                                                store.sendQueuedNow(failed.id, client: bridgeClient)
                                            }
                                            .disabled(store.isLoading || store.isSwitchingSession)
                                        }
                                        // Place approvals at the last assistant carrying their Mac turn identity.
                                        inlinePendingCards(
                                            approvals: approvalsByAnchor[msg.id] ?? [],
                                            cards: msg.id == cardAnchor ? cards : [])
	                                }
                                exchangeRows(exchanges[""] ?? [])
                                // The bottom holds only what waits on you; a settled
                                // outcome is history and shows with its own turn.
                                inlinePendingCards(
                                    approvals: (approvalsByAnchor[nil] ?? []).filter(ConversationApprovals.waitsOnYou),
                                    cards: cardAnchor == nil ? cards : [])
                                // Reaching the bottom by hand is following again:
                                // the Latest button goes away on its own.
                                Color.clear.frame(height: 1)
                                    .id(Self.chatBottomID)
                                    .onAppear {
                                        autoFollowChat = true
                                    }
                            }
                            .frame(maxWidth: NativeAgentMobileTheme.Layout.roomColumn)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                        }
                    }
                    // Follow the bottom through streaming and layout; preserve position while reading above.
                    // Explicit scrolls serve sends, session changes, Latest and the keyboard.
                    .defaultScrollAnchor(autoFollowChat ? .bottom : .top)
                    // The transcript softens out under the composer and the tab bar.
                    .aliveBottomFade(room: AliveChatRoom(store: store))
                    // SwiftUI subtracts the measured composer inset from the keyboard-adjusted viewport.
                    .safeAreaInset(edge: .bottom, spacing: NativeAgentMobileTheme.Spacing.md) {
                        VStack(alignment: .trailing, spacing: 8) {
                            // Only while scrolled up, and above the composer, never on it.
                            if showLatestButton {
                                Button {
                                    autoFollowChat = true
                                    scheduleScrollToBottom(proxy, animated: true, delayMilliseconds: 0, force: true)
                                } label: {
                                    Label("Latest", systemImage: "arrow.down")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(AlivePalette.text)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 44)
                                        .aliveGlass(in: Capsule(), interactive: true)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, NativeAgentMobileTheme.Spacing.lg)
                                .transition(.opacity)
                            }
                            GlassEffectContainer(spacing: NativeAgentMobileTheme.Spacing.md) { composerBar }
                                .padding(.horizontal, NativeAgentMobileTheme.Spacing.lg)
                                .padding(.bottom, NativeAgentMobileTheme.Spacing.sm)
                        }
                        .animation(.easeOut(duration: 0.18), value: showLatestButton)
                    }
                    // Dragging or tapping the thread dismisses the keyboard.
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
                                autoFollowChat = false
                            }
                        }
                    )
                    .onAppear {
                        autoFollowChat = true
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 120, force: true)
                    }
                    .onChange(of: store.messages.count) {
                        scheduleScrollToBottom(proxy, animated: false)
                    }
                    // A late reply requests an explicit scroll even while reading above.
                    .onChange(of: store.scrollToBottomTick) {
                        scheduleScrollToBottom(proxy, animated: true, delayMilliseconds: 0, force: true)
                    }
                    // A selected session opens at the bottom of its transcript.
                    .onChange(of: store.selectedSessionID) {
                        autoFollowChat = true
                        scheduleScrollToBottom(proxy, animated: false, delayMilliseconds: 80, force: true)
                    }
                    // Scroll again after the new transcript arrives and lays out.
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
            // The header carries chat actions; the hidden title serves VoiceOver and the app switcher.
            .navigationTitle(agentDisplayName)
            .toolbar(.hidden, for: .navigationBar)
            .tint(AlivePalette.text)
            .animation(AppMotion.snappy, value: voiceInput.isListening)
            // Sync-error dismissal lasts only as long as its condition.
            .onChange(of: sync.syncError) { _, newValue in
                if MacSyncErrorBannerPresentation.normalizedMessage(newValue) == nil {
                    dismissedSyncError = nil
                }
            }
            .sheet(isPresented: Binding(get: { inboxDetailID != nil }, set: { if !$0 { inboxDetailID = nil } }), onDismiss: { inboxGroup = nil }) {
                if let inboxGroup {
                    InboxView(initialGroup: inboxGroup)
                } else {
                    InboxDetailSheet(itemID: inboxDetailID ?? "", onOpenGroup: { group in
                        inboxGroup = group
                    }) {
                        inboxDetailID = nil
                    }
                }
            }
            .sheet(isPresented: $showsChatSetup) {
                PairingView(onSkip: { showsChatSetup = false }, onPaired: { showsChatSetup = false })
            }
            .sheet(isPresented: $showsSyncConnection) {
                NavigationStack { SettingsViewFull(opensConnection: true) }
            }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.pdf, .plainText, .init(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) { result in
                loadFileAttachments(result)
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
            .task { await restoreConversation() }
            .onAppear(perform: conversationAppeared)
            .onChange(of: scenePhase, conversationSceneChanged)
            .onDisappear(perform: conversationDisappeared)
            .onChange(of: store.isSwitchingSession) { _, switching in
                if !switching { importSharedItems() }
            }
            .onChange(of: notifiedSessionID) { _, _ in consumeNotifiedChatSessionIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: MobileQuickAskRoute.notification)) { _ in
                if MobileQuickAskRoute.consume() { composerIsFocused = true }
            }
            // Consume retained notification intent when session loading finishes.
            .onChange(of: store.isSwitchingSession) { _, switching in
                guard !switching else { return }
                consumeNotifiedChatSessionIfNeeded()
                adoptMainSessionFromSnapshots()
            }
            // Only process arguments can inject a turn; the release target has no URL route.
            .onReceive(NotificationCenter.default.publisher(for: .nativeagentDeepLinkSend)) { _ in
                NativeAgentDeepLinkSendHook.deliverPending(
                    to: store,
                    client: bridgeClient,
                    controls: runtimeControls
                )
            }
            .onChange(of: voiceInput.lastFinalTranscript, dictationFinished)
            // No words came back (the error says why): nothing to send.
            .onChange(of: voiceInput.error) { _, error in
                if error != nil { sendWhenDictationLands = false }
            }
            .onChange(of: selectedPhotoItems, photoSelectionChanged)
        }
    }

    /// The agent's name, light and current activity or connection status.
    private var runtimeControlsBar: some View {
        let online = isChatSample || bridgeClient.connection.holds
        // Keep the shared tab-header height and the status chip's full 44pt target.
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
        if let heard = store.activeTurnHeardByMac ?? (isChatSample && visibleMessages.last?.isStreaming == true ? true : nil) {
            guard heard else { return ("Sending…", .working) }
            let replying = visibleMessages.last.map { $0.role == .assistant && $0.isStreaming && !$0.text.isEmpty } ?? false
            return (replying ? "Replying…" : "Received by Mac", replying ? .working : .waiting)
        }
        if inlineChatApprovals.contains(where: ConversationApprovals.waitsOnYou) { return ("Waiting on you", .waiting) }
        return ("Here", .here)
    }

    static let chatBottomID = "chat-bottom"

    private func scheduleScrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool = false,
        delayMilliseconds: Int = 30,
        force: Bool = false
    ) {
        guard !visibleMessages.isEmpty else { return }
        guard force || autoFollowChat else { return }
        // The bottom follows every reply, other-room row, card and approval.
        guard let serial = scrollScheduler.schedule(
            animated: animated,
            force: force
        ) else { return }
        let elapsed = Date().timeIntervalSince(lastScrollAt)
        let minimumInterval = animated ? 0.12 : 0.09
        let effectiveDelayMs = max(delayMilliseconds, Int(max(0, minimumInterval - elapsed) * 1000))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(effectiveDelayMs)) {
            guard scrollScheduler.complete(
                serial: serial,
                messagesAreAvailable: !visibleMessages.isEmpty
            ) else { return }
            lastScrollAt = Date()
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.chatBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.chatBottomID, anchor: .bottom)
            }
        }
    }
}
