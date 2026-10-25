// Diagnostics renders the engine’s retained Desk revision.

import SwiftUI
import Desk
import EngineRuntime

// Blueprint: | `DeskDebugPanels.swift` | `DeskDebugPanels`: diagnostic disclosures over the engine's retained Desk revision |

struct DeskDebugPanels: View {
    @Environment(AppModel.self) private var appModel
    private var desk: DeskFacade { appModel.engine.desk }
    let agentDisplayName: String
    @State private var showAgentView = false
    @State private var showAllItems = false

    var body: some View {
        NativePanel(title: "Desk (debug)", systemImage: "tablecells", tint: .gray) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                Text("The Desk, as raw state — the compact projection the agent reads in-context and the underlying records with their aliases and handles.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let reason = desk.board.deskError { Text(reason).foregroundStyle(.orange) }
                agentViewDisclosure(desk.board)
                allItemsDisclosure(desk.board)
            }
        }
        .task { _ = await desk.loadBoard() }
    }

    // MARK: agent's compact view (the projection she actually reads)

    private func agentViewDisclosure(_ board: DeskBoardRead) -> some View {
        DisclosureGroup(isExpanded: $showAgentView) {
            Text(board.debugProjection.isEmpty ? "\u{2014}" : board.debugProjection)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .houseInset(in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label("\(agentDisplayName)'s view (the compact projection used in context)", systemImage: "eye")
                .font(.callout).foregroundStyle(.secondary)
                .togglesDisclosure($showAgentView)
        }
        .padding(.top, 8)
    }

    // MARK: all items (debug) — raw aliases/handles

    private func allItemsDisclosure(_ board: DeskBoardRead) -> some View {
        DisclosureGroup(isExpanded: $showAllItems) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(board.items, id: \.handle) { item in
                    Text("\(item.alias)  \(item.handle)  \(item.kind.rawValue)  \(item.status.rawValue)  \(item.origin.rawValue)  \(item.project)  —  \(item.title)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .houseInset(in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label("All items (debug — raw records with numbers)", systemImage: "tablecells")
                .font(.callout).foregroundStyle(.secondary)
                .togglesDisclosure($showAllItems)
        }
        .padding(.top, 2)
    }

}
