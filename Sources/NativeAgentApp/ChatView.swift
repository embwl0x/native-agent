import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// PATCH-Phase1a-dispatcher: "note" added — routes to POST /v1/notes via Dispatcher.run(commit_memory)
// PATCH-phase-3c: "scratch" added — routes to POST /v1/scratch via Dispatcher.run(scratchpad_write)
// PATCH-Phase6b: added "tools" — opens the canonical Tools destination
// PATCH-2026-05-09: nextgen-surface — added "nextgen" command to navigate to NextGen panel
// PATCH-2026-06-06: chat-upgrades — added "export" (dumps current session as Markdown to ~/Downloads)
let knownSlashCommands: Set<String> = ["clear", "compact", "model", "think", "fast", "persona", "remember", "note", "scratch", "help", "tools", "nextgen", "export"]
let chatSessionDragType = UTType(exportedAs: "com.nativeagent.chat-session")
let chatSessionDragPlainTextPrefix = "nativeagent-chat-session:"
let chatSessionDropTypes: [UTType] = [chatSessionDragType, .plainText]

struct ChatView: View {
    @Environment(AppModel.self) var appModel
    // chat-smoothness phase 6: respect the system Reduce Motion setting on the
    // motion this phase adds (bubble entrance) and the phase-4 thinking-row fade.
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    // Fix 2: draft text and pending attachments live in AppModel keyed by sessionId so they
    // survive tab changes.
    //
    // H5 (2026-07-09): the draft used to be read AND WRITTEN through
    // `appModel.chatDrafts` on every keystroke. `chatDrafts` is @Observable
    // state, so each character invalidated the whole of ChatView.body — which
    // re-ran the session-id fingerprint (map + join over every session), the
    // search filter, and the pinned-session dictionary rebuild, and every other
    // view observing `chatDrafts` (the detached chat panels) with it.
    //
    // The in-progress text now lives here, in view-local @State. It is
    // COMMITTED back to `appModel.chatDrafts` only at the four points where it
    // has to survive this view: send, session switch, view disappear, and the
    // outbound half of an external prefill. `draftSessionId` records which
    // session `draftText` belongs to so a commit can never file it under the
    // wrong key after the active session moves.
    @State var draftText = ""
    @State var draftSessionId = ""

    var text: String {
        get { draftText }
        nonmutating set { draftText = newValue }
    }
    var textBinding: Binding<String> {
        Binding(get: { draftText }, set: { draftText = $0 })
    }
    var pendingAttachments: [MultimodalAttachment] {
        get { appModel.chatPendingAttachments[appModel.activeChatSessionId] ?? [] }
        nonmutating set { appModel.chatPendingAttachments[appModel.activeChatSessionId] = newValue }
    }

    /// Persist the composer's text under the session it was typed into.
    func commitDraft() {
        guard !draftSessionId.isEmpty else { return }
        appModel.commitChatDraft(draftText, sessionId: draftSessionId)
    }

    /// Point the composer at `sessionId`, loading whatever draft it holds.
    func adoptDraft(for sessionId: String) {
        draftSessionId = sessionId
        draftText = appModel.chatDraft(for: sessionId)
    }
    @State var renameTitle = ""
    @State var sessionSearch = ""
    @State var showContext = false
    @State var showConversationControls = false
    let bottomAnchor = "chat-bottom-anchor"

    // Sprint 3.1 — voice input
    @State var voiceInput = VoiceInputController()
    @State var voiceDraftBeforeListening = ""
    // Sprint 3.2 — voice output
    @State var voiceOutput = VoiceOutputController()
    @AppStorage("voiceAutoRead") var voiceAutoRead = false
    @AppStorage("voiceUseOpenAI") var voiceUseOpenAI = false
    // Sprint 3.3 — screen capture
    @State var isCapturing = false
    @State var toasts = ChatToastQueue()
    // Slow-turn advisories belong to the conversation viewport, not the
    // app-wide bottom toast lane. A dedicated center preserves the shared
    // visual/dismiss behavior while letting the message area own placement.
    @StateObject var turnNoticeToasts = SystemToastCenter()
    // PATCH-2026-05-08: wave2-chat-ux — slash command popover
    @State var showSlashMenu = false
    @State var slashFilter = ""
    // N34: FocusState so we can refocus the text field after slash-command insertion.
    @FocusState var inputFocused: Bool
    // PATCH-2026-05-08: wave2-chat-ux — clear confirmation
    @State var showClearConfirm = false
    // Capability store supplies dynamic slash-command suggestions and dispatch metadata.
    @State var capabilitiesStore = CapabilitiesStore()
    // PATCH-Phase7b: tool dispatch sheet + in-flight plan
    @State var showToolInputForm = false
    @State var currentDispatchPlan: DispatchArgPlan? = nil
    @State var scrollCoordinator = ChatScrollCoordinator()
    @State var lastAutoReadMessageId: String?
    @State var pinnedSessionDropTargeted = false
    @AppStorage("NativeAgent.pinnedChatSessionIds") var pinnedChatSessionIdsRaw = ""

    var activeSession: ChatSession? {
        appModel.chatSessions.first { $0.id == appModel.activeChatSessionId }
    }

    // H5: was `chatSessions.map(\.id).joined(separator: "|")` — an array
    // allocation plus a string build, forced on every body pass by the
    // `.onChange(of:)` below. Hashing in place is allocation-free and still
    // detects any insert/remove/reorder of the session list.
    var chatSessionIdsFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(appModel.chatSessions.count)
        for session in appModel.chatSessions {
            hasher.combine(session.id)
        }
        return hasher.finalize()
    }

    var filteredSessions: [ChatSession] {
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return appModel.chatSessions }
        return appModel.chatSessions.filter {
            $0.title.lowercased().contains(query) ||
                ($0.lastMessagePreview ?? "").lowercased().contains(query)
        }
    }

    var pinnedSessionIds: [String] {
        decodedPinnedSessionIds()
    }

    var pinnedSessions: [ChatSession] {
        let ids = pinnedSessionIds
        // H5: skip the dictionary build entirely in the (common) no-pins case.
        // `uniquingKeysWith` because `Dictionary(uniqueKeysWithValues:)` traps
        // on a duplicate id, and nothing upstream guarantees the session list
        // is id-unique.
        guard !ids.isEmpty else { return [] }
        let byId = Dictionary(
            appModel.chatSessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byId[$0] }
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionSidebar
            Divider()
            chatColumn
        }
        .navigationTitle("Chat")
        .onAppear {
            voiceOutput.nativeBaseURL = appModel.nativeBaseURL
            prunePinnedSessions()
            // H5: pick up whatever draft this session already holds (a prefill
            // that landed while Chat was off-screen, or our own last commit).
            adoptDraft(for: appModel.activeChatSessionId)
        }
        .onDisappear {
            // H5: the draft only lives in @State now — persist it before the
            // view (and its @State) goes away on a tab change.
            commitDraft()
            if voiceInput.isListening {
                Task { @MainActor in _ = await voiceInput.stopListening() }
            }
            voiceDraftBeforeListening = ""
            // Re-arm sentinel cleanup — lazy children may skip their own
            // onDisappear during window/tab teardown.
            scrollCoordinator.setBottomSpacerVisible(false)
        }
        // Seed CapabilitiesStore when chat view appears (TTL-gated, no-op if fresh).
        .task {
            capabilitiesStore = CapabilitiesStore()
            await capabilitiesStore.refresh()
            // First-run: agent greets the user once a provider is connected.
            // Idempotent + self-gating; safe to call from multiple triggers.
            await appModel.maybeSendFirstRunGreeting()
        }
        .onChange(of: appModel.activeChatSessionId) { _, newSessionId in
            // H5: hand the old session its draft back before adopting the new
            // one. `commitDraft` keys off `draftSessionId`, not the (already
            // updated) active id, so the text lands where it was typed.
            commitDraft()
            adoptDraft(for: newSessionId)
            Task { await appModel.maybeSendFirstRunGreeting() }
        }
        // H5: the only channel by which text written OUTSIDE the composer
        // (skill-build starter, suggestion chip) reaches it. Bumped rarely and
        // never on the keystroke path, so observing it costs nothing.
        .onChange(of: appModel.chatDraftInjectionGeneration) {
            let active = appModel.activeChatSessionId
            // Prefill-if-empty is enforced HERE, not at the caller: the live
            // draft is this view's @State, so a `chatDrafts`-based emptiness
            // check upstream can't see uncommitted keystrokes and would let an
            // injection overwrite text the user is looking at (gpt-5.5 review,
            // 2026-07-09).
            if draftSessionId == active, !draftText.isEmpty { return }
            draftText = appModel.chatDraft(for: active)
            draftSessionId = active
        }
        .onChange(of: appModel.chatProvider) {
            // Catches the case where the user skipped the provider step at
            // onboarding and connected an LLM later in Settings.
            Task { await appModel.maybeSendFirstRunGreeting() }
        }
        .onChange(of: appModel.chatMessages.count) {
            speakLatestAssistantIfReady()
        }
        .onChange(of: appModel.chatMessages.last?.content) {
            if !appModel.isBusy {
                speakLatestAssistantIfReady()
            }
        }
        .onChange(of: appModel.isBusy) {
            if !appModel.isBusy {
                speakLatestAssistantIfReady()
            }
        }
        .onChange(of: chatSessionIdsFingerprint) {
            prunePinnedSessions()
        }
        // Read-aloud failures (trust denied / not configured / auth rejected)
        // land in voiceOutput.errorMessage, which nothing else reads — surface
        // them as a toast. Cleared after showing so a repeat failure re-fires.
        .onChange(of: voiceOutput.errorMessage) {
            if let msg = voiceOutput.errorMessage {
                showToast(msg)
                voiceOutput.errorMessage = nil
            }
        }
    }

    @ViewBuilder
    var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await appModel.archiveActiveChat() }
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.borderless)
                .disabled(appModel.activeChatSessionId.isEmpty)
                .help("Archive active chat")
                .accessibilityLabel("Archive active chat")

                Button {
                    Task {
                        await appModel.newChatSession()
                        await MainActor.run {
                            renameTitle = activeSession?.title ?? ""
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New chat")
                .accessibilityLabel("New chat")
            }

            // PATCH-2026-05-08: wave3-health-card Feature A — always-visible health pill
            HealthCardPill()
                .task {
                    await appModel.loadHealthCard()
                }

            // PATCH-2026-05-08: wave3-whats-running Feature B — what's running panel
            WhatsRunningPanel()

            LivingStatusPanel()

            // M12 (2026-07-09): refreshForSidebarItem falls back to the previous
            // value whenever an endpoint fails, so a dead backend used to render
            // a panel of stale data with no tell at all. Say so.
            if let notice = appModel.panelStaleNotice(for: .chat) {
                StalePanelNotice(text: notice)
            }

            TextField("Search sessions", text: $sessionSearch)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if filteredSessions.isEmpty {
                        Text("No matching sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach(filteredSessions) { session in
                        let isPinned = pinnedSessionIds.contains(session.id)
                        SessionRow(
                            session: session,
                            selected: session.id == appModel.activeChatSessionId,
                            pinned: isPinned
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                renameTitle = session.title
                                Task { await appModel.selectChatSession(session) }
                            }
                            // detached-chat-windows Phase 1 W1.3: AppKit drag
                            // source replaces SwiftUI .onDrag so we can detect
                            // "dropped on desktop" via NSDraggingSource and
                            // open a detached panel at the drop point. The
                            // payload is the custom chat-session UTI only —
                            // no plain-text, so Finder can't mint a desktop
                            // .textClipping (2026-07-24 fix).
                            .overlay(SessionDragSource(sessionId: session.id, sessionTitle: session.title))
                            .contextMenu {
                                if isPinned {
                                    Button("Unpin Tab", systemImage: "pin.slash") {
                                        unpinSession(session.id)
                                    }
                                } else {
                                    Button("Pin as Tab", systemImage: "pin") {
                                        pinSession(session.id, selectAfterPin: false)
                                    }
                                }
                                Divider()
                                // detached-chat-windows Phase 1 W1.8: context-menu
                                // trigger for detaching a session into its own
                                // floating window. One panel per session — when
                                // already detached, the entry focuses it / offers
                                // close instead.
                                if DetachedChatWindowController.shared.isDetached(session.id) {
                                    Button("Bring Detached Window to Front", systemImage: "macwindow.on.rectangle") {
                                        DetachedChatWindowController.shared.focus(sessionId: session.id)
                                    }
                                    Button("Close Detached Window", systemImage: "xmark.rectangle") {
                                        DetachedChatWindowController.shared.close(sessionId: session.id)
                                    }
                                } else {
                                    Button("Open in Detached Window", systemImage: "rectangle.badge.plus") {
                                        DetachedChatWindowController.shared.open(sessionId: session.id, origin: nil)
                                    }
                                }
                            }
                            .help("Drag into chat to pin · right-click to open in a detached window")
                    }
                }
            }
            // M12: dim the list when the session/message fetch itself failed —
            // the rows on screen are a snapshot from an earlier refresh.
            .opacity(appModel.chatStateLoadFailed ? 0.55 : 1)
        }
        .frame(width: 240)
        .padding()
        .background(.thinMaterial)
    }

    @ViewBuilder
    var chatColumn: some View {
        VStack(spacing: 0) {
            // PATCH-2026-05-08: wave2-chat-ux — hidden clear confirmation trigger
            Color.clear
                .frame(width: 0, height: 0)
                .confirmationDialog("Clear all messages in this session?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("Clear Messages", role: .destructive) {
                        Task { await appModel.clearActiveChatMessages() }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                // PATCH-Phase7b: ToolInputForm sheet — opened when dispatch needs multiple/complex fields
                // Phase 13 (item 8): serialize [String: Any] values to Data BEFORE crossing
                // the Task actor boundary so Swift 6 strict concurrency does not flag
                // the capture of a non-Sendable [String: Any] in a Task closure.
                .sheet(isPresented: $showToolInputForm) {
                    if let plan = currentDispatchPlan {
                        ToolInputForm(
                            plan: plan,
                            onSubmit: { values in
                                showToolInputForm = false
                                // Serialize to Data on the current actor (MainActor) before Task.
                                let inputData = try? JSONSerialization.data(withJSONObject: values)
                                let toolName = plan.tool.name
                                Task {
                                    if let data = inputData {
                                        // Use the Data overload to avoid capturing [String: Any].
                                        await runDispatchAndRenderReceiptData(
                                            tool: toolName, inputData: data
                                        )
                                    } else {
                                        await runDispatchAndRenderReceipt(
                                            tool: toolName, input: [:]
                                        )
                                    }
                                }
                            },
                            onCancel: { showToolInputForm = false }
                        )
                    }
                }
            ChatHeaderView(
                    session: activeSession,
                    compiled: appModel.compiledPersonality,
                    context: appModel.latestContextReceipt,
                    nextGenSummary: appModel.nextGenSummary,
                    showContext: $showContext,
                    showConversationControls: $showConversationControls,
                    onRename: { title in
                        renameActiveChatTitle(title)
                    }
                )
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)

                if showConversationControls {
                    ChatBrainControlBar()
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // PATCH-2026-05-07: chat-context-fill Small bar showing how
                // full the active session's context window is. Updates after
                // each chat send. Auto-compaction kicks in server-side at
                // 75%; this bar lets the user see it coming + manually
                // compact early.
                ContextFillBar(sessionId: appModel.activeChatSessionId)
                    .padding(.horizontal)
                    .padding(.bottom, 6)

                if !pinnedSessions.isEmpty || pinnedSessionDropTargeted {
                    PinnedSessionTabStrip(
                        sessions: pinnedSessions,
                        activeSessionId: appModel.activeChatSessionId,
                        runningSessionIds: appModel.streamingSessions,
                        dropTargeted: pinnedSessionDropTargeted,
                        onSelect: { session in
                            renameTitle = session.title
                            Task { await appModel.selectChatSession(session) }
                        },
                        onClose: { session in
                            unpinSession(session.id)
                        },
                        onRename: { session, title in
                            renameSession(session.id, title)
                        }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showContext {
                    ContextReceiptView(context: appModel.latestContextReceipt)
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }

                Divider()

                // PATCH-2026-05-07: proactive-inbox-1 Inbox strip above messages
                InboxStripContainer()
                    .environment(appModel)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if appModel.chatMessages.isEmpty {
                                // PATCH-2026-05-09: chat-ux-polish — persona-aware empty state + suggestion chips
                                ChatEmptyState(
                                    personaName: appModel.agentDisplayName,
                                    onSuggestion: { suggestion in
                                        text = suggestion
                                    }
                                )
                                .frame(minHeight: 360)
                            } else {
                                // B.6: ForEach lives directly in LazyVStack so lazy rendering applies.
                                // Groups are pre-computed from the message list once.
                                // PATCH-2026-05-09: chat-ux-polish — compute last assistant message id for hover Regenerate
                                let lastAssistantId = appModel.chatMessages.last(where: { $0.role == "assistant" })?.id
                                let chatGroups = MessageGrouper.groups(for: appModel.chatMessages, sessionId: appModel.activeChatSessionId)
                                let sessionBusy = appModel.isBusy && appModel.currentChatTaskSessionId == appModel.activeChatSessionId
                                // The live flip-box is the LAST tool group while she's
                                // still working and her reply text hasn't started yet.
                                let liveAssistantStarted = appModel.chatMessages.last?.role == "assistant"
                                    && appModel.chatMessages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                let liveToolGroupId = (sessionBusy && !liveAssistantStarted)
                                    ? chatGroups.last(where: { $0.isToolGroup })?.id : nil
                                ForEach(chatGroups) { group in
                                    if group.isToolGroup {
                                        if group.messages.count == 1 {
                                            let msg = group.messages[0]
                                            let kind = msg.metadata?.kind ?? ""
                                            if kind == "approval_pending" {
                                                InlineApprovalCard(message: msg)
                                            } else {
                                                ToolPillView(message: msg)
                                            }
                                        } else {
                                            // isLive: this session is streaming AND this is the last
                                            // group -> show the live flip-through box; else collapse.
                                            ToolCallGroup(
                                                messages: group.messages,
                                                isLive: liveToolGroupId != nil && group.id == liveToolGroupId
                                            )
                                        }
                                    } else {
                                        let msg = group.messages[0]
                                        MessageBubble(
                                            message: msg,
                                            isLastAssistant: msg.role == "assistant" && msg.id == lastAssistantId
                                        )
                                        // phase 6: entrance animates ONLY when
                                        // the append seam (appendChatMessage)
                                        // supplies a transaction; removals and
                                        // wholesale replaces are .identity →
                                        // instant (no animated teardown on the
                                        // end-of-turn id swap or session switch).
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .offset(y: 8)),
                                            removal: .identity))
                                    }
                                }
                            }
                            // phase 4: the scroll TARGET is the clearance —
                            // scrollToBottom aligns this spacer's bottom to the
                            // viewport, so the last message line always clears
                            // the floating thinking row. Constant height so
                            // idle→busy never shifts rows. (Padding below the
                            // anchor would sit OUTSIDE the scroll target and
                            // the card would still cover the last line.)
                            Color.clear
                                .frame(height: 56)
                                .id(bottomAnchor)
                                // Re-arm sentinel: inside the LazyVStack this
                                // spacer only EXISTS when the viewport is at /
                                // near the bottom, so its appearance is a free
                                // "user is at the bottom" signal (no geometry
                                // plumbing).
                                .onAppear { scrollCoordinator.setBottomSpacerVisible(true) }
                                .onDisappear { scrollCoordinator.setBottomSpacerVisible(false) }
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 18)
                        .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4).onChanged { _ in
                            scrollCoordinator.disarmFollow()
                        }
                    )
                    .onDrop(
                        of: chatSessionDropTypes,
                        isTargeted: $pinnedSessionDropTargeted,
                        perform: handlePinnedSessionDrop
                    )
                    .background(
                        ScrollWheelCatcher { deltaY in
                            if deltaY > 0.5 {
                                scrollCoordinator.disarmFollow()
                            } else if deltaY < -0.5, scrollCoordinator.bottomSpacerVisible, !scrollCoordinator.autoFollow {
                                // Scrolling back DOWN to the bottom re-arms
                                // follow (standard chat UX — the user's catch
                                // 2026-06-12: once follow disarmed, streaming
                                // grew below the fold and only the small
                                // "Latest" pill could recover it). Snap flush
                                // so the next delta continues from the bottom.
                                scrollCoordinator.forceFollow()
                                scrollToBottom(proxy, animated: true, delay: 0, force: true)
                            }
                        }
                        .allowsHitTesting(false)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if !scrollCoordinator.autoFollow {
                            Button {
                                scrollCoordinator.forceFollow()
                                scrollToBottom(proxy, animated: true, delay: 0, force: true)
                            } label: {
                                Label("Latest", systemImage: "arrow.down.circle.fill")
                                    .font(NativeAgentFont.tag)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 18)
                            .padding(.top, 18)
                            // phase 4: lift clear of the floating thinking row
                            // while a turn streams so it stays visible/clickable.
                            .padding(.bottom, showThinkingRow ? 56 : 18)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .onChange(of: appModel.chatMessages.count) {
                        scrollToBottom(proxy, animated: true, delay: 0.03)
                    }
                    .onChange(of: appModel.isBusy) { _, isBusy in
                        // PATCH-2026-06-06: chat-upgrades — smarter auto-scroll.
                        // On stream completion (isBusy true→false), if the user
                        // never scrolled up during the stream (auto-follow
                        // still true), do a final clean scroll and keep follow
                        // armed for the next answer. If they scrolled up,
                        // respect their position — do nothing.
                        if !isBusy {
                            turnNoticeToasts.dismissAll()
                            if scrollCoordinator.autoFollow {
                                scrollToBottom(proxy, animated: true, delay: 0.03)
                            }
                        } else {
                            // stream just started — keep current follow state
                            scrollToBottom(proxy, animated: false, delay: 0.03)
                        }
                    }
                    .onChange(of: appModel.activeChatSessionId) {
                        turnNoticeToasts.dismissAll()
                        scrollCoordinator.forceFollow()
                        renameTitle = activeSession?.title ?? ""
                        lastAutoReadMessageId = appModel.chatMessages.last(where: { $0.role == "assistant" })?.id
                        scrollToBottom(proxy, animated: false, delay: 0.05, force: true)
                    }
                    // session-switch scroll fix 2026-05-23: activeChatSessionId
                    // flips IMMEDIATELY (sync) but chatMessages is loaded
                    // async by selectChatSession (network round-trip), so the
                    // scroll above lands on an empty LazyVStack. When the
                    // first message id changes, content has actually swapped
                    // — force a scroll with enough delay for the LazyVStack
                    // to lay out the new messages.
                    .onChange(of: appModel.chatMessages.first?.id) { _, _ in
                        scrollToBottom(proxy, animated: false, delay: 0.12, force: true)
                    }
                    // PATCH-2026-05-06: hotpath-4 scroll as streaming deltas arrive
                    .onChange(of: appModel.chatMessages.last?.content) { _, _ in
                        if appModel.isBusy && scrollCoordinator.autoFollow {
                            scrollToBottom(proxy, animated: false, delay: 0.02)
                        }
                    }
                    // H4 (2026-07-09): a completed turn re-reads the active
                    // session's messages and nothing else. This used to call
                    // `loadChatState()`, whose health busy-wait alone could
                    // stall the turn tail for 2.8s before it even started
                    // fetching. A notification with no session id is legacy and
                    // still gets the full reload — it carries no active-session
                    // guarantee, so it may need the session list rebuilt.
                    .onReceive(NotificationCenter.default.publisher(for: .chatTurnCompleted)) { note in
                        guard let completedSessionId = note.object as? String else {
                            Task { await appModel.loadChatState() }
                            return
                        }
                        guard completedSessionId == appModel.activeChatSessionId else { return }
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
                    // Notify-don't-hang (2026-06-09): in-turn tool notices
                    // (invoke_claude start / 30s heartbeat / timeout) surface
                    // as live toasts instead of a silent multi-minute hang.
                    .onReceive(
                        NotificationCenter.default.publisher(for: .nativeAgentTurnNotice)
                            // Posted from the stream-consumer background task —
                            // hop to main before touching the toast center.
                            .receive(on: DispatchQueue.main)
                    ) { note in
                        guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
                        // Session-scope (audit #7/#9): a notice that names a
                        // session only toasts when that session is active, so a
                        // background/detached turn's advisory + tool notices don't
                        // bleed over the active conversation. Notices without a
                        // sessionId (legacy/other posters) are not filtered.
                        if let noticeSession = note.userInfo?["sessionId"] as? String,
                           !noticeSession.isEmpty,
                           noticeSession != appModel.activeChatSessionId {
                            return
                        }
                        let kind = (note.userInfo?["kind"] as? String) ?? ""
                        switch ChatTurnNoticePresentation.destination(for: kind) {
                        case .chatTop:
                            turnNoticeToasts.push(info: text, autoDismissAfter: 6)
                        case .globalWarning:
                            appModel.systemToasts.push(warn: text)
                        case .globalInfo:
                            appModel.systemToasts.push(info: text, autoDismissAfter: 6)
                        }
                    }
                    .task {
                        await appModel.loadChatState()
                        await MainActor.run {
                            if let session = appModel.chatSessions.first(where: { $0.id == appModel.activeChatSessionId }) {
                                renameTitle = session.title
                            }
                            lastAutoReadMessageId = appModel.chatMessages.last(where: { $0.role == "assistant" })?.id
                            scrollCoordinator.forceFollow()
                            scrollToBottom(proxy, animated: false, delay: 0, force: true)
                        }
                    }
                }
                // The slow-turn advisory is centered against the conversation
                // viewport itself. It floats at the top of the message area,
                // so resizing the split view/window keeps it centered and it
                // never covers the composer or changes transcript layout.
                .overlay(alignment: .top) {
                    SystemToastBar(center: turnNoticeToasts, placement: .top)
                }
                // chat-smoothness phase 4: the thinking row FLOATS over the
                // bottom of the message area instead of living in the composer
                // stack — its appearance must not change the composer height
                // (reserve-no-space row jump, jitter-anatomy item 5). The
                // ZStack + explicit animation scope the fade to the overlay
                // only (isBusy flips arrive from async model updates with no
                // ambient transaction — a bare .transition would pop).
                .overlay(alignment: .bottom) {
                    ZStack {
                        if showThinkingRow {
                            ChatThinkingRow(
                                personaName: appModel.agentDisplayName,
                                onStop: { appModel.stopChatStream() }
                            )
                            .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 6)
                            .transition(.opacity)
                        }
                    }
                    .animation(
                        NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                        value: showThinkingRow)
                }

                Divider()

                // PATCH-2026-05-09: chat-ux-polish — polished composer area
                VStack(spacing: NativeAgentSpacing.xs) {
                    ChatQueuedTurnsView(
                        sessionId: appModel.activeChatSessionId,
                        isBusy: appModel.isBusy || appModel.isChatStreaming
                    )
                    .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)

                    // Attachment thumbnail strip
                    if !pendingAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: NativeAgentSpacing.sm) {
                                ForEach(pendingAttachments) { att in
                                    AttachmentChip(attachment: att) {
                                        pendingAttachments.removeAll { $0.id == att.id }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        if pendingAttachments.count >= 2 {
                            Text("\(appModel.agentDisplayName) will treat these as one combined input.")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }

                    // PATCH-2026-05-13: parallel-sessions — banner now counts
                    // OTHER sessions still streaming. With per-session state,
                    // the user can keep typing here while N background sessions
                    // run; this banner is just a friendly nudge.
                    if appModel.anySessionStreaming {
                        let otherRunning = appModel.streamingSessions.filter { $0 != appModel.activeChatSessionId }
                        if !otherRunning.isEmpty {
                            HStack(spacing: NativeAgentSpacing.sm) {
                                Label(otherRunning.count == 1
                                      ? "Chat running in another session"
                                      : "\(otherRunning.count) other sessions running",
                                      systemImage: "ellipsis.message")
                                    .font(NativeAgentFont.tag)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if otherRunning.count == 1, let onlySid = otherRunning.first {
                                    Button("Return", systemImage: "arrow.turn.up.left") {
                                        if let session = appModel.chatSessions.first(where: { $0.id == onlySid }) {
                                            Task { await appModel.selectChatSession(session) }
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    Button("Stop", systemImage: "stop.fill") {
                                        appModel.stopChatStream(sessionId: onlySid)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                } else {
                                    Button("Stop Others", systemImage: "stop.fill") {
                                        for sid in otherRunning { appModel.stopChatStream(sessionId: sid) }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                            }
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    // Toast
                    if let toast = toasts.current {
                        Text(toast)
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .transition(.opacity)
                    }

                    // PATCH-2026-05-09: nextgen-surface — suggested action chips above composer
                    if appModel.nextGenSummary != nil {
                        NextGenActionChipsRow(appModel: appModel)
                            .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // PATCH-2026-06-06: chat-upgrades — capabilities chip surfaces
                    // tools/connectors/screen-capture state in one tap.
                    HStack(spacing: NativeAgentSpacing.sm) {
                        ComposerMetaRow(appModel: appModel)
                        CapabilitiesChip()
                    }
                    .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)

                    GlassCard(tint: NativeAgentBrand.accent.opacity(0.2)) {
                        HStack(alignment: .bottom, spacing: NativeAgentSpacing.sm) {
                            // Mic toggle — PulsingDot halo when listening
                            ZStack {
                                if voiceInput.isListening {
                                    PulsingDot(color: .red, size: 10, animates: true)
                                        .frame(width: 28, height: 28)
                                        .offset(x: -1, y: -1)
                                }
                                Button {
                                    toggleVoice()
                                } label: {
                                    Image(systemName: voiceInput.isListening ? "mic.fill" : "mic")
                                        .foregroundStyle(voiceInput.isListening ? Color.red : Color.primary)
                                        .frame(width: 30, height: 30)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help(voiceInput.isListening ? "Stop listening" : "Voice input")
                                .accessibilityLabel(voiceInput.isListening ? "Stop listening" : "Voice input")
                            }

                            let screenCaptureAllowed = appModel.trustPolicy?.multimodalPolicy?.screen_capture == true
                            // Screen capture
                            Button {
                                captureScreen()
                            } label: {
                                Image(systemName: "camera.viewfinder")
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .help(screenCaptureAllowed ? "Show agent my screen" : "Enable screen capture in Trust → Multimodal Capabilities")
                            .accessibilityLabel("Show agent my screen")
                            .disabled(appModel.isBusy || appModel.isChatStreaming || isCapturing || !screenCaptureAllowed)

                            // Attach — badge shows pending count
                            ZStack(alignment: .topTrailing) {
                                Button {
                                    attachFromClipboardOrPickFile()
                                } label: {
                                    Image(systemName: "paperclip")
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.borderless)
                                .help("Attach image or file (or drag onto the input field)")
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

                            // Text input
                            TextField(
                                voiceInput.isListening ? "" : "Ask \(appModel.agentDisplayName)",
                                text: textBinding,
                                axis: .vertical
                            )
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .focused($inputFocused)
                            .foregroundStyle(voiceInput.isListening ? .secondary : .primary)
                            .italic(voiceInput.isListening)
                            .onSubmit { send() }
                            .onChange(of: voiceInput.transcript) { _, newVal in
                                if !newVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    text = composeVoiceDraft(newVal)
                                }
                            }
                            .onChange(of: text) { _, newVal in
                                if newVal.hasPrefix("/") {
                                    let afterSlash = String(newVal.dropFirst())
                                    let hasArgsAlready = afterSlash.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                                    let firstToken = afterSlash.components(separatedBy: .whitespacesAndNewlines).first ?? afterSlash
                                    let lowerToken = firstToken.lowercased()
                                    let dynamicCommandNames = capabilitiesStore.slashCommandTools().map(\.name)
                                    let prefixMatch = !hasArgsAlready && (
                                        lowerToken.isEmpty
                                        || knownSlashCommands.contains { $0.hasPrefix(lowerToken) }
                                        || dynamicCommandNames.contains { $0.hasPrefix(lowerToken) }
                                    )
                                    if prefixMatch {
                                        slashFilter = afterSlash
                                        showSlashMenu = true
                                    } else {
                                        showSlashMenu = false
                                        slashFilter = ""
                                    }
                                } else {
                                    showSlashMenu = false
                                    slashFilter = ""
                                }
                            }
                            .popover(isPresented: $showSlashMenu, arrowEdge: .bottom) {
                                SlashCommandMenu(filter: slashFilter, onSelect: { command in
                                    if command.hasSuffix(" ") {
                                        text = "/" + command
                                    } else {
                                        handleSlashCommand(command)
                                    }
                                    showSlashMenu = false
                                    inputFocused = true
                                }, onDismiss: {
                                    showSlashMenu = false
                                }, extraTools: capabilitiesStore.slashCommandTools())
                            }
                            .background(
                                DropZoneView(onDrop: { providers in
                                    handleDrop(providers: providers)
                                }, onToast: { msg in
                                    showToast(msg)
                                })
                            )

                            let activeSessionIsRunning = appModel.isBusy || appModel.isChatStreaming
                            let canSend = !isCapturing
                                && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)

                            // Stop stays independently available while the send
                            // button keeps accepting messages into send-next.
                            if activeSessionIsRunning {
                                Button {
                                    appModel.stopChatStream()
                                } label: {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 34, height: 34)
                                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: NativeAgentRadius.control))
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.borderless)
                                .help("Stop generation")
                                .accessibilityLabel("Stop generation")
                            }

                            Button {
                                send()
                            } label: {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 34, height: 34)
                                    .background(
                                        canSend ? NativeAgentBrand.accentDeep : Color.secondary.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: NativeAgentRadius.control)
                                    )
                                    .foregroundStyle(canSend ? .white : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canSend)
                            .animation(NativeAgentMotion.snappy, value: canSend)
                            .help(activeSessionIsRunning ? "Queue message to send next" : "Send message")
                            .accessibilityLabel(activeSessionIsRunning ? "Queue message to send next" : "Send message")
                        }
                    }
                    // Cap the composer width and center it on the chat column
                    // instead of spanning the whole window; it still grows
                    // upward via the TextField's 1...5 lineLimit.
                    .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
        }
        .background(.background)
        .contentShape(Rectangle())
        .onDrop(
            of: chatSessionDropTypes,
            isTargeted: $pinnedSessionDropTargeted,
            perform: handlePinnedSessionDrop
        )
        // PATCH-2026-06-06: chat-upgrades — bump the scroll-serial on disappear
        // so any in-flight DispatchQueue.main.asyncAfter scroll closures bail
        // out through the scroll coordinator serial check. Belt-and-braces
        // hygiene per the state-lifecycle bug class.
        .onDisappear {
            scrollCoordinator.markViewDisappeared()
        }
        .focusedSceneValue(\.chatCommandActions, ChatFocusedCommandActions(
            send: { if !showToolInputForm { send() } },
            attach: attachFromClipboardOrPickFile,
            toggleVoice: toggleVoice,
            focusComposer: { inputFocused = true }
        ))
    }

}

/// M12: the honest counterpart to `try? await api.getX() ?? existingValue`.
/// Shown above a panel whose last refresh could not reach every endpoint, so
/// the user knows the values below are carried over rather than current.
struct StalePanelNotice: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stale data. \(text)")
        .help(text)
    }
}
