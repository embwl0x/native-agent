import SwiftUI

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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.tools }
        return store.tools.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.kind?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if store.isLoading && store.tools.isEmpty {
                ProgressView("Loading tool catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleTools.isEmpty {
                AppEmptyState(
                    title: searchText.isEmpty ? "No tools synced" : "No tools match",
                    systemImage: "wrench.and.screwdriver",
                    description: store.error ?? "The paired Mac publishes the agent's trust-aware tool catalog."
                )
            } else {
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

    private var status: String {
        let value = (tool.status ?? "on demand").replacingOccurrences(of: "_", with: " ")
        return value.isEmpty ? "On demand" : value.capitalized
    }

    private var statusColor: Color {
        switch (tool.status ?? "").lowercased() {
        case "active", "loaded", "available": .green
        case "policy_locked", "blocked", "unavailable": .orange
        default: NativeAgentPalette.agentAccent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(tool.name)
                    .font(AppFont.section)
                    .textSelection(.enabled)
                Spacer()
                Text(status)
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
                if tool.autoRun == true {
                    Label("Automatic", systemImage: "bolt.fill")
                }
            }
            .font(AppFont.tag)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
