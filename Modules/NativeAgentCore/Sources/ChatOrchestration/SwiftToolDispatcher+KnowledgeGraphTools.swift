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
    func impl_search_kg(input: [String: JSONValue]) async throws -> JSONValue {
        // Bad input is a thrown refusal before any gate, so an empty call is
        // an error whatever the switch says.
        let query = try requireString(input, "query")
        let limit = min(100, max(1, optionalInt(input, "limit") ?? 10))
        // Settings ▸ "Knowledge graph": off means the graph is not read. Say so
        // with no `results` key, so a refusal can never be read as an empty
        // search (reviewer, 2026-09-05). The policy is the one that owns
        // THIS dispatcher's data root.
        guard MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) else {
            return .object([
                "status": .string("disabled"),
                "reason": .string(MemoryPolicyGate.knowledgeGraphOffMessage),
            ])
        }
        let reader = SwiftNativeKnowledgeGraphReader(
            graphPath: knowledgeGraphPath,
            flushURL: nil
        )
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
        for (rank, ent) in results.prefix(limit * 3).enumerated() {
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
                persona: nil,
                surface: nil
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
                    guard case .found(let ent)? = await reader.entity(id: nodeID) else { continue }
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
        return .object(["results": .array(capped), "meaning_search": .string(meaningSearch)])
    }
}
