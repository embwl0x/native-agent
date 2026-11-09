import AppToolRuntime
import SwiftUI
import NativeAgentShared
import TrustCenter

// Blueprint: | `ShellRailPages.swift` | Canonical rail-tab identities for body routing and search |


enum ShellRailTab {
    static func storageKey(_ item: SidebarItem) -> String { "shell.tab.\(item.rawValue)" }

    /// Share layout order between page routes and command search.
    @MainActor static func all(_ layout: SurfaceLayoutAvailability) -> [(page: SidebarItem, tabs: [ShellTab<String>])] {
        [(.memories, shown(.memories, [ShellTab(key: "memories", title: "Memories"), ShellTab(key: "knowledge", title: "Knowledge graph")], layout)),
         (.personality, shown(.personality, PersonalityFaceDestinations.tabs, layout)),
         (.diagnostics, shown(.diagnostics, DiagnosticsRailPage.tabs, layout))]
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
