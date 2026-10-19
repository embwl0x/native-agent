import AppToolRuntime
import ChatOrchestration
import SwiftUI
import TrustCenter

// User, 2026-09-04: the rail pages that carry tabs. Which tab is open is
// remembered per page, and a route to something that is now a tab (Telegram,
// the knowledge graph, MCP, Mac integration, Dreams, Skills and tools) lands on
// its page with that tab open — see `SidebarItem.shellHome(for:)` and
// `ContentView.selectSidebarItem`.

enum ShellRailTab {
    static func storageKey(_ item: SidebarItem) -> String { "shell.tab.\(item.rawValue)" }

    /// Every rail page's tabs as the layout shows them, for ⌘K. A tab opens
    /// by writing its key here before the page is selected, as a route to a
    /// former page does.
    @MainActor static var all: [(page: SidebarItem, tabs: [ShellTab<String>])] {
        [(.memories, shown(.memories, MemoriesRailPage.tabs)), (.personality, shown(.personality, PersonalityRailPage.tabs)),
         (.trust, shown(.trust, TrustRailPage.tabs)), (.connectors, shown(.connectors, ConnectorsRailPage.tabs)),
         (.capabilities, shown(.capabilities, CapabilitiesRailPage.tabs)), (.diagnostics, shown(.diagnostics, DiagnosticsRailPage.tabs))]
    }

    /// A rail page's tabs in the layout's order (ui/layout.json, `tabs.<page>`),
    /// those it hides left out.
    @MainActor static func shown(_ page: SidebarItem, _ tabs: [ShellTab<String>]) -> [ShellTab<String>] {
        SurfaceLayoutLive.shared.layout.arranged("tabs." + page.rawValue.lowercased(), profile: SimpleViewMode.advanced, tabs) { $0.key }
    }
}

extension View {
    /// A tab the layout hides gives way to the first it shows, on arrival and
    /// whenever what it shows changes; a key the page maps itself (Trust's old
    /// "control") is left to it.
    @MainActor func keepsShownTab(_ page: SidebarItem, _ tabs: [ShellTab<String>], _ selection: Binding<String>) -> some View {
        onChange(of: ShellRailTab.shown(page, tabs).map(\.key), initial: true) { _, keys in
            if let first = keys.first, !keys.contains(selection.wrappedValue), tabs.contains(where: { $0.key == selection.wrappedValue }) {
                selection.wrappedValue = first
            }
        }
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
        ShellTabbedPage(title: "Capabilities", tabs: ShellRailTab.shown(.capabilities, Self.tabs), selection: $tab, alive: true) { key in
            switch key {
            case "senses": SensesView()
            case "installed": CapabilitiesView(initialMode: .installed)
            default: CapabilitiesView()
            }
        }
        .keepsShownTab(.capabilities, Self.tabs, $tab)
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
            tabs: ShellRailTab.shown(.memories, Self.tabs),
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
        .keepsShownTab(.memories, Self.tabs, $tab)
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
            tabs: ShellRailTab.shown(.personality, Self.tabs),
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "minds": SetupMindsView()
            case "dreams": DreamsView()
            default: PersonalityView()
            }
        }
        .keepsShownTab(.personality, Self.tabs, $tab)
    }
}

struct TrustRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.trust)) private var tab = TrustTab.access.rawValue

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
            tabs: ShellRailTab.shown(.trust, Self.tabs),
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "mac", TrustTab.macAndBrowser.rawValue:
                MacIntegrationView(showsMacControl: true)
            default: TrustCenterView(tab: TrustTab(rawValue: key) ?? .access)
            }
        }
        .keepsShownTab(.trust, Self.tabs, $tab)
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
            tabs: ShellRailTab.shown(.connectors, Self.tabs),
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
        .keepsShownTab(.connectors, Self.tabs, $tab)
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
            tabs: ShellRailTab.shown(.diagnostics, Self.tabs),
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
        .keepsShownTab(.diagnostics, Self.tabs, $tab)
    }
}
