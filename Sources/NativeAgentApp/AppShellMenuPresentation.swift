import SwiftUI
import NativeAgentShared

/// D7: the Navigate menu is a PROJECTION of the sidebar, not a second list kept
/// by hand. The hand-kept version had drifted — it offered Personality (an
/// Advanced tab) at ⌘5 and never mentioned Skills & Tools or Mac Integration,
/// so the digit a person learned from the sidebar landed somewhere else.
/// Deriving from `primaryItems` makes that class of drift unrepresentable.
enum NavigateMenuPresentation {
    struct Entry: Equatable, Identifiable {
        let item: SidebarItem
        /// ⌘1…⌘9 in sidebar order. An item past the ninth is listed WITHOUT a
        /// shortcut rather than with a wrong or duplicated one.
        let shortcut: Character?

        var id: String { item.rawValue }
        var title: String { item.displayName }
    }

    static var entries: [Entry] {
        SidebarItem.primaryItems.enumerated().map { index, item in
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
            return status.isEmpty ? "Runtime status unknown" : status
        }
        let reachability = health.ok ? "Native runtime online" : "Native runtime unavailable"
        guard !status.isEmpty,
              status.caseInsensitiveCompare(reachability) != .orderedSame else {
            return reachability
        }
        return "\(reachability) — \(status)"
    }
}
