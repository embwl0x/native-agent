import SwiftUI
import NativeAgentShared

/// D7: the Navigate menu is a PROJECTION of the rail, not a second list kept
/// by hand. It numbered `primaryItems`, which lacks the Helpers row the rail
/// adds at six, so ⌘6–⌘9 each opened the page one below. It reads the rail's
/// own order and words now (`BotsShelfRailProposal.ordered`).
enum NavigateMenuPresentation {
    struct Entry: Equatable, Identifiable {
        let item: SidebarItem
        /// ⌘1…⌘9 in rail order. An item past the ninth is listed WITHOUT a
        /// shortcut rather than with a wrong or duplicated one.
        let shortcut: Character?

        var id: String { item.rawValue }
        var title: String { item.shellRailTitle }
    }

    static func entries(helpersShown: Bool) -> [Entry] {
        BotsShelfRailProposal.ordered(SidebarItem.primaryItems, enabled: helpersShown).enumerated().map { index, item in
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
