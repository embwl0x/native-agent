import EngineRuntime
import AppToolRuntime
import ChatSessionWork
import NativeAgentCore
import SwiftUI
import NativeAgentShared
import Desk
import StandingBots
import DreamREMCycle
import MemoryV2
import Foundation
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ToolExecution
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import TrustCenter
import MultimodalTTS
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import ApprovalInbox
import AppKit
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
// Blueprint: | `CommandPaletteInventory.swift` | Palette item inventory, saved-owner projections and deterministic search ranking |

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
