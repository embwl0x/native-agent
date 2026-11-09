import SwiftUI
import Foundation
import Accessibility
import CryptoKit
import NativeAgentShared
// Blueprint: | `KnowledgeGraphView.swift` | Device-local graph pages, held queries and revision-bound collection/item reads |

struct KGEntityResponse: Decodable, Equatable, Sendable {
    var entities: [KGEntity]
    var edges: [KnowledgeGraphEdgeWireSnapshot]
    var total: Int

    private enum CodingKeys: String, CodingKey {
        case entities, edges
        case totalEntities = "total_entities"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        entities = try container.decode([KGEntity].self, forKey: .entities)
        edges = try container.decode([KnowledgeGraphEdgeWireSnapshot].self, forKey: .edges)
        total = try container.decode(Int.self, forKey: .totalEntities)
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
        id = try c.decode(String.self, forKey: .id)
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Knowledge graph entities require their canonical identity.")
        }
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
        first_seen = try c.decodeIfPresent(String.self, forKey: .first_seen)
        last_seen = try c.decodeIfPresent(String.self, forKey: .last_seen)
        mention_count = try c.decodeIfPresent(Int.self, forKey: .mention_count)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}


private struct PhoneGraphInput: Equatable {
    let snapshot: KGEntityResponse?
    let query: String
    let item: String?
}

private struct PhoneGraphReading {
    let input: PhoneGraphInput
    let result: Result<PartFace, PartCallError>
}

/// The sync owner holds the received graph; this owner projects that value without reaching the Mac.
@MainActor private struct PhoneGraphFaceOwner: MobileLocalFaceOwner {
    let query: String
    var waitingOn: String { "this iPhone's graph" }

    func readFace(_ request: FaceReadRequest) async throws -> PartFace {
        guard let snapshot = iCloudSyncEngine.shared.knowledgeGraph else {
            throw PartCallError(code: "graph_not_received", message: "Waiting for a published Knowledge Graph on this iPhone.")
        }
        return try await Self.project(snapshot: snapshot, query: query, request: request)
    }

    func readText(_ request: FaceReadRequest) async throws -> String {
        guard let snapshot = iCloudSyncEngine.shared.knowledgeGraph,
              request.expectedCall?.action == "phone.graph.summary",
              case .string(let id)? = request.expectedCall?.args["id"],
              request.key == "summary/" + id,
              let entity = snapshot.entities.first(where: { $0.id == id }), let summary = entity.summary else {
            throw PartCallError(code: "graph_summary_unavailable", message: "This received graph does not contain the requested summary.")
        }
        let revision = try await Self.revision(snapshot, query: query)
        if let expected = request.revision, expected != revision {
            throw PartCallError(code: "document_changed", message: "The received graph changed. Reopen the summary to read its current value.")
        }
        return summary
    }

    @concurrent private static func project(snapshot: KGEntityResponse, query baseQuery: String, request: FaceReadRequest) async throws -> PartFace {
        try Task.checkCancellation()
        let query: String
        if request.key == "entities" {
            guard request.expectedCall?.action == "phone.graph.read",
                  case .string(let supplied)? = request.expectedCall?.args["query"],
                  request.query == nil || request.query == supplied else {
                throw PartCallError(code: "graph_query_changed", message: "The graph query does not match the held read.")
            }
            query = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { query = baseQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
        let revision = try await revision(snapshot, query: query)
        if let expected = request.revision, expected != revision {
            throw PartCallError(code: "collection_changed", message: "The received graph changed; read again from the selected entity.")
        }
        let cursor = try offset(request.cursor)
        if request.key == "entities" {
            let entities = snapshot.entities.filter { entity in
                query.isEmpty || ([entity.name, entity.type, entity.summary ?? ""] + (entity.aliases ?? []))
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            let anchor = request.anchor.flatMap { anchor in entities.firstIndex { $0.id == anchor } }
            let start = request.cursor == nil ? anchor ?? 0 : cursor
            guard start <= entities.count else {
                throw PartCallError(code: "graph_cursor_invalid", message: "The graph cursor is beyond the received entities.")
            }
            var face = try GraphCollectionFace.list(entities: entities.map(\.graphValue), total: query.isEmpty ? snapshot.total : entities.count,
                cursor: start, revision: revision, page: "phone-graph")
            face.sections = face.sections.map { original in
                var section = original
                section.filter = nil
                section.revision = revision
                section.more?.read = .init("phone.graph.read", ["query": .string(query)])
                if query.isEmpty, snapshot.total > entities.count {
                    section.footer = "This iPhone received \(entities.count) of \(snapshot.total) entities; the rest remain on your Mac."
                }
                if entities.isEmpty {
                    section.rows = [.init(id: "empty", title: query.isEmpty ? "No entities in the received graph." : "No matching entities.",
                                          tone: .quiet)]
                }
                return section
            }
            return face
        }
        let id: String
        let readingRelationships = request.expectedCall?.action == "phone.graph.relationships"
        if readingRelationships {
            guard case .string(let owner)? = request.expectedCall?.args["id"], request.key == "relationships:" + owner else {
                throw PartCallError(code: "graph_item_missing", message: "The relationships request has no entity identity.")
            }
            id = owner
        } else {
            guard request.expectedCall?.action == "phone.graph.item",
                  case .string(let owner)? = request.expectedCall?.args["id"], owner == request.key else {
                throw PartCallError(code: "graph_item_changed", message: "The graph item does not match the held read.")
            }
            id = owner
        }
        guard let entity = snapshot.entities.first(where: { $0.id == id }) else {
            return PartFace(sections: [.init(id: "unavailable", style: .note,
                rows: [.init(id: id, title: "This entity is not in the received Knowledge Graph.", tone: .quiet)])])
        }
        let edges = snapshot.edges.filter { $0.from == id || $0.to == id }
        guard cursor <= edges.count else {
            throw PartCallError(code: "graph_cursor_invalid", message: "The relationship cursor is beyond the received edges.")
        }
        let page = edges.dropFirst(cursor).prefix(256)
        let next = cursor.addingReportingOverflow(page.count)
        guard !next.overflow else { throw PartCallError(code: "graph_cursor_invalid", message: "The relationship cursor exceeds its range.") }
        var face = try GraphCollectionFace.detail(entity: entity.graphValue, entities: snapshot.entities.map(\.graphValue),
            edges: page.map { .init(from: $0.from, to: $0.to, kind: $0.kind, weight: $0.weight) }, state: .ready, page: "phone-graph")
        face.sections = face.sections.map { original in
            var section = original
            section.revision = revision
            if section.id == "relationships:" + id {
                section.rows = zip(page, section.rows).map { edge, row in
                    .init(id: edge.id, title: row.title, detail: row.detail, value: row.value, open: row.open)
                }
                if edges.isEmpty { section.rows = [.init(id: "empty", title: "No relationships recorded.", tone: .quiet)] }
                if next.partialValue < edges.count {
                    section.more = .init(next: String(next.partialValue), total: edges.count, revision: revision,
                                        read: .init("phone.graph.relationships", ["id": .string(id)]))
                }
            }
            return section
        }
        if readingRelationships { face.sections = face.sections.filter { $0.id == "relationships:" + id }; return face }
        var facts: [PartFace.Row] = []
        if let count = entity.mention_count { facts.append(.init(id: "mentions", title: "Mentions", value: String(count))) }
        if let first = entity.first_seen { facts.append(.init(id: "first-seen", title: "First seen", value: first)) }
        if let last = entity.last_seen { facts.append(.init(id: "last-seen", title: "Last seen", value: last)) }
        if let aliases = entity.aliases, !aliases.isEmpty {
            facts.append(.init(id: "aliases", title: "Aliases", detail: aliases.joined(separator: ", ")))
        }
        if !facts.isEmpty { face.sections.insert(.init(id: "facts", style: .values, rows: facts), at: 0) }
        if let summary = entity.summary, !summary.isEmpty {
            face.sections.insert(.init(id: "summary", rows: [], block: .init(key: "summary/" + id,
                text: summary.utf8.count <= PartFace.Block.inlineByteLimit ? summary : nil, copy: true,
                read: .init("phone.graph.summary", ["id": .string(id)]), revision: revision)), at: 0)
        }
        return face
    }

    private nonisolated static func offset(_ value: String?) throws -> Int {
        guard let value else { return 0 }
        guard let offset = Int(value), offset >= 0 else {
            throw PartCallError(code: "graph_cursor_invalid", message: "The graph cursor must be a nonnegative row offset.")
        }
        return offset
    }

    @concurrent private static func revision(_ snapshot: KGEntityResponse, query: String) async throws -> String {
        let entities = snapshot.entities.map { entity in
            PartFace.Value.array([.string(entity.id), .string(entity.name), .string(entity.type),
                entity.first_seen.map(PartFace.Value.string) ?? .null, entity.last_seen.map(PartFace.Value.string) ?? .null,
                entity.mention_count.map { .int(Int64($0)) } ?? .null,
                entity.aliases.map { .array($0.map(PartFace.Value.string)) } ?? .null,
                entity.summary.map(PartFace.Value.string) ?? .null])
        }
        let edges = snapshot.edges.map { edge in
            PartFace.Value.array([.string(edge.from), .string(edge.to), .string(edge.kind), edge.weight.map(PartFace.Value.double) ?? .null])
        }
        let data = try JSONEncoder().encode(PartFace.Value.array([.array(entities), .array(edges), .int(Int64(snapshot.total)), .string(query)]))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension KGEntity {
    nonisolated var graphValue: FaceGraphEntity {
        .init(id: id, name: name, kind: type, detail: nil, weight: nil)
    }
}

extension KnowledgeGraphEdgeWireSnapshot: @retroactive Identifiable {
    public var id: String { "\(from.utf8.count):\(from)\(to.utf8.count):\(to)\(kind)" }
}

struct KnowledgeGraphView: View {
    @State private var searchText = ""
    @State private var selected: PhoneGraphItem?
    @State private var session = FacePageSession()
    @State private var reading: PhoneGraphReading?
    @State private var latest = LatestRead()
    private let sync = iCloudSyncEngine.shared
    private var owner: PhoneGraphFaceOwner { .init(query: searchText) }
    private var input: PhoneGraphInput { .init(snapshot: sync.knowledgeGraph, query: searchText, item: nil) }

    var body: some View {
        AlivePage(title: "Knowledge Graph", line: "The graph received on this iPhone.", freshnessGroup: "knowledge_graph") {
            MobileLocalFaceRows(face: shownFace, owner: owner, session: session, open: open)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AliveSearchField(prompt: "Search people, places and projects", text: $searchText)
                .padding(.horizontal, AliveMetrics.pageInset).padding(.vertical, 8)
        }
        .task(id: input) { await read() }
        .task { await sync.refreshKnowledgeGraphSnapshot() }
        .refreshable { await sync.refreshKnowledgeGraphSnapshot() }
        .navigationDestination(item: $selected) { item in PhoneGraphItemPage(id: item.id) }
        .onChange(of: sync.knowledgeGraph) { old, new in selected = PhoneGraphItem.reconciled(selected, old: old, new: new) }
        .macSyncErrorBanner()
    }

    private var shownFace: PartFace {
        guard let reading, reading.input == input else {
            return .init(sections: [.init(id: "waiting", style: .waiting,
                rows: [.init(id: "waiting", title: sync.knowledgeGraph == nil
                    ? "Waiting for a published Knowledge Graph on this iPhone." : "Searching this iPhone's graph…", tone: .quiet)])])
        }
        switch reading.result {
        case .success(let face): return .init(sections: face.sections, detail: face.detail)
        case .failure(let failure): return .init(sections: [.init(id: "failure", style: .note,
            rows: [.init(id: "failure", title: failure.message, tone: .failed)])])
        }
    }

    private func read() async {
        let input = input
        guard input.snapshot != nil else { return }
        _ = await latest.read({
            let result: Result<PartFace, PartCallError>
            do {
                result = .success(try await owner.readFace(.init(id: UUID(), key: "entities",
                    expectedCall: .init("phone.graph.read", ["query": .string(input.query)]), query: input.query)))
            } catch is CancellationError { return nil as PhoneGraphReading? }
            catch { result = .failure(.init(code: "graph_read_failed", message: error.localizedDescription)) }
            return PhoneGraphReading(input: input, result: result)
        }, publish: { if let value = $0 { reading = value } })
    }

    private func open(_ link: String) {
        guard case .page("phone-graph", let id)? = FaceLink(link), let id else { return }
        selected = .init(id: id)
    }
}

private struct PhoneGraphItem: Hashable {
    let id: String

    @MainActor static func reconciled(_ selected: Self?, old: KGEntityResponse?, new: KGEntityResponse?) -> Self? {
        guard let selected, let new, !new.entities.contains(where: { $0.id == selected.id }) else { return selected }
        let order = old?.entities.map(\.id) ?? []
        let position = order.firstIndex(of: selected.id)
        let next = position.flatMap { position in order.dropFirst(position + 1).first { id in new.entities.contains { $0.id == id } } }
        let entity = next.flatMap { id in new.entities.first { $0.id == id } } ?? new.entities.last
        if let entity { AccessibilityNotification.Announcement(entity.name).post() }
        return entity.map { .init(id: $0.id) }
    }
}

private struct PhoneGraphItemPage: View {
    let id: String
    @State private var session = FacePageSession()
    @State private var reading: PhoneGraphReading?
    @State private var latest = LatestRead()
    @State private var selected: PhoneGraphItem?
    private let sync = iCloudSyncEngine.shared
    private let owner = PhoneGraphFaceOwner(query: "")
    private var input: PhoneGraphInput { .init(snapshot: sync.knowledgeGraph, query: "", item: id) }

    var body: some View {
        AlivePage(title: sync.knowledgeGraph?.entities.first { $0.id == id }?.name ?? "Graph entity") {
            MobileLocalFaceRows(face: shownFace, owner: owner, session: session) { link in
                guard case .page("phone-graph", let target)? = FaceLink(link), let target else { return }
                selected = .init(id: target)
            }
        }
        .task(id: input) { await read() }
        .navigationDestination(item: $selected) { PhoneGraphItemPage(id: $0.id) }
        .onChange(of: sync.knowledgeGraph) { old, new in selected = PhoneGraphItem.reconciled(selected, old: old, new: new) }
        .macSyncErrorBanner()
    }

    private var shownFace: PartFace {
        guard let reading, reading.input == input else {
            return .init(sections: [.init(id: "waiting", style: .waiting,
                rows: [.init(id: "waiting", title: sync.knowledgeGraph == nil
                    ? "Waiting for a published Knowledge Graph on this iPhone." : "Reading this iPhone's graph entity…", tone: .quiet)])])
        }
        switch reading.result {
        case .success(let face): return .init(sections: face.sections)
        case .failure(let failure): return .init(sections: [.init(id: "failure", style: .note,
            rows: [.init(id: "failure", title: failure.message, tone: .failed)])])
        }
    }

    private func read() async {
        let input = input
        guard input.snapshot != nil else { return }
        _ = await latest.read({
            let result: Result<PartFace, PartCallError>
            do {
                result = .success(try await owner.readFace(.init(id: UUID(), key: id,
                    expectedCall: .init("phone.graph.item", ["id": .string(id)]))))
            } catch is CancellationError { return nil as PhoneGraphReading? }
            catch { result = .failure(.init(code: "graph_read_failed", message: error.localizedDescription)) }
            return PhoneGraphReading(input: input, result: result)
        }, publish: { if let value = $0 { reading = value } })
    }
}
