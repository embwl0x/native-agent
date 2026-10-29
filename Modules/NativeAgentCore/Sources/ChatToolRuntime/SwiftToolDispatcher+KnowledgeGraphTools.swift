import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
import WorkshopExecution
// Blueprint: | `SwiftToolDispatcher+KnowledgeGraphTools.swift` | `SwiftToolDispatcher`: `impl_search_kg`, `kgSeenDate`; failed semantic recall or graph hydration returns partial search with the checked read's cause |

// MARK: - Knowledge graph tools

extension SwiftToolDispatcher {
    func impl_search_kg(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Bad input is a thrown refusal before any gate, so an empty call is
        // an error whatever the switch says.
        let openID = optionalString(input, "entity_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = optionalString(input, "query")
        let limit = min(100, max(1, Self.jsonInt(input["limit"]) ?? 10))
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
        // Off and damaged Trust are different causes with different levers.
        if let failure = MemoryPolicyGate.knowledgeGraphFailure(dataRoot: dataRoot) {
            return ChatToolOutcome.failure(error: failure, tool: "search_kg")
        }
        let disclosedIDs = Set(try await memoryV2.listMemory(kind: nil).filter {
            MemoryRecordDisclosurePolicy.classify($0)?.permits(surface: surface, personaID: nil) == true
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
            graphPath: knowledgeGraphPath
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
        // Fact nodes reuse memory vectors; lexical and meaning hits fuse by reciprocal rank, 1 / (60 + rank).
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
        var meaningSearchError: String?
        do {
            let response = try await memoryV2.recall(MemoryV2RecallRequest(
                text: query,
                topK: limit * 2,
                persona: nil,
                surface: surface
            ))
            // An epoch-mismatched query vector yields lexical hits, which cannot count as meaning matches.
            let lexical = response.hits.contains { $0.source == "swift-native-keyword-fallback" }
            if lexical { meaningSearch = "keyword-fallback" }
            var missing = Set<String>()
            let missingIDs = response.scored.map { SwiftNativeKnowledgeGraphIndexer.memoryFactEntityID(for: $0.record.id) }
                .filter { entities[$0] == nil && missing.insert($0).inserted }
            let recalledEntities = try await reader.entitiesChecked(ids: missingIDs)
            for (rank, scored) in response.scored.enumerated() {
                let nodeID = SwiftNativeKnowledgeGraphIndexer.memoryFactEntityID(for: scored.record.id)
                if entities[nodeID] == nil {
                    guard let ent = recalledEntities[nodeID], passesFilters(ent) else { continue }
                    order.append(nodeID); entities[nodeID] = ent
                }
                fused[nodeID, default: 0] += 1.0 / (60.0 + Double(rank))
                via[nodeID, default: []].append(lexical ? "keyword" : "meaning")
            }
        } catch {
            // Preserve text hits, but neither a failed recall nor failed graph
            // hydration proves complete semantic coverage.
            meaningSearch = "unavailable"
            meaningSearchError = error.localizedDescription
        }
        let ranked = order.sorted { (fused[$0] ?? 0) > (fused[$1] ?? 0) }.prefix(limit)
        let capped: [JSONValue] = ranked.compactMap { id in
            guard case .object(var o)? = entities[id] else { return nil }
            o["matched_by"] = .array((via[id] ?? []).map { .string($0) })
            return .object(o)
        }
        var answer: [String: JSONValue] = ["status": .string(meaningSearchError == nil ? "ok" : "partial"),
            "results": .array(capped), "meaning_search": .string(meaningSearch)]
        if let meaningSearchError { answer["meaning_search_error"] = .string(meaningSearchError) }
        return .object(answer)
    }

    /// The Knowledge Graph page's date reading (KnowledgeGraphView.parseKGDate).
    static func kgSeenDate(_ s: String) -> Date? {
        if let date = NativeTimestampFormat.parseISO8601FractionalFirst(s) { return date }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: String(s.prefix(10)))
    }
}
