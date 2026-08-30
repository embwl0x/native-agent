import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

private enum CanonicalFallbackFixtureError: Error { case denseUnavailable }

private struct CanonicalFallbackEmbedder: EmbeddingProvider {
    let dimensions = 2
    let modelId = "canonical-fallback-fixture"
    let fail: Bool
    func embed(_ texts: [String]) async throws -> [[Float]] {
        if fail { throw CanonicalFallbackFixtureError.denseUnavailable }
        return texts.map { _ in [1, 0] }
    }
}

@Suite("Recall KG fallback canonical authority")
struct RecallCanonicalFallbackTests {
    private func entity(_ id: String, memoryID: String? = nil, type: String = "fact") -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "name": .string("Orchard \(id)"), "type": .string(type),
            "summary": .string("Orchard stale graph claim should never be returned."),
        ]
        if let memoryID { value["memory_id"] = .string(memoryID) }
        return .object(value)
    }

    private func fixture(
        failEmbedding: Bool, records: [MemoryRecord], entities: [JSONValue], unavailable: Bool = false
    ) async throws -> (SwiftToolDispatcher, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-canonical-fallback-\(UUID())")
        let directory = root.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var graphEntities: [String: JSONValue] = [:]
        for (index, entity) in entities.enumerated() { graphEntities["e\(index)"] = entity }
        try JSONValue.object(["entities": .object(graphEntities), "edges": .array([])])
            .serializedData(pretty: false).write(to: directory.appendingPathComponent("knowledge_graph.json"))
        let storage = InMemoryMemoryStorage()
        for record in records {
            // No vectors: successful dense recall is genuinely empty while
            // exact canonical records remain available for candidate checks.
            _ = try await storage.insert(record: record, embedding: nil)
        }
        let memory = unavailable ? SwiftNativeMemoryV2() : SwiftNativeMemoryV2(
            embedder: CanonicalFallbackEmbedder(fail: failEmbedding), storage: storage
        )
        return (SwiftToolDispatcher(dataRoot: root, memoryV2: memory, allowProcessGlobalTools: false), root)
    }

    private func recall(_ dispatcher: SwiftToolDispatcher, surface: String = "chat") async throws -> [String: JSONValue] {
        let result = try await dispatcher.dispatch(
            tool: "recall_memory", input: ["query": .string("Orchard"), "k": .int(10)], surface: surface
        )
        guard case .object(let object) = result else {
            Issue.record("missing recall envelope"); return [:]
        }
        return object
    }

    @Test(arguments: [false, true])
    func fallbackReadsCurrentCanonicalTextDatesAndRecoveryAction(failEmbedding: Bool) async throws {
        let text = String(repeating: "The orchard watering plan is now twice weekly. ", count: 70) + "End."
        let record = MemoryRecord(
            id: "current", text: text, memoryKind: "note", personaId: "Agent",
            createdAt: "2026-08-01T00:00:00Z", observedAt: "2026-08-29T12:00:00Z"
        )
        let (dispatcher, root) = try await fixture(
            failEmbedding: failEmbedding, records: [record], entities: [entity("old-copy", memoryID: "current")]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await recall(dispatcher)
        #expect(result["status"] == .string(failEmbedding ? "degraded" : "ok"))
        #expect(result["memory_available"] == .bool(!failEmbedding))
        guard case .array(let hits)? = result["hits"], hits.count == 1,
              case .object(let hit) = hits[0], case .string(let content)? = hit["content"] else {
            Issue.record("missing authorized fallback"); return
        }
        #expect(hit["id"] == .string("current"))
        #expect(text.hasPrefix(content))
        #expect(!content.contains("stale graph"))
        #expect(hit["score"] == nil)
        #expect(hit["kg_entity_name"] == nil)
        #expect(hit["retrieval_source"] == .string("knowledge_graph_candidate_canonical_memory"))
        #expect(hit["temporal"] == .object(["observed_at": .string("2026-08-29T12:00:00Z")]))
        #expect(hit["content_truncated"] == .bool(true))
        #expect(hit["full_content_chars"] == .int(Int64(text.count)))
        guard case .object(let action)? = hit["read_more"] else { Issue.record("missing paging action"); return }
        #expect(action["memory_id"] == .string("current"))
    }

    @Test(arguments: [false, true])
    func retiredMissingUnlinkedAndAggregateEvidenceCannotEscape(failEmbedding: Bool) async throws {
        let retired = MemoryRecord(
            id: "retired", text: "The orchard was watered daily.", lifecycle: "corrected",
            createdAt: "2026-08-01T00:00:00Z", status: "active"
        )
        let current = MemoryRecord(id: "current", text: "The orchard is watered weekly.", createdAt: "2026-08-01T00:00:00Z")
        guard case .object(var aggregate) = entity("aggregate", memoryID: "current", type: "project") else {
            Issue.record("invalid aggregate fixture"); return
        }
        aggregate["last_memory_id"] = .string("current")
        let (dispatcher, root) = try await fixture(
            failEmbedding: failEmbedding, records: [retired, current], entities: [
                entity("retired-copy", memoryID: "retired"), entity("missing-copy", memoryID: "missing"),
                entity("legacy-unlinked"), .object(aggregate),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await recall(dispatcher)
        #expect(result["hits"] == .array([]))
        #expect(result["status"] == .string(failEmbedding ? "degraded" : "ok"))
        // Explicit graph inspection is a separate tool and remains available.
        let graph = try await dispatcher.dispatch(tool: "search_kg", input: ["query": .string("Orchard")], surface: "chat")
        guard case .object(let graphObject) = graph, case .array(let graphHits)? = graphObject["results"] else {
            Issue.record("missing explicit graph result"); return
        }
        #expect(graphHits.count == 4)
    }

    @Test(arguments: [false, true])
    func privateCanonicalRecordStaysPrivateOnRestrictedSurface(failEmbedding: Bool) async throws {
        let record = MemoryRecord(id: "private", text: "The orchard access code is local only.", createdAt: "2026-08-01T00:00:00Z")
        let (dispatcher, root) = try await fixture(
            failEmbedding: failEmbedding, records: [record], entities: [entity("private-copy", memoryID: "private")]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await recall(dispatcher, surface: "slack")
        #expect(result["hits"] == .array([]))
    }

    @Test func unavailableCanonicalReadReportsDegradedWithoutGraphProse() async throws {
        let (dispatcher, root) = try await fixture(
            failEmbedding: true, records: [], entities: [entity("graph-copy", memoryID: "unreadable")], unavailable: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await recall(dispatcher)
        #expect(result["status"] == .string("degraded"))
        #expect(result["error"] == .string("canonical_memory_unavailable"))
        #expect(result["memory_available"] == .bool(false))
        #expect(result["hits"] == .array([]))
    }
}
