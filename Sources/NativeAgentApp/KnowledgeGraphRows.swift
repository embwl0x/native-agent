import SwiftUI
import MemoryV2
import NativeAgentShared
// Blueprint: | `KnowledgeGraphRows.swift` | Entity rows and detail render `MemoryFacade.graphSnapshot`, without separate neighborhood reads |

// ---------------------------------------------------------------------------
// MARK: - Entity row
// ---------------------------------------------------------------------------

struct KGEntityRow: View {
    let entity: KnowledgeGraphEntity

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            Image(systemName: knowledgeGraphTypeSymbols[entity.type] ?? "circle")
                .foregroundStyle(KGEntityRow.typeColor(entity.type))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(NativeAgentFont.body)
                Text(entity.type.capitalized)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let count = entity.mentionCount, count > 1 {
                HStack(spacing: 3) {
                    Image(systemName: "text.alignleft")
                        .font(.caption2)
                    Text("\(count)").font(NativeAgentFont.label)
                }
                .foregroundStyle(.tertiary)
                .help("Mentioned \(count) time\(count == 1 ? "" : "s") across indexed documents.")
            }
        }
        .padding(.vertical, NativeAgentSpacing.xs)
    }

    static func typeColor(_ type: String) -> Color {
        switch type {
        case "person": return .blue
        case "organization": return .indigo
        case "project": return .orange
        case "concept": return .purple
        case "place": return .green
        case "event": return .red
        case "tool": return .gray
        case "fact": return .teal
        default: return .secondary
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Entity detail
// ---------------------------------------------------------------------------

struct KGEntityDetailView: View {
    let entity: KnowledgeGraphEntity
    let memory: MemoryFacade
    let selectableEntityIDs: Set<String>
    let onSelectEntity: (String) -> Void

    var body: some View {
        let neighbors = memory.neighborhood(entityID: entity.id)
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                // Header: the kit's card (content, so a fill — never glass);
                // the entity type's colour stays on its icon and name.
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        Image(systemName: knowledgeGraphTypeSymbols[entity.type] ?? "circle")
                            .font(.title2)
                            .foregroundStyle(KGEntityRow.typeColor(entity.type))
                        Text(entity.name)
                            .font(NativeAgentFont.section)
                            .foregroundStyle(KGEntityRow.typeColor(entity.type))
                        Spacer()
                        StatusBadge(text: entity.type.capitalized, status: "info")
                    }
                    if let count = entity.mentionCount {
                        LabeledRow(label: "Mentions", value: "\(count)")
                    }
                    if let first = entity.firstSeen {
                        LabeledRow(label: "First seen", value: String(first.prefix(10)))
                    }
                    if let last = entity.lastSeen {
                        LabeledRow(label: "Last seen", value: String(last.prefix(10)))
                    }
                    if let aliases = entity.aliases, !aliases.isEmpty {
                        LabeledRow(label: "Aliases", value: aliases.joined(separator: ", "))
                    }
                    if let summary = entity.summary, !summary.isEmpty {
                        Divider()
                        Text(summary).font(NativeAgentFont.body).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NativeAgentLayout.cardPadding)
                .aliveCard()

                // Edges / neighbors
                let relationshipState = KnowledgeGraphPresentation.entityDetailRelationships(
                    isLoading: memory.graphLoading,
                    error: memory.graphLoadError,
                    response: neighbors
                )
                switch relationshipState {
                case .loading:
                    ProgressView("Loading neighbors…")
                case let .failed(loadError):
                    // Failed neighbor reads show their error and Retry, never an empty relationship list.
                    NativePanel(title: "Relationships") {
                        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .font(NativeAgentFont.body)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                            Button("Retry", systemImage: "arrow.clockwise") {
                                Task { await memory.loadGraph() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                case .none:
                    NativePanel(title: "Relationships") {
                        Text("No relationships recorded yet.")
                            .font(NativeAgentFont.body).foregroundStyle(.secondary)
                    }
                case let .loaded(count):
                    if let nbr = neighbors {
                        NativePanel(title: "Relationships (\(count))") {
                            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                                ForEach(nbr.edges) { edge in
                                    KGEdgeRow(
                                        edge: edge, entities: nbr.neighbors, rootId: entity.id,
                                        selectableEntityIDs: selectableEntityIDs,
                                        onSelectEntity: onSelectEntity
                                    )
                                }
                            }
                        }
                    }
                case .notLoaded:
                    NativePanel(title: "Relationships") {
                        Text("Relationship evidence has not loaded yet.")
                            .font(NativeAgentFont.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(NativeAgentSpacing.lg)
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(NativeAgentFont.label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(NativeAgentFont.body)
            Spacer()
        }
    }
}

private struct KGEdgeRow: View {
    let edge: KnowledgeGraphEdge
    let entities: [String: KnowledgeGraphEntity]
    let rootId: String
    let selectableEntityIDs: Set<String>
    let onSelectEntity: (String) -> Void

    private var otherName: String {
        let otherID = edge.from == rootId ? edge.to : edge.from
        return entities[otherID]?.name ?? otherID
    }

    var body: some View {
        if let destination = KnowledgeGraphPresentation.relationshipNavigationDestination(
            edge: edge, rootID: rootId, visibleIDs: selectableEntityIDs
        ) {
            Button { onSelectEntity(destination) } label: {
                relationshipContent(isLink: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(otherName) in Knowledge Graph")
            .accessibilityLabel("Show entity \(otherName)")
            .accessibilityHint("Selects this related entity without changing your filters.")
        } else {
            relationshipContent(isLink: false)
        }
        Divider()
    }

    private func relationshipContent(isLink: Bool) -> some View {
        HStack(spacing: NativeAgentSpacing.xs) {
            Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
            let direction = edge.from == rootId ? "→" : "←"
            Text("\(direction) \(KnowledgeGraphPresentation.relationshipLabel(edge.kind)) · \(otherName)")
                .font(NativeAgentFont.body)
                .foregroundStyle(isLink ? Color.accentColor : Color.primary)
            Spacer()
            if let w = edge.weight {
                Text(String(format: "%.2f", w)).font(NativeAgentFont.label).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

extension KnowledgeGraphPresentation {
    enum EntityDetailRelationships: Equatable {
        case loading
        case failed(String)
        case notLoaded
        case none
        case loaded(count: Int)
    }

    static func relationshipLabel(_ kind: String) -> String {
        let words = kind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Relationship navigation uses the same filtered selection boundary as
    /// the list and canvas; it never silently clears filters to reveal a node.
    static func relationshipNavigationDestination(
        edge: KnowledgeGraphEdge,
        rootID: String,
        visibleIDs: Set<String>
    ) -> String? {
        guard edge.from == rootID || edge.to == rootID else { return nil }
        let destination = edge.from == rootID ? edge.to : edge.from
        guard !destination.isEmpty, destination != rootID else { return nil }
        return reconciledSelection(destination, visibleIDs: visibleIDs)
    }

    static func entityDetailRelationships(
        isLoading: Bool,
        error: String?,
        response: KnowledgeGraphNeighborhood?
    ) -> EntityDetailRelationships {
        if isLoading { return .loading }
        if let error {
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? "Relationship details could not be loaded." : detail)
        }
        guard let response else { return .notLoaded }
        return response.edges.isEmpty ? .none : .loaded(count: response.edges.count)
    }
}
