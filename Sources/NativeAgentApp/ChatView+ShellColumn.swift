import EngineRuntime
import AppToolRuntime
import ChatSessionWork
import SwiftUI
import Transcripts
import UniformTypeIdentifiers
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ChatView+ShellColumn.swift` | `ChatView`: Conversation sidebar, archive, opening lines and stable row identities |

// Group by recorded kind so presentation cannot recategorize conversations.

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
            // Keep one row per ID so lazy view state cannot alias duplicate sessions.
            unpinned: visible.filter {
                !pinnedIDs.contains($0.id) && seenUnpinned.insert($0.id).inserted
            }
        )
    }
}

/// Cache exact structural inputs independently of streaming text so chunks cannot rebuild the sidebar.
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

/// Remount rows across section changes so their local state cannot follow another conversation.
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

    var shellConversationSections: (rows: [ChatSession], working: [ChatSession], briefs: [ChatSession]) {
        let sections = sidebarProjection
        var rows: [ChatSession] = []
        var working: [ChatSession] = []
        var briefs: [ChatSession] = []
        // Pins may reorder a section without changing recorded conversation kind.
        for session in sections.pinned {
            if ChatShellConversationRow.isWorking(session) { working.append(session) } else { rows.append(session) }
        }
        for session in sections.unpinned {
            let onScreen = session.id == appModel.activeChatSessionId
            if !onScreen, (session.messageCount ?? 0) == 0, !shellSessionHasUnsentWork(session.id) {
                // Keep empty conversations reachable while they contain unsent work.
                continue
            } else if ChatShellConversationRow.isWorking(session) {
                working.append(session)
            } else if onScreen {
                rows.append(session)
            } else if ChatShellConversationRow.isAgentOwn(session, openingLines: appModel.engine.transcripts.openingLines) {
                briefs.append(session)
            } else {
                rows.append(session)
            }
        }
        return (rows, working, briefs)
    }

    /// Unsent text and attachments must keep their conversation reachable.
    func shellSessionHasUnsentWork(_ sessionId: String) -> Bool {
        !appModel.chatDraft(for: sessionId).isEmpty
            || !(appModel.chatPendingAttachments[sessionId] ?? []).isEmpty
    }

    /// Only saved user pins count as pinned; the live anchor must not.
    func shellSessionIsPinned(_ session: ChatSession) -> Bool {
        humanPinnedSessionIds().contains(session.id)
    }

    @ViewBuilder
    func shellConversationsColumn(_ layout: SurfaceLayoutAvailability) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure = layout.failure {
                Text(failure.localizedDescription).font(.caption).textSelection(.enabled)
            }
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

            // Mark retained rows stale when their list refresh fails.
            PanelStaleNoticeView(item: .chat)
            if appModel.chatSessionIndexRefreshFailed {
                StalePanelNotice(
                    text: "The session list could not update, so it is showing the last known sessions."
                )
            }

            // Let native sidebar selection own arrows and collapsible sections.
            let sections = shellConversationSections
            // Draw offscreen selection explicitly because bitmap capture renders the native vibrancy highlight as a black slab.
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
                // Read block order and fold state from the layout owner so the column reflects saved choices.
                ForEach(layout.contentNames("chat", profile: layoutProfile), id: \.self) { block in
                    switch block {
                    case "rows":
                        ForEach(sections.rows) { session in
                            shellSessionRow(session).tag(session.id)
                        }
                    case "briefs" where !sections.briefs.isEmpty:
                        Section(isExpanded: shellFold("briefs", layout: layout)) {
                            ForEach(sections.briefs) { session in
                                shellSessionRow(session).tag(session.id)
                            }
                        } header: {
                            Text("\(ChatShellCopy.briefsRowTitle)  \(sections.briefs.count)")
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    case "working" where !sections.working.isEmpty:
                        // The active conversation must not fold out of sight.
                        Section(isExpanded: shellFold("working", layout: layout,
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
        // Include the gutter in conversation-column measurement so alignment uses its full width.
        .frame(width: NativeAgentShellLayout.conversationsWidth)
        .padding(.top, NativeAgentShellLayout.columnHeaderTopInset)
        .padding(.bottom, 16)
        // Keep the list transparent so it shares the room's sheet.
    }

    /// Persist fold changes as the person's own layout choices.
    func shellFold(_ block: String, layout: SurfaceLayoutAvailability, openWhile forced: Bool = false) -> Binding<Bool> {
        // Without a layout there is no fold state to edit; keep its rows exposed.
        guard case .available(let document) = layout else { return .constant(true) }
        return Binding(get: { forced || document.expanded("chat", block) },
                set: { open in Task { await appModel.engine.setSurfaceExpanded(open, surface: "chat", block: block) } })
    }

    /// Use SessionRow during rename because its single-fire commit owner prevents duplicate state machines from losing edits.
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

    /// Reserve teal for approvals waiting on the user's decision.
    var shellHasPendingApproval: Bool {
        !WorkOverviewRead.waitingApprovals(appModel.engine.approvals.records).isEmpty
    }

    /// Derive failure from the loaded transcript so no duplicate retry counter can go stale.
    var shellHasTrouble: Bool {
        ChatShellTroubleState.consecutiveFailures(appModel.chatMessages) > 0
    }

    var shellStatus: ChatShellStatus {
        .make(
            hasPendingApproval: shellHasPendingApproval,
            hasTrouble: shellHasTrouble
        )
    }

    /// Keep one placeholder; failure cards must not promise queued work.
    var shellComposerPlaceholder: String {
        // Observe the agent's name so the placeholder follows identity changes.
        ChatShellCopy.composerPlaceholder(agentName: appModel.agentAddressName)
    }
}

// MARK: - Transcript viewport motion
// Keep these expressions outside the viewport body because its generic chain is at the type-checker's limit.
extension ChatView {
    var latestPillAnimation: Animation? {
        NativeAgentMotion.respecting(NativeAgentMotion.spring, reduceMotion: reduceMotion)
    }

    var latestPillTransition: AnyTransition {
        NativeAgentMotion.reveal(reduceMotion: reduceMotion, anchor: .bottom)
    }

    /// Animate the Latest pill because arriving content itself is offscreen.
    var latestPillOverlay: some View {
        ChatLatestPillGate(handle: transcriptHandle, animation: latestPillAnimation) {
            Button {
                transcriptLatestRequest &+= 1
            } label: {
                latestPillLabel
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    // Use an opaque pill for quiet capture because tinted glass can blank the bitmap.
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
            // Observe clearance in the modifier so only this pill re-lays out when the card grows.
            .modifier(ChatTurnCardClearancePadding(
                store: turnCardClearanceStore,
                idle: 18
            ))
            .transition(latestPillTransition)
        }
    }

    /// Bounce once per arrival to signal unseen content; Reduce Motion keeps the value unchanged.
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

/// Read the at-end signal in the pill's own body so crossing the bottom cannot re-render ChatView.
struct ChatLatestPillGate<Pill: View>: View {
    let handle: TranscriptDocumentHandle
    let animation: Animation?
    @ViewBuilder let pill: () -> Pill

    var body: some View {
        let shows = !handle.isAtEnd
        ZStack(alignment: .bottomTrailing) {
            if shows { pill() }
        }
        .animation(animation, value: shows)
    }
}

/// Mount archive controls independently so hosting the durable route cannot start unrelated chat work.
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
