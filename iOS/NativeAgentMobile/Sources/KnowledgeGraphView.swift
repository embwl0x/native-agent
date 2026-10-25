// KnowledgeGraphView.swift — iOS port of Mac KnowledgeGraphView.
// Data source: a Mac-produced iCloud knowledge_graph.json projection from the
// canonical KnowledgeGraph reader. The retired /v1 HTTP transport is not
// available on iPhone.
// Phone-friendly: list + tap-to-detail sheet and pull-to-refresh.
//
// List, detail headers and neighbors all read the sync engine's typed graph.
import SwiftUI
import NativeAgentShared
// Blueprint: | `KnowledgeGraphView.swift` | Graph presentation and ID-resolved entity details/neighbors from the shared typed graph; local search/loading state |

enum KnowledgeGraphPresentation {
    enum ContentState: Equatable {
        case loading
        case unpublished
        case emptyPublished
        case noMatches
        case content
    }

    static func contentState(isLoading: Bool, hasPublishedSnapshot: Bool, entityCount: Int, query: String) -> ContentState {
        if isLoading && entityCount == 0 { return .loading }
        guard hasPublishedSnapshot else { return .unpublished }
        if entityCount == 0 { return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyPublished : .noMatches }
        return .content
    }

    static func entityCountHeader(visibleCount: Int) -> String {
        let count = max(0, visibleCount)
        return count == 1 ? "1 entity" : "\(count) entities"
    }

    static func filterContext(visibleCount: Int, totalCount: Int, isFiltered: Bool) -> String? {
        guard isFiltered, totalCount > visibleCount else { return nil }
        return "Showing \(max(0, visibleCount)) of \(totalCount) published entities."
    }
}

enum KnowledgeGraphEmptyStatePresentation {
    static let unpublishedDescription = "Knowledge Graph is read-only on iPhone. Keep the Mac app open until it publishes a readable snapshot."
    static let emptyPublishedDescription = "Knowledge Graph is read-only on iPhone. It will update after the Mac publishes entities; pull to refresh later."
}

/// User-facing reasons the detail sheet cannot resolve its selected entity.
/// A downloaded graph can legitimately no longer contain a row that was
/// selected from an older list snapshot, so do not misreport that case as an
/// iCloud delivery failure.
enum KnowledgeGraphDetailNeighborsPresentation {
    enum UnavailableReason: Equatable {
        case entityNoLongerPublished
    }

    static func message(for reason: UnavailableReason) -> String {
        switch reason {
        case .entityNoLongerPublished:
            return "This entity is no longer in the published Knowledge Graph."
        }
    }

    static func neighborName(id: String, publishedName: String?) -> String {
        guard let publishedName = publishedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !publishedName.isEmpty else {
            return "Unknown entity (\(id)) — graph data is incomplete."
        }
        return publishedName
    }
}

// MARK: - Models

// Dual-shape decoder.
// CANONICAL (Mac-produced checked projection):
//   {entities: [...], edges: [...], total_entities, total_edges, page}.
// LEGACY DICT SHAPE remains readable only for pre-SQLite snapshots:
//   {_commit_seq, version, entities: { "<id>": {...}, ... }, edges: [...]}.
//
// We retain both decoders during migration. Either way we expose a normalized
// `entities: [KGEntity]` array so
// the SwiftUI view doesn't have to know which path was taken.
struct KGEntityResponse: Decodable, Equatable, Sendable {
    var entities: [KGEntity]
    var edges: [KGEdge]
    var total: Int
    var totalEdges: Int?
    var page: Int

    private enum CodingKeys: String, CodingKey {
        case entities, page, edges
        case total
        case totalEntities = "total_entities"
        case totalEdges = "total_edges"
        case commitSeq = "_commit_seq"
        case version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try the legacy dict shape first because decoding an array as a dict
        // fails cheaply, then decode the canonical checked array envelope.
        if let dict = try? container.decode([String: KGEntity].self, forKey: .entities) {
            // Each value's `id` falls back to its dict key if absent or blank.
            entities = dict.map { (key, value) -> KGEntity in
                var e = value
                if e.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    e.id = key
                }
                return e
            }
            // Stable order — by name, then id — so the SwiftUI list isn't random.
            entities.sort { lhs, rhs in
                if lhs.name == rhs.name { return lhs.id < rhs.id }
                return lhs.name < rhs.name
            }
            // Legacy dict shape has no trustworthy top-level totals.
            total = entities.count
            // edges is an array of KGEdge; count if present.
            edges = (try? container.decode([KGEdge].self, forKey: .edges)) ?? []
            totalEdges = edges.count
            page = 0
            return
        }

        // Checked SQLite projection uses an entity array.
        entities = try container.decode([KGEntity].self, forKey: .entities)
        edges = (try? container.decode([KGEdge].self, forKey: .edges)) ?? []
        if let decodedTotal = try? container.decode(Int.self, forKey: .total) {
            total = decodedTotal
        } else if let decodedTotal = try? container.decode(Int.self, forKey: .totalEntities) {
            total = decodedTotal
        } else {
            total = entities.count
        }
        totalEdges = try? container.decode(Int.self, forKey: .totalEdges)
        page = (try? container.decode(Int.self, forKey: .page)) ?? 0
    }
}

struct KGEntity: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var type: String
    var first_seen: String?
    var last_seen: String?
    var mention_count: Int?
    var aliases: [String]?
    var summary: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, aliases, summary
        case first_seen
        case last_seen
        case mention_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` may be absent on the value in the dict shape — caller fills it
        // in from the dict key. Default to empty so this decode doesn't fail.
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        let decodedName = try c.decode(String.self, forKey: .name)
        guard !decodedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: c,
                debugDescription: "Knowledge graph entities require a non-empty name."
            )
        }
        name = decodedName

        let decodedType = try c.decode(String.self, forKey: .type)
        guard !decodedType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Knowledge graph entities require a non-empty type."
            )
        }
        type = decodedType
        first_seen = try? c.decode(String.self, forKey: .first_seen)
        last_seen = try? c.decode(String.self, forKey: .last_seen)
        mention_count = try? c.decode(Int.self, forKey: .mention_count)
        aliases = try? c.decode([String].self, forKey: .aliases)
        summary = try? c.decode(String.self, forKey: .summary)
    }
}

private struct KGNeighborsResponse: Sendable {
    var edges: [KGEdge]
    var neighbors: [String: KGEntity]
}

struct KGEdge: Decodable, Identifiable, Equatable, Sendable {
    var id: String { "\(from)-\(to)-\(kind)" }
    var from: String
    var to: String
    var kind: String
    var weight: Double?

    init(from decoder: Decoder) throws {
        let snapshot = try KnowledgeGraphEdgeWireSnapshot(from: decoder)
        from = snapshot.from
        to = snapshot.to
        kind = snapshot.kind
        weight = snapshot.weight
    }
}

// MARK: - Store

@MainActor
private final class KGStore: ObservableObject {
    var snapshot: KGEntityResponse? { iCloudSyncEngine.shared.knowledgeGraph }
    var entities: [KGEntity] { snapshot?.entities ?? [] }
    var total: Int { snapshot?.total ?? 0 }
    @Published var isLoading = false
    @Published var bannerError: String?
    /// This is deliberately separate from `bannerError`: a quiet initial
    /// launch has neither an error nor a Mac-published projection.
    var hasPublishedSnapshot: Bool { snapshot != nil }
    static let maxSearchResults = 200

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await iCloudSyncEngine.shared.refreshKnowledgeGraphSnapshot()
        if snapshot != nil {
            bannerError = nil
        } else {
            bannerError = "Knowledge graph snapshot is still downloading from iCloud. Try again in a moment."
        }
    }

}

// MARK: - KnowledgeGraphView

struct KnowledgeGraphView: View {
    @StateObject private var store = KGStore()
    @State private var searchText = ""
    @State private var searchIndex = MobileSearchIndex<KGEntity>()
    @State private var searchResults: [KGEntity] = []
    @State private var selectedEntityID: String?

    private var displayEntities: [KGEntity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MobileDesignSamples.rows(store.entities) }
        return searchResults
    }

    var body: some View {
        let displayEntities = displayEntities
        ZStack(alignment: .top) {
            List {
                // E6: freshness of the Mac snapshot behind this graph, under the door.
                VStack(alignment: .leading, spacing: 14) {
                    AlivePageHeader(title: "Knowledge Graph", line: "The people, places and projects I know about.",
                                    style: .pushed)
                        .padding(.horizontal, 4)
                    AliveFreshnessNote(group: "knowledge_graph")
                }
                .aliveListRow(top: 4, bottom: 10)
                // Only over a graph already shown: before the first snapshot
                // the empty state and the freshness note already say this.
                if let err = store.bannerError, store.hasPublishedSnapshot {
                    Label(err, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                switch KnowledgeGraphPresentation.contentState(
                    isLoading: store.isLoading && MobileDesignSamples.screen == nil,
                    hasPublishedSnapshot: store.hasPublishedSnapshot || MobileDesignSamples.screen != nil,
                    entityCount: displayEntities.count,
                    query: searchText
                ) {
                case .loading:
                    ProgressView("Loading graph…")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                case .unpublished:
                    AliveCalmState(title: "Graph unavailable", line: KnowledgeGraphEmptyStatePresentation.unpublishedDescription)
                    .aliveListRow()
                case .emptyPublished:
                    AliveCalmState(title: "No entities", line: KnowledgeGraphEmptyStatePresentation.emptyPublishedDescription)
                    .aliveListRow()
                case .noMatches:
                    AliveCalmState(title: "No matching entities", line: "The published graph is available, but no entity matches this search.")
                    .aliveListRow()
                case .content:
                    Section {
                        ForEach(displayEntities) { entity in
                            Button {
                                selectedEntityID = entity.id
                            } label: {
                                KGEntityRowCell(entity: entity)
                            }
                            .buttonStyle(.plain)
                            // Row chrome belongs on the row, not inside its label.
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    } header: {
                        Text(KnowledgeGraphPresentation.entityCountHeader(visibleCount: displayEntities.count))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AlivePalette.secondary)
                            .textCase(nil)
                    } footer: {
                        if let context = KnowledgeGraphPresentation.filterContext(
                            visibleCount: displayEntities.count,
                            totalCount: store.total,
                            isFiltered: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            Text(context)
                                .font(.footnote)
                                .foregroundStyle(AlivePalette.secondary)
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .task(id: MobileSearchInput(rows: store.entities, query: searchText)) {
                let input = MobileSearchInput(rows: store.entities, query: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                let result = await searchIndex.search(input, maximum: KGStore.maxSearchResults,
                    fields: { [$0.name, $0.type, $0.summary ?? ""] + ($0.aliases ?? []) },
                    matches: { $0.localizedCaseInsensitiveContains($1) })
                guard !Task.isCancelled else { return }
                searchResults = result
            }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }

        }
        .animation(AppMotion.snappy, value: store.bannerError)
        .alivePageChrome(title: "Knowledge Graph", root: false)
        // The search floats over the list, like Memories: outside the chrome,
        // so the list's bottom fade runs under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Nothing to search until a graph has arrived.
            if store.hasPublishedSnapshot || MobileDesignSamples.screen != nil || !searchText.isEmpty {
                AliveSearchField(prompt: "Search people, places and projects", text: $searchText)
                    .padding(.horizontal, AliveMetrics.pageInset)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
        .macSyncErrorBanner()
        .sheet(isPresented: Binding(get: { selectedEntityID != nil }, set: { if !$0 { selectedEntityID = nil } })) {
            if let entity = MobileDesignSamples.rows(store.entities).first(where: { $0.id == selectedEntityID }) {
                KGEntityDetailSheet(entity: entity, store: store)
            } else {
                AliveCalmState(title: "Entity unavailable", line: KnowledgeGraphDetailNeighborsPresentation.message(for: .entityNoLongerPublished))
            }
        }
    }
}

// MARK: - Entity row cell

private struct KGEntityRowCell: View {
    let entity: KGEntity

    var body: some View {
        let meta = KGEntityMeta.presentation(for: entity.type)
        let mentions = entity.mention_count.flatMap { $0 > 0 ? ($0 == 1 ? "1 mention" : "\($0) mentions") : nil }
        HStack(spacing: 14) {
            Image(systemName: meta.icon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(AlivePalette.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entity.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(([meta.label] + [mentions].compactMap { $0 }).joined(separator: " \u{00B7} "))
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AlivePalette.secondary.opacity(0.7))
                .accessibilityHidden(true)
        }
        .aliveRow()
        .aliveCard(radius: 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Entity detail sheet

private struct KGEntityDetailSheet: View {
    let entity: KGEntity
    @ObservedObject var store: KGStore
    @Environment(\.dismiss) private var dismiss

    private var neighbors: KGNeighborsResponse? {
        guard let snapshot = store.snapshot else { return nil }
        let edges = snapshot.edges.filter { $0.from == entity.id || $0.to == entity.id }
        let ids = Set(edges.flatMap { [$0.from, $0.to] }).subtracting([entity.id])
        return KGNeighborsResponse(edges: edges,
            neighbors: Dictionary(snapshot.entities.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        let meta = KGEntityMeta.presentation(for: entity.type)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header card
                    MobileReadingSurface {
                        VStack(alignment: .leading, spacing: 12) {
                            MobileAdaptiveRow(spacing: 12) {
                                Image(systemName: meta.icon)
                                    .font(.title2)
                                    .foregroundStyle(AlivePalette.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entity.name)
                                        .font(.system(.title2, design: .serif))
                                        .foregroundStyle(AlivePalette.text)
                                    Text(meta.label)
                                        .font(.footnote)
                                        .foregroundStyle(AlivePalette.secondary)
                                }
                                Spacer()
                            }
                            if let count = entity.mention_count {
                                KGDetailRow(label: "Mentions", value: "\(count)")
                            }
                            if let first = entity.first_seen {
                                KGDetailRow(label: "First seen", value: String(first.prefix(10)))
                            }
                            if let last = entity.last_seen {
                                KGDetailRow(label: "Last seen", value: String(last.prefix(10)))
                            }
                            if let aliases = entity.aliases, !aliases.isEmpty {
                                KGDetailRow(label: "Aliases", value: aliases.joined(separator: ", "))
                            }
                            if let summary = entity.summary, !summary.isEmpty {
                                Divider()
                                Text(summary)
                                    .font(.body)
                                    .foregroundStyle(AlivePalette.text)
                            }
                        }
                    }

                    // Edges / neighbors
                    if let nbr = neighbors {
                        if nbr.edges.isEmpty {
                            AliveCalmState(title: "No relationships", line: "No edges recorded yet for this entity.")
                            .frame(minHeight: 200)
                        } else {
                            MobileReadingSurface {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Connections")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(AlivePalette.secondary)
                                        .accessibilityAddTraits(.isHeader)
                                    ForEach(nbr.edges) { edge in
                                        KGEdgeRowView(edge: edge, neighbors: nbr.neighbors, rootId: entity.id)
                                        if edge.id != nbr.edges.last?.id { Divider() }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .mobileReadingScreen()
            .navigationTitle(entity.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

}

// MARK: - Edge row

private struct KGEdgeRowView: View {
    let edge: KGEdge
    let neighbors: [String: KGEntity]
    let rootId: String

    var body: some View {
        let otherId = edge.from == rootId ? edge.to : edge.from
        let otherName = KnowledgeGraphDetailNeighborsPresentation.neighborName(
            id: otherId,
            publishedName: neighbors[otherId]?.name
        )
        let direction = edge.from == rootId ? "→" : "←"

        VStack(alignment: .leading, spacing: 2) {
            Text(otherName)
                .font(.body)
                .foregroundStyle(AlivePalette.text)
            Text("\(direction) \(edge.kind.replacingOccurrences(of: "_", with: " "))")
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail row helper

private struct KGDetailRow: View {
    let label: String
    let value: String
    var body: some View {
        MobileAdaptiveRow(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.body)
                .foregroundStyle(AlivePalette.text)
            Spacer()
        }
    }
}

// MARK: - Entity meta helpers

enum KGEntityMeta {
    struct Presentation {
        let label: String
        let icon: String
        let color: Color
        let isKnown: Bool
    }

    static func presentation(for rawType: String) -> Presentation {
        switch rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "person":
            return .init(label: "Person", icon: "person.circle", color: .blue, isKnown: true)
        case "organization":
            return .init(label: "Organization", icon: "building.2", color: .indigo, isKnown: true)
        case "project":
            return .init(label: "Project", icon: "folder", color: .orange, isKnown: true)
        case "concept":
            return .init(label: "Concept", icon: "lightbulb", color: .purple, isKnown: true)
        case "place":
            return .init(label: "Place", icon: "mappin.circle", color: .green, isKnown: true)
        case "event":
            return .init(label: "Event", icon: "calendar", color: .red, isKnown: true)
        case "tool":
            return .init(label: "Tool", icon: "wrench.and.screwdriver", color: .gray, isKnown: true)
        case "fact":
            return .init(label: "Fact", icon: "text.quote", color: .teal, isKnown: true)
        default:
            let cleanType = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = cleanType.isEmpty ? "Type unavailable" : "Unrecognized type: \(cleanType)"
            return .init(label: label, icon: "questionmark.circle", color: .orange, isKnown: false)
        }
    }
}
