import Foundation
import Testing
@testable import MemoryV2
import NativeAgentCore

// Best-agent sweep R4 A5(b). The legacy recall lane had NO fallback when the
// query embedding was unavailable: a cold MiniLM (reliably the state on the
// first message after launch) produced `recalled = []` and a trace flag, and
// that was the whole of the agent's memory for that turn. Recall now degrades
// to a lexical lane instead of going silent.
@Suite("Keyword recall fallback")
struct KeywordRecallFallbackTests {

    private func seed(_ store: MemoryStorage) async throws {
        for (content, source) in [
            ("User prefers Opus 4.8 for implementation work", "chat"),
            ("the espresso machine needs descaling monthly", "chat"),
            ("NativeAgent ships as a signed macOS app", "chat"),
        ] {
            _ = try await store.insertMemory(StoredMemory(content: content, source: source))
        }
    }

    @Test func zeroEmbeddingFallsBackToKeywordHitsInsteadOfEmpty() async throws {
        let store = try MemoryStorage()
        try await seed(store)
        // A cold embedder's vector: right shape, no direction.
        let cold: [Float] = [0, 0, 0]
        let hits = try await store.recall(
            embedding: cold, queryText: "espresso descaling", topK: 5, persona: nil
        )
        #expect(!hits.isEmpty, "cold embedder must not mean zero recall")
        #expect(hits.first?.memory.content.contains("espresso") == true)
    }

    @Test func keywordRecallRanksTheLexicallyBestRowFirst() async throws {
        let store = try MemoryStorage()
        try await seed(store)
        let hits = try await store.recallByKeyword(
            queryText: "Opus implementation", topK: 5, persona: nil
        )
        #expect(!hits.isEmpty)
        #expect(hits.first?.memory.content.contains("Opus 4.8") == true)
    }

    @Test func keywordRecallReturnsNothingForAnUnmatchedQuery() async throws {
        let store = try MemoryStorage()
        try await seed(store)
        let hits = try await store.recallByKeyword(
            queryText: "quantum chromodynamics", topK: 5, persona: nil
        )
        #expect(hits.isEmpty, "the fallback must not invent hits")
    }

    @Test func keywordRecallHonorsTopK() async throws {
        let store = try MemoryStorage()
        for i in 0..<10 {
            _ = try await store.insertMemory(
                StoredMemory(content: "descaling note number \(i)", source: "chat")
            )
        }
        let hits = try await store.recallByKeyword(
            queryText: "descaling note", topK: 3, persona: nil
        )
        #expect(hits.count <= 3)
    }

    @Test func keywordRecallEscapesLikeWildcards() async throws {
        let store = try MemoryStorage()
        try await seed(store)
        // A raw `%` would otherwise match every row.
        let hits = try await store.recallByKeyword(
            queryText: "%", topK: 5, persona: nil
        )
        #expect(hits.isEmpty)
    }

    @Test func keywordRecallExcludesRetiredLifecycles() async throws {
        let store = try MemoryStorage()
        let mem = StoredMemory(content: "User's favorite color is green", source: "chat")
        _ = try await store.insertMemory(mem)
        let live = try await store.recallByKeyword(
            queryText: "favorite color", topK: 5, persona: nil
        )
        #expect(live.count == 1)

        _ = try await store.updateMemory(
            id: mem.id,
            patch: MemoryPatch(lifecycle: MemoryLifecycle.corrected)
        )
        let after = try await store.recallByKeyword(
            queryText: "favorite color", topK: 5, persona: nil
        )
        #expect(after.isEmpty, "a corrected memory must not resurface via the fallback")
    }

    @Test func keywordRecallFindsRowsWithNoEmbeddingAtAll() async throws {
        // The dense lane requires `embedding IS NOT NULL`; the fallback must
        // still answer on a store whose vectors were never backfilled.
        let store = try MemoryStorage()
        _ = try await store.insertMemory(
            StoredMemory(content: "unembedded but real memory about kayaking", source: "chat")
        )
        let hits = try await store.recallByKeyword(
            queryText: "kayaking", topK: 5, persona: nil
        )
        #expect(hits.count == 1)
    }
}
