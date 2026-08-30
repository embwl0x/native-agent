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

let chatSessionDragType = UTType(exportedAs: "com.nativeagent.chat-session")
let chatSessionDragPlainTextPrefix = "nativeagent-chat-session:"
let chatSessionDropTypes: [UTType] = [chatSessionDragType, .plainText]

/// Value-only presentation rules used by the chat viewport. The view is their
/// sole consumer; no state is duplicated here.
enum ChatViewportPresentation {
    static func turnCardClearance(showingTurnCard: Bool, measuredHeight: CGFloat) -> CGFloat {
        guard showingTurnCard else { return MacChatTurnCardMetrics.floatingClearance }
        return max(MacChatTurnCardMetrics.floatingClearance, measuredHeight)
    }

    static func shouldShowLatestPill(autoFollow: Bool) -> Bool {
        !autoFollow
    }

    enum ScrollFollowAction: Equatable {
        case none
        case disarm
        case rearm
    }

    static func scrollFollowAction(
        deltaY: CGFloat,
        bottomSpacerVisible: Bool,
        autoFollow: Bool
    ) -> ScrollFollowAction {
        if deltaY > 0.5 { return .disarm }
        if deltaY < -0.5, bottomSpacerVisible, !autoFollow { return .rearm }
        return .none
    }
}

/// Owns the destructive clear action's presentation lifecycle. The view may
/// dismiss a confirmation dialog more than once (button action plus binding
/// teardown), so only a currently presented dialog may consume the clear.
struct ChatClearConfirmationState: Equatable {
    private(set) var isPresented = false

    mutating func request() {
        isPresented = true
    }

    mutating func cancel() {
        isPresented = false
    }

    /// Returns true exactly once for a presented destructive confirmation.
    mutating func consumeConfirmation() -> Bool {
        guard isPresented else { return false }
        isPresented = false
        return true
    }
}

struct ChatSidebarSections {
    let pinned: [ChatSession]
    let unpinned: [ChatSession]

    static func split(visible: [ChatSession], orderedPinned: [ChatSession]) -> Self {
        let visibleByID = Dictionary(
            visible.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenPinned = Set<String>()
        let pinned: [ChatSession] = orderedPinned.compactMap { candidate -> ChatSession? in
            guard seenPinned.insert(candidate.id).inserted else { return nil }
            return visibleByID[candidate.id]
        }
        let pinnedIDs = Set(pinned.map(\.id))
        var seenUnpinned = Set<String>()
        return Self(
            pinned: pinned,
            // A damaged or concurrently refreshed index can contain a
            // duplicate session ID.  A LazyVStack needs one stable row per
            // ID; rendering both would let it recycle one row's closures and
            // appearance for the other.  Keep the first visible receipt,
            // matching the pinned projection above.
            unpinned: visible.filter {
                !pinnedIDs.contains($0.id) && seenUnpinned.insert($0.id).inserted
            }
        )
    }
}

struct ChatSidebarProjection {
    let sections: ChatSidebarSections
    let pinnedTabs: [ChatSession]
}

/// Chat messages stream at token cadence, while the session rail usually does
/// not change at all. Keep its decoded pins, search filter, dictionaries, and
/// partition behind an exact-input cache so a transcript delta only rebuilds
/// the transcript. Arrays are retained copy-on-write and compared exactly;
/// there is no hash-collision or stale-row shortcut.
@MainActor
final class ChatSidebarProjectionCache {
    private var sessions: [ChatSession]?
    private var pinnedRaw = ""
    private var search = ""
    private var cached = ChatSidebarProjection(
        sections: .init(pinned: [], unpinned: []),
        pinnedTabs: []
    )
    private(set) var rebuildCount = 0

    func project(
        sessions newSessions: [ChatSession],
        pinnedRaw newPinnedRaw: String,
        search newSearch: String
    ) -> ChatSidebarProjection {
        if sessions == newSessions,
           pinnedRaw == newPinnedRaw,
           search == newSearch {
            return cached
        }

        let query = newSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = query.isEmpty ? newSessions : newSessions.filter {
            $0.title.lowercased().contains(query)
                || ($0.lastMessagePreview ?? "").lowercased().contains(query)
        }
        let pinnedIDs = MacPinnedChatSessionStore.decode(newPinnedRaw)
        let pinnedTabs: [ChatSession]
        if pinnedIDs.isEmpty {
            pinnedTabs = []
        } else {
            let byID = Dictionary(
                newSessions.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            pinnedTabs = pinnedIDs.compactMap { byID[$0] }
        }

        let result = ChatSidebarProjection(
            sections: ChatSidebarSections.split(visible: visible, orderedPinned: pinnedTabs),
            pinnedTabs: pinnedTabs
        )
        sessions = newSessions
        pinnedRaw = newPinnedRaw
        search = newSearch
        cached = result
        rebuildCount += 1
        return result
    }
}

/// The identity SwiftUI uses for a sidebar row.  Section membership is part
/// of the identity on purpose: moving a session between Pinned and Recent
/// must destroy the old lazy row rather than recycle its local view state.
struct ChatSidebarSessionRowIdentity: Hashable, Sendable {
    enum Section: Hashable, Sendable {
        case pinned
        case recent
    }

    let sessionID: String
    let section: Section

    init(sessionID: String, pinned: Bool) {
        self.sessionID = sessionID
        self.section = pinned ? .pinned : .recent
    }
}

/// D4 (2026-08-28): the auto-read triggers, lifted off ChatView's root body.
///
/// Read-aloud has to watch three token-rate signals (a new message, the tail
/// message's growing content, and the turn ending). Hanging those on the root
/// body made every streamed delta a dependency of the WHOLE Chat screen — the
/// session rail included. This view renders nothing and exists only to own
/// those three dependencies; `onChanged` is `speakLatestAssistantIfReady`,
/// whose own gate (ChatVoiceAutoReadGate) is unchanged, so the firing
/// CONDITIONS are identical to before the move.
struct ChatReadAloudObserver: View {
    @Environment(AppModel.self) private var appModel
    var onChanged: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: appModel.chatMessages.count) {
                onChanged()
            }
            .onChange(of: appModel.chatMessages.last?.content) {
                if !appModel.isBusy { onChanged() }
            }
            .onChange(of: appModel.isBusy) {
                if !appModel.isBusy { onChanged() }
            }
    }
}

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
    // sidebar-density 2026-08-10: single driver for in-list rename — exactly
    // one row may be editing; SessionRow reports commit/cancel back and this
    // clears. Kept outside the row so the context menu (which lives on the
    // row's ChatView-side wrapper) can start the edit.
    @State var renamingSessionId: String? = nil
    @State var showContext = false
    @State var showConversationControls = false
    let bottomAnchor = "chat-bottom-anchor"
    // User 2026-08-20: the floating turn card can outgrow the fixed 80pt
    // clearance (larger accessibility text sizes scale its two rows) and land
    // on the streaming reply. Measure the real card height and let the
    // clearance grow with it. The fixed constant stays as the FLOOR so
    // idle→busy never shifts rows at default text size (card ≈ 67pt < 80);
    // only a genuinely taller card moves the transcript up. The measurement
    // already includes the card's 6pt bottom inset — no additive on top, or
    // busy clearance exceeds the floor at default size and every turn start
    // shifts the transcript (sweep 2026-08-21).
    @State var turnCardMeasuredHeight: CGFloat = 0

    var turnCardClearance: CGFloat {
        ChatViewportPresentation.turnCardClearance(
            showingTurnCard: showThinkingRow,
            measuredHeight: turnCardMeasuredHeight
        )
    }

    // Sprint 3.1 — voice input
    @State var voiceInput = VoiceInputController()
    @State var voiceDraftBeforeListening = ""
    // Sprint 3.2 — voice output
    @State var voiceOutput = VoiceOutputController()
    @AppStorage("voiceAutoRead") var voiceAutoRead = false
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
    @State var transcriptSearch = MacChatTranscriptSearchController()
    @State var showTranscriptSearch = false
    @State var transcriptSearchFocusRequest: UInt = 0
    // The state gate is separate from the SwiftUI binding so dismissal and a
    // destructive button action cannot race into duplicate clears.
    @State var clearConfirmation = ChatClearConfirmationState()
    // Capability store supplies dynamic slash-command suggestions and dispatch metadata.
    @State var capabilitiesStore = CapabilitiesStore.shared
    // PATCH-Phase7b: tool dispatch sheet + in-flight plan
    @State var showToolInputForm = false
    @State var currentDispatchPlan: DispatchArgPlan? = nil
    @State var scrollCoordinator = ChatScrollCoordinator()
    @State var sidebarProjectionCache = ChatSidebarProjectionCache()
    /// Per-session cursor prevents a tab switch from overwriting the marker
    /// for a response that is still arriving in another conversation.
    @State var lastAutoReadMessageIds: [String: String] = [:]
    /// A session is primed from its already-loaded transcript once. Until then
    /// auto-read must not mistake old history for a newly appended reply.
    @State var autoReadPrimedSessionIds: Set<String> = []
    @State var pinnedSessionDropTargeted = false
    /// D1: `hasAnyUsableProvider()` stats credential files on disk, so it must
    /// not be called from `body` (which re-runs at token rate). Cached here and
    /// refreshed at the three moments the answer can change for this view:
    /// appearing, switching session, and a provider being connected. Starts
    /// TRUE so a working machine can never flash the connect prompt.
    @State var hasUsableProvider = true
    /// Fences overlapping "Go to" tasks. A route may need to refresh the
    /// session index before selection; an older click must not resume after a
    /// newer click and become the newest AppModel selection request.
    @State var runningSessionNavigationGeneration: UInt = 0
    @AppStorage("NativeAgent.pinnedChatSessionIds") var pinnedChatSessionIdsRaw = ""

    var clearConfirmationBinding: Binding<Bool> {
        Binding(
            get: { clearConfirmation.isPresented },
            set: { isPresented in
                if isPresented {
                    clearConfirmation.request()
                } else {
                    clearConfirmation.cancel()
                }
            }
        )
    }

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

    var sidebarProjection: ChatSidebarProjection {
        sidebarProjectionCache.project(
            sessions: appModel.chatSessions,
            pinnedRaw: pinnedChatSessionIdsRaw,
            search: sessionSearch
        )
    }

    // 658.14: kept off the body so ChatView's already-maximal body expression
    // does not have to type-check them.
    private func runningSessionRoutes(_ sessionIds: [String]) -> [MacChatRunningSessionRoute] {
        MacChatRunningSessionRoute.routes(
            sessionIds: sessionIds,
            sessions: appModel.chatSessions
        )
    }

    private func goToRunningSession(_ sessionId: String) {
        runningSessionNavigationGeneration &+= 1
        let generation = runningSessionNavigationGeneration
        Task { @MainActor in
            let navigated = await MacChatRunningSessionNavigation.navigate(
                sessionId: sessionId,
                sessions: { appModel.chatSessions },
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

    private func openTranscriptSearch() {
        showTranscriptSearch = true
        transcriptSearchFocusRequest &+= 1
        transcriptSearch.replaceSource(
            messages: appModel.chatMessages,
            sessionID: appModel.activeChatSessionId
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

    private func refreshTranscriptSearchIfPresented() {
        guard showTranscriptSearch else { return }
        transcriptSearch.replaceSource(
            messages: appModel.chatMessages,
            sessionID: appModel.activeChatSessionId
        )
    }

    private func refreshTranscriptSearchTailIfPresented() {
        guard showTranscriptSearch else { return }
        transcriptSearch.replaceLastMessage(
            appModel.chatMessages.last,
            ordinal: appModel.chatMessages.count - 1,
            sessionID: appModel.activeChatSessionId
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionSidebar
            Divider()
            chatColumn
            // D4: the three token-rate read-aloud triggers used to hang off
            // THIS view's modifier chain, so every streamed delta re-evaluated
            // `chatMessages.last?.content` alongside the whole root body (and
            // the session rail with it). They now live in a zero-size observer
            // that owns those dependencies by itself.
            ChatReadAloudObserver(onChanged: speakLatestAssistantIfReady)
        }
        .navigationTitle("Chat")
        .onAppear {
            voiceOutput.nativeBaseURL = appModel.nativeBaseURL
            prunePinnedSessions()
            hasUsableProvider = appModel.hasAnyUsableProvider()
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
            hasUsableProvider = appModel.hasAnyUsableProvider()
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
            hasUsableProvider = appModel.hasAnyUsableProvider()
            Task { await appModel.maybeSendFirstRunGreeting() }
        }
        // D1 review fix: readiness can change WITHOUT chatProvider changing
        // (credentials added for the already-selected provider in Settings).
        // Any window regaining key — e.g. returning from the Settings window —
        // re-derives it, so the connect prompt can never sit stale while the
        // user is looking at Chat.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in
            hasUsableProvider = appModel.hasAnyUsableProvider()
        }
        .onChange(of: chatSessionIdsFingerprint) {
            prunePinnedSessions()
            // A rename target that left the list (archived/deleted/refreshed
            // away) must not leave a phantom editor pointed at a dead id.
            if let id = renamingSessionId,
               !appModel.chatSessions.contains(where: { $0.id == id }) {
                renamingSessionId = nil
            }
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
            HStack(spacing: 6) {
                Text("Sessions")
                    .font(.headline)
                Spacer()

                // Chat keeps one compact, conversation-relevant presence
                // signal. Global running work and Agent's broader Today view
                // belong to Activity rather than standing between the user
                // and their sessions.
                HealthCardPill()

                ChatSidebarArchiveButton()

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

            TextField("Search sessions", text: $sessionSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search sessions")

            // M12 (2026-07-09): refreshForSidebarItem falls back to the previous
            // value whenever an endpoint fails, so a dead backend used to render
            // a panel of stale data with no tell at all. Say so.
            if let notice = appModel.panelStaleNotice(for: .chat) {
                StalePanelNotice(text: notice)
            }

            if appModel.chatSessionIndexRefreshFailed {
                StalePanelNotice(text: "The session list could not update, so it is showing the last known sessions.")
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    let sections = sidebarProjection.sections
                    let pinnedRows = sections.pinned
                    let recentRows = sections.unpinned
                    if pinnedRows.isEmpty && recentRows.isEmpty {
                        Text(
                            ChatSessionListEmptyStatePresentation.message(
                                totalSessionCount: appModel.chatSessions.count,
                                searchQuery: sessionSearch
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    if !pinnedRows.isEmpty {
                        sessionSectionHeader("Pinned")
                        ForEach(pinnedRows) { session in
                            sidebarSessionRow(session, pinned: true)
                        }
                        if !recentRows.isEmpty {
                            sessionSectionHeader("Recent")
                                .padding(.top, 6)
                        }
                    }
                    ForEach(recentRows) { session in
                        sidebarSessionRow(session, pinned: false)
                    }
                }
            }
            // M12: dim the list when the session/message fetch itself failed —
            // the rows on screen are a snapshot from an earlier refresh.
            .opacity(appModel.chatSidebarSessionListOpacity)
        }
        .frame(width: 240)
        .padding()
        .background(.thinMaterial)
    }

    func sessionSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    // sidebar-density 2026-08-10: one row builder for both sections so the
    // pinned rows keep every affordance (select, drag-to-detach, context
    // menu) the plain rows have.
    @ViewBuilder
    func sidebarSessionRow(_ session: ChatSession, pinned isPinned: Bool) -> some View {
        let renaming = renamingSessionId == session.id
        let renamePencil = SessionRowRenamePencilPresentation.make(
            renameAvailable: true,
            hovering: false,
            renaming: renaming
        )
        let pinState: SessionRow.PinState = isPinned
            ? .pinned(onUnpin: { unpinSession(session.id) })
            : .unpinned
        let selectSession: () -> Void = {
            // While this row is editing its title, clicks belong to the
            // TextField — re-selecting would steal focus mid-rename.
            guard !renaming else { return }
            // Selecting another row cancels the current edit. Both pointer
            // and accessibility activation must use this same path; a
            // disappearing editor must never commit a half-typed title.
            if renamingSessionId != nil { renamingSessionId = nil }
            renameTitle = session.title
            Task { await appModel.selectChatSession(session) }
        }
        SessionRow(
            session: session,
            selected: session.id == appModel.activeChatSessionId,
            pinState: pinState,
            onSelect: selectSession,
            renaming: renaming,
            onRenameBegin: { renamingSessionId = session.id },
            onRenameEnd: { title in
                renamingSessionId = nil
                if let title { renameSession(session.id, title) }
            }
        )
            .contentShape(Rectangle())
            .onTapGesture(perform: selectSession)
            // detached-chat-windows Phase 1 W1.3: AppKit drag
            // source replaces SwiftUI .onDrag so we can detect
            // "dropped on desktop" via NSDraggingSource and
            // open a detached panel at the drop point. The
            // payload is the custom chat-session UTI only —
            // no plain-text, so Finder can't mint a desktop
            // .textClipping (2026-07-24 fix).
            // Suspended during rename: the AppKit overlay sits above the
            // row and would swallow the TextField's mouse events.
            .overlay {
                if !renaming {
                    SessionDragSource(sessionId: session.id, sessionTitle: session.title)
                }
            }
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
                if renamePencil.contextMenuRenameAvailable {
                    Button("Rename Session", systemImage: "pencil") {
                        renamingSessionId = session.id
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
            .help("\(session.displayTitle)\n\nHover for rename · drag into chat to pin · right-click for more")
            // Live-verified 2026-08-10: when a session moves between the
            // Pinned and Recent sections, the LazyVStack can hand back a
            // recycled row still wearing the OLD section's appearance (pin
            // glyph after an unpin) until the whole view rebuilds. Branding
            // the row id with its section makes a pin flip a destroy+create
            // instead of a reuse.
            .id(ChatSidebarSessionRowIdentity(sessionID: session.id, pinned: isPinned))
    }

    @ViewBuilder
    var chatColumn: some View {
        VStack(spacing: 0) {
            // The tool-input sheet remains a deliberately inert host. The
            // clear confirmation is mounted on the real column below so it
            // is laid out and presented by the visible conversation surface.
            Color.clear
                .frame(width: 0, height: 0)
                // The form owns schema validation and emits only a JSON Data
                // payload; the sheet can close only after a dispatch-safe
                // body exists, and the Task never captures [String: Any].
                .sheet(isPresented: $showToolInputForm) {
                    if let plan = currentDispatchPlan {
                        ToolInputForm(
                            plan: plan,
                            onSubmit: { inputData in
                                showToolInputForm = false
                                let toolName = plan.tool.name
                                Task {
                                    await runDispatchAndRenderReceiptData(
                                        tool: toolName, inputData: inputData
                                    )
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
                    nextGenPhases: appModel.nextGenPhases,
                    showContext: $showContext,
                    showConversationControls: $showConversationControls,
                    onRename: { title in
                        renameActiveChatTitle(title)
                    },
                    onFind: openTranscriptSearch
                )
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)

                if showConversationControls {
                    VStack(spacing: NativeAgentSpacing.sm) {
                        ChatBrainControlBar()
                        HStack {
                            Spacer()
                            CapabilitiesChip()
                        }
                    }
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

                // D4: one decode + one dictionary build for the strip, instead
                // of one for the emptiness test and another for the rows.
                let pinnedTabs = sidebarProjection.pinnedTabs
                if !pinnedTabs.isEmpty || pinnedSessionDropTargeted {
                    PinnedSessionTabStrip(
                        sessions: pinnedTabs,
                        activeSessionId: appModel.activeChatSessionId,
                        runningSessionIds: appModel.pinnedTabRunningSessionIDs,
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
                                switch ChatEmptyStateMode.mode(
                                    hasUsableProvider: hasUsableProvider
                                ) {
                                case .connectProvider:
                                    // D1: never invite a message that can only
                                    // dead-end. Send the user to Providers first.
                                    ChatProviderConnectEmptyState {
                                        _ = NativeAgentAppCoordinator.shared
                                            .request(.sidebar(.providers))
                                    }
                                    .frame(minHeight: 360)
                                case .suggestions:
                                    // PATCH-2026-05-09: chat-ux-polish — persona-aware empty state + suggestion chips
                                    ChatEmptyState(
                                        personaName: appModel.agentDisplayName,
                                        onSuggestion: { suggestion in
                                            ChatEmptyStateSuggestionAction.apply(
                                                suggestion,
                                                model: appModel,
                                                activeSessionID: appModel.activeChatSessionId,
                                                draftText: &draftText,
                                                draftSessionID: &draftSessionId
                                            )
                                        }
                                    )
                                    .frame(minHeight: 360)
                                }
                            } else {
                                let sessionBusy = appModel.isBusy && appModel.currentChatTaskSessionId == appModel.activeChatSessionId
                                // Main and detached chat share the exact grouped
                                // transcript owner, including search row IDs and
                                // selected-result highlighting.
                                ChatMessageListView(
                                    messages: appModel.chatMessages,
                                    sessionId: appModel.activeChatSessionId,
                                    isStreaming: sessionBusy,
                                    highlightedMessageID: showTranscriptSearch
                                        ? transcriptSearch.selectedMessageID
                                        : nil
                                )
                            }
                            // phase 4: the scroll TARGET is the clearance —
                            // scrollToBottom aligns this spacer's bottom to the
                            // viewport, so the last message line always clears
                            // the floating thinking row. Constant height so
                            // idle→busy never shifts rows. (Padding below the
                            // anchor would sit OUTSIDE the scroll target and
                            // the card would still cover the last line.)
                            Color.clear
                                .frame(height: turnCardClearance)
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
                            switch ChatViewportPresentation.scrollFollowAction(
                                deltaY: deltaY,
                                bottomSpacerVisible: scrollCoordinator.bottomSpacerVisible,
                                autoFollow: scrollCoordinator.autoFollow
                            ) {
                            case .disarm:
                                scrollCoordinator.disarmFollow()
                            case .rearm:
                                // Scrolling back DOWN to the bottom re-arms
                                // follow (standard chat UX — the user's catch
                                // 2026-06-12: once follow disarmed, streaming
                                // grew below the fold and only the small
                                // "Latest" pill could recover it). Snap flush
                                // so the next delta continues from the bottom.
                                scrollCoordinator.forceFollow()
                                scrollToBottom(proxy, animated: true, delay: 0, force: true)
                            case .none:
                                break
                            }
                        }
                        .allowsHitTesting(false)
                    )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if showTranscriptSearch {
                            MacChatTranscriptSearchBar(
                                controller: transcriptSearch,
                                focusRequest: transcriptSearchFocusRequest,
                                onDismiss: closeTranscriptSearch
                            )
                            .transition(
                                reduceMotion
                                    ? .identity
                                    : .move(edge: .top).combined(with: .opacity)
                            )
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if ChatViewportPresentation.shouldShowLatestPill(
                            autoFollow: scrollCoordinator.autoFollow
                        ) {
                            Button {
                                scrollCoordinator.forceFollow()
                                scrollToBottom(proxy, animated: true, delay: 0, force: true)
                            } label: {
                                Label("Latest", systemImage: "arrow.down.circle.fill")
                                    .font(NativeAgentFont.tag)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .glassEffect(.regular.interactive(), in: Capsule())  // Liquid Feel W2
                            }
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 18)
                            .padding(.top, 18)
                            // phase 4: lift clear of the floating thinking row
                            // while a turn streams so it stays visible/clickable.
                            .padding(.bottom, showThinkingRow ? turnCardClearance : 18)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .onChange(of: appModel.chatMessages.count) {
                        if showTranscriptSearch {
                            refreshTranscriptSearchIfPresented()
                        } else {
                            scrollToBottom(proxy, animated: true, delay: 0.03)
                        }
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
                            if scrollCoordinator.autoFollow && !showTranscriptSearch {
                                scrollToBottom(proxy, animated: true, delay: 0.03)
                            }
                        } else if !showTranscriptSearch {
                            // stream just started — keep current follow state
                            scrollToBottom(proxy, animated: false, delay: 0.03)
                        }
                    }
                    .onChange(of: appModel.activeChatSessionId) {
                        showTranscriptSearch = false
                        transcriptSearch.reset(for: appModel.activeChatSessionId)
                        turnNoticeToasts.dismissAll()
                        scrollCoordinator.forceFollow()
                        // A turn can be live in both the old and new session
                        // with different card heights — don't carry one over.
                        turnCardMeasuredHeight = 0
                        renameTitle = activeSession?.title ?? ""
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
                        primeAutoReadForCurrentSessionIfNeeded()
                        if showTranscriptSearch {
                            refreshTranscriptSearchIfPresented()
                        } else {
                            scrollToBottom(proxy, animated: false, delay: 0.12, force: true)
                        }
                    }
                    // PATCH-2026-05-06: hotpath-4 scroll as streaming deltas arrive
                    .onChange(of: appModel.chatMessages.last?.content) { _, _ in
                        if showTranscriptSearch {
                            refreshTranscriptSearchTailIfPresented()
                        } else if appModel.isBusy && scrollCoordinator.autoFollow {
                            scrollToBottom(proxy, animated: false, delay: 0.02)
                        }
                    }
                    .onChange(of: appModel.chatMessages.last?.id) { _, _ in
                        refreshTranscriptSearchTailIfPresented()
                    }
                    // gpt-5.5 review (MEDIUM): a card that grows mid-turn (an
                    // approval row arriving) enlarges the clearance spacer, but
                    // with no new token to trigger a content scroll the
                    // viewport stays aligned to the OLD clearance and the
                    // taller card covers the tail. Re-align when the clearance
                    // changes while follow is armed; never yank the viewport
                    // out from under a search or a user who scrolled away.
                    .onChange(of: turnCardClearance) { _, _ in
                        guard showThinkingRow, scrollCoordinator.autoFollow, !showTranscriptSearch else { return }
                        scrollToBottom(proxy, animated: false, delay: 0, force: false)
                    }
                    .onChange(of: transcriptSearch.selectionRevision) { _, _ in
                        guard showTranscriptSearch,
                              let messageID = transcriptSearch.selectedMessageID
                        else { return }
                        scrollCoordinator.disarmFollow()
                        withAnimation(NativeAgentMotion.respecting(
                            .easeOut(duration: 0.16),
                            reduceMotion: reduceMotion
                        )) {
                            proxy.scrollTo(
                                MacChatTranscriptSearch.scrollTargetID(for: messageID),
                                anchor: .center
                            )
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
                            primeAutoReadForCurrentSessionIfNeeded()
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
                            // Desk 658.11: the one shared live-turn card. The
                            // detached window composes this exact host.
                            MacChatTurnCardHost(
                                sessionId: appModel.activeChatSessionId,
                                onStop: { appModel.stopChatStream() }
                            )
                            .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 6)
                            // Feed the measured height (card + bottom inset)
                            // into the transcript clearance so a grown card
                            // (large accessibility text) never covers the reply.
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                turnCardMeasuredHeight = height
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(
                        NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                        value: showThinkingRow)
                    .onChange(of: showThinkingRow) { _, visible in
                        // Card gone: drop the stale measurement so the next
                        // turn's clearance starts at the floor instead of the
                        // previous card's height (one settle-scroll, not two).
                        if !visible { turnCardMeasuredHeight = 0 }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {

                // (divider removed — content flows under the glass composer)

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
                    MacChatOtherSessionsBanner(
                        otherRunning: appModel.otherRunningChatSessionIDs,
                        routes: runningSessionRoutes,
                        onGoTo: goToRunningSession,
                        onStop: { appModel.stopChatStream(sessionId: $0) }
                    )

                    // Toast
                    if let toast = ChatComposerBottomToastPresentation.visibleEntry(from: toasts) {
                        Text(toast)
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .transition(.opacity)
                            .accessibilityIdentifier("chat.composer.bottom-toast")
                    }

                    // PATCH-2026-05-09: nextgen-surface — suggested action chips above composer
                    if appModel.nextGenSummary != nil {
                        NextGenActionChipsRow(appModel: appModel)
                            .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    let screenCaptureAllowed = appModel.trustPolicy?.multimodalPolicy?.screen_capture == true
                    let activeSessionIsRunning = appModel.isBusy || appModel.isChatStreaming
                    let canSend = !isCapturing
                        && (ChatTranscriptPresentation.hasVisibleText(text)
                            || !pendingAttachments.isEmpty)

                    MacChatComposerControlStrip(
                        isListening: voiceInput.isListening,
                        screenCaptureAllowed: screenCaptureAllowed,
                        screenCaptureDisabled: activeSessionIsRunning || isCapturing || !screenCaptureAllowed,
                        pendingAttachmentCount: pendingAttachments.count,
                        isRunning: activeSessionIsRunning,
                        hasQueuedTurns: !appModel.queuedChatTurns(for: appModel.activeChatSessionId).isEmpty,
                        isQueuePaused: appModel.isChatQueuePaused(appModel.activeChatSessionId),
                        canSend: canSend,
                        onToggleVoice: toggleVoice,
                        onCaptureScreen: captureScreen,
                        onAttach: attachFromClipboardOrPickFile,
                        onStop: { appModel.stopChatStream() },
                        onSend: send,
                        onFocusRequest: { inputFocused = true }
                    ) {
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
                            if ChatTranscriptPresentation.hasVisibleText(newVal) {
                                text = composeVoiceDraft(newVal)
                            }
                        }
                        .onChange(of: text) { _, newVal in
                            if newVal.hasPrefix("/") {
                                let afterSlash = String(newVal.dropFirst())
                                let hasArgsAlready = afterSlash.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                                let firstToken = afterSlash.components(separatedBy: .whitespacesAndNewlines).first ?? afterSlash
                                let lowerToken = firstToken.lowercased()
                                let dynamicCommandNames = capabilitiesStore.slashCommandNames
                                let prefixMatch = !hasArgsAlready && (
                                    lowerToken.isEmpty
                                    || ChatSlashCommandRegistry.commandNames.contains { $0.hasPrefix(lowerToken) }
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
                    }
                    // Cap the composer width and center it on the chat column
                    // instead of spanning the whole window; it still grows
                    // upward via the TextField's 1...5 lineLimit.
                    .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
                .background {
                    // Liquid Feel W2: transcript scrolls UNDER the floating
                    // composer; this fade keeps the last lines readable while
                    // the GlassCard refracts what passes beneath it.
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0),
                            Color(nsColor: .windowBackgroundColor).opacity(0.88),
                        ]),
                        startPoint: .top, endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
                }
        }
        .confirmationDialog(
            "Clear all messages in this session?",
            isPresented: clearConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Clear Messages", role: .destructive) {
                guard clearConfirmation.consumeConfirmation() else { return }
                Task { await appModel.clearActiveChatMessages() }
            }
            Button("Cancel", role: .cancel) {
                clearConfirmation.cancel()
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
            focusComposer: { inputFocused = true },
            focusTranscriptSearch: openTranscriptSearch,
            findNext: findNextTranscriptMatch,
            findPrevious: findPreviousTranscriptMatch
        ))
    }

}

/// Kept as its own mounted control so the durable archive route can be hosted
/// without starting ChatView's unrelated provider, voice, and file-watch work.
struct ChatSidebarArchiveButton: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            Task { await appModel.archiveActiveChat() }
        } label: {
            Image(systemName: "archivebox")
        }
        .buttonStyle(.borderless)
        .disabled(appModel.activeChatSessionId.isEmpty)
        .help("Archive active chat")
        .accessibilityLabel("Archive active chat")
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
