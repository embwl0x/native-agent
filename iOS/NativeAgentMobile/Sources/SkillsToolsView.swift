import SwiftUI
import NativeAgentShared
// Blueprint: | `SkillsToolsView.swift` | Combined catalog refresh/loading/error owner; tool renderer reads shared sync catalog and retains local search state |

enum ToolCatalogPresentation {
    enum ContentState: Equatable {
        case loading
        case syncError(String)
        case unpublished
        case noMatches
        case content
    }

    static func contentState(isLoading: Bool, error: String?, toolCount: Int, visibleCount: Int) -> ContentState {
        if isLoading && toolCount == 0 { return .loading }
        if toolCount == 0, let error, !error.isEmpty { return .syncError(error) }
        if toolCount == 0 { return .unpublished }
        if visibleCount == 0 { return .noMatches }
        return .content
    }

}

// MARK: - Skills & Tools

private enum MobileSkillsToolsSection: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case tools = "Tools"

    var id: String { rawValue }
}

/// One combined destination matching the Mac app. Both pages read the shared
/// sync catalog; this destination owns their one refresh and visible page
/// selection, inside its caller's navigation stack.
struct SkillsToolsView: View {
    @AppStorage("NativeAgentMobile.skillsToolsSection") private var selectedRawValue = MobileSkillsToolsSection.skills.rawValue
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var isLoading = false
    @State private var error: String?
    private let sync = iCloudSyncEngine.shared

    private var selection: Binding<MobileSkillsToolsSection> {
        Binding(
            get: { MobileSkillsToolsSection(rawValue: selectedRawValue) ?? .skills },
            set: { selectedRawValue = $0.rawValue }
        )
    }

    /// The page switch sits under the header; each page owns its scroll and filters.
    private var picker: some View {
        AliveSegmentedPicker(selection: selection, options: MobileSkillsToolsSection.allCases) { $0.rawValue }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Skills and Tools page")
            .accessibilityIdentifier("skills-tools-section-picker")
    }

    var body: some View {
        VStack(spacing: 0) {
            switch selection.wrappedValue {
            case .skills:
                SkillLifecycleView(accessory: AnyView(picker), isLoading: isLoading, error: error, refresh: { await refresh() })
            case .tools:
                MobileToolCatalogView(accessory: AnyView(picker), isLoading: isLoading, error: error, refresh: { await refresh() })
            }
        }
        .macSyncErrorBanner()
        .refreshable { await refresh() }
        .task(id: sync.groupTransportDeliveryAt["catalog"]) {
            await refresh(pollIncoming: sync.groupTransportDeliveryAt["catalog"] == nil)
        }
    }

    private func refresh(pollIncoming: Bool = true) async {
        guard !isLoading else { return }
        guard pairingStore.isPaired else {
            error = "Pair iPhone with the Mac to see skills and tools."
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        if pollIncoming { await iCloudBridge.shared.pollIncomingNow() }
        if !(await sync.refreshCatalogSnapshot()) {
            error = "Some of the skill and tool catalog is still downloading from iCloud."
        }
    }
}

#if DEBUG
private enum MobileToolDesignSample {
    static let tools: [MobileToolCatalogRecord] = [
        MobileToolCatalogRecord(id: "t2", name: "web_search", kind: "builtin", status: "available",
                   description: "Search the web and read the pages that answer the question.", autoRun: true),
        MobileToolCatalogRecord(id: "t3", name: "shell_exec", kind: "builtin", status: "policy_locked",
                   description: "Run a command in Terminal on the Mac.", autoRun: false),
    ]
}
#endif

private struct MobileToolCatalogView: View {
    let accessory: AnyView
    let isLoading: Bool
    let error: String?
    let refresh: () async -> Void
    private let sync = iCloudSyncEngine.shared
    @State private var searchText = ""
    @State private var searchIndex = MobileSearchIndex<MobileToolCatalogRecord>()
    @State private var searchResults: [MobileToolCatalogRecord] = []

    private var tools: [MobileToolCatalogRecord] {
        #if DEBUG
        if MobileDesignSamples.screen != nil { return MobileToolDesignSample.tools }
        #endif
        return sync.tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var visibleTools: [MobileToolCatalogRecord] {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tools : searchResults
    }

    var body: some View {
        let visibleTools = visibleTools
        return AlivePage(title: "Skills & Tools", line: "What I can do, and how.",
                 freshnessGroup: "tools_snapshot", accessory: accessory) {
            switch ToolCatalogPresentation.contentState(
                isLoading: isLoading,
                error: error,
                toolCount: tools.count,
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
            if !tools.isEmpty || !searchText.isEmpty {
                AliveSearchField(prompt: "Search tools", text: $searchText)
                    .padding(.horizontal, AliveMetrics.pageInset)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
        .task(id: MobileSearchInput(rows: tools, query: searchText)) {
            let input = MobileSearchInput(rows: tools, query: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            let result = await searchIndex.search(input, maximum: input.rows.count,
                fields: { [$0.name, $0.description ?? "", $0.kind ?? ""] },
                matches: { $0.localizedCaseInsensitiveContains($1) })
            guard !Task.isCancelled else { return }
            searchResults = result
        }
    }

    private func retry() {
        Task { await refresh() }
    }
}

private struct ToolCatalogRow: View {
    let tool: MobileToolCatalogRecord

    /// Status, how it runs and its kind, folded into one secondary line.
    private var statusLine: String {
        var parts: [String] = []
        if let raw = tool.status?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let value = raw.replacingOccurrences(of: "_", with: " ").capitalized
            parts.append(value.prefix(1).uppercased() + value.dropFirst().lowercased())
        } else {
            parts.append("Status unknown")
        }
        if let autoRun = tool.autoRun {
            parts.append(autoRun ? "runs on its own" : "asks first")
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
