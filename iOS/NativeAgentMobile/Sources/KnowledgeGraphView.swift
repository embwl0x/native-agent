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
private struct KGEntityResponse: Decodable {
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
            // Each value's `id` falls back to its dict key if missing on the value.
            entities = dict.map { (key, value) -> KGEntity in
                var e = value
                if e.id.isEmpty { e.id = key }
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

        // Legacy envelope fallback.
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

private struct KGEntity: Decodable, Identifiable {
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
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
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

private struct KGEdge: Decodable, Identifiable {
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

    func refresh(client: MacBridgeClient) async {
        isLoading = true
        defer { isLoading = false }
        let _ = client
        if let resp: KGEntityResponse = await iCloudSyncEngine.shared.loadSnapshotObjectAsync(named: "knowledge_graph.json") {
            withAnimation(AppMotion.snappy) {
                entities = resp.entities
                total = resp.total
            }
            bannerError = nil
        } else {
            bannerError = "Knowledge graph snapshot is still downloading from iCloud. Try again in a moment."
        }
    }

    func search(q: String, client: MacBridgeClient) async {
        isLoading = true
        defer { isLoading = false }
        let _ = client
        if let snapshot: KGEntityResponse = await iCloudSyncEngine.shared.loadSnapshotObjectAsync(named: "knowledge_graph.json") {
            let needle = q.lowercased()
            let filtered = snapshot.entities.filter { entity in
                entity.name.lowercased().contains(needle)
                    || entity.type.lowercased().contains(needle)
                    || (entity.summary?.lowercased().contains(needle) == true)
                    || (entity.aliases?.contains { $0.lowercased().contains(needle) } == true)
            }
            withAnimation(AppMotion.snappy) { entities = filtered }
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
    @State private var debounceTask: Task<Void, Never>?

    private var displayEntities: [KGEntity] {
        guard searchText.isEmpty else { return store.entities }
        return store.entities
    }

    var body: some View {
        ZStack(alignment: .top) {
            List {
                if store.isLoading && store.entities.isEmpty {
                    ProgressView("Loading graph…")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if displayEntities.isEmpty && !store.isLoading {
                    AppEmptyState(
                        title: "No entities",
                        systemImage: "circle.hexagongrid",
                        description: "Enable knowledge_graph in Memory Policy to start tracking entities from conversations."
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section("\(store.total) entities") {
                        ForEach(displayEntities) { entity in
                            Button {
                                selectedEntity = entity
                            } label: {
                                KGEntityRowCell(entity: entity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search entities…")
            .onChange(of: searchText) { _, q in
                debounceTask?.cancel()
                if q.isEmpty {
                    debounceTask = Task { await store.refresh(client: bridgeClient) }
                } else {
                    debounceTask = Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        await store.search(q: q, client: bridgeClient)
                    }
                }
            }
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
        .navigationBarTitleDisplayMode(.inline)
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
        GlassCard(tint: KGEntityMeta.color(entity.type)) {
            HStack(spacing: 12) {
                Image(systemName: KGEntityMeta.icon(entity.type))
                    .font(.title3)
                    .foregroundStyle(KGEntityMeta.color(entity.type))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entity.name)
                        .font(AppFont.section)
                    Text(entity.type.capitalized)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(KGEntityMeta.color(entity.type).opacity(0.12))
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header card
                    GlassCard(tint: KGEntityMeta.color(entity.type)) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: KGEntityMeta.icon(entity.type))
                                    .font(.title2)
                                    .foregroundStyle(KGEntityMeta.color(entity.type))
                                GradientText(
                                    text: entity.name,
                                    colors: [KGEntityMeta.color(entity.type), .purple],
                                    font: AppFont.title
                                )
                                Spacer()
                                Text(entity.type.capitalized)
                                    .font(AppFont.label)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(KGEntityMeta.color(entity.type), in: Capsule())
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
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(AppFont.label)
                                .foregroundStyle(.red)
                        }
                    } else if let nbr = neighbors {
                        if nbr.edges.isEmpty {
                            AppEmptyState(
                                title: "No relationships",
                                systemImage: "arrow.triangle.branch",
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
        let snapshot: KGEntityResponse? = await iCloudSyncEngine.shared
            .loadSnapshotObjectAsync(named: "knowledge_graph.json")
        if let snapshot, let match = snapshot.entities.first(where: { $0.id == entity.id }) {
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
        } else {
            loadError = "Knowledge graph detail snapshot is still downloading from iCloud."
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
        let otherName = neighbors[otherId]?.name ?? otherId
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

private enum KGEntityMeta {
    static func icon(_ type: String) -> String {
        switch type {
        case "person":  return "person.circle"
        case "organization": return "building.2"
        case "project": return "folder"
        case "concept": return "lightbulb"
        case "place":   return "mappin.circle"
        case "event":   return "calendar"
        case "tool":    return "wrench.and.screwdriver"
        default:        return "circle"
        }
    }

    static func color(_ type: String) -> Color {
        switch type {
        case "person":  return .blue
        case "organization": return .indigo
        case "project": return .orange
        case "concept": return .purple
        case "place":   return .green
        case "event":   return .red
        case "tool":    return .gray
        default:        return NativeAgentPalette.agentAccent
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
