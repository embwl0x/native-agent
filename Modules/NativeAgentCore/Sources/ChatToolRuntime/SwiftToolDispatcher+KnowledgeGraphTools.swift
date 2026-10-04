import Foundation
import NativeAgentCore
import PersistenceCore
import MemoryV2
import MCPDispatcher
import KnowledgeGraph
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution

// MARK: - Knowledge graph tools

extension SwiftToolDispatcher {
    func impl_search_kg(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Bad input is a thrown refusal before any gate, so an empty call is
        // an error whatever the switch says.
        let openID = optionalString(input, "entity_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = optionalString(input, "query")
        let limit = min(100, max(1, optionalInt(input, "limit") ?? 10))
        // The Knowledge Graph page's filters: its type/kind menus (one
        // attribute, entity.type) and its time window on last_seen, falling
        // back to first_seen.
        let types = Set((optionalString(input, "type") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        let since = optionalString(input, "since")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sinceDays: Int?
        switch since {
        case nil: sinceDays = nil
        case "day": sinceDays = 1
        case "week": sinceDays = 7
        case "month": sinceDays = 30
        default:
            throw AutonomyGateError.toolDenied(reason: "search_kg 'since' must be day, week or month.")
        }
        let cutoff = sinceDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        guard query != nil || openID != nil || !types.isEmpty || cutoff != nil else {
            throw AutonomyGateError.toolDenied(
                reason: "search_kg needs 'query' (text to search for), 'entity_id' (an id from a search result), or a 'type' or 'since' filter to browse."
            )
        }
        guard MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) else {
            return .object([
                "status": .string("disabled"),
                "reason": .string(MemoryPolicyGate.knowledgeGraphOffMessage),
            ])
        }
        let persona = memoryRecallPersonaFilter(ChatTurnRuntimeContext.current?.personaID)
        let disclosedIDs = Set(try await memoryV2.listMemory(kind: nil).filter {
            MemoryRecordDisclosurePolicy.classify($0)?.permits(surface: surface, personaID: persona) == true
        }.map(\.id))
        let disclosedFactIDs = Set(disclosedIDs.map(SwiftNativeKnowledgeGraphIndexer.memoryFactEntityID))
        func permitsDisclosure(_ value: JSONValue) -> Bool {
            guard case .object(let o) = value else { return false }
            for key in ["memory_id", "last_memory_id"] {
                if let source = o[key], source != .null {
                    guard case .string(let id) = source, disclosedIDs.contains(id) else { return false }
                }
            }
            if case .string(let id)? = o["id"], id.hasPrefix("memfact_") {
                return disclosedFactIDs.contains(id)
            }
            return true
        }
        func passesFilters(_ ent: JSONValue) -> Bool {
            guard permitsDisclosure(ent) else { return false }
            guard case .object(let o) = ent else { return false }
            if !types.isEmpty {
                guard case .string(let type)? = o["type"], types.contains(type.lowercased()) else { return false }
            }
            if let cutoff {
                let stamp: String? = if case .string(let v)? = o["last_seen"] { v }
                    else if case .string(let v)? = o["first_seen"] { v } else { nil }
                guard let stamp, let seen = Self.kgSeenDate(stamp), seen >= cutoff else { return false }
            }
            return true
        }
        let reader = SwiftNativeKnowledgeGraphReader(
            graphPath: knowledgeGraphPath,
            flushURL: nil
        )
        if let openID {
            // The page's entity detail: MemoryFacade.neighborhood's read.
            guard case .found(.object(let found)) = try await reader.entityChecked(id: openID),
                  let entity = found["entity"], permitsDisclosure(entity) else {
                return .object([
                    "status": .string("failed"),
                    "reason": .string("No available entity with that id. Search with query first and use an id from its results."),
                ])
            }
            func entityRow(_ e: JSONValue) -> JSONValue {
                guard case .object(let o) = e else { return .null }
                let fields: Set<String> = ["id", "name", "type", "summary", "first_seen", "last_seen", "mention_count"]
                return .object(o.filter { fields.contains($0.key) })
            }
            guard case .array(let rawEdges)? = found["edges"],
                  case .object(let rawNeighbors)? = found["neighbors"] else {
                throw KnowledgeGraphReadError.malformedEnvelope("entity read did not contain edges and neighbors")
            }
            let neighbors = rawNeighbors.filter { permitsDisclosure($0.value) }
            let edges = try rawEdges.compactMap { raw -> (from: String, to: String, kind: String, mentions: Int64)? in
                guard case .object(let o) = raw,
                      case .string(let from)? = o["from"], case .string(let to)? = o["to"],
                      case .string(let kind)? = o["kind"] ?? o["type"] else {
                    throw KnowledgeGraphReadError.malformedEnvelope("edge needs string endpoints and a kind")
                }
                guard permitsDisclosure(raw),
                      from == openID || neighbors[from] != nil,
                      to == openID || neighbors[to] != nil else { return nil }
                let mentions: Int64 = if case .int(let n)? = o["mention_count"] { n } else { 0 }
                return (from, to, kind, mentions)
            }.sorted { $0.mentions > $1.mentions }
            let shown = edges.prefix(limit)
            var neighborIDs = Set(shown.flatMap { [$0.from, $0.to] })
            neighborIDs.remove(openID)
            return .object([
                "status": .string("ok"),
                "entity": entityRow(entity),
                "edges": .array(shown.map { .object(["from": .string($0.from), "to": .string($0.to), "kind": .string($0.kind)]) }),
                "neighbors": .array(neighborIDs.sorted().compactMap { neighbors[$0].map(entityRow) }),
                "total_edges": .int(Int64(edges.count)),
            ])
        }
        guard let query else {
            // Filters with no text browse the whole graph, as the page does
            // with an empty search field.
            var rows: [JSONValue] = []
            var page = 0
            while rows.count < limit, page < 500 {
                guard case .object(let env) = try await reader.allEntitiesChecked(page: page),
                      case .array(let ents)? = env["entities"], !ents.isEmpty else { break }
                rows += ents.filter(passesFilters)
                page += 1
            }
            return .object(["status": .string("ok"), "results": .array(Array(rows.prefix(limit)))])
        }
        let result = try await reader.searchChecked(q: query)
        guard case .object(let obj) = result,
              case .array(let results)? = obj["results"]
        else {
            throw KnowledgeGraphReadError.malformedEnvelope(
                "search_kg did not receive a results array"
            )
        }
        // User, 2026-09-05: "get the embeddings right." Every fact node in the
        // graph is one memory row, and every memory row already carries its
        // MiniLM vector, so meaning-search over the graph is memory recall
        // mapped onto fact-node ids. Text hits and meaning hits are fused by
        // reciprocal rank (1 / (60 + rank)), which needs no shared scale:
        // a node found both ways rises, a node found either way still shows.
        func entityID(_ ent: JSONValue) -> String? {
            guard case .object(let o) = ent, case .string(let id)? = o["id"] else { return nil }
            return id
        }
        var order: [String] = []
        var entities: [String: JSONValue] = [:]
        var fused: [String: Double] = [:]
        var via: [String: [String]] = [:]
        for (rank, ent) in results.filter(passesFilters).prefix(limit * 3).enumerated() {
            guard let id = entityID(ent) else { continue }
            if entities[id] == nil { order.append(id); entities[id] = ent }
            fused[id, default: 0] += 1.0 / (60.0 + Double(rank))
            via[id, default: []].append("text")
        }
        var meaningSearch = "ok"
        do {
            let response = try await memoryV2.recall(MemoryV2RecallRequest(
                text: query,
                topK: limit * 2,
                persona: persona,
                surface: surface
            ))
            // 2026-09-06: recall degrades to the keyword lane when the query
            // vector's epoch does not match the corpus. Those hits are lexical;
            // calling them meaning matches, on a lane reported as `ok`,
            // overstated the answer.
            let lexical = response.hits.contains { $0.source == "swift-native-keyword-fallback" }
            if lexical { meaningSearch = "keyword-fallback" }
            for (rank, scored) in response.scored.enumerated() {
                let nodeID = SwiftNativeKnowledgeGraphIndexer.memoryFactEntityID(for: scored.record.id)
                if entities[nodeID] == nil {
                    // The read returns {entity, edges, neighbors}; a result row
                    // is the entity, like a text hit (entity_id has the rest).
                    guard case .found(.object(let env))? = await reader.entity(id: nodeID),
                          let ent = env["entity"], ent != .null, passesFilters(ent) else { continue }
                    order.append(nodeID); entities[nodeID] = ent
                }
                fused[nodeID, default: 0] += 1.0 / (60.0 + Double(rank))
                via[nodeID, default: []].append(lexical ? "keyword" : "meaning")
            }
        } catch {
            // The embedder fails closed when the model will not load; say so
            // rather than letting text-only pass as a full answer.
            meaningSearch = "unavailable"
        }
        let ranked = order.sorted { (fused[$0] ?? 0) > (fused[$1] ?? 0) }.prefix(limit)
        let capped: [JSONValue] = ranked.compactMap { id in
            guard case .object(var o)? = entities[id] else { return nil }
            o["matched_by"] = .array((via[id] ?? []).map { .string($0) })
            return .object(o)
        }
        return .object(["status": .string("ok"), "results": .array(capped), "meaning_search": .string(meaningSearch)])
    }

    /// The Knowledge Graph page's date reading (KnowledgeGraphView.parseKGDate).
    static func kgSeenDate(_ s: String) -> Date? {
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFull.date(from: s) { return d }
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        if let d = isoNoFrac.date(from: s) { return d }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: String(s.prefix(10)))
    }
}
