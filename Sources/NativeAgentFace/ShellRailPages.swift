import Foundation
import Observation
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

    @MainActor static func match(_ word: String, page: SidebarItem, layout: SurfaceLayoutAvailability?) -> String? {
        let tabs = layout.flatMap { all($0).first(where: { $0.page == page })?.tabs } ?? []
        let destinations = page == .personality ? PersonalityFaceDestinations.tabs : []
        return (tabs + destinations).first {
            $0.key.caseInsensitiveCompare(word) == .orderedSame || $0.title.caseInsensitiveCompare(word) == .orderedSame
        }?.key
    }
}

extension View {
    /// Keep an unavailable saved selection visible until the person chooses a tab.
    @MainActor func keepsShownTab(
        _ tabs: [ShellTab<String>],
        _ selection: Binding<String>
    ) -> some View {
        modifier(ShownRailTab(tabs: tabs, selection: selection))
    }
}

private struct ShownRailTab: ViewModifier {
    let tabs: [ShellTab<String>]
    @Binding var selection: String
    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tabs.contains(where: { $0.key == selection }) {
                Text("Tab ‘\(selection)’ is unavailable. Choose a visible tab.")
                    .font(.caption).foregroundStyle(.red).padding(8)
            }
            content
        }
    }
}

@MainActor @Observable
final class ShellRailTabStore {
    static let shared = ShellRailTabStore()
    private var values: [SidebarItem: String] = [:]

    func value(for item: SidebarItem, default fallback: String) -> String {
        if let stored = values[item] { return stored }
        return UserDefaults.standard.string(forKey: ShellRailTab.storageKey(item)) ?? fallback
    }

    func set(_ tab: String, for item: SidebarItem) {
        let key = ShellRailTab.storageKey(item)
        if UserDefaults.standard.string(forKey: key) != tab {
            UserDefaults.standard.set(tab, forKey: key)
        }
        if values[item] != tab { values[item] = tab }
    }

    func binding(for item: SidebarItem, default fallback: String) -> Binding<String> {
        Binding(
            get: { self.value(for: item, default: fallback) },
            set: { self.set($0, for: item) }
        )
    }
}

struct DiagnosticsRailPage: View {
    @Environment(AppModel.self) private var appModel

    private var tab: Binding<String> {
        ShellRailTabStore.shared.binding(for: .diagnostics, default: "diagnostics")
    }

    private struct RunSelection: Identifiable { let id: String }

    static var tabs: [ShellTab<String>] {
        [ShellTab(key: "diagnostics", title: "Diagnostics"), ShellTab(key: "Cognition", title: "Cognition"),
            ShellTab(key: "Inspector", title: "Chat turn details")]
    }

    var body: some View {
        SurfaceLayoutContent(appModel.shellLayout) { layout in
        ShellTabbedPage(
            title: "Diagnostics",
            tabs: ShellRailTab.shown(.diagnostics, Self.tabs, layout),
            selection: tab
        ) { key in
            switch key {
            case "diagnostics":
                FacePageView(page: "diagnostics", isReading: appModel.panelIsReading(.diagnostics))
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
        .keepsShownTab(Self.tabs, tab)
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
