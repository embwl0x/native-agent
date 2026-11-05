import AppToolRuntime
import SwiftUI
import NativeAgentShared
import TrustCenter

/// Keep layout failures visible; neither stale documents nor seeds prove the requested layout loaded.
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

// Blueprint: | `ShellRailPages.swift` | `SurfaceLayoutContent`: checked layout; `ShellRailTab`: canonical tab routing |


enum ShellRailTab {
    static func storageKey(_ item: SidebarItem) -> String { "shell.tab.\(item.rawValue)" }

    /// Share layout order between page routes and command search.
    @MainActor static func all(_ layout: SurfaceLayoutAvailability) -> [(page: SidebarItem, tabs: [ShellTab<String>])] {
        [(.memories, shown(.memories, MemoriesFaceNavigation.tabs, layout)),
         (.personality, shown(.personality, PersonalityFaceDestinations.tabs, layout)),
         (.connectors, shown(.connectors, ConnectorsRailPage.tabs, layout)),
         (.capabilities, shown(.capabilities, CapabilitiesRailPage.tabs, layout)), (.diagnostics, shown(.diagnostics, DiagnosticsRailPage.tabs, layout))]
    }

    @MainActor static func shown(_ page: SidebarItem, _ tabs: [ShellTab<String>], _ layout: SurfaceLayoutAvailability) -> [ShellTab<String>] {
        layout.arranged("tabs." + page.rawValue.lowercased(), profile: SimpleViewMode.advanced, tabs) { $0.key }
    }
}

extension View {
    /// Reconcile hidden selections on arrival and layout changes so the page always has a visible tab.
    @MainActor func keepsShownTab(
        _ page: SidebarItem,
        _ tabs: [ShellTab<String>],
        _ selection: Binding<String>,
        _ layout: SurfaceLayoutAvailability
    ) -> some View {
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
            if let first = keys.first, !keys.contains(selection) {
                selection = first
            }
        }
    }
}

struct CapabilitiesRailPage: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(ShellRailTab.storageKey(.capabilities)) private var tab = "capabilities"

    /// Keep the first tab key stable because routes persist it.
    static let tabs = [
        ShellTab(key: "capabilities", title: "What I can do"),
        ShellTab(key: "senses", title: "Senses"),
    ]

    var body: some View {
        SurfaceLayoutContent(appModel.engine.layout.availability) { layout in
        ShellTabbedPage(title: "Capabilities", subtitlePage: .capabilities, tabs: ShellRailTab.shown(.capabilities, Self.tabs, layout),
                        selection: $tab, alive: true) { key in
            switch key {
            case "senses": SensesView()
            default: FacePageView(page: "capabilities", asTab: true, isReading: appModel.panelRefreshCounts[.capabilities, default: 0] > 0)
            }
        }
        .keepsShownTab(.capabilities, Self.tabs, $tab, layout)
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
            default: FacePageView(page: "connectors", asTab: true, isReading: appModel.panelRefreshCounts[.connectors, default: 0] > 0)
            }
        }
        .keepsShownTab(.connectors, Self.tabs, $tab, layout)
        }
    }
}

struct DiagnosticsRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.diagnostics)) private var tab = "diagnostics"
    @Environment(AppModel.self) private var appModel

    static var tabs: [ShellTab<String>] {
        [ShellTab(key: "diagnostics", title: "Diagnostics"), ShellTab(key: "Cognition", title: "Cognition"),
            ShellTab(key: "Inspector", title: "Chat turn details"), ShellTab(key: "skills", title: "Skills"), ShellTab(key: "tools", title: "Tools")]
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
            case "diagnostics":
                FacePageView(page: "diagnostics", asTab: true, isReading: appModel.panelRefreshCounts[.diagnostics, default: 0] > 0)
            case "Cognition":
                if let runtime = appModel.engine.cognitionView.runtime {
                    CognitionObservatoryView(cognition: appModel.engine.cognitionView, runtime: runtime, dependencies: .live(appModel: appModel))
                } else {
                    Text("Unavailable").foregroundStyle(.secondary)
                }
            case "Inspector": InspectorView(feed: appModel.engine.trace)
            case "skills":
                SkillLifecycleView()
            case "tools":
                ToolsView()
            default: EmptyView()
            }
        }
        .sheet(item: Binding(get: {
            appModel.engine.runs.rows.first { $0.id == appModel.diagnosticsRunID }
        }, set: { if $0 == nil { appModel.diagnosticsRunID = nil } })) { run in
            RunDetailSheet(run: run)
        }
        .keepsShownTab(.diagnostics, Self.tabs, $tab, layout)
        }
    }
}
