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

private enum MobileSkillsToolsSection: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case tools = "Tools"

    var id: String { rawValue }
}

/// One primary destination matching the Mac app. Each page retains its own
/// read/refresh owner; this wrapper owns only the visible page selection.
struct SkillsToolsView: View {
    @AppStorage("NativeAgentMobile.skillsToolsSection") private var selectedRawValue = MobileSkillsToolsSection.skills.rawValue

    private var selection: Binding<MobileSkillsToolsSection> {
        Binding(
            get: { MobileSkillsToolsSection(rawValue: selectedRawValue) ?? .skills },
            set: { selectedRawValue = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Skills and Tools page", selection: selection) {
                    ForEach(MobileSkillsToolsSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("skills-tools-section-picker")

                Divider()

                switch selection.wrappedValue {
                case .skills:
                    SkillLifecycleView()
                case .tools:
                    MobileToolCatalogView()
                }
            }
            .navigationTitle("Skills & Tools")
            .macSyncErrorBanner()
            // Sweep R4 C11.4: skills and tools are read straight from the last
            // Mac snapshot, so "is the Mac reachable" decides whether this list
            // is current.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    MacStatusChip()
                }
            }
        }
    }
}

@MainActor
private final class MobileToolCatalogStore: ObservableObject {
    @Published var tools: [ToolRecord] = []
    @Published var isLoading = false
    @Published var error: String?

    func refresh(pairingStore: PairingStore) async {
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

private struct MobileToolCatalogView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @StateObject private var store = MobileToolCatalogStore()
    @State private var searchText = ""

    private var visibleTools: [ToolRecord] {
        ToolCatalogPresentation.visibleTools(store.tools, query: searchText)
    }

    var body: some View {
        Group {
            switch ToolCatalogPresentation.contentState(
                isLoading: store.isLoading,
                error: store.error,
                toolCount: store.tools.count,
                visibleCount: visibleTools.count
            ) {
            case .loading:
                ProgressView("Loading tool catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .syncError(let message):
                AppEmptyState(
                    title: "Tool catalog unavailable",
                    systemImage: "icloud.slash",
                    kind: .unavailable,
                    description: message
                )
            case .unpublished:
                AppEmptyState(
                    title: "No tools synced",
                    systemImage: "wrench.and.screwdriver",
                    kind: .unavailable,
                    description: "The paired Mac has not published a readable tool catalog yet."
                )
            case .noMatches:
                AppEmptyState(
                    title: "No tools match",
                    systemImage: "magnifyingglass",
                    kind: .empty,
                    description: "Try a different tool name, kind, or description."
                )
            case .content:
                List(visibleTools) { tool in
                    ToolCatalogRow(tool: tool)
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search tools")
        .refreshable {
            await store.refresh(pairingStore: pairingStore)
        }
        .task {
            await store.refresh(pairingStore: pairingStore)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct ToolCatalogRow: View {
    let tool: ToolRecord

    private var statusColor: Color {
        switch ToolCatalogPresentation.status(for: tool) {
        case .known(let status):
            switch status.lowercased() {
            case "active", "loaded", "available": return .green
            case "policy locked", "blocked", "unavailable": return .orange
            default: return NativeAgentPalette.agentAccent
            }
        case .unknown:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(tool.name)
                    .font(AppFont.section)
                    .textSelection(.enabled)
                Spacer()
                Text(statusText)
                    .font(AppFont.tag)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            if let description = tool.description, !description.isEmpty {
                Text(description)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                if let kind = tool.kind, !kind.isEmpty {
                    Label(kind, systemImage: "arrow.triangle.branch")
                }
                switch ToolCatalogPresentation.automaticity(for: tool) {
                case .automatic:
                    Label("Automatic", systemImage: "bolt.fill")
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.yellow.opacity(0.16), in: Capsule())
                case .manual:
                    Label("Manual", systemImage: "hand.raised")
                case .unknown:
                    Label("Automation unknown", systemImage: "questionmark.circle")
                }
            }
            .font(AppFont.tag)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch ToolCatalogPresentation.status(for: tool) {
        case .known(let value): return value
        case .unknown: return "Status unknown"
        }
    }
}
