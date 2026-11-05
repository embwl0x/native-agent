import AppToolRuntime
import Foundation
import SwiftUI
import NativeAgentShared

// Blueprint: | `AppShellMenuPresentation.swift` | `NavigateMenuPresentation`, `MenuBarStatusPresentation`: Rail-derived shortcuts and one status line |

/// Derive Navigate order and labels from SidebarItem.rail so numbered shortcuts always match the visible rail.
enum NavigateMenuPresentation {
    struct Entry: Equatable, Identifiable {
        let item: SidebarItem
        /// Only the first nine rail items receive shortcuts to avoid duplicate or misleading digits.
        let shortcut: Character?

        var id: String { item.rawValue }
        var title: String { item.shellRailTitle }
    }

    static func entries(_ layout: SurfaceLayoutAvailability) -> [Entry] {
        SidebarItem.rail(layout).compactMap { $0 }.enumerated().map { index, item in
            Entry(item: item, shortcut: index < 9 ? Character("\(index + 1)") : nil)
        }
    }
}

/// Render reachability before status detail on one line so conflicting status cannot obscure an unavailable runtime.
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
    /// Read layout order from the rail so Navigate shortcuts and palette pages follow the visible rows.
    static func rail(_ layout: SurfaceLayoutAvailability) -> [SidebarItem?] {
        layout.contentNames("rail", profile: SimpleViewMode.advanced).filter { name in
            // An unreadable layout cannot override the user's Helpers switch.
            layout.failure == nil || name != "bots"
                || (UserDefaults.standard.object(forKey: "uiBotsShelfPreview") as? Bool) != false
        }.map { name in
            QuietPages.all.first { $0.id == name && $0.tab == nil }?.item
        }
    }
}
