import BodyRuntime
import NativeAgentCore
import SwiftUI
import NativeAgentShared
import DeskCore
import MindCore
import Foundation
import SenseCore
import PersistenceCore
import ProviderRouting
import MacNerves
import WidgetKit
import AppIntents
import Observation
import AppKit
import UniformTypeIdentifiers
// Blueprint: | `CommandPaletteInventory.swift` | Saved palette destinations, shared inventory and deterministic ranking |

enum PaletteSavedDestination: Hashable, Sendable {
    case botReply(botID: UUID, entryID: UUID)
    case dream(String)
    case memory(String)
}

struct PaletteItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let kind: Kind
    /// Search hidden full text after visible labels so matches need not appear in the row.
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
        case ownPage(String)
        case railTab(SidebarItem, String)
        case setting(String, tab: String?)
        case chatSession(String)
        case recentAction(String)
        case deskItem(String)
        case saved(PaletteSavedDestination)
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

/// Share the palette's pool and ranking across presentation states.
enum CommandPalettePresentation {
    /// Index-confirmed chat matches keep their rank without rematching display text.
    static func filteredItems(pool: [PaletteItem], query: String, confirmed: [PaletteItem], rail: [SidebarItem],
                              sessions: [[String]]) -> [PaletteItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanQuery.isEmpty else {
            return Array(pool.filter {
                if case .tab(let item) = $0.kind { return $0.id == "tab." + item.rawValue && rail.contains(item) }
                return false
            }.prefix(8))
        }

        let candidates: [(PaletteItem, Int)] = pool.compactMap { item in
            let title = item.normalizedTitle
            let subtitle = item.normalizedSubtitle
            if title == cleanQuery { return (item, 0) }
            if title.hasPrefix(cleanQuery) { return (item, 1) }
            if subtitle.hasPrefix(cleanQuery) { return (item, 2) }
            if title.contains(cleanQuery) { return (item, 3) }
            if subtitle.contains(cleanQuery) { return (item, 4) }
            if item.normalizedSearch.contains(cleanQuery) { return (item, 5) }
            return nil
        }
        var scored = candidates.enumerated().map { ($0.element.0, $0.element.1, $0.offset) }
        for (rank, ids) in sessions.enumerated() {
            for id in ids {
                scored.append((PaletteItem(id: "chat.\(id)", title: "", subtitle: nil,
                    systemImage: "bubble.left.and.bubble.right", kind: .chatSession(id)), rank, scored.count))
            }
        }
        // Do not duplicate a chat already matched by title.
        var chats = Set<String>()
        return (scored.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }.map(\.0) + confirmed).filter { item in
            guard case .chatSession(let id) = item.kind else { return true }
            return chats.insert(id).inserted
        }
    }

    @MainActor static func railItems(_ layout: SurfaceLayoutAvailability) -> [SidebarItem] {
        SidebarItem.rail(layout).compactMap { $0 }
    }

    @MainActor
    static func itemPool(
        layout: SurfaceLayoutAvailability,
        agentName: String,
        ownPages: [QuietToolPage],
        settings: [PaletteItem] = [],
        saved: [PaletteItem] = []
    ) -> [PaletteItem] {
        let rail = railItems(layout)
        let pages = (rail + SidebarItem.allCases.filter {
            !rail.contains($0) && SidebarItem.shellHome(for: $0) == nil && SidebarItem.doorPage($0) != nil
        }).map { item in
            PaletteItem(id: "tab.\(item.rawValue)", title: item.shellRailTitle, subtitle: nil,
                        systemImage: item.systemImage, kind: .tab(item))
        }
        let placedNames = ShellSurface.allCases.flatMap { surface -> [PaletteItem] in
            let item = surface.firstPage
            let title = surface.title(agentName: "", simple: true)
            var names = title == item.shellRailTitle ? [] : [title]
            if surface == .agent {
                let named = surface.title(agentName: agentName)
                if named != title, ShellSurface.named(named, agentName: agentName) == .agent { names.append(named) }
            }
            return names.enumerated().map { index, name in
                PaletteItem(id: "place.\(surface.rawValue).\(index)", title: name, subtitle: nil,
                            systemImage: item.systemImage, kind: .tab(item))
            }
        }
        let authored = ownPages.map { page in
            PaletteItem(id: SurfaceLayout.pagePrefix + page.id, title: page.title, subtitle: nil,
                        systemImage: SidebarItem.ownPage.systemImage, kind: .ownPage(page.id), searchText: page.id)
        }
        // A page's first tab shares its name, so the page row already represents it.
        let tabs = ShellRailTab.all(layout, includeHidden: true).flatMap { page, tabs in
            tabs.filter { $0.title != page.shellRailTitle }.map { tab in
                PaletteItem(id: "railtab.\(page.rawValue).\(tab.key)", title: tab.title,
                            subtitle: page.shellRailTitle, systemImage: page.systemImage,
                            kind: .railTab(page, tab.key), searchText: tab.key)
            }
        }
        // Destinations win ties so a page name still opens that page.
        return pages + placedNames + tabs + authored + settings + saved + CommandPaletteRecentAction.allCases.map { action in
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

}

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
                kind: .saved(.botReply(botID: record.id, entryID: entry.id))
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
                kind: .saved(.dream(entry.date))
            )
        }
    }

    /// Search all saved memories and their full text, not a newest slice.
    private static func memoryItems(_ memories: [MindCore.MemoryRecord]) -> [PaletteItem] {
        memories.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            .map { record in
                PaletteItem(
                    id: "memory.\(record.id)",
                    title: firstLine(record.text),
                    subtitle: record.layer.flatMap { $0.isEmpty ? nil : "Memory · \($0)" } ?? "Memory",
                    systemImage: "brain",
                    kind: .saved(.memory(record.id)),
                    searchText: record.text
                )
            }
    }
}
