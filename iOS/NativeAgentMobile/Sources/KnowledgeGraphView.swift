// KnowledgeGraphView.swift — iOS port of Mac KnowledgeGraphView.
// Data source: a Mac-produced iCloud knowledge_graph.json projection from the
// canonical KnowledgeGraph reader. The retired /v1 HTTP transport is not
// available on iPhone.
// Phone-friendly: list + tap-to-detail sheet and pull-to-refresh.
//
// F3 (fix3) — iOS source choice: KEEP the existing iCloud snapshot fallback
// (`iCloudSyncEngine.shared.loadSnapshotObjectAsync(named: "knowledge_graph.json")`).
// Rationale: iCloud snapshots already round-trip from the Mac Swift runtime to the
// phone with no additional plumbing; adding a `kg_snapshot` BridgeMessage kind
// for this surface would duplicate transport with no functional gain. The Mac
// app's KG storage cutover to SQLite (when it happens) will still emit the same
// JSON envelope into the iCloud snapshot folder, so this code path stays valid
// across that transition.
import SwiftUI

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

    static func matches(
        query: String,
        name: String,
        type: String,
        summary: String?,
        aliases: [String]?
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(needle)
            || type.localizedCaseInsensitiveContains(needle)
            || (summary?.localizedCaseInsensitiveContains(needle) ?? false)
            || (aliases?.contains { $0.localizedCaseInsensitiveContains(needle) } ?? false)
    }

    static func bounded<T>(_ values: [T], maximum: Int) -> [T] {
        Array(values.prefix(max(0, maximum)))
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
        case snapshotStillDownloading
        case entityNoLongerPublished
    }

    static func message(for reason: UnavailableReason) -> String {
        switch reason {
        case .snapshotStillDownloading:
            return "Knowledge graph snapshot is still downloading from iCloud."
        case .entityNoLongerPublished:
            return "This entity is no longer in the published Knowledge Graph."
        }
    }

    static func recoveryDetail(for reason: UnavailableReason) -> String? {
        switch reason {
        case .snapshotStillDownloading:
            return nil
        case .entityNoLongerPublished:
            return "The list and detail snapshots disagree. Refresh the Knowledge Graph on the Mac to publish a consistent view."
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
struct KGEntityResponse: Decodable {
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

struct KGEntity: Decodable, Identifiable {
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

private struct KGNeighborsResponse: Decodable {
    var entity: KGEntity?
    var edges: [KGEdge]
    var neighbors: [String: KGEntity]
}

struct KGEdge: Decodable, Identifiable {
    var id: String { "\(from)-\(to)-\(kind)" }
    var from: String
    var to: String
    var kind: String
    var weight: Double?

    private enum CodingKeys: String, CodingKey {
        case from, to, kind, type, weight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        if let decodedKind = try? container.decode(String.self, forKey: .kind) {
            kind = decodedKind
        } else {
            kind = try container.decode(String.self, forKey: .type)
        }
        weight = try? container.decode(Double.self, forKey: .weight)
    }
}

private struct KGSearchResponse: Decodable {
    var results: [KGEntity]
}

// MARK: - Store

@MainActor
private final class KGStore: ObservableObject {
    @Published var entities: [KGEntity] = []
    @Published var total: Int = 0
    @Published var isLoading = false
    @Published var bannerError: String?
    /// This is deliberately separate from `bannerError`: a quiet initial
    /// launch has neither an error nor a Mac-published projection.
    @Published private(set) var hasPublishedSnapshot = false
    private var cachedSnapshot: KGEntityResponse?
    private(set) var snapshotReadCount = 0
    static let maxSearchResults = 200

    private func snapshot(forceReload: Bool) async -> KGEntityResponse? {
        if !forceReload, let cachedSnapshot { return cachedSnapshot }
        snapshotReadCount += 1
        let loaded: KGEntityResponse? = await iCloudSyncEngine.shared.loadSnapshotObjectAsync(named: "knowledge_graph.json")
        if let loaded {
            cachedSnapshot = loaded
            hasPublishedSnapshot = true
        }
        return loaded
    }

    func refresh(client: MacBridgeClient) async {
        isLoading = true
        defer { isLoading = false }
        let _ = client
        if let resp = await snapshot(forceReload: true) {
            withAnimation(AppMotion.snappy) {
                entities = resp.entities
                total = resp.total
            }
            bannerError = nil
        } else {
            bannerError = "Knowledge graph snapshot is still downloading from iCloud. Try again in a moment."
        }
    }

}

// MARK: - KnowledgeGraphView

struct KnowledgeGraphView: View {
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var syncEngine = iCloudSyncEngine.shared
    @StateObject private var store = KGStore()
    @State private var searchText = ""
    @State private var selectedEntity: KGEntity?

    private var displayEntities: [KGEntity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.entities }
        return KnowledgeGraphPresentation.bounded(
            store.entities.filter { entity in
                KnowledgeGraphPresentation.matches(
                    query: query,
                    name: entity.name,
                    type: entity.type,
                    summary: entity.summary,
                    aliases: entity.aliases
                )
            },
            maximum: KGStore.maxSearchResults
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            List {
                switch KnowledgeGraphPresentation.contentState(
                    isLoading: store.isLoading,
                    hasPublishedSnapshot: store.hasPublishedSnapshot,
                    entityCount: displayEntities.count,
                    query: searchText
                ) {
                case .loading:
                    ProgressView("Loading graph…")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                case .unpublished:
                    AppEmptyState(
                        title: "Graph unavailable",
                        systemImage: "icloud.slash",
                        kind: .unavailable,
                        description: KnowledgeGraphEmptyStatePresentation.unpublishedDescription
                    )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                case .emptyPublished:
                    AppEmptyState(
                        title: "No entities",
                        systemImage: "circle.hexagongrid",
                        kind: .empty,
                        description: KnowledgeGraphEmptyStatePresentation.emptyPublishedDescription
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                case .noMatches:
                    AppEmptyState(
                        title: "No matching entities",
                        systemImage: "magnifyingglass",
                        kind: .empty,
                        description: "The published graph is available, but no entity matches this search."
                    )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                case .content:
                    Section {
                        ForEach(displayEntities) { entity in
                            Button {
                                selectedEntity = entity
                            } label: {
                                KGEntityRowCell(entity: entity)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(KnowledgeGraphPresentation.entityCountHeader(visibleCount: displayEntities.count))
                    } footer: {
                        if let context = KnowledgeGraphPresentation.filterContext(
                            visibleCount: displayEntities.count,
                            totalCount: store.total,
                            isFiltered: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            Text(context)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search entities…")
            .refreshable { await store.refresh(client: bridgeClient) }
            .task { await store.refresh(client: bridgeClient) }
            .onChange(of: syncEngine.lastSyncAt) { _, _ in
                Task { await store.refresh(client: bridgeClient) }
            }

            if let err = store.bannerError {
                BannerRow(message: err, style: .error)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(AppMotion.snappy, value: store.bannerError)
        .navigationTitle("Knowledge Graph")
        .macSyncErrorBanner()
        // E6: freshness of the Mac snapshot behind this graph.
        .macSnapshotFreshnessBadge(group: "knowledge_graph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                MacStatusChip()
            }
        }
        .sheet(item: $selectedEntity) { entity in
            KGEntityDetailSheet(entity: entity)
                .environmentObject(bridgeClient)
        }
    }
}

// MARK: - Entity row cell

private struct KGEntityRowCell: View {
    let entity: KGEntity

    var body: some View {
        let meta = KGEntityMeta.presentation(for: entity.type)
        GlassCard(tint: meta.color) {
            HStack(spacing: 12) {
                Image(systemName: meta.icon)
                    .font(.title3)
                    .foregroundStyle(meta.color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entity.name)
                        .font(AppFont.section)
                    Text(meta.label)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(meta.color.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
                if let count = entity.mention_count, count > 0 {
                    VStack {
                        Text("\(count)")
                            .font(AppFont.section)
                            .foregroundStyle(.secondary)
                        Text("mentions")
                            .font(AppFont.tag)
                            .foregroundStyle(.tertiary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(AppFont.label)
                    .foregroundStyle(.tertiary)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

// MARK: - Entity detail sheet

private struct KGEntityDetailSheet: View {
    let entity: KGEntity
    @State private var neighbors: KGNeighborsResponse?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadUnavailableReason: KnowledgeGraphDetailNeighborsPresentation.UnavailableReason?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let meta = KGEntityMeta.presentation(for: entity.type)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header card
                    GlassCard(tint: meta.color) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: meta.icon)
                                    .font(.title2)
                                    .foregroundStyle(meta.color)
                                GradientText(
                                    text: entity.name,
                                    colors: [meta.color, .purple],
                                    font: AppFont.title
                                )
                                Spacer()
                                Text(meta.label)
                                    .font(AppFont.label)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(meta.color, in: Capsule())
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
                                    .font(AppFont.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Edges / neighbors
                    if isLoading {
                        HStack { Spacer(); ProgressView("Loading edges…"); Spacer() }
                            .padding()
                    } else if let err = loadError {
                        GlassCard(tint: .red) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(err, systemImage: "exclamationmark.triangle")
                                    .font(AppFont.label)
                                    .foregroundStyle(.red)
                                if let reason = loadUnavailableReason,
                                   let detail = KnowledgeGraphDetailNeighborsPresentation.recoveryDetail(for: reason) {
                                    Text(detail)
                                        .font(AppFont.label)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else if let nbr = neighbors {
                        if nbr.edges.isEmpty {
                            AppEmptyState(
                                title: "No relationships",
                                systemImage: "arrow.triangle.branch",
                                kind: .empty,
                                description: "No edges recorded yet for this entity."
                            )
                            .frame(height: 200)
                        } else {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Relationships (\(nbr.edges.count))", systemImage: "arrow.triangle.branch")
                                        .font(AppFont.section)
                                    Divider()
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
            .navigationTitle(entity.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadNeighbors() }
        }
    }

    private func loadNeighbors() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        loadUnavailableReason = nil
        let snapshot: KGEntityResponse? = await iCloudSyncEngine.shared
            .loadSnapshotObjectAsync(named: "knowledge_graph.json")
        guard let snapshot else {
            let reason: KnowledgeGraphDetailNeighborsPresentation.UnavailableReason = .snapshotStillDownloading
            loadUnavailableReason = reason
            loadError = KnowledgeGraphDetailNeighborsPresentation.message(for: reason)
            return
        }
        guard let match = snapshot.entities.first(where: { $0.id == entity.id }) else {
            let reason: KnowledgeGraphDetailNeighborsPresentation.UnavailableReason = .entityNoLongerPublished
            loadUnavailableReason = reason
            loadError = KnowledgeGraphDetailNeighborsPresentation.message(for: reason)
            return
        }

        let incidentEdges = snapshot.edges.filter {
            $0.from == entity.id || $0.to == entity.id
        }
        let neighborIDs = Set(incidentEdges.flatMap { [$0.from, $0.to] })
            .subtracting([entity.id])
        let neighborMap = Dictionary(uniqueKeysWithValues: snapshot.entities
            .filter { neighborIDs.contains($0.id) }
            .map { ($0.id, $0) })
        neighbors = KGNeighborsResponse(
            entity: match,
            edges: incidentEdges,
            neighbors: neighborMap
        )
        loadError = nil
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

        HStack(spacing: 8) {
            Text(direction)
                .font(AppFont.label)
                .foregroundStyle(NativeAgentPalette.agentAccent)
            Text("[\(edge.kind)]")
                .font(AppFont.label)
                .foregroundStyle(.secondary)
            Text(otherName)
                .font(AppFont.body)
            Spacer()
            if let w = edge.weight {
                Text(String(format: "%.2f", w))
                    .font(AppFont.tag)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail row helper

private struct KGDetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(AppFont.label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(AppFont.body)
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

    static let knownTypes = [
        "person", "organization", "project", "concept", "place", "event", "tool", "fact",
    ]

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

// MARK: - Shared banner helper (private — ApprovalsView has its own)

private struct BannerRow: View {
    enum Style { case error, warning }
    let message: String
    let style: Style

    private var bgColor: Color { style == .error ? .red.opacity(0.85) : .orange.opacity(0.85) }
    private var icon: String { style == .error ? "wifi.slash" : "exclamationmark.triangle" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(message).font(AppFont.label).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgColor)
        .ignoresSafeArea(edges: .horizontal)
    }
}
