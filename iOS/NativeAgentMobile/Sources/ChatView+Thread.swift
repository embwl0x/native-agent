import SwiftUI
import UIKit
import NativeAgentShared
import UniformTypeIdentifiers
// Blueprint: | `ChatView+Thread.swift` | The conversation's document: its rows, cards and actions, the composer's room and Latest |

extension ChatView {
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

    #if DEBUG
    /// The sample's rows as the Mac would send them: its messages, and with extras a tool run (the agent's words, one ask) before the fourth.
    private var sampleRecords: [ChatMessageRecord] {
        let extras = ProcessInfo.processInfo.arguments.contains("-chatSampleExtras")
        var records: [ChatMessageRecord] = []
        func add(_ id: String, _ role: String, _ content: String, minute: Int, face: TranscriptRowFace? = nil, approvalId: String? = nil) {
            var metadata: ChatMessageMetadata?
            if let approvalId {
                metadata = ChatMessageMetadata()
                metadata?.approvalId = approvalId
            }
            var record = ChatMessageRecord(id: id, sessionId: nil, role: role, content: content,
                                           createdAt: String(format: "2026-11-04T09:%02d:00Z", minute), runId: nil, source: nil,
                                           metadata: metadata, isPersonVisible: true)
            record.face = face
            records.append(record)
        }
        for (index, message) in visibleMessages.prefix(5).enumerated() {
            if extras, index == 3 {
                add("sample-tool-1", "tool", "", minute: 5, face: .init(seat: .left, line: "Calendar · upcoming",
                                                                         headline: "Checked tomorrow's calendar and the weather"))
                add("sample-tool-2", "tool", "", minute: 5, face: .init(seat: .left, line: "Weather forecast", detail: "Clear after noon"))
                add("sample-approval", "tool", "", minute: 6, face: .init(seat: .left, asks: true), approvalId: "sample-approval")
            }
            add(message.id.uuidString, message.role.rawValue, message.text, minute: index * 2)
        }
        return records
    }
    #endif

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
                                    reason: """
                                        [run_memory_hygiene] Run memory hygiene to consolidate duplicates and clear test-derived noise before it settles into \
                                        long-term memory.
                                        """,
                                    status: "pending", localOnly: true, remoteResolvable: false)]
        }
        #endif
        return ConversationApprovals.pendingApprovals(
            sessionId: store.selectedSessionID,
            approvals: sync.approvals
        )
    }

    /// Mirrored cards answer their original thread through the signed inbox action.
    private var inlineChatCards: [InboxItemRecord] {
        guard let session = store.selectedSessionID, !session.isEmpty else { return [] }
        return sync.inboxItems.filter { item in
            item.source == "interaction" && item.chat_session_id == session && !["archived", "dismissed"].contains(item.status)
        }
    }

    /// The Mac's rows for the conversation on screen, in its order (tool runs and asks included).
    private var transcriptRecords: [ChatMessageRecord] {
        #if DEBUG
        if isChatSample { return sampleRecords }
        #endif
        guard let session = store.selectedSessionID ?? store.mainSessionID else { return [] }
        return sync.chatTranscripts[session]?.records ?? []
    }

    /// The conversation as the document reads it: the Mac's rows and the phone's own, the streaming reply, approvals where they were
    /// asked and the decisions still owed after everything, mirrored cards, other-room rows, and each row's buttons.
    private var transcriptInput: MobileTranscriptInput {
        let messages = visibleMessages
        let rows = MobileTranscriptRow.rows(records: transcriptRecords, messages: messages)
        let session = store.selectedSessionID ?? store.mainSessionID
        let all = inlineChatApprovals
        var byID: [String: ApprovalRequest] = [:]
        for approval in all { byID[approval.id] = approval }
        var approvals: [String: ApprovalRequest] = [:]
        var asked: Set<String> = []
        for row in rows {
            guard row.face?.asks == true, let id = row.metadata?.approvalId else { continue }
            asked.insert(id)
            if let approval = byID[id] { approvals[row.id] = approval }
        }
        // Only decisions still owed belong at the end; settled outcomes stay with the row that asked.
        let owed = all.filter { !asked.contains($0.id) && ConversationApprovals.waitsOnYou($0) }
        for approval in owed { approvals[approval.id] = approval }
        var cards: [String: InboxItemRecord] = [:]
        for item in inlineChatCards { cards[item.id] = item }
        let live = messages.last { $0.role == .assistant && ($0.isStreaming || store.liveTurnBubbles.values.contains($0.id)) }
        return MobileTranscriptInput(
            sessionKey: store.selectedSessionID ?? "",
            messages: messages,
            rows: rows,
            liveMessageID: live?.id,
            // The agent's newest movement for this reply: the running tool, or what the agent is writing into a call.
            waitingLine: live.map { store.streamingHint(for: $0) } ?? "",
            approvals: approvals,
            tailApprovals: owed,
            inboxCards: cards,
            exchanges: session.flatMap { sync.chatTranscripts[$0]?.otherRooms } ?? [],
            cardsAvailable: transcriptReadError == nil,
            canLoadOlder: store.canLoadOlderHistory,
            isLoadingHistory: store.isLoadingHistory,
            expired: Set(messages.filter { store.isExpiredRequest($0) }.map(\.id)),
            retries: Dictionary(store.queuedSendsForSelectedSession.compactMap { send in send.placeholderID.map { ($0, send.id) } },
                                uniquingKeysWith: { first, _ in first }),
            sendsEnabled: !(store.isLoading || store.isSwitchingSession)
        )
    }

    /// What the document's links, cards and menu do: the same store calls the rows' buttons made.
    private var transcriptActions: MobileTranscriptActions {
        MobileTranscriptActions(
            loadOlder: { Task { await store.loadOlderHistory() } },
            sendNow: { id in store.sendNow(messageId: id, client: bridgeClient) },
            loadWholeMessage: { id in Task { await store.loadWholeMessage(id) } },
            retrySend: { id in store.sendQueuedNow(id, client: bridgeClient) },
            openExchange: { exchange in openedAgentContactID = exchange.contactID },
            inboxAction: { itemID, actionID in
                Task {
                    do {
                        _ = try await sync.inboxAction(itemId: itemID, actionId: actionID)
                    } catch {
                        store.errorBanner = error.localizedDescription
                    }
                }
            },
            openInboxItem: { _ in showsInbox = true },
            canRegenerate: store.canRegenerateLast,
            regenerate: { store.regenerateLast(client: bridgeClient, controls: runtimeControls) },
            canReadAloud: voiceOutput.enabled,
            isReading: voiceOutput.isSpeaking,
            readAloud: { text in voiceOutput.speak(text) },
            stopReading: { voiceOutput.stop() }
        )
    }

    var chatBody: some View {
        let input = transcriptInput
        return NavigationStack {
            VStack(spacing: 0) {
                MobileChatBannerLane(banners: chatBanners)
                if let reason = transcriptReadError {
                    Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                runtimeControlsBar
                if showsChatSessionTabs {
                    chatSessionTabsBar
                }

                Group {
                    if input.isEmpty {
                        ScrollView {
                            chatEmptyState
                                .containerRelativeFrame(.vertical)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                        }
                    } else {
                        // The document runs under the composer: the composer's room (and the keyboard's) is its bottom inset.
                        GeometryReader { geometry in
                            MobileTranscriptView(input: input, width: geometry.size.width, bottomInset: geometry.safeAreaInsets.bottom,
                                                 actions: transcriptActions, handle: transcript)
                                .ignoresSafeArea(edges: .bottom)
                        }
                    }
                }
                .aliveBottomFade(room: AliveChatRoom(store: store))
                .safeAreaInset(edge: .bottom, spacing: NativeAgentMobileTheme.Spacing.md) {
                    VStack(alignment: .trailing, spacing: 8) {
                        // Keep Latest above the composer and visible only while the reader is away from the end.
                        if showLatestButton {
                            Button {
                                followEnd()
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
                // Only the reader's own acts move the chat: Latest, sending, the keyboard rising, opening a conversation.
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in followEnd() }
            }
            .background { AliveChatRoom(store: store) }
            // Hide the visual navigation title but retain it for VoiceOver and the app switcher.
            .navigationTitle(agentDisplayName)
            .toolbar(.hidden, for: .navigationBar)
            .tint(AlivePalette.text)
            .animation(AppMotion.snappy, value: voiceInput.isListening)
            // Sync-error dismissal must end when its condition changes.
            .onChange(of: sync.syncError) { _, newValue in
                if MacSyncErrorBannerPresentation.normalizedMessage(newValue) == nil {
                    dismissedSyncError = nil
                }
            }
            // A note's card opens the Inbox, where the note is read and answered in place.
            .sheet(isPresented: $showsInbox) {
                NavigationStack { MobileFacePage(page: "inbox") }
            }
            .sheet(isPresented: $showsChatSetup) {
                PairingView(onSkip: { showsChatSetup = false }, onPaired: { showsChatSetup = false })
            }
            .sheet(isPresented: Binding(get: { openedAgentContactID != nil }, set: { if !$0 { openedAgentContactID = nil } })) {
                if let id = openedAgentContactID {
                    NavigationStack {
                        MobileAgentThreadView(id: id)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { openedAgentContactID = nil }
                                }
                            }
                    }
                }
            }
            .sheet(isPresented: $showsSyncConnection) {
                NavigationStack { SettingsViewFull(opensConnection: true) }
            }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.pdf, .plainText, .init(filenameExtension: "md") ?? .plainText],
                allowsMultipleSelection: true) { result in
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
            .onChange(of: store.isSwitchingSession) { _, switching in
                guard !switching else { return }
                consumeNotifiedChatSessionIfNeeded()
                adoptMainSessionFromSnapshots()
            }
            // Only process arguments may inject turns; Release exposes no URL route.
            .onReceive(NotificationCenter.default.publisher(for: .nativeagentDeepLinkSend)) { _ in
                NativeAgentDeepLinkSendHook.deliverPending(
                    to: store,
                    client: bridgeClient,
                    controls: runtimeControls
                )
            }
            .onChange(of: voiceInput.lastFinalTranscript, dictationFinished)
            // Without recognized words there is nothing to send; the error already explains the cause.
            .onChange(of: voiceInput.error) { _, error in
                if error != nil { sendWhenDictationLands = false }
            }
            .onChange(of: selectedPhotoItems, photoSelectionChanged)
        }
    }

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

    private var agentDoing: (text: String, dot: AliveStatusDot.State) {
        if store.pendingExchanges.values.contains(where: {
            $0.sessionID == ChatStore.cleanSessionID(store.selectedSessionID) && $0.deliveryUnconfirmed
        }) {
            return ("Couldn't confirm it arrived", .waiting)
        }
        if let heard = store.activeTurnHeardByMac ?? (isChatSample && visibleMessages.last?.isStreaming == true ? true : nil) {
            guard heard else {
                let accepted = store.pendingExchanges.values.contains {
                    $0.sessionID == ChatStore.cleanSessionID(store.selectedSessionID) && $0.deliveryAccepted
                }
                return accepted ? ("Sent · waiting for Mac", .waiting) : ("Sending…", .working)
            }
            let replying = visibleMessages.last.map { $0.role == .assistant && $0.isStreaming && !$0.text.isEmpty } ?? false
            return (replying ? "Replying…" : "Received by Mac", replying ? .working : .waiting)
        }
        if inlineChatApprovals.contains(where: ConversationApprovals.waitsOnYou) { return ("Waiting on you", .waiting) }
        return ("Here", .here)
    }

    /// Back to the end, and following from there.
    func followEnd() {
        transcript.goToLatest()
    }
}
