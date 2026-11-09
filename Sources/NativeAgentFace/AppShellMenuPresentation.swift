import Foundation
import SwiftUI
import NativeAgentShared

// Blueprint: | `AppShellMenuPresentation.swift` | Rail-derived shortcuts, status words and ordered rail rows |

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

/// One row of the Advanced rail, in the layout's order: an app page, the divider, or a page of the agent's own by its id.
enum ShellRailRow: Hashable {
    case item(SidebarItem)
    case divider
    case page(String)
}

extension SidebarItem {
    /// Read layout order from the rail so the rail, Navigate shortcuts and palette pages follow the visible rows.
    static func railRows(_ layout: SurfaceLayoutAvailability) -> [ShellRailRow] {
        layout.contentNames("rail", profile: ShellViewMode.advanced).map { name -> ShellRailRow in
            if let page = SurfaceLayout.ownPage("rail", name) { return .page(page) }
            return QuietPages.all.first { $0.id == name }.map { ShellRailRow.item($0.item) } ?? .divider
        }
    }

    /// The rail's app pages and its divider (nil); a page of the agent's own is the rail's alone.
    static func rail(_ layout: SurfaceLayoutAvailability) -> [SidebarItem?] {
        railRows(layout).flatMap { row -> [SidebarItem?] in
            switch row {
            case .item(let item): [item]
            case .divider: [nil]
            case .page: []
            }
        }
    }
}
