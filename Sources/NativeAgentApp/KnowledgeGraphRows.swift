import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Entity row
// ---------------------------------------------------------------------------

// PATCH-2026-05-07: polish-KnowledgeGraphView static type helpers promoted to internal for detail view
struct KGEntityRow: View {
    let entity: KGEntity

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            Image(systemName: KGEntityRow.typeIcon(entity.type))
                .foregroundStyle(KGEntityRow.typeColor(entity.type))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(NativeAgentFont.body)
                Text(entity.type.capitalized)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let count = entity.mention_count, count > 1 {
                // ui-taste-sweep 2026-06-07: bare "8" with no context — a
                // user has no idea what the number means. Now: icon + count
                // + tooltip so it reads as "this entity was mentioned 8
                // times."
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

    static func typeIcon(_ type: String) -> String {
        switch type {
        case "person": return "person.circle"
        case "organization": return "building.2"
        case "project": return "folder"
        case "concept": return "lightbulb"
        case "place": return "mappin.circle"
        case "event": return "calendar"
        case "tool": return "wrench.and.screwdriver"
        case "fact": return "text.quote"
        default: return "circle"
        }
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
    let entity: KGEntity
    let api: NativeClient
    let selectableEntityIDs: Set<String>
    let onSelectEntity: (String) -> Void

    @State private var neighbors: KGNeighborsResponse? = nil
    @State private var loading = false
    @State private var loadError: String? = nil

    // PATCH-2026-05-07: polish-KnowledgeGraphView GlassCard entity header tinted by entity type
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                // Header with GlassCard tinted by entity type
                GlassCard(tint: KGEntityRow.typeColor(entity.type)) {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        HStack(spacing: NativeAgentSpacing.sm) {
                            Image(systemName: KGEntityRow.typeIcon(entity.type))
                                .font(.title2)
                                .foregroundStyle(KGEntityRow.typeColor(entity.type))
                            GradientText(
                                text: entity.name,
                                colors: [KGEntityRow.typeColor(entity.type), .purple],
                                font: NativeAgentFont.section
                            )
                            Spacer()
                            StatusBadge(text: entity.type.capitalized, status: "info")
                        }
                        if let count = entity.mention_count {
                            LabeledRow(label: "Mentions", value: "\(count)")
                        }
                        if let first = entity.first_seen {
                            LabeledRow(label: "First seen", value: String(first.prefix(10)))
                        }
                        if let last = entity.last_seen {
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
                }

                // Edges / neighbors
                let relationshipState = KnowledgeGraphPresentation.entityDetailRelationships(
                    isLoading: loading,
                    error: loadError,
                    rootID: entity.id,
                    response: neighbors
                )
                let visibleEdges = KnowledgeGraphPresentation.visibleRelationshipEdges(
                    rootID: entity.id,
                    response: neighbors
                )
                switch relationshipState {
                case .loading:
                    ProgressView("Loading neighbors…")
                case let .failed(loadError):
                    // ui-honesty 2026-06-10: loadError was captured but never
                    // rendered — a failed neighbors fetch looked identical to
                    // "no relationships". Show the error + a Retry.
                    NativePanel(title: "Relationships") {
                        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .font(NativeAgentFont.body)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                            Button("Retry", systemImage: "arrow.clockwise") {
                                Task { await loadNeighbors() }
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
                        NativePanel(title: "Relationships (\(count))", systemImage: "arrow.triangle.branch") {
                            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                                ForEach(visibleEdges) { edge in
                                    KGEdgeRow(
                                        edge: edge, entities: nbr.neighbors, rootId: entity.id,
                                        selectableEntityIDs: selectableEntityIDs,
                                        onSelectEntity: onSelectEntity
                                    )
                                }
                            }
                        }
                    }
                case let .partial(visibleCount, omittedUnrelatedCount):
                    if let nbr = neighbors {
                        NativePanel(title: "Relationships (\(visibleCount))", systemImage: "arrow.triangle.branch") {
                            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                                Label(
                                    "\(omittedUnrelatedCount) unrelated relationship record\(omittedUnrelatedCount == 1 ? " was" : "s were") omitted.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(NativeAgentFont.label)
                                .foregroundStyle(.orange)
                                if visibleEdges.isEmpty {
                                    Text("No usable relationships were returned for this entity.")
                                        .font(NativeAgentFont.body)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(visibleEdges) { edge in
                                        KGEdgeRow(
                                            edge: edge, entities: nbr.neighbors, rootId: entity.id,
                                            selectableEntityIDs: selectableEntityIDs,
                                            onSelectEntity: onSelectEntity
                                        )
                                    }
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
        .task(id: entity.id) { await loadNeighbors() }
    }

    private func loadNeighbors() async {
        loading = true; defer { loading = false }
        loadError = nil
        do {
            neighbors = try await api.getKGEntity(id: entity.id)
        } catch {
            // PATCH-2026-05-07: surface-load-errors Don't swallow.
            neighbors = nil
            loadError = error.localizedDescription
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
    let edge: KGEdge
    let entities: [String: KGEntity]
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
