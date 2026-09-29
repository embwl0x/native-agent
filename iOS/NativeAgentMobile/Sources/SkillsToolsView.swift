import SwiftUI

enum ToolCatalogPresentation {
    enum ContentState: Equatable {
        case loading
        case syncError(String)
        case unpublished
        case noMatches
        case content
    }
    enum Status: Equatable {
        case known(String)
        case unknown
    }

    enum Automaticity: Equatable {
        case automatic
        case manual
        case unknown
    }

    static func contentState(isLoading: Bool, error: String?, toolCount: Int, visibleCount: Int) -> ContentState {
        if isLoading && toolCount == 0 { return .loading }
        if toolCount == 0, let error, !error.isEmpty { return .syncError(error) }
        if toolCount == 0 { return .unpublished }
        if visibleCount == 0 { return .noMatches }
        return .content
    }

    static func visibleTools(_ tools: [ToolRecord], query: String) -> [ToolRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tools }
        return tools.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.description?.localizedCaseInsensitiveContains(needle) ?? false)
                || ($0.kind?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    static func status(for tool: ToolRecord) -> Status {
        guard let raw = tool.status?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        return .known(raw.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    static func automaticity(for tool: ToolRecord) -> Automaticity {
        switch tool.autoRun {
        case true: return .automatic
        case false: return .manual
        case nil: return .unknown
        }
    }
}

// MARK: - Skills & Tools

private enum MobileSkillsToolsSection: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case tools = "Tools"

    var id: String { rawValue }
}

/// One combined destination matching the Mac app. Each page retains its own
/// read/refresh owner; this wrapper owns only the visible page selection and
/// can either host its own navigation stack or live inside More's stack.
struct SkillsToolsView: View {
    @AppStorage("NativeAgentMobile.skillsToolsSection") private var selectedRawValue = MobileSkillsToolsSection.skills.rawValue
    private let embedInNavigationStack: Bool

    init(embedInNavigationStack: Bool = true) {
        self.embedInNavigationStack = embedInNavigationStack
    }

    private var selection: Binding<MobileSkillsToolsSection> {
        Binding(
            get: { MobileSkillsToolsSection(rawValue: selectedRawValue) ?? .skills },
            set: { selectedRawValue = $0.rawValue }
        )
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { content }
        } else {
            content
        }
    }

    /// The page switch sits under the header; each page owns its own scroll,
    /// pull-to-refresh and search.
    private var picker: some View {
        AliveSegmentedPicker(selection: selection, options: MobileSkillsToolsSection.allCases) { $0.rawValue }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Skills and Tools page")
            .accessibilityIdentifier("skills-tools-section-picker")
    }

    private var content: some View {
        Group {
            switch selection.wrappedValue {
            case .skills:
                SkillLifecycleView(accessory: AnyView(picker))
            case .tools:
                MobileToolCatalogView(accessory: AnyView(picker))
            }
        }
        .macSyncErrorBanner()
    }
}

@MainActor
private final class MobileToolCatalogStore: ObservableObject {
    @Published var tools: [ToolRecord] = []
    @Published var isLoading = false
    @Published var error: String?

    func refresh(pairingStore: PairingStore) async {
        #if DEBUG
        if MobileDesignSamples.screen != nil {
            tools = MobileToolDesignSample.tools
            return
        }
        #endif
        guard pairingStore.isPaired else {
            error = "Pair iPhone with the Mac to see tools."
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        await iCloudBridge.shared.pollIncomingNow()
        if let rows: [ToolRecord] = await iCloudSyncEngine.shared.loadSnapshotArrayAsync(
            named: "tools_snapshot.json"
        ) {
            tools = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else if tools.isEmpty {
            error = "No tool catalog has synced yet — Mac is publishing."
        }
    }
}

#if DEBUG
private enum MobileToolDesignSample {
    static let tools: [ToolRecord] = [
        ToolRecord(id: "t1", name: "calendar_read", kind: "connector", status: "available",
                   description: "Look up upcoming events across your calendars.", autoRun: true),
        ToolRecord(id: "t2", name: "web_search", kind: "builtin", status: "available",
                   description: "Search the web and read the pages that answer the question.", autoRun: true),
        ToolRecord(id: "t3", name: "shell_exec", kind: "builtin", status: "policy_locked",
                   description: "Run a command in Terminal on the Mac.", autoRun: false),
    ]
}
#endif

private struct MobileToolCatalogView: View {
    let accessory: AnyView
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var store = MobileToolCatalogStore()
    @State private var searchText = ""

    private var visibleTools: [ToolRecord] {
        ToolCatalogPresentation.visibleTools(store.tools, query: searchText)
    }

    var body: some View {
        AlivePage(title: "Skills & Tools", line: "What I can do, and how.",
                 freshnessGroup: "skills_snapshot", accessory: accessory) {
            switch ToolCatalogPresentation.contentState(
                isLoading: store.isLoading,
                error: store.error,
                toolCount: store.tools.count,
                visibleCount: visibleTools.count
            ) {
            case .loading:
                ProgressView("Loading tools…")
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            case .syncError(let message):
                AliveCalmState(title: "Tools aren’t here yet", line: message,
                               actionTitle: "Try again", action: retry)
            case .unpublished:
                AliveCalmState(title: "No tools yet",
                               line: "The Mac hasn’t published a tool list this iPhone can read.",
                               actionTitle: "Try again", action: retry)
            case .noMatches:
                AliveCalmState(title: "No tools match",
                               line: "Try a different name or description.")
            case .content:
                AliveSection("Tools") {
                    ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { AliveDivider() }
                        ToolCatalogRow(tool: tool)
                    }
                }
            }
        }
        // The search floats over the list, like Memories.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Nothing to search until the Mac has published tools.
            if !store.tools.isEmpty || !searchText.isEmpty {
                AliveSearchField(prompt: "Search tools", text: $searchText)
                    .padding(.horizontal, AliveMetrics.pageInset)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
        .refreshable {
            await store.refresh(pairingStore: pairingStore)
        }
        .task {
            await store.refresh(pairingStore: pairingStore)
        }
    }

    private func retry() {
        Task { await store.refresh(pairingStore: pairingStore) }
    }
}

private struct ToolCatalogRow: View {
    let tool: ToolRecord

    /// Status, how it runs and its kind, folded into one secondary line.
    private var statusLine: String {
        var parts: [String] = []
        switch ToolCatalogPresentation.status(for: tool) {
        case .known(let value): parts.append(value.prefix(1).uppercased() + value.dropFirst().lowercased())
        case .unknown: parts.append("Status unknown")
        }
        switch ToolCatalogPresentation.automaticity(for: tool) {
        case .automatic: parts.append("runs on its own")
        case .manual: parts.append("asks first")
        case .unknown: break
        }
        if let kind = tool.kind, !kind.isEmpty {
            parts.append(kind.lowercased() == "builtin" ? "built in" : AliveWords.humanized(kind).lowercased())
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AliveWords.humanized(tool.name))
                .font(.body)
                .foregroundStyle(AlivePalette.text)
                .textSelection(.enabled)
            if let description = tool.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
        }
        .aliveRow()
        .accessibilityElement(children: .combine)
    }
}
