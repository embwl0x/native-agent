import AppToolRuntime
import ChatSessionWork
import NativeAgentCore
import SwiftUI
import AppKit
import NativeAgentShared
import PersistenceCore
import Desk
import StandingBots
import DreamREMCycle
import MemoryV2

// Blueprint: | `CommandPalette.swift` | `CommandPaletteView`: keyboard navigation/search across pages, sessions and saved items; coordinator owns navigation and canonical owners supply actions |

// PATCH-2026-06-06: command-palette — Cmd+K modal that lets the user jump to any
// sidebar tab, any chat session, or any well-known recent action without
// touching the mouse. ContentView owns the sheet binding and the sidebar
// selection (@SceneStorage("selection")); the palette commits a navigation
// through NativeAgentAppCoordinator for navigation, and by calling AppModel
// directly only for the selected chat-session or explicit refresh action.

/// A single match row in the command palette.
struct PaletteItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let kind: Kind
    /// Matched after the title and subtitle, never shown: a memory's whole
    /// text, a tab's stored key.
    let searchText: String?
    let normalizedTitle: String
    let normalizedSubtitle: String
    let normalizedSearch: String

    init(id: String, title: String, subtitle: String?, systemImage: String, kind: Kind, searchText: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.kind = kind
        self.searchText = searchText
        normalizedTitle = title.lowercased()
        normalizedSubtitle = (subtitle ?? "").lowercased()
        normalizedSearch = (searchText ?? "").lowercased()
    }

    enum Kind: Hashable, Sendable {
        case tab(SidebarItem)
        case railTab(SidebarItem, String)  // rail page, tab key
        case setting(String, tab: String?) // registry page id, the tab it is on
        case chatSession(String)         // chat session id
        case recentAction(String)        // recent-action id
        case deskItem(String)            // desk handle — active OR done
        case bot(String)                 // bot id, found by what a run said
        case dream(String)               // diary date key
        case memory(String)              // memory id
    }
}

extension PaletteItem {
    /// A live Desk row, as the Desk page hands it in.
    init(desk row: DeskPaletteRow) {
        self.init(
            id: "desk.\(row.handle)",
            title: row.title,
            subtitle: "\(row.alias) · \(row.status) · \(row.project)",
            systemImage: "tray.full",
            kind: .deskItem(row.handle)
        )
    }
}

/// What the Desk page adds when ⌘K opens there: its live rows, the row
/// already selected, and its three verbs. A leading
/// close / defer / note turns the field into a Desk command; anything else is
/// the ordinary app-wide search with the Desk's rows in it.
struct DeskPaletteScope {
    let rows: [DeskPaletteRow]
    let selectedHandle: String?
    let onSelect: (String) -> Void
    let onCommand: (DeskPaletteQuery.Verb, String) -> Void
}

/// Resolves the one row a Desk command names in its banner and hands to Enter.
enum DeskPalettePresentation {
    static func target(
        rows: [DeskPaletteRow],
        matches: [DeskPaletteRow],
        selectedHandle: String?,
        parsed: DeskPaletteQuery,
        highlighted: Int
    ) -> DeskPaletteRow? {
        if parsed.verb != nil, parsed.query.isEmpty {
            return rows.first { $0.handle == selectedHandle }
        }
        guard !matches.isEmpty else { return nil }
        return matches[min(max(highlighted, 0), matches.count - 1)]
    }

    /// Says out loud what Enter is about to do. A palette that mutates on
    /// Enter without naming the mutation is how a stray keystroke closes an item.
    static func bannerText(
        for verb: DeskPaletteQuery.Verb,
        target: DeskPaletteRow?,
        query: String
    ) -> String {
        guard let target else {
            return query.isEmpty
                ? "\(verb.actionLabel) — nothing selected yet; type part of an item's title."
                : "\(verb.actionLabel) — no item matches \u{201C}\(query)\u{201D}."
        }
        switch verb {
        case .close: return "Enter closes \u{201C}\(target.title)\u{201D}."
        case .deferItem: return "Enter selects \u{201C}\(target.title)\u{201D} and opens the park menu."
        case .note: return "Enter selects \u{201C}\(target.title)\u{201D} and opens the note field."
        }
    }
}

enum CommandPaletteRecentAction: String, CaseIterable, Sendable {
    case newChat = "new_chat"
    case refreshActivity = "refresh_activity"
    case reloadAll = "reload_all"

    var presentation: (title: String, subtitle: String, systemImage: String) {
        switch self {
        case .newChat:
            ("New chat session", "Start a fresh chat", "plus.bubble")
        case .refreshActivity:
            ("Refresh Today", "Reload approvals, Inbox, and proposals", "arrow.clockwise")
        case .reloadAll:
            ("Refresh everything", "Read every page again", "arrow.triangle.2.circlepath")
        }
    }
}

/// The visible, deterministic projection behind Cmd+K. Keeping this separate
/// from the sheet lets every presentation state use the same exact pool and
/// ranking rules the user interacts with.
enum CommandPalettePresentation {
    /// `confirmed` are rows already matched elsewhere (a chat's words, found
    /// by the message index): listed after the pool's matches, never
    /// re-matched against what they display.
    static func filteredItems(pool: [PaletteItem], query: String, confirmed: [PaletteItem], rail: [SidebarItem]) -> [PaletteItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanQuery.isEmpty else {
            return Array(pool.filter {
                if case .tab(let item) = $0.kind { return rail.contains(item) }
                return false
            }.prefix(8))
        }

        let scored: [(PaletteItem, Int, Int)] = pool.enumerated().compactMap { index, item in
            let title = item.normalizedTitle
            let subtitle = item.normalizedSubtitle
            if title == cleanQuery { return (item, 0, index) }
            if title.hasPrefix(cleanQuery) { return (item, 1, index) }
            if subtitle.hasPrefix(cleanQuery) { return (item, 2, index) }
            if title.contains(cleanQuery) { return (item, 3, index) }
            if subtitle.contains(cleanQuery) { return (item, 4, index) }
            if item.normalizedSearch.contains(cleanQuery) { return (item, 5, index) }
            return nil
        }
        // A chat its title already found is not listed again for its words.
        var chats = Set<String>()
        return (scored.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }.map(\.0) + confirmed).filter { item in
            guard case .chatSession(let id) = item.kind else { return true }
            return chats.insert(id).inserted
        }
    }

    /// The rail top to bottom, in its own words — the Navigate menu's order.
    @MainActor static func railItems(_ layout: SurfaceLayout) -> [SidebarItem] {
        SidebarItem.rail(layout).compactMap { $0 }
    }

    @MainActor
    static func itemPool(
        layout: SurfaceLayout,
        sessions: [ChatSession],
        settings: [PaletteItem] = [],
        saved: [PaletteItem] = []
    ) -> [PaletteItem] {
        let rail = railItems(layout)
        let pages = rail.map { item in
            PaletteItem(id: "tab.\(item.rawValue)", title: item.shellRailTitle, subtitle: nil,
                        systemImage: item.systemImage, kind: .tab(item))
        }
        // Every tab, under the rail page that holds it; a page's first tab
        // shares its name and is the page row above.
        let tabs = ShellRailTab.all(layout).flatMap { page, tabs in
            tabs.filter { $0.title != page.shellRailTitle }.map { tab in
                PaletteItem(id: "railtab.\(page.rawValue).\(tab.key)", title: tab.title,
                            subtitle: page.shellRailTitle, systemImage: page.systemImage,
                            kind: .railTab(page, tab.key), searchText: tab.key)
            }
        }
        let chats = visibleSessions(sessions).map { session in
            let title = ChatShellConversationRow.title(for: session)
            let preview = ChatShellConversationRow.preview(for: session)
            return PaletteItem(
                id: "chat.\(session.id)",
                title: title,
                subtitle: preview.isEmpty ? "Chat session" : preview,
                systemImage: "bubble.left.and.bubble.right",
                kind: .chatSession(session.id)
            )
        }
        // Destinations and chats rank first on an equal match; the saved things
        // sit behind them, so ⌘K still opens a page when that is what was typed.
        return pages + tabs + settings + chats + saved + CommandPaletteRecentAction.allCases.map { action in
            let presentation = action.presentation
            return PaletteItem(
                id: "action.\(action.rawValue)",
                title: presentation.title,
                subtitle: presentation.subtitle,
                systemImage: presentation.systemImage,
                kind: .recentAction(action.rawValue)
            )
        }
    }

    static func visibleSessions(_ sessions: [ChatSession]) -> [ChatSession] {
        let ordered = sessions
            .filter { $0.archived != true }
            .sorted {
                let lhsRecency = $0.updatedAt ?? $0.createdAt
                let rhsRecency = $1.updatedAt ?? $1.createdAt
                if lhsRecency != rhsRecency { return lhsRecency > rhsRecency }
                return $0.id < $1.id
            }
        var ids = Set<String>()
        return ordered.filter { ids.insert($0.id).inserted }
    }

    /// Every control in the settings registry, by its label, opening the
    /// page it is on. Read once per opening.
    @MainActor
    static func settingItems(appModel: AppModel) -> [PaletteItem] {
        QuietSettings.all(host: AppQuietSettingsHost(appModel)).map { row in
            PaletteItem(id: "setting.\(row.id)", title: row.label,
                        subtitle: QuietPages.page(named: row.page)?.title ?? row.page,
                        systemImage: "slider.horizontal.3", kind: .setting(row.page, tab: row.tab))
        }
    }
}


/// Search rows derived from the engine's current Desk and diary revisions.
/// Bot replies and the full memory listing use their existing checked readers.
enum CommandPaletteSavedThings {
    @MainActor
    static func shared(engine: NativeAgentEngine) -> [PaletteItem] {
        deskItems(Array(engine.desk.board.items.sorted { $0.updatedAt > $1.updatedAt }.prefix(40)))
            + dreams(Array((engine.cognitionView.diary?.entries ?? []).prefix(40)))
            + botReplies(engine.transcripts.savedBotReplies)
            + memoryItems(engine.transcripts.savedMemories)
    }

    private static func firstLine(_ text: String, limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" } ?? ""
        return TodayWords.line(line, limit: limit)
    }

    private static func deskItems(_ items: [DeskItem]) -> [PaletteItem] {
        items.map { item in
            let done = item.status.isTerminal
            let where_ = done ? "Done" : "On the desk"
            let detail = TodayWords.line(item.summary ?? item.project, limit: 90)
            return PaletteItem(
                id: "desk.\(item.handle)",
                title: TodayWords.line(item.title, limit: 90),
                subtitle: detail.isEmpty ? where_ : "\(where_) · \(detail)",
                systemImage: done ? "checkmark.circle" : "tray.full",
                kind: .deskItem(item.handle)
            )
        }
    }

    private static func botReplies(_ replies: [(BotsShelfRecord, ShelfEntry)]) -> [PaletteItem] {
        replies.map { record, entry in
            let said = entry.headline.isEmpty ? firstLine(entry.actualReply) : TodayWords.line(entry.headline, limit: 90)
            return PaletteItem(
                id: "bot.\(entry.id.uuidString)",
                title: said,
                subtitle: "\(record.definition.name) · \(BotsShelfRecord.shortDate(entry.runAt))",
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                kind: .bot(record.id.uuidString)
            )
        }
    }

    private static func dreams(_ entries: [DreamEntry]) -> [PaletteItem] {
        entries.map { entry in
            let excerpt = firstLine(entry.content ?? "")
            return PaletteItem(
                id: "dream.\(entry.date)",
                title: excerpt.isEmpty ? "Dream · \(entry.date)" : excerpt,
                subtitle: "Dream · \(entry.date)",
                systemImage: "moon.stars",
                kind: .dream(entry.date)
            )
        }
    }

    /// Every memory, not a newest slice; its whole text is searched.
    private static func memoryItems(_ memories: [MemoryV2.MemoryRecord]) -> [PaletteItem] {
        memories.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            .map { record in
                PaletteItem(
                    id: "memory.\(record.id)",
                    title: firstLine(record.text),
                    subtitle: "Memory · \(record.layer ?? "")",
                    systemImage: "brain",
                    kind: .memory(record.id),
                    searchText: record.text
                )
            }
    }
}

/// The one ⌘K palette. ContentView presents it everywhere except the Desk,
/// which presents the same view with its `DeskPaletteScope`.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    var desk: DeskPaletteScope? = nil

    @State private var query: String = ""
    @State private var selection: Int = 0
    private var savedThings: [PaletteItem] {
        CommandPaletteSavedThings.shared(engine: appModel.engine)
    }
    /// The settings registry's controls — read once per opening.
    @State private var settingThings: [PaletteItem] = []
    /// Conversations whose words hold the query, from the message index.
    @State private var messageHits: [PaletteItem] = []
    /// The query `messageHits` answer; another query shows none of them.
    @State private var messageHitsQuery = ""
    @State private var messagesIndexed = false
    @State private var indexRevision: UInt64 = 0
    private struct IndexRequest: Equatable {
        var sessions: [ChatSession]
        var revision: UInt64
    }
    private var indexRequest: IndexRequest {
        IndexRequest(sessions: appModel.engine.transcripts.sessions,
                     revision: appModel.engine.transcripts.structureVersion)
    }
    /// Conversations the current index could not read.
    @State private var unreadChats = 0
    @State private var indexRead = LatestRead()
    @State private var matchesRead = LatestRead()
    @State private var hitsRead = LatestRead()
    private struct MatchRequest: Equatable, Sendable {
        let pool: [PaletteItem]
        let query: String
        let confirmed: [PaletteItem]
        let rail: [SidebarItem]
    }
    @State private var matchedRequest: MatchRequest?
    @State private var matches: [PaletteItem] = []
    @State private var pendingCommit = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(desk == nil ? "Jump to anything…" : "Find anything — or type close, defer or note", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { commitCurrent() }
                    .onChange(of: query) { _, _ in
                        // Reset highlight whenever the query changes so the
                        // top match is always the default.
                        selection = 0
                        pendingCommit = false
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        // Re-focus the field; the cleared button disappears
                        // and the responder would otherwise drift.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 10_000_000)
                            fieldFocused = true
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if let desk, let verb = DeskPaletteQuery.parse(query).verb {
                Text(DeskPalettePresentation.bannerText(
                    for: verb, target: deskTarget(desk), query: DeskPaletteQuery.parse(query).query))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }

            if let error = appModel.engine.transcripts.savedSearchError ?? appModel.engine.cognitionView.diaryError ?? appModel.engine.desk.board.deskError {
                Text(error).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            let items = filteredItems()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                // Row identity must be the ITEM id, never the index:
                                // an explicit .id(index) collides across filter
                                // changes (old row 0 vs new row 0), and LazyVStack
                                // then reuses the dead subtree — stale title AND
                                // stale tap closure (observed: "trust" rendering the
                                // old Chat row, tap navigating to Chat).
                                paletteRow(item: item, isSelected: index == selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selection = index
                                        commit(item)
                                    }
                                    .onContinuousHover { phase in
                                        // A filtered row can materialize beneath a
                                        // stationary pointer while the user types.
                                        // Treat only real pointer movement as hover
                                        // navigation so Return still opens the top
                                        // keyboard match.
                                        if commandPaletteShouldAdoptHover(
                                            phase.isActive,
                                            eventType: NSApp.currentEvent?.type
                                        ) {
                                            selection = index
                                        }
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, new in
                        guard new >= 0, new < items.count else { return }
                        withAnimation(NativeAgentMotion.quick) {
                            proxy.scrollTo(items[new].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                paletteHint(symbol: "arrow.up.arrow.down", label: "Navigate")
                paletteHint(symbol: "return", label: "Open")
                paletteHint(symbol: "escape", label: "Close")
                Spacer()
                Text("\(items.count) result\(items.count == 1 ? "" : "s")"
                     + (unreadChats > 0 ? " · \(unreadChats) chat\(unreadChats == 1 ? "" : "s") could not be searched" : ""))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 560)
        .houseSheet()
        .background(KeyCatcher(
            onMoveUp: { moveSelection(-1) },
            onMoveDown: { moveSelection(1) },
            onEscape: { isPresented = false }
        ))
        .onAppear {
            selection = 0
            // SwiftUI sheet presentation animation can swallow a synchronous
            // @FocusState assignment on first present, leaving the palette
            // open but un-typeable. Defer one run-loop tick so the responder
            // chain lands after the window is on screen.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                fieldFocused = true
            }
        }
        .task {
            settingThings = CommandPalettePresentation.settingItems(appModel: appModel)
            _ = await appModel.engine.desk.loadBoard()
            await appModel.engine.cognitionView.refreshDiary()
        }
        .task {
            await appModel.engine.transcripts.observeSavedSearch(bots: appModel.engine.bots, memory: appModel.engine.memory)
        }
        .task(id: indexRequest) {
            let transcripts = appModel.engine.transcripts
            let sessions = CommandPalettePresentation.visibleSessions(transcripts.sessions)
                .map { (id: $0.id, stamp: CommandPaletteMessageIndex.stamp($0)
                        + "|\(transcripts.structureVersion(for: $0.id))") }
            _ = await indexRead.read({ await transcripts.messageIndex.refresh(sessions, transcripts: transcripts) }, publish: { unread in
                unreadChats = unread
                messagesIndexed = true
                indexRevision &+= 1
            })
            guard !Task.isCancelled else { return }
            try? await ChatShellOpeningLine.shared.prepare(transcripts.sessions, dataRoot: transcripts.dataRoot)
        }
        .task(id: matchRequest) {
            let request = matchRequest
            _ = await matchesRead.read({
            await Task.detached(priority: .userInitiated) {
                CommandPalettePresentation.filteredItems(pool: request.pool, query: request.query,
                                                         confirmed: request.confirmed, rail: request.rail)
            }.value
            }, publish: { result in
            matches = result
            matchedRequest = request
            if pendingCommit { pendingCommit = false; commitCurrent() }
            })
        }
        // The words of every chat, searched a beat after typing stops.
        .task(id: "\(messagesIndexed) \(indexRevision) \(query)") {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard messagesIndexed, text.count >= 3 else { hitsRead.write { messageHits = [] }; return }
            _ = await hitsRead.read({
            try? await Task.sleep(for: .milliseconds(150))
            let hits = await appModel.engine.transcripts.messageIndex.search(text)
            let sessions = appModel.engine.transcripts.sessions
            return hits.compactMap { hit -> PaletteItem? in
                guard let session = sessions.first(where: { $0.id == hit.sessionID }) else { return nil }
                return PaletteItem(id: "message.\(hit.sessionID)", title: ChatShellConversationRow.title(for: session),
                                   subtitle: hit.snippet, systemImage: "text.bubble", kind: .chatSession(hit.sessionID))
            }
            }, publish: { hits in
                messageHitsQuery = text
                messageHits = hits
            })
        }
    }

    // MARK: - Rows

    // The shell's row: the soft fill marks the highlighted row, the kind is a
    // quiet word at the trailing edge.
    @ViewBuilder
    private func paletteRow(item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 22)
                .foregroundStyle(NativeAgentShell.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(kindLabel(item))
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .fill(isSelected ? NativeAgentShell.softFill : Color.clear)
                .padding(.horizontal, 4)
        )
    }

    private func kindLabel(_ item: PaletteItem) -> String {
        switch item.kind {
        case .tab: return "Page"
        case .railTab: return "Tab"
        case .setting: return "Setting"
        case .chatSession: return "Chat"
        case .recentAction: return "Action"
        case .deskItem(let handle):
            return handle == desk?.selectedHandle ? "Selected" : "Desk"
        case .bot: return "Bot"
        case .dream: return "Dream"
        case .memory: return "Memory"
        }
    }

    @ViewBuilder
    private func paletteHint(symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(label)
        }
        .font(ShellType.caption)
        .foregroundStyle(NativeAgentShell.secondary)
    }

    // MARK: - Filtering / ranking

    private func filteredItems() -> [PaletteItem] {
        let general = matchedRequest == matchRequest ? matches : []
        guard let desk else {
            return general
        }
        let parsed = DeskPaletteQuery.parse(query)
        // A verb narrows the list to the rows it can act on; an empty field
        // opens on the Desk's own rows.
        let rows = deskMatches(desk, parsed).map(PaletteItem.init(desk:))
        if parsed.verb != nil || parsed.query.isEmpty { return rows }
        // A plain search: the Desk's rows fuzzy-matched first, as the Desk
        // ranks them, then everything else — including the saved Desk entries,
        // so an item's summary still finds it.
        let shown = Set(rows.map(\.id))
        return rows + general
            .filter { !shown.contains($0.id) }
    }

    private var currentMessageHits: [PaletteItem] {
        messageHitsQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) ? messageHits : []
    }

    private func itemPool() -> [PaletteItem] {
        CommandPalettePresentation.itemPool(
            layout: appModel.engine.layout.layout,
            sessions: appModel.engine.transcripts.sessions,
            settings: settingThings,
            saved: savedThings
        )
    }

    private var matchRequest: MatchRequest {
        MatchRequest(pool: itemPool(), query: query, confirmed: currentMessageHits,
                     rail: CommandPalettePresentation.railItems(appModel.engine.layout.layout))
    }

    private func deskMatches(_ desk: DeskPaletteScope, _ parsed: DeskPaletteQuery) -> [DeskPaletteRow] {
        DeskFuzzy.filter(desk.rows, query: parsed.query)
    }

    /// The row a Desk command applies to: the selected row when only the verb
    /// is typed, otherwise the highlighted match.
    private func deskTarget(_ desk: DeskPaletteScope) -> DeskPaletteRow? {
        let parsed = DeskPaletteQuery.parse(query)
        return DeskPalettePresentation.target(
            rows: desk.rows,
            matches: deskMatches(desk, parsed),
            selectedHandle: desk.selectedHandle,
            parsed: parsed,
            highlighted: selection
        )
    }

    // MARK: - Commit / navigation

    private func moveSelection(_ delta: Int) {
        let items = filteredItems()
        guard !items.isEmpty else { return }
        let next = (selection + delta).clamped(to: 0...(items.count - 1))
        selection = next
    }

    private func commitCurrent() {
        // A Desk command applies to the row its banner names; with nothing
        // named the sheet stays open so the query can be corrected.
        if let desk, DeskPaletteQuery.parse(query).verb != nil {
            guard let target = deskTarget(desk) else { return }
            commit(PaletteItem(desk: target))
            return
        }
        let items = filteredItems()
        if items.isEmpty, matchedRequest != matchRequest { pendingCommit = true; return }
        guard !items.isEmpty else { return }
        let idx = max(0, min(selection, items.count - 1))
        commit(items[idx])
    }

    private func commit(_ item: PaletteItem) {
        if let desk, case .deskItem(let handle) = item.kind,
           desk.rows.contains(where: { $0.handle == handle }) {
            isPresented = false
            if let verb = DeskPaletteQuery.parse(query).verb {
                desk.onCommand(verb, handle)
            } else {
                desk.onSelect(handle)
            }
            return
        }
        switch item.kind {
        case .tab(let s):
            NativeAgentAppCoordinator.shared.request(.sidebar(s.normalized))
        case .railTab(let page, let key):
            // A route lands on the page's first tab; Settings' own links
            // choose the tab after it, and so does this.
            SettingsLink.open(page, tab: key)
        case .setting(let pageID, let tab):
            // The page the control is on, on the tab it is on.
            if let page = QuietPages.page(named: pageID) {
                let home = SidebarItem.shellHome(for: page.item)
                SettingsLink.open(home?.parent ?? page.item, tab: tab ?? page.tab ?? home?.tab)
            }
        case .chatSession(let sid):
            if let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sid }) {
                Task { await appModel.selectChatSession(session) }
            }
            NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        case .recentAction(let id):
            handleRecentAction(id)
        case .deskItem(let handle):
            // The same handle a Desk notification click hands the page, so the
            // row is scrolled to and opened rather than merely on screen.
            appModel.pendingDeskHandle = handle
            NativeAgentAppCoordinator.shared.request(.sidebar(.desk))
        case .bot:
            NativeAgentAppCoordinator.shared.request(.sidebar(.bots))
        case .dream:
            NativeAgentAppCoordinator.shared.request(.sidebar(.dreams))
        case .memory:
            NativeAgentAppCoordinator.shared.request(.sidebar(.memories))
        }
        isPresented = false
    }

    private func handleRecentAction(_ id: String) {
        guard let action = CommandPaletteRecentAction(rawValue: id) else { return }
        switch action {
        case .newChat:
            Task { await appModel.newChatSession() }
            NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        case .refreshActivity:
            Task { await appModel.refreshForSidebarItem(.activity) }
            NativeAgentAppCoordinator.shared.request(.sidebar(.activity))
        case .reloadAll:
            Task { await appModel.refreshAll() }
        }
    }

}

/// True when a key event carries no USER-HELD modifiers — Cmd/Opt/Shift/Ctrl
/// combos must pass through to the field for text navigation. Arrow keys
/// always carry `.function` and `.numericPad` by hardware convention (Escape
/// carries `.function` on many keyboards), so those two flags are ignored;
/// comparing the raw device-independent mask against "empty" rejects every
/// arrow press ever made.
func commandPaletteIsBareKeyEvent(_ flags: NSEvent.ModifierFlags) -> Bool {
    flags.intersection(.deviceIndependentFlagsMask)
        .subtracting([.function, .numericPad])
        .isEmpty
}

/// The executable contract for the palette's AppKit key monitor. Keeping the
/// routing and monitor lifecycle here prevents a local event hook from either
/// consuming keys belonging to another window or lingering after its view is
/// removed.
enum CommandPaletteKeyCatcherMonitor {
    enum KeyAction: Equatable {
        case passThrough
        case moveUp
        case moveDown
        case dismiss
    }

    enum LifecycleAction: Equatable {
        case none
        case install
        case uninstall
    }

    static func lifecycleAction(
        isAttachedToWindow: Bool,
        hasMonitor: Bool
    ) -> LifecycleAction {
        switch (isAttachedToWindow, hasMonitor) {
        case (true, false): return .install
        case (false, true): return .uninstall
        default: return .none
        }
    }

    static func action(
        eventBelongsToPaletteWindow: Bool,
        paletteWindowIsKey: Bool,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> KeyAction {
        guard eventBelongsToPaletteWindow,
              paletteWindowIsKey,
              commandPaletteIsBareKeyEvent(modifierFlags) else {
            return .passThrough
        }
        switch keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 53: return .dismiss
        default: return .passThrough
        }
    }
}

@MainActor
func commandPaletteShouldAdoptHover(
    _ hovering: Bool,
    eventType: NSEvent.EventType?
) -> Bool {
    guard hovering else { return false }
    switch eventType {
    case .mouseMoved, .leftMouseDragged:
        return true
    default:
        return false
    }
}

private extension HoverPhase {
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Arrow / escape key catcher
// SwiftUI doesn't surface up/down arrow events from a focused TextField, so
// we use an NSViewRepresentable that observes local key events while the
// view is in the window.

private struct KeyCatcher: NSViewRepresentable {
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onMoveUp = onMoveUp
        nsView.onMoveDown = onMoveDown
        nsView.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: KeyCatcherView, coordinator: ()) {
        // Deterministic teardown — don't rely on viewDidMoveToWindow(nil)
        // or deinit timing to drop the global key monitor.
        nsView.dismantle()
    }
}

final class KeyCatcherView: NSView {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        switch CommandPaletteKeyCatcherMonitor.lifecycleAction(
            isAttachedToWindow: window != nil,
            hasMonitor: monitor != nil
        ) {
        case .install:
            install()
        case .uninstall:
            uninstall()
        case .none:
            break
        }
    }

    func dismantle() {
        uninstall()
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Scope strictly to the palette's own window so we never swallow
            // arrows/escape in another NativeAgent window (or after the sheet
            // has visually dismissed but a stray monitor is still alive).
            let paletteWindow = self.window
            switch CommandPaletteKeyCatcherMonitor.action(
                eventBelongsToPaletteWindow: event.window === paletteWindow,
                paletteWindowIsKey: paletteWindow?.isKeyWindow == true,
                modifierFlags: event.modifierFlags,
                keyCode: event.keyCode
            ) {
            case .moveUp:
                self.onMoveUp?()
                return nil
            case .moveDown:
                self.onMoveDown?()
                return nil
            case .dismiss:
                self.onEscape?()
                return nil
            case .passThrough:
                return event
            }
        }
    }

    private func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // Note: no deinit fallback — Swift 6 forbids touching the non-Sendable
    // monitor handle from a nonisolated deinit. The two deterministic
    // teardown paths (dismantleNSView from NSViewRepresentable and
    // viewDidMoveToWindow(nil)) both run on the main thread and call
    // uninstall() directly, so we never rely on deinit to drop the monitor.
}
