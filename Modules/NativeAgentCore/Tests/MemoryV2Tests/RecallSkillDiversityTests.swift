import Foundation
import Testing
@testable import MemoryV2
import NativeAgentCore

@Suite("Final recall skill diversity")
struct RecallSkillDiversityTests {
    private struct QueryEmbedder: EmbeddingProvider {
        let cold: Bool
        let dimensions = 2
        let modelId = "recall-diversity-fixture"
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in cold ? [0, 0] : [1, 0] }
        }
    }

    private func fixture(factCount: Int, deniedFactCount: Int = 0) async throws -> MemoryStorage {
        let store = try MemoryStorage(inMemoryName: "recall-diversity-\(UUID().uuidString)")
        for index in 0..<12 {
            _ = try await store.insertMemory(StoredMemory(
                id: "skill-pointer:\(index)", content: "Orchard skill \(index)",
                embedding: [1, 0],
                metadata: .object(["kind": .string("skill"), "privacy": .string("public_safe")])
            ))
        }
        for index in 0..<factCount {
            _ = try await store.insertMemory(StoredMemory(
                id: "fact-\(index)", content: "Orchard watering fact \(index) is useful for the seasonal planting calendar.",
                embedding: [0.8, 0.6],
                metadata: .object(["kind": .string("fact"), "privacy": .string("public_safe")])
            ))
        }
        for index in 0..<deniedFactCount {
            _ = try await store.insertMemory(StoredMemory(
                id: "denied-\(index)", content: "Orchard private fact \(index)",
                embedding: [1, 0], metadata: .object(["kind": .string("fact")])
            ))
        }
        return store
    }

    @Test(arguments: [false, true])
    func requestedTopKUsesItsOwnQuotaAfterTheDisclosureWindow(cold: Bool) async throws {
        let store = try await fixture(factCount: 8, deniedFactCount: 4)
        let memory = SwiftNativeMemoryV2(
            embedder: QueryEmbedder(cold: cold), storage: MemoryStorageBridge(storage: store)
        )
        let response = try await memory.recall(MemoryV2RecallRequest(
            text: "Orchard", topK: 8, surface: "slack"
        ))
        let ids = response.scored.map(\.record.id)
        #expect(ids.count == 8)
        #expect(ids.filter { $0.hasPrefix("skill-pointer:") }.count == 2)
        #expect(ids.filter { $0.hasPrefix("fact-") }.count == 6)
        #expect(!ids.contains { $0.hasPrefix("denied-") })
        #expect(response.disclosureFilteredCount == 4)
        #expect(response.scored.map(\.score) == response.scored.map(\.score).sorted(by: >))
    }

    @Test(arguments: [0, 1])
    func scarceFactsStillFillRequestedResultsFromSkills(factCount: Int) async throws {
        let store = try await fixture(factCount: factCount)
        let memory = SwiftNativeMemoryV2(
            embedder: QueryEmbedder(cold: false), storage: MemoryStorageBridge(storage: store)
        )
        let response = try await memory.recall(MemoryV2RecallRequest(
            text: "Orchard", topK: 8, surface: "chat"
        ))
        #expect(response.hits.count == 8)
        #expect(response.scored.filter { $0.record.id.hasPrefix("fact-") }.count == factCount)
        #expect(response.scored.filter { $0.record.id.hasPrefix("skill-pointer:") }.count == 8 - factCount)
    }

    @Test func singleRequestedResultKeepsTheExistingBestMatchPolicy() async throws {
        let store = try await fixture(factCount: 8)
        let memory = SwiftNativeMemoryV2(
            embedder: QueryEmbedder(cold: false), storage: MemoryStorageBridge(storage: store)
        )
        let response = try await memory.recall(MemoryV2RecallRequest(text: "Orchard", topK: 1, surface: "chat"))
        #expect(response.hits.count == 1)
        #expect(response.scored.first?.record.id.hasPrefix("skill-pointer:") == true)
    }
}
