import SwiftUI
import NativeAgentShared

/// Keep layout failures visible; neither stale documents nor seeds prove the requested layout loaded.
struct SurfaceLayoutContent<Content: View>: View {
    let availability: SurfaceLayoutAvailability?
    let content: (SurfaceLayoutAvailability) -> Content

    init(_ availability: SurfaceLayoutAvailability?, @ViewBuilder content: @escaping (SurfaceLayoutAvailability) -> Content) {
        self.availability = availability; self.content = content
    }

    var body: some View {
        switch availability {
        case .available(let layout): content(.available(layout))
        case .unavailable(let failure):
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup("Layout unavailable") {
                    Text(failure.localizedDescription).textSelection(.enabled)
                }.font(.caption).padding(8)
                content(.unavailable(failure))
            }
        case nil: Text("Waiting on layout…").foregroundStyle(.secondary)
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
         (.diagnostics, shown(.diagnostics, DiagnosticsRailPage.tabs, layout))]
    }

    @MainActor static func shown(_ page: SidebarItem, _ tabs: [ShellTab<String>], _ layout: SurfaceLayoutAvailability) -> [ShellTab<String>] {
        layout.arranged("tabs." + page.rawValue.lowercased(), profile: ShellViewMode.advanced, tabs) { $0.key }
    }
}

extension View {
    /// Keep an unavailable saved selection visible until the person chooses a tab.
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
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ShellRailTab.shown(page, tabs, layout).contains(where: { $0.key == selection }) {
                Text("Tab ‘\(selection)’ is unavailable. Choose a visible tab.")
                    .font(.caption).foregroundStyle(.red).padding(8)
            }
            content
        }
    }
}

struct DiagnosticsRailPage: View {
    @AppStorage(ShellRailTab.storageKey(.diagnostics)) private var tab = "diagnostics"
    @Environment(AppModel.self) private var appModel

    private struct RunSelection: Identifiable { let id: String }

    static var tabs: [ShellTab<String>] {
        [ShellTab(key: "diagnostics", title: "Diagnostics"), ShellTab(key: "Cognition", title: "Cognition"),
            ShellTab(key: "Inspector", title: "Chat turn details")]
    }

    var body: some View {
        SurfaceLayoutContent(appModel.shellLayout) { layout in
        ShellTabbedPage(
            title: "Diagnostics",
            subtitlePage: .diagnostics,
            tabs: ShellRailTab.shown(.diagnostics, Self.tabs, layout),
            selection: $tab,
            alive: true
        ) { key in
            switch key {
            case "diagnostics":
                FacePageView(page: "diagnostics", asTab: true, isReading: appModel.panelIsReading(.diagnostics))
            case "Cognition":
                CognitionObservatoryView()
            case "Inspector": InspectorView()
            default: EmptyView()
            }
        }
        .sheet(item: Binding(get: { appModel.diagnosticsRunID.map(RunSelection.init) },
                            set: { if $0 == nil { appModel.diagnosticsRunID = nil } })) { run in
            ShellRunDetail(id: run.id)
        }
        .keepsShownTab(.diagnostics, Self.tabs, $tab, layout)
        }
    }
}

private struct ShellRunDetail: View {
    let id: String
    @Environment(AppModel.self) private var appModel
    var body: some View {
        let detail = appModel.face.slot(.run(id)).value(as: RunFace.self)
        Group {
            if let record = detail?.record { RunDetailSheet(run: record) }
            else { FaceReadStatus(state: detail?.state).padding() }
        }.modifier(FaceObservation(demand: .key(.run(id))))
    }
}
