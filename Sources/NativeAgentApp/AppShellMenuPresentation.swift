import AppToolRuntime
import SwiftUI
import NativeAgentShared

/// D7: the Navigate menu is a PROJECTION of the rail, not a second list kept
/// by hand. It numbered the old primary list, which lacked the Helpers row the rail
/// adds at six, so ⌘6–⌘9 each opened the page one below. It reads the rail's
/// own order and words now (`SidebarItem.rail`).
enum NavigateMenuPresentation {
    struct Entry: Equatable, Identifiable {
        let item: SidebarItem
        /// ⌘1…⌘9 in rail order. An item past the ninth is listed WITHOUT a
        /// shortcut rather than with a wrong or duplicated one.
        let shortcut: Character?

        var id: String { item.rawValue }
        var title: String { item.shellRailTitle }
    }

    static func entries(_ layout: SurfaceLayout) -> [Entry] {
        SidebarItem.rail(layout).compactMap { $0 }.enumerated().map { index, item in
            Entry(item: item, shortcut: index < 9 ? Character("\(index + 1)") : nil)
        }
    }
}

/// D7: the menu-bar extra renders ONE truth line. It used to stack the last
/// status string above a separately-derived health sentence, which let the menu
/// say "Ready" directly above "Native runtime unavailable" — two claims, no
/// stated winner. Reachability leads (it is what the menu is opened for) and the
/// status detail follows it on the same line.
enum MenuBarStatusPresentation {
    static func line(statusText: String, health: RuntimeHealth?) -> String {
        let status = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let health else {
            return status.isEmpty ? "My connection status is unknown" : status
        }
        let reachability = health.ok ? "I'm online" : "I'm unavailable"
        guard !status.isEmpty,
              status.caseInsensitiveCompare(reachability) != .orderedSame else {
            return reachability
        }
        return "\(reachability) — \(status)"
    }
}

extension SidebarItem {
    /// Advanced's rail top to bottom as the layout shows it (ui/layout.json,
    /// the rail's blocks by their page ids): a page, or nil for the line
    /// between its groups. The Navigate menu's digits and ⌘K's pages read its
    /// pages, so ⌘N is the Nth rail row.
    static func rail(_ layout: SurfaceLayout) -> [SidebarItem?] {
        layout.shown("rail", profile: SimpleViewMode.advanced).map { block in
            QuietPages.all.first { $0.id == block.name && $0.tab == nil }?.item
        }
    }
}
