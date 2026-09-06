import SwiftUI

// User, 2026-09-04: the rail pages that carry tabs. Which tab is open is
// remembered per page, and a route to something that is now a tab (Telegram,
// the knowledge graph, MCP, Mac integration, Dreams, Skills and tools) lands on
// its page with that tab open — see `SidebarItem.shellHome(for:)` and
// `ContentView.selectSidebarItem`.

enum ShellRailTab {
    static func storageKey(_ item: SidebarItem) -> String { "shell.tab.\(item.rawValue)" }
}

struct MemoriesRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.memories)) private var tab = "memories"

    var body: some View {
        ShellTabbedPage(
            title: "Memories",
            tabs: [
                ShellTab(key: "memories", title: "Memories"),
                ShellTab(key: "knowledge", title: "Knowledge graph"),
            ],
            selection: $tab
        ) { key in
            switch key {
            case "knowledge": KnowledgeGraphView()
            default: MemoriesPageView(embedded: true)
            }
        }
    }
}

struct PersonalityRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.personality)) private var tab = "personality"

    var body: some View {
        ShellTabbedPage(
            title: "Personality",
            tabs: [
                ShellTab(key: "personality", title: "Personality"),
                ShellTab(key: "minds", title: "\(AgentVoice.live.possessive) minds"),
                ShellTab(key: "dreams", title: "Dreams"),
            ],
            selection: $tab
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
    @AppStorage(ShellRailTab.storageKey(.trust)) private var tab = "trust"

    var body: some View {
        ShellTabbedPage(
            title: "Trust",
            tabs: [
                ShellTab(key: "trust", title: "Trust"),
                ShellTab(key: "mac", title: "Mac integration"),
            ],
            selection: $tab
        ) { key in
            switch key {
            case "mac": MacIntegrationView()
            default: TrustCenterView()
            }
        }
    }
}

struct ConnectorsRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.connectors)) private var tab = "connectors"
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ShellTabbedPage(
            title: "Connectors",
            tabs: [
                ShellTab(key: "connectors", title: "Connectors"),
                ShellTab(key: "mcp", title: "MCP"),
                ShellTab(key: "telegram", title: "Telegram"),
                ShellTab(key: "iphone", title: "iPhone"),
            ],
            selection: $tab
        ) { key in
            switch key {
            case "mcp": MCPHubView()
            case "telegram": TelegramView()
            case "iphone": MacPairingView()
            default: ConnectorsView()
            }
        }
        // MCPHubView reads what ContentView fetched for the MCP row; as a tab
        // here it is under Connectors, so the tab fetches for itself.
        .task(id: tab) {
            guard tab == "mcp" else { return }
            _ = await appModel.refreshForSidebarItem(.mcp)
        }
    }
}

struct DiagnosticsRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.diagnostics)) private var tab = DiagnosticsView.DiagnosticsMode.doctor.rawValue

    var body: some View {
        ShellTabbedPage(
            title: "Diagnostics",
            tabs: DiagnosticsView.DiagnosticsMode.allCases.map { ShellTab(key: $0.rawValue, title: $0.title) }
                // Skills and Tools are tabs here, not a segmented control
                // under the tab row (the reviewer's catch, 2026-09-04).
                + [ShellTab(key: "skills", title: "Skills"), ShellTab(key: "tools", title: "Tools")],
            selection: $tab
        ) { key in
            switch key {
            case "skills": SkillLifecycleView()
            case "tools": ToolsView()
            default:
                DiagnosticsView(
                    initialMode: DiagnosticsView.DiagnosticsMode(rawValue: key) ?? .doctor,
                    showsModePicker: false
                )
            }
        }
    }
}
