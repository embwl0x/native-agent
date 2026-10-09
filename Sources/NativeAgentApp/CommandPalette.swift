import AppToolRuntime
import NativeAgentCore
import SwiftUI
import AppKit
import NativeAgentShared
import PersistenceCore
import Desk
import StandingBots
import DreamREMCycle
import MemoryV2

// PATCH-2026-06-06: command-palette — Cmd+K modal that lets the user jump to any
// sidebar tab, any chat session, or any well-known recent action without
// touching the mouse. ContentView owns the sheet binding and the sidebar
// selection (@SceneStorage("selection")); the palette commits a navigation
// through NativeAgentAppCoordinator for navigation, and by calling AppModel
// directly only for the selected chat-session or explicit refresh action.

/// A single match row in the command palette.
struct PaletteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let kind: Kind
    /// Matched after the title and subtitle, never shown: a memory's whole
    /// text, a tab's stored key.
    var searchText: String? = nil

    enum Kind: Hashable {
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
            systemImage: row.isActionable ? "tray.full" : "eye",
            kind: .deskItem(row.handle)
        )
    }
}

/// What the Desk page adds when ⌘K opens there: its live rows (GitHub watcher
/// rows included), the row already selected, and its three verbs. A leading
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
            return rows.first { $0.handle == selectedHandle && $0.isActionable }
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
    static func filteredItems(pool: [PaletteItem], query: String, confirmed: [PaletteItem] = []) -> [PaletteItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanQuery.isEmpty else {
            let rail = railItems()
            return Array(pool.filter {
                if case .tab(let item) = $0.kind { return rail.contains(item) }
                return false
            }.prefix(8))
        }

        let scored: [(PaletteItem, Int, Int)] = pool.enumerated().compactMap { index, item in
            let title = item.title.lowercased()
            let subtitle = (item.subtitle ?? "").lowercased()
            if title == cleanQuery { return (item, 0, index) }
            if title.hasPrefix(cleanQuery) { return (item, 1, index) }
            if subtitle.hasPrefix(cleanQuery) { return (item, 2, index) }
            if title.contains(cleanQuery) { return (item, 3, index) }
            if subtitle.contains(cleanQuery) { return (item, 4, index) }
            if item.searchText?.lowercased().contains(cleanQuery) == true { return (item, 5, index) }
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
    static func railItems() -> [SidebarItem] {
        BotsShelfRailProposal.ordered(SidebarItem.primaryItems, enabled: BotsShelfPreference.isEnabled())
    }

    @MainActor
    static func itemPool(
        sessions: [ChatSession],
        settings: [PaletteItem] = [],
        saved: [PaletteItem] = []
    ) -> [PaletteItem] {
        let pages = railItems().map { item in
            PaletteItem(id: "tab.\(item.rawValue)", title: item.shellRailTitle, subtitle: nil,
                        systemImage: item.systemImage, kind: .tab(item))
        }
        // Every tab, under the rail page that holds it; a page's first tab
        // shares its name and is the page row above.
        let tabs = ShellRailTab.all.flatMap { page, tabs in
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

/// Every visible conversation's words, for ⌘K: the text ⌘F searches in the
/// open chat (`MacChatTranscriptSearch`), across all of them. A transcript is
/// read once and again only when its session row moves; held for the app's
/// life, so a second opening searches at once.
actor CommandPaletteMessageIndex {
    static let shared = CommandPaletteMessageIndex()

    struct Hit: Sendable {
        let sessionID: String
        let snippet: String
    }

    private var texts: [String: (stamp: String, lines: [String])] = [:]
    /// Newest conversation first, as the palette lists them.
    private var order: [String] = []

    static func stamp(_ session: ChatSession) -> String {
        "\(session.updatedAt ?? session.createdAt)|\(session.transcriptGeneration ?? -1)|\(session.messageCount ?? -1)"
    }

    /// Reads what changed and returns how many conversations could not be
    /// read. A failed read is not cached: it keeps whatever text it had
    /// before, and is tried again on the next opening.
    func refresh(_ sessions: [(id: String, stamp: String)], transcripts: TranscriptsFacade) async -> Int {
        order = sessions.map(\.id)
        let stale = sessions.filter { texts[$0.id]?.stamp != $0.stamp }
        let read = await withTaskGroup(of: (String, String, [String]?).self) { group in
            for session in stale {
                group.addTask {
                    guard let messages = try? await transcripts.loadMessages(sessionId: session.id) else {
                        return (session.id, session.stamp, nil)
                    }
                    return (session.id, session.stamp, MacChatTranscriptSearch.documents(from: messages).map(\.content))
                }
            }
            return await group.reduce(into: [(String, String, [String]?)]()) { $0.append($1) }
        }
        var unread = 0
        for (id, stamp, lines) in read {
            if let lines { texts[id] = (stamp, lines) } else { unread += 1 }
        }
        let kept = Set(order)
        texts = texts.filter { kept.contains($0.key) }
        return unread
    }

    /// The newest line in each conversation that holds `query`, newest
    /// conversation first, every conversation that has one.
    func search(_ query: String) -> [Hit] {
        var hits: [Hit] = []
        for id in order {
            guard !Task.isCancelled else { break }
            guard let lines = texts[id]?.lines else { continue }
            for line in lines.reversed() {
                guard let range = line.range(of: query, options: .caseInsensitive) else { continue }
                hits.append(Hit(sessionID: id, snippet: Self.snippet(line, around: range)))
                break
            }
        }
        return hits
    }

    /// A line of the message starting a few words before the match.
    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        var start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        if start != text.startIndex, let space = text[start..<range.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        let flat = text[start...].split(whereSeparator: \.isNewline).joined(separator: " ")
        return (start == text.startIndex ? "" : "…") + TodayWords.line(flat, limit: 90)
    }
}

/// The saved things ⌘K can find: Desk items (still open AND finished), what a
/// bot actually said, dreams, and every memory by its words. Read once when
/// the palette opens, through the canonical readers, newest first; the Desk,
/// bot replies and dreams are bounded — finished work recedes, it does not
/// disappear.
enum CommandPaletteSavedThings {
    /// Per bounded source. Enough to reach back weeks; small enough that the
    /// pool stays a list a person can rank in their head.
    static let perSource = 40

    static func load(dataRoot: URL, memories: [MemoryV2.MemoryRecord]) async -> [PaletteItem] {
        var items: [PaletteItem] = []
        items += await deskItems(dataRoot: dataRoot)
        items += await botReplies(dataRoot: dataRoot)
        items += await dreams(dataRoot: dataRoot)
        items += memoryItems(memories)
        return items
    }

    private static func firstLine(_ text: String, limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" } ?? ""
        return TodayWords.line(line, limit: limit)
    }

    private static func deskItems(dataRoot: URL) async -> [PaletteItem] {
        guard let all = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items else { return [] }
        return all.sorted { $0.updatedAt > $1.updatedAt }.prefix(perSource).map { item in
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

    private static func botReplies(dataRoot: URL) async -> [PaletteItem] {
        let records = await Task.detached(priority: .utility) {
            (try? BotsShelfView.readRecords(root: dataRoot)) ?? []
        }.value
        var replies: [(BotsShelfRecord, ShelfEntry)] = []
        for record in records {
            for entry in record.sortedEntries where !entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                replies.append((record, entry))
            }
        }
        return replies.sorted { $0.1.runAt > $1.1.runAt }.prefix(perSource).map { record, entry in
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

    private static func dreams(dataRoot: URL) async -> [PaletteItem] {
        let entries = await Task.detached(priority: .utility) {
            FileBackedDreamDiary(dataRoot: dataRoot).listEntries(limit: perSource)
        }.value
        return entries.map { entry in
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
    /// Desk items, bot replies, dreams and memories — read once per opening.
    @State private var savedThings: [PaletteItem] = []
    /// The settings registry's controls — read once per opening.
    @State private var settingThings: [PaletteItem] = []
    /// Conversations whose words hold the query, from the message index.
    @State private var messageHits: [PaletteItem] = []
    /// The query `messageHits` answer; another query shows none of them.
    @State private var messageHitsQuery = ""
    @State private var messagesIndexed = false
    /// Conversations the index could not read this opening.
    @State private var unreadChats = 0
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
        // The saved things land behind the field; typing never waits on them.
        .task {
            settingThings = CommandPalettePresentation.settingItems(appModel: appModel)
            savedThings = await CommandPaletteSavedThings.load(
                dataRoot: PersistenceCore.defaultDataRoot(),
                memories: (try? await appModel.engine.memory.activeMemories(limit: nil)) ?? []
            )
            let sessions = CommandPalettePresentation.visibleSessions(appModel.engine.transcripts.sessions)
                .map { (id: $0.id, stamp: CommandPaletteMessageIndex.stamp($0)) }
            unreadChats = await CommandPaletteMessageIndex.shared.refresh(sessions, transcripts: appModel.engine.transcripts)
            messagesIndexed = true
        }
        // The words of every chat, searched a beat after typing stops.
        .task(id: "\(messagesIndexed) \(query)") {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard messagesIndexed, text.count >= 3 else { messageHits = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let hits = await CommandPaletteMessageIndex.shared.search(text)
            guard !Task.isCancelled else { return }
            let sessions = appModel.engine.transcripts.sessions
            messageHitsQuery = text
            messageHits = hits.compactMap { hit in
                guard let session = sessions.first(where: { $0.id == hit.sessionID }) else { return nil }
                return PaletteItem(id: "message.\(hit.sessionID)", title: ChatShellConversationRow.title(for: session),
                                   subtitle: hit.snippet, systemImage: "text.bubble", kind: .chatSession(hit.sessionID))
            }
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
            guard let row = desk?.rows.first(where: { $0.handle == handle }) else { return "Desk" }
            if handle == desk?.selectedHandle { return "Selected" }
            return row.isActionable ? "Desk" : "Watch only"
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
        guard let desk else {
            return CommandPalettePresentation.filteredItems(pool: itemPool(), query: query, confirmed: currentMessageHits)
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
        return rows + CommandPalettePresentation.filteredItems(pool: itemPool(), query: query, confirmed: currentMessageHits)
            .filter { !shown.contains($0.id) }
    }

    private var currentMessageHits: [PaletteItem] {
        messageHitsQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) ? messageHits : []
    }

    private func itemPool() -> [PaletteItem] {
        CommandPalettePresentation.itemPool(
            sessions: appModel.engine.transcripts.sessions,
            settings: settingThings,
            saved: savedThings
        )
    }

    private func deskMatches(_ desk: DeskPaletteScope, _ parsed: DeskPaletteQuery) -> [DeskPaletteRow] {
        DeskFuzzy.filter(parsed.verb == nil ? desk.rows : desk.rows.filter(\.isActionable), query: parsed.query)
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
