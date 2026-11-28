import BodyRuntime
import SwiftUI
import NativeAgentShared
import DeskCore

// Blueprint: | `ShellRailPages.swift` | Canonical rail-tab identities for body routing and search |


enum ShellRailTab {
    @MainActor static func all(_ layout: SurfaceLayoutAvailability, includeHidden: Bool = false) -> [(page: SidebarItem, tabs: [ShellTab<String>])] {
        let destinations: [(SidebarItem, [ShellTab<String>])] = [
            (.memories, [ShellTab(key: "memories", title: "Memories"), ShellTab(key: "knowledge", title: "Knowledge graph")]),
            (.personality, PersonalityFaceDestinations.tabs), (.diagnostics, DiagnosticsRailPage.tabs),
        ]
        return destinations.map { page, tabs in
            let visible = shown(page, tabs, layout)
            guard includeHidden else { return (page, visible) }
            return (page, visible + tabs.filter { tab in !visible.contains { $0.key == tab.key } })
        }
    }

    @MainActor static func shown(_ page: SidebarItem, _ tabs: [ShellTab<String>], _ layout: SurfaceLayoutAvailability) -> [ShellTab<String>] {
        layout.arranged("tabs." + page.rawValue.lowercased(), profile: SimpleViewMode.advanced, tabs) { $0.key }
    }
}

enum DiagnosticsRailPage {
    static var tabs: [ShellTab<String>] {
        [ShellTab(key: "diagnostics", title: "Diagnostics"), ShellTab(key: "Cognition", title: "Cognition"),
         ShellTab(key: "Inspector", title: "Chat turn details")]
    }
}
