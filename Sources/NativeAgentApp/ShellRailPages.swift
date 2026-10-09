import SwiftUI
import TrustCenter

// User, 2026-09-04: the rail pages that carry tabs. Which tab is open is
// remembered per page, and a route to something that is now a tab (Telegram,
// the knowledge graph, MCP, Mac integration, Dreams, Skills and tools) lands on
// its page with that tab open — see `SidebarItem.shellHome(for:)` and
// `ContentView.selectSidebarItem`.

enum ShellRailTab {
    static func storageKey(_ item: SidebarItem) -> String { "shell.tab.\(item.rawValue)" }

    /// Every rail page's tabs, for ⌘K. A tab opens by writing its key here
    /// before the page is selected, as a route to a former page does.
    @MainActor static var all: [(page: SidebarItem, tabs: [ShellTab<String>])] {
        [(.memories, MemoriesRailPage.tabs), (.personality, PersonalityRailPage.tabs),
         (.trust, TrustRailPage.tabs), (.connectors, ConnectorsRailPage.tabs),
         (.capabilities, CapabilitiesRailPage.tabs), (.diagnostics, DiagnosticsRailPage.tabs)]
    }
}

struct CapabilitiesRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.capabilities)) private var tab = "capabilities"

    /// The page's own sections are tabs here, not a segmented control under
    /// the tab row. The first keeps the key routes already write.
    static let tabs = [
        ShellTab(key: "capabilities", title: CapabilityWorkspaceMode.canDo.rawValue),
        ShellTab(key: "installed", title: CapabilityWorkspaceMode.installed.rawValue),
        ShellTab(key: "senses", title: "Senses"),
    ]

    var body: some View {
        ShellTabbedPage(title: "Capabilities", tabs: Self.tabs, selection: $tab, alive: true) { key in
            switch key {
            case "senses": SensesView()
            case "installed": CapabilitiesView(initialMode: .installed)
            default: CapabilitiesView()
            }
        }
    }
}

struct MemoriesRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.memories)) private var tab = "memories"
    @Environment(AppModel.self) private var appModel

    static let tabs = [
        ShellTab(key: "memories", title: "Memories"),
        ShellTab(key: "knowledge", title: "Knowledge graph"),
    ]

    var body: some View {
        ShellTabbedPage(
            title: "Memories",
            tabs: Self.tabs,
            selection: $tab,
            alive: true
        ) { key in
            Group {
                switch key {
                case "knowledge": KnowledgeGraphView()
                default: MemoriesPageView(embedded: true)
                }
            }
            // One sentence for both tabs, from the read the rail page's
            // selection already makes (`refreshForSidebarItem(.memories)`).
            .alivePageLine(MemoriesPageContent.headerLine(appModel), id: "memories.kept-line")
        }
    }
}

struct PersonalityRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.personality)) private var tab = "personality"

    static let tabs = [
        ShellTab(key: "personality", title: "Personality"),
        ShellTab(key: "minds", title: "My minds"),
        ShellTab(key: "dreams", title: "Dreams"),
    ]

    var body: some View {
        ShellTabbedPage(
            title: "Personality",
            subtitle: SidebarItem.personality.shellPageSubtitle,
            tabs: Self.tabs,
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "minds": SetupMindsView()
            case "dreams": DreamsView()
            default: PersonalityView()
            }
        }
    }
}

struct TrustRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.trust)) private var tab = TrustTab.access.rawValue
    /// Mac control's unsaved edits live here, above the tabs, so switching
    /// tabs (which rebuilds each tab's view) keeps them.
    @State private var macControlDraft: TrustMacControlPolicy?

    static let tabs = [
        ShellTab(key: TrustTab.access.rawValue, title: "Access"),
        ShellTab(key: TrustTab.features.rawValue, title: "Features"),
        // One Mac tab: Chrome and Mac control, then the per-app grants. The
        // old "Mac & browser" key lands here too.
        ShellTab(key: "mac", title: "Mac"),
        ShellTab(key: TrustTab.advanced.rawValue, title: "Advanced"),
    ]

    var body: some View {
        ShellTabbedPage(
            title: "Trust",
            subtitle: SidebarItem.trust.shellPageSubtitle,
            tabs: Self.tabs,
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "mac", TrustTab.macAndBrowser.rawValue:
                MacIntegrationView(showsMacControl: true, macControlDraft: $macControlDraft)
            default: TrustCenterView(tab: TrustTab(rawValue: key) ?? .access, macControlDraft: $macControlDraft)
            }
        }
        .onAppear { if tab == TrustTab.macAndBrowser.rawValue { tab = "mac" } }
    }
}

struct ConnectorsRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.connectors)) private var tab = "connectors"
    @Environment(AppModel.self) private var appModel

    static let tabs = [
        ShellTab(key: "connectors", title: "Connectors"),
        ShellTab(key: "agents", title: "Agents"),
        ShellTab(key: "mcp", title: "MCP"),
        ShellTab(key: "telegram", title: "Telegram"),
        ShellTab(key: "iphone", title: "iPhone"),
    ]

    var body: some View {
        ShellTabbedPage(
            title: "Connectors",
            subtitle: SidebarItem.connectors.shellPageSubtitle,
            tabs: Self.tabs,
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "agents": AgentThreadsTab()
            case "mcp": MCPHubView()
            case "telegram": TelegramView()
            case "iphone": MacPairingView()
            default: ConnectorsView()
            }
        }
        // MCPHubView reads what ContentView fetched for the MCP row; as a tab
        // here it is under Connectors, so the tab fetches for itself.
        .liveTask(id: tab) {
            guard tab == "mcp" else { return }
            _ = await appModel.refreshForSidebarItem(.mcp)
        }
    }
}

struct DiagnosticsRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.diagnostics)) private var tab = DiagnosticsView.DiagnosticsMode.doctor.rawValue
    @Environment(AppModel.self) private var appModel

    static var tabs: [ShellTab<String>] {
        DiagnosticsView.DiagnosticsMode.allCases.map { ShellTab(key: $0.rawValue, title: $0.title) }
            // Skills and Tools are tabs here, not a segmented control
            // under the tab row (the reviewer's catch, 2026-09-04).
            + [ShellTab(key: "skills", title: "Skills"), ShellTab(key: "tools", title: "Tools")]
    }

    var body: some View {
        ShellTabbedPage(
            title: "Diagnostics",
            subtitle: SidebarItem.diagnostics.shellPageSubtitle,
            tabs: Self.tabs,
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            // The same header line as the Diagnostics tabs.
            case "skills":
                SkillLifecycleView()
                    .alivePageLine(DiagnosticsView.headerLine(appModel), id: "diagnostics.line")
            case "tools":
                ToolsView()
                    .alivePageLine(DiagnosticsView.headerLine(appModel), id: "diagnostics.line")
            default:
                DiagnosticsView(
                    initialMode: DiagnosticsView.DiagnosticsMode(rawValue: key) ?? .doctor,
                    showsModePicker: false
                )
            }
        }
    }
}
