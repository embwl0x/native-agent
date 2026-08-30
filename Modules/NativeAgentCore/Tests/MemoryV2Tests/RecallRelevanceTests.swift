import Foundation
import Testing
@testable import MemoryV2
import NativeAgentCore

@Suite("Recall relevance survives age")
struct RecallRelevanceTests {
    @Test func inflectedQueryMatchesSingularFactsInBothRecallLanes() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(StoredMemory(
            id: "answer", content: "The user dislikes verbose search narration.", embedding: [1, 0]
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "tangent", content: "The user enjoys informal commentary.", embedding: [1, 0]
        ))
        let dense = try await store.recall(embedding: [1, 0], queryText: "searches", topK: 1)
        let cold = try await store.recallByKeyword(queryText: "searches", topK: 1)
        #expect(dense.first?.memory.id == "answer")
        #expect(cold.first?.memory.id == "answer")
        #expect(MemoryRecallScoring.lexicalTokens("searches reports brushes boxes") == ["search", "report", "brush", "box"])
        #expect(MemoryRecallScoring.lexicalTokens("status analysis class v123s") == ["status", "analysis", "class", "v123s"])
    }

    @Test(arguments: ["project", "operational", "volatile", "decision", "note", "incident"])
    func oldDirectAnswerBeatsFreshTangents(kind: String) async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(StoredMemory(
            id: "answer", content: "The observatory archive contains infrared telescope exposures.",
            createdAt: "2000-01-01T00:00:00Z", updatedAt: "2000-01-01T00:00:00Z",
            embedding: [1, 0], metadata: .object(["kind": .string(kind)])
        ))
        for index in 0..<6 {
            _ = try await store.insertMemory(StoredMemory(
                id: "tangent-\(index)", content: "Recent observatory meeting note \(index).",
                embedding: [0.6, 0.8], metadata: .object(["kind": .string(kind)])
            ))
        }
        let hits = try await store.recall(embedding: [1, 0], topK: 5)
        #expect(hits.first?.memory.id == "answer")
        #expect((hits.first?.similarity ?? 0) >= 0.9)
        // Age does not mutate the fact, lifecycle, or use counters.
        let answer = try await store.listMemories(status: "active").first { $0.id == "answer" }
        #expect(answer?.lifecycle == MemoryLifecycle.confirmed)
        #expect(answer?.useCount == 0)
    }

    @Test func lexicalFallbackAlsoRetainsOldDirectAnswers() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(StoredMemory(
            id: "answer", content: "Observatory archive holds infrared exposures.",
            createdAt: "2000-01-01T00:00:00Z", updatedAt: "2000-01-01T00:00:00Z",
            metadata: .object(["kind": .string("operational")])
        ))
        for index in 0..<6 {
            _ = try await store.insertMemory(StoredMemory(
                id: "tangent-\(index)", content: "Observatory schedules meeting number \(index)."
            ))
        }
        let hits = try await store.recallByKeyword(queryText: "observatory archive infrared exposures", topK: 5)
        #expect(hits.first?.memory.id == "answer")
    }

    @Test func recencyIsBoundedButStillBreaksEqualRelevanceTies() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = MemoryRecallScoring.recallRecencyFactor(kind: "project", updatedAt: "2000-01-01T00:00:00Z", now: now)
        #expect(old >= 0.9 && old < 1)
        #expect(MemoryRecallScoring.recallRecencyFactor(kind: "identity", updatedAt: "2000-01-01T00:00:00Z", now: now) == 1)
        #expect(MemoryRecallScoring.recallRecencyFactor(kind: nil, updatedAt: "invalid", now: now) == 1)
    }
}
