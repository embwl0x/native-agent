import AppToolRuntime
import SwiftUI
import NativeAgentShared
import TrustCenter

/// The layout failure stays visible alongside the shipped content. No stale
/// document or seed stands in for the unavailable layout.
struct SurfaceLayoutContent<Content: View>: View {
    let availability: SurfaceLayoutAvailability
    let content: (SurfaceLayoutAvailability) -> Content

    init(_ availability: SurfaceLayoutAvailability, @ViewBuilder content: @escaping (SurfaceLayoutAvailability) -> Content) {
        self.availability = availability; self.content = content
    }

    var body: some View {
        switch availability {
        case .available: content(availability)
        case .unavailable(let failure):
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup("Layout unavailable") {
                    Text(failure.localizedDescription).textSelection(.enabled)
                }.font(.caption).padding(8)
                content(availability)
            }
        }
    }
}

// Blueprint: | `ShellRailPages.swift` | `SurfaceLayoutContent` keeps shipped content reachable alongside the checked layout path/repair failure; `ShellRailTab` and rail page wrappers own remembered tab selection and canonical route-to-tab projection |

// Each page remembers its tab; routes to tabs select their owning page and tab.

enum ShellRailTab {
    static func storageKey(_ item: SidebarItem) -> String { "shell.tab.\(item.rawValue)" }

    /// Every rail page's visible tabs in layout order, for page routes and ⌘K.
    @MainActor static func all(_ layout: SurfaceLayoutAvailability) -> [(page: SidebarItem, tabs: [ShellTab<String>])] {
        [(.memories, shown(.memories, MemoriesRailPage.tabs, layout)), (.personality, shown(.personality, PersonalityRailPage.tabs, layout)),
         (.trust, shown(.trust, TrustRailPage.tabs, layout)), (.connectors, shown(.connectors, ConnectorsRailPage.tabs, layout)),
         (.capabilities, shown(.capabilities, CapabilitiesRailPage.tabs, layout)), (.diagnostics, shown(.diagnostics, DiagnosticsRailPage.tabs, layout))]
    }

    /// A rail page's tabs in the layout's order (ui/layout.json, `tabs.<page>`),
    /// those it hides left out.
    @MainActor static func shown(_ page: SidebarItem, _ tabs: [ShellTab<String>], _ layout: SurfaceLayoutAvailability) -> [ShellTab<String>] {
        layout.arranged("tabs." + page.rawValue.lowercased(), profile: SimpleViewMode.advanced, tabs) { $0.key }
    }
}

extension View {
    /// A tab the layout hides gives way to the first it shows, on arrival and
    /// whenever what it shows changes.
    @MainActor func keepsShownTab(_ page: SidebarItem, _ tabs: [ShellTab<String>], _ selection: Binding<String>, _ layout: SurfaceLayoutAvailability) -> some View {
        modifier(ShownRailTab(page: page, tabs: tabs, selection: selection, layout: layout))
    }
}

private struct ShownRailTab: ViewModifier {
    let page: SidebarItem
    let tabs: [ShellTab<String>]
    @Binding var selection: String
    let layout: SurfaceLayoutAvailability
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    func body(content: Content) -> some View {
        content.onChange(of: ShellRailTab.shown(page, tabs, layout).map(\.key), initial: true) { _, keys in
            guard !quietOffscreenRead else { return }
            if let first = keys.first, !keys.contains(selection), tabs.contains(where: { $0.key == selection }) {
                selection = first
            }
        }
    }
}

struct CapabilitiesRailPage: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(ShellRailTab.storageKey(.capabilities)) private var tab = "capabilities"

    /// The page's own sections are tabs here, not a segmented control under
    /// the tab row. The first keeps the key routes already write.
    static let tabs = [
        ShellTab(key: "capabilities", title: CapabilityWorkspaceMode.canDo.rawValue),
        ShellTab(key: "installed", title: CapabilityWorkspaceMode.installed.rawValue),
        ShellTab(key: "senses", title: "Senses"),
    ]

    var body: some View {
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellTabbedPage(title: "Capabilities", tabs: ShellRailTab.shown(.capabilities, Self.tabs, layout), selection: $tab, alive: true) { key in
            switch key {
            case "senses": SensesView()
            case "installed": CapabilitiesView(initialMode: .installed)
            default: CapabilitiesView()
            }
        }
        .keepsShownTab(.capabilities, Self.tabs, $tab, layout)
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
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellTabbedPage(
            title: "Memories",
            tabs: ShellRailTab.shown(.memories, Self.tabs, layout),
            selection: $tab,
            alive: true
        ) { key in
            Group {
                switch key {
                case "knowledge": KnowledgeGraphView()
                default: MemoriesPageView()
                }
            }
            // One sentence for both tabs, from the read the rail page's
            // selection already makes (`refreshForSidebarItem(.memories)`).
            .alivePageLine(MemoriesPageContent.headerLine(appModel), id: "memories.kept-line")
        }
        .keepsShownTab(.memories, Self.tabs, $tab, layout)
        }
    }
}

struct PersonalityRailPage: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(ShellRailTab.storageKey(.personality)) private var tab = "personality"

    static let tabs = [
        ShellTab(key: "personality", title: "Personality"),
        ShellTab(key: "minds", title: "My minds"),
        ShellTab(key: "dreams", title: "Dreams"),
    ]

    var body: some View {
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellTabbedPage(
            title: "Personality",
            subtitlePage: .personality,
            tabs: ShellRailTab.shown(.personality, Self.tabs, layout),
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "minds": SetupMindsView()
            case "dreams": DreamsView()
            default: PersonalityView()
            }
        }
        .keepsShownTab(.personality, Self.tabs, $tab, layout)
        }
    }
}

struct TrustRailPage: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(ShellRailTab.storageKey(.trust)) private var tab = TrustTab.access.rawValue

    static let tabs = [
        ShellTab(key: TrustTab.access.rawValue, title: "Access"),
        ShellTab(key: TrustTab.features.rawValue, title: "Features"),
        // One Mac tab: Chrome and Mac control, then the per-app grants.
        ShellTab(key: TrustTab.macAndBrowser.rawValue, title: "Mac"),
        ShellTab(key: TrustTab.advanced.rawValue, title: "Advanced"),
    ]

    var body: some View {
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellTabbedPage(
            title: "Trust",
            subtitlePage: .trust,
            tabs: ShellRailTab.shown(.trust, Self.tabs, layout),
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case TrustTab.macAndBrowser.rawValue:
                MacIntegrationView()
            default: TrustCenterView(tab: TrustTab(rawValue: key) ?? .access)
            }
        }
        .keepsShownTab(.trust, Self.tabs, $tab, layout)
        }
    }
}

struct ConnectorsRailPage: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(ShellRailTab.storageKey(.connectors)) private var tab = "connectors"

    static let tabs = [
        ShellTab(key: "connectors", title: "Connectors"),
        ShellTab(key: "agents", title: "Agents"),
        ShellTab(key: "telegram", title: "Telegram"),
        ShellTab(key: "iphone", title: "iPhone"),
    ]

    var body: some View {
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellTabbedPage(
            title: "Connectors",
            subtitlePage: .connectors,
            tabs: ShellRailTab.shown(.connectors, Self.tabs, layout),
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "agents": AgentThreadsTab()
            case "telegram": TelegramView()
            case "iphone": MacPairingView()
            default: ConnectorsView()
            }
        }
        .keepsShownTab(.connectors, Self.tabs, $tab, layout)
        }
    }
}

struct DiagnosticsRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.diagnostics)) private var tab = DiagnosticsView.DiagnosticsMode.doctor.rawValue
    @Environment(AppModel.self) private var appModel

    static var tabs: [ShellTab<String>] {
        DiagnosticsView.DiagnosticsMode.allCases.map { ShellTab(key: $0.rawValue, title: $0.title) }
            // Skills and Tools share the Diagnostics tab row.
            + [ShellTab(key: "skills", title: "Skills"), ShellTab(key: "tools", title: "Tools")]
    }

    var body: some View {
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellTabbedPage(
            title: "Diagnostics",
            subtitlePage: .diagnostics,
            tabs: ShellRailTab.shown(.diagnostics, Self.tabs, layout),
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
                    mode: DiagnosticsView.DiagnosticsMode(rawValue: key) ?? .doctor
                )
            }
        }
        .keepsShownTab(.diagnostics, Self.tabs, $tab, layout)
        }
    }
}
