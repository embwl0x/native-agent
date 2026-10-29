import EngineRuntime
import AppToolRuntime
import ChatSessionWork
import SwiftUI
import Transcripts
import UniformTypeIdentifiers
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ChatView+ShellColumn.swift` | `ChatView`: conversation sidebar, archive control and cached opening-line/pin projection; stable section row identities |

// Person conversations and agent/helper conversations are grouped by recorded kind.

let chatSessionDragType = UTType(exportedAs: "com.nativeagent.chat-session")
let chatSessionDragPlainTextPrefix = "nativeagent-chat-session:"
let chatSessionDropTypes: [UTType] = [chatSessionDragType, .plainText]

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
            // Keep the first row per ID so lazy view state cannot alias duplicate sessions.
            unpinned: visible.filter {
                !pinnedIDs.contains($0.id) && seenUnpinned.insert($0.id).inserted
            }
        )
    }
}

/// Cache exact session, pin, search and opening-line inputs independently of streaming text.
@MainActor
final class ChatSidebarProjectionCache {
    private var sessions: [ChatSession]?
    private var navigation: ChatSessionNavigation?
    private var search = ""
    private var openingLines: ChatShellOpeningLine?
    private var openingRevision: UInt64 = 0
    private var cached = ChatSidebarSections(pinned: [], unpinned: [])

    func project(
        sessions newSessions: [ChatSession],
        navigation newNavigation: ChatSessionNavigation,
        search newSearch: String,
        openingLines newOpeningLines: ChatShellOpeningLine
    ) -> ChatSidebarSections {
        let newOpeningRevision = newOpeningLines.revision
        if sessions == newSessions,
           navigation == newNavigation,
           search == newSearch,
           openingLines === newOpeningLines,
           openingRevision == newOpeningRevision {
            return cached
        }

        let query = newSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = newSessions.filter {
            newOpeningLines.isPrepared(for: $0)
                && (query.isEmpty || $0.title.lowercased().contains(query)
                || ($0.lastMessagePreview ?? "").lowercased().contains(query)
                )
        }
        let result = ChatSidebarSections.split(
            visible: visible, orderedPinned: newNavigation.rows.map(\.session)
        )
        sessions = newSessions
        navigation = newNavigation
        search = newSearch
        openingLines = newOpeningLines
        openingRevision = newOpeningRevision
        cached = result
        return result
    }
}

/// Section changes remount sidebar rows instead of recycling their local state.
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

extension ChatView {
    var sidebarProjection: ChatSidebarSections {
        sidebarProjectionCache.project(
            sessions: appModel.engine.transcripts.sessions,
            navigation: appModel.engine.transcripts.navigation,
            search: sessionSearch,
            openingLines: appModel.engine.transcripts.openingLines
        )
    }

    /// Visible conversations grouped by their recorded kind.
    var shellConversationSections: (rows: [ChatSession], working: [ChatSession], briefs: [ChatSession]) {
        let sections = sidebarProjection
        var rows: [ChatSession] = []
        var working: [ChatSession] = []
        var briefs: [ChatSession] = []
        // Pins order conversations within their own section without changing their kind.
        for session in sections.pinned {
            if ChatShellConversationRow.isWorking(session) { working.append(session) } else { rows.append(session) }
        }
        for session in sections.unpinned {
            let onScreen = session.id == appModel.activeChatSessionId
            if !onScreen, (session.messageCount ?? 0) == 0, !shellSessionHasUnsentWork(session.id) {
                // Hide offscreen empty conversations only when they have no unsent work.
                continue
            } else if ChatShellConversationRow.isWorking(session) {
                working.append(session)
            } else if onScreen {
                rows.append(session)
            } else if ChatShellConversationRow.isHerOwn(session, openingLines: appModel.engine.transcripts.openingLines) {
                // Morning briefs share one row.
                briefs.append(session)
            } else {
                rows.append(session)
            }
        }
        return (rows, working, briefs)
    }

    /// Unsent text or attachments keep an empty conversation reachable from its row.
    func shellSessionHasUnsentWork(_ sessionId: String) -> Bool {
        !appModel.chatDraft(for: sessionId).isEmpty
            || !(appModel.chatPendingAttachments[sessionId] ?? []).isEmpty
    }

    /// Only the person's saved pins count as pinned; the live conversation anchor does not.
    func shellSessionIsPinned(_ session: ChatSession) -> Bool {
        humanPinnedSessionIds().contains(session.id)
    }

    @ViewBuilder
    var shellConversationsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                Text(ChatShellCopy.conversationsTitle)
                    .font(ShellType.columnTitle)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ChatSidebarArchiveButton(shell: true)

                Button {
                    Task {
                        await appModel.newChatSession()
                    }
                } label: {
                    Text("New")
                        .font(ShellType.labelSemibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            NativeAgentShell.quietFill,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NativeAgentShell.text)
                .help("New chat")
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("chat.conversations.new")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            NativeSearchField(text: $sessionSearch, prompt: "Search",
                              identifier: "chat.conversations.search",
                              accessibilityLabel: "Search conversations")
                .padding(.bottom, 8)

            // A failed list refresh identifies the retained snapshot as stale.
            PanelStaleNoticeView(item: .chat)
            if appModel.chatSessionIndexRefreshFailed {
                StalePanelNotice(
                    text: "The session list could not update, so it is showing the last known sessions."
                )
            }

            // Native sidebar selection owns arrow keys and collapsible sections.
            let sections = shellConversationSections
            // A screenshot's copy draws the selection itself (below): the
            // list's own highlight is a vibrancy view, which a bitmap capture
            // draws as a solid black slab.
            List(selection: Binding<String?>(
                get: { quietOffscreenRead ? nil : appModel.activeChatSessionId },
                set: { id in
                    guard let id, id != appModel.activeChatSessionId, renamingSessionId == nil,
                          let session = (sections.rows + sections.briefs + sections.working)
                            .first(where: { $0.id == id }) else { return }
                    Task { await appModel.selectChatSession(session) }
                }
            )) {
                if sections.rows.isEmpty && sections.briefs.isEmpty && sections.working.isEmpty {
                    Text(
                        ChatSessionListEmptyStatePresentation.message(
                            totalSessionCount: appModel.engine.transcripts.sessions.count,
                            searchQuery: sessionSearch
                        )
                    )
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .selectionDisabled()
                }
                // The column's blocks in the layout's order (ui/layout.json,
                // chat); whether a fold is open is saved there too.
                ForEach(shellColumnBlocks, id: \.self) { block in
                    switch block {
                    case "rows":
                        ForEach(sections.rows) { session in
                            shellSessionRow(session).tag(session.id)
                        }
                    case "briefs" where !sections.briefs.isEmpty:
                        Section(isExpanded: shellFold("briefs")) {
                            ForEach(sections.briefs) { session in
                                shellSessionRow(session).tag(session.id)
                            }
                        } header: {
                            Text("\(ChatShellCopy.briefsRowTitle)  \(sections.briefs.count)")
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    case "working" where !sections.working.isEmpty:
                        // The conversation on screen is never folded out of sight.
                        Section(isExpanded: shellFold("working",
                            openWhile: sections.working.contains { $0.id == appModel.activeChatSessionId })) {
                            ForEach(sections.working) { session in
                                shellSessionRow(session).tag(session.id)
                            }
                        } header: {
                            Text("\(ChatShellCopy.workingRowTitle(agentName: appModel.agentAddressName))  \(sections.working.count)")
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .opacity(appModel.chatSidebarSessionListOpacity)
        }
        .padding(.horizontal, NativeAgentShellLayout.conversationsInset)
        // Measure the conversation column edge to edge, including its gutter.
        .frame(width: NativeAgentShellLayout.conversationsWidth)
        .padding(.top, NativeAgentShellLayout.columnHeaderTopInset)
        .padding(.bottom, 16)
        // The list stays transparent over ShellFrame's sheet; only its gutter separates it from the room.
    }

    /// The conversations column's blocks as this chat's view shows them;
    /// none shown, no column (Simple's profile, as seeded).
    var shellColumnBlocks: [String] {
        appModel.engine.layout.layout.shown("chat", profile: layoutProfile).map(\.name)
    }

    /// A fold the person opens or closes: the layout's, written as theirs.
    func shellFold(_ block: String, openWhile forced: Bool = false) -> Binding<Bool> {
        Binding(get: { forced || appModel.engine.layout.layout.expanded("chat", block) },
                set: { open in Task { await appModel.engine.setSurfaceExpanded(open, surface: "chat", block: block) } })
    }

    /// One row. While a rename is in flight the classic `SessionRow` renders
    /// instead — it already owns the single-fire rename state machine, and a
    /// second implementation of "when does an edit commit" is exactly the kind
    /// of drift that loses somebody's typing.
    @ViewBuilder
    func shellSessionRow(_ session: ChatSession) -> some View {
        let renaming = renamingSessionId == session.id
        let isPinned = shellSessionIsPinned(session)
        let selectSession: () -> Void = {
            guard !renaming else { return }
            if renamingSessionId != nil { renamingSessionId = nil }
            Task { await appModel.selectChatSession(session) }
        }
        Group {
            if renaming {
                SessionRow(
                    session: session,
                    selected: session.id == appModel.activeChatSessionId,
                    pinState: isPinned
                        ? .pinned(onUnpin: { unpinSession(session.id) })
                        : .unpinned,
                    onSelect: selectSession,
                    renaming: true,
                    onRenameBegin: { renamingSessionId = session.id },
                    onRenameEnd: { title in
                        renamingSessionId = nil
                        if let title { renameSession(session.id, title) }
                    }
                )
            } else {
                ShellConversationRow(
                    session: session,
                    openingLines: appModel.engine.transcripts.openingLines,
                    selected: session.id == appModel.activeChatSessionId,
                    isPinned: isPinned,
                    onTogglePin: {
                        if isPinned { unpinSession(session.id) } else { pinSession(session.id, selectAfterPin: false) }
                    }
                )
            }
        }
        .overlay(alignment: .leading) {
            if MacChatUnreadSessions.shared.ids.contains(session.id) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .offset(x: -7)
                    .accessibilityLabel("Unread messages")
            }
        }
        .overlay {
            if !renaming {
                SessionDragSource(sessionId: session.id, sessionTitle: session.displayTitle)
            }
        }
        .contextMenu {
            if isPinned {
                Button("Unpin Tab", systemImage: "pin.slash") { unpinSession(session.id) }
            } else {
                Button("Pin as Tab", systemImage: "pin") {
                    pinSession(session.id, selectAfterPin: false)
                }
            }
            Button("Rename Chat", systemImage: "pencil") {
                renamingSessionId = session.id
            }
            Divider()
            detachedSessionMenu(sessionID: session.id)
        }
        .listRowBackground(quietOffscreenRead && session.id == appModel.activeChatSessionId
            ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .padding(.horizontal, 10)
            : nil)
        .help("\(ChatShellConversationRow.title(for: session))\n\nRight-click to rename, pin, or detach")
        .id(ChatSidebarSessionRowIdentity(sessionID: session.id, pinned: isPinned))
    }

    // MARK: - The room's felt state

    /// Only approvals waiting on the owner's decision spend the teal.
    var shellHasPendingApproval: Bool {
        !WorkOverviewRead.waitingApprovals(appModel.engine.approvals.records).isEmpty
    }

    /// True when her last turn came apart. Derived from the transcript that is
    /// already loaded — no retry counter to go stale.
    var shellHasTrouble: Bool {
        ChatShellTroubleState.consecutiveFailures(appModel.chatMessages) > 0
    }

    var shellStatus: ChatShellStatus {
        .make(
            hasPendingApproval: shellHasPendingApproval,
            hasTrouble: shellHasTrouble
        )
    }

    /// One placeholder; the trouble card reports failures without promising queued work.
    var shellComposerPlaceholder: String {
        // The observed agent name keeps the composer placeholder current.
        ChatShellCopy.composerPlaceholder(agentName: appModel.agentAddressName)
    }
}

// MARK: - Transcript viewport motion
//
// These live outside the body because the viewport's ZStack is already at the
// type-checker's limit; each one is a one-liner the compiler can chew alone.
extension ChatView {
    /// Change blindness: a bubble that enters below the fold is motion nobody
    /// sees. Scrolled up, the arrival is instant and the "Latest" pill leads.
    var animatesMessageArrival: Bool { scrollCoordinator.autoFollow }

    var latestPillAnimation: Animation? {
        NativeAgentMotion.respecting(NativeAgentMotion.spring, reduceMotion: reduceMotion)
    }

    var latestPillTransition: AnyTransition {
        NativeAgentMotion.reveal(reduceMotion: reduceMotion, anchor: .bottom)
    }

    /// The transcript itself. Lifted out of the viewport body for the same
    /// type-checker reason as the pill below it.
    var transcriptList: some View {
        ChatMessageListView(
            messages: appModel.chatMessages,
            sessionId: appModel.activeChatSessionId,
            isStreaming: appModel.isBusy && appModel.isChatStreaming,
            highlightedMessageID: showTranscriptSearch ? transcriptSearch.selectedMessageID : nil,
            animatesArrival: animatesMessageArrival,
            latestRequest: transcriptLatestRequest,
            onPagedBackChange: { [scrollCoordinator] in scrollCoordinator.transcriptPagedBack = $0 }
        )
        .safeAreaInset(edge: .top) {
            if case .unavailable(let reason) = appModel.engine.transcripts.transcriptReadStatus(for: appModel.activeChatSessionId) {
                Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .environment(\.inlineCardAction) { [inlineCards, appModel] card, action in
            inlineCards.handle(card: card, action: action, appModel: appModel)
        }
    }

    /// The pill that says there is something below the fold. It enters on
    /// `.snappy` and its glyph bounces once per arriving message — the whole
    /// point being that the arrival itself is off-screen.
    var latestPillOverlay: some View {
        ChatLatestPillGate(coordinator: scrollCoordinator, animation: latestPillAnimation) {
            Button {
                transcriptLatestRequest &+= 1
            } label: {
                latestPillLabel
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    // A quiet screenshot takes the opaque pill, as the
                    // composer does: tinted glass blanks the capture.
                    .background {
                        if reduceTransparency || quietOffscreenRead { Capsule().fill(NativeAgentShell.room) }
                    }
                    .glassEffect(reduceTransparency || quietOffscreenRead ? .identity : HouseGlass.plate.interactive(), in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("chat.latest")
            .accessibilityLabel("Jump to latest message")
            .padding(.horizontal, 18)
            .padding(.top, 18)
            // The modifier observes card clearance so growth re-lays out only this pill.
            .modifier(ChatTurnCardClearancePadding(
                store: turnCardClearanceStore,
                idle: 18
            ))
            .transition(latestPillTransition)
        }
    }

    /// One bounce per arriving message, so the eye is led to what it cannot
    /// see. Under Reduce Motion the value never changes and it never bounces.
    var latestPillLabel: some View {
        Label("Latest", systemImage: "arrow.down.circle.fill")
            .font(NativeAgentFont.tag)
            .symbolEffect(
                .bounce,
                options: .nonRepeating,
                value: reduceMotion ? 0 : appModel.chatMessages.count
            )
    }
}

/// Reads the follow state in its own body, so the reader crossing the bottom
/// re-renders the pill and not ChatView.
struct ChatLatestPillGate<Pill: View>: View {
    let coordinator: ChatScrollFollow
    let animation: Animation?
    @ViewBuilder let pill: () -> Pill

    var body: some View {
        let shows = ChatViewportPresentation.shouldShowLatestPill(
            autoFollow: coordinator.autoFollow, atBottom: coordinator.atBottom,
            pagedBack: coordinator.transcriptPagedBack)
        ZStack(alignment: .bottomTrailing) {
            if shows { pill() }
        }
        .animation(animation, value: shows)
    }
}

/// Kept as its own mounted control so the durable archive route can be hosted
/// without starting ChatView's unrelated provider, voice, and file-watch work.
struct ChatSidebarArchiveButton: View {
    @Environment(AppModel.self) private var appModel
    var shell = false
    @State private var failure: String?
    @State private var isArchiving = false

    var body: some View {
        Button {
            isArchiving = true
            Task {
                let result = await appModel.archiveActiveChat()
                if !result.succeeded { failure = result.userMessage }
                isArchiving = false
            }
        } label: {
            if shell {
                Text("Archive")
                    .font(ShellType.labelSemibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                Image(systemName: "archivebox")
            }
        }
        .buttonStyle(.borderless)
        .disabled(appModel.activeChatSessionId.isEmpty || isArchiving)
        .help("Archive active chat")
        .accessibilityLabel("Archive active chat")
        .alert("Couldn’t archive conversation", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "The conversation was not archived.")
        }
    }
}
