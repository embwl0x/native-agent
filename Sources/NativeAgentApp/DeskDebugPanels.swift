// B2.6 (g): DeskView's debug disclosures — the compact projection the agent
// reads in-context, and the raw all-items table with aliases/handles/numbers —
// moved OUT of the Workshop (DeskView) and INTO Diagnostics ▸ Cognition, so the
// Workshop surface keeps zero debug chrome. The rendering is a move (not a
// rewrite) of DeskView.agentViewDisclosure / .allItemsDisclosure; this view
// loads its own desk state independently.

import SwiftUI
import PersistenceCore

struct DeskDebugPanels: View {
    @Environment(AppModel.self) private var appModel
    @State private var items: [DeskItem] = []
    @State private var projection: String = ""
    @State private var showAgentView = false
    @State private var showAllItems = false

    private var dataRoot: URL { PersistenceCore.defaultDataRoot() }

    var body: some View {
        NativePanel(title: "Desk (debug)", systemImage: "tablecells", tint: .gray) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                Text("The Workshop bench, as raw state — the compact projection the agent reads in-context and the underlying records with their aliases and handles.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                agentViewDisclosure
                allItemsDisclosure
            }
        }
        .task { await load() }
    }

    // MARK: agent's compact view (the projection she actually reads)

    private var agentViewDisclosure: some View {
        DisclosureGroup(isExpanded: $showAgentView) {
            Text(projection.isEmpty ? "\u{2014}" : projection)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label("\(appModel.agentDisplayName)'s view (the compact projection used in context)", systemImage: "eye")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: all items (debug) — raw aliases/handles

    private var allItemsDisclosure: some View {
        DisclosureGroup(isExpanded: $showAllItems) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.handle) { item in
                    Text("\(item.alias)  \(item.handle)  \(item.kind.rawValue)  \(item.status.rawValue)  \(item.origin.rawValue)  \(item.project)  —  \(item.title)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label("All items (debug — raw records with numbers)", systemImage: "tablecells")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    // MARK: load (own desk read — lenient; a broken read leaves the panel empty)

    @MainActor private func load() async {
        let root = dataRoot
        let state = await Task.detached(priority: .utility) {
            try? await SwiftNativeDeskStore(dataRoot: root).liveState()
        }.value
        guard !Task.isCancelled, let state else { return }
        items = state.items
        projection = DeskProjection.render(state)
    }
}
