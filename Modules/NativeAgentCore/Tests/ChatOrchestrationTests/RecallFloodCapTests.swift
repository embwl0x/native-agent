// U3 review blockers (gpt-5.5, 2026-06-10): recall flood caps.
//
// impl_recall_memory had no upper bound on k and serialized up to
// 2000 chars of content per hit — k=100 meant ~200k chars pushed into the
// tool loop. These tests pin the two caps:
//   1. k clamps to [1, maxRecallK].
//   2. content rides along in rank order only until the total
//      recallContentBudgetChars budget is spent; later hits degrade to
//      preview-only with an explanatory note.
import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MemoryV2

@Suite("recall_memory flood caps")
struct RecallFloodCapSuite {

    // MARK: k cap

    @Test func kClampsToTheCeiling() {
        #expect(SwiftToolDispatcher.cappedRecallK(100) == SwiftToolDispatcher.maxRecallK)
        #expect(SwiftToolDispatcher.cappedRecallK(SwiftToolDispatcher.maxRecallK + 1)
            == SwiftToolDispatcher.maxRecallK)
        #expect(SwiftToolDispatcher.cappedRecallK(2000) == SwiftToolDispatcher.maxRecallK)
    }

    @Test func kClampsToAtLeastOne() {
        #expect(SwiftToolDispatcher.cappedRecallK(0) == 1)
        #expect(SwiftToolDispatcher.cappedRecallK(-5) == 1)
    }

    @Test func reasonableKPassesThrough() {
        #expect(SwiftToolDispatcher.cappedRecallK(5) == 5)
        #expect(SwiftToolDispatcher.cappedRecallK(SwiftToolDispatcher.maxRecallK)
            == SwiftToolDispatcher.maxRecallK)
    }

    // MARK: total content budget

    private func makeHits(count: Int, contentChars: Int) -> [MemoryRecallHit] {
        (0..<count).map { i in
            MemoryRecallHit(
                score: 1.0 - Double(i) * 0.01,
                sessionId: "s\(i)",
                role: "user",
                ts: "2026-06-10T00:00:0\(i % 10)Z",
                preview: "preview \(i)",
                content: String(repeating: "x", count: contentChars),
                source: "test"
            )
        }
    }

    private func contentString(_ hit: JSONValue) -> String? {
        guard case .object(let obj) = hit, case .string(let s)? = obj["content"] else { return nil }
        return s
    }

    private func noteString(_ hit: JSONValue) -> String? {
        guard case .object(let obj) = hit, case .string(let s)? = obj["content_note"] else { return nil }
        return s
    }

    private func object(_ hit: JSONValue) -> [String: JSONValue] {
        guard case .object(let obj) = hit else { return [:] }
        return obj
    }

    @Test func contentStopsExactlyWhenBudgetIsSpent() {
        // 2000-char rows against the 12k budget: hits 0-5 (6 × 2000 = 12000)
        // carry content; hits 6+ are preview-only with a note.
        let perRow = 2000
        let fullRows = SwiftToolDispatcher.recallContentBudgetChars / perRow
        let hits = makeHits(count: fullRows + 4, contentChars: perRow)
        let out = SwiftToolDispatcher.recallHitsJSON(hits)
        #expect(out.count == hits.count) // hit COUNT is never reduced
        for (i, row) in out.enumerated() {
            if i < fullRows {
                #expect(contentString(row)?.count == perRow, "hit \(i) should carry content")
                #expect(noteString(row) == nil)
            } else {
                #expect(contentString(row) == nil, "hit \(i) should be preview-only")
                #expect(noteString(row)?.contains("budget") == true)
            }
        }
        // Previews and scores survive on the degraded hits.
        if case .object(let last)? = out.last {
            #expect(last["preview"] != nil)
            #expect(last["score"] != nil)
        }
    }

    @Test func budgetCutoffIsRankOrderNotBestFit() {
        // First hit consumes most of the budget; the second doesn't fit.
        // A smaller third hit WOULD fit the remainder, but inclusion is
        // strictly rank-ordered — once spent, everything after degrades.
        let big = SwiftToolDispatcher.recallContentBudgetChars - 100
        var hits = makeHits(count: 1, contentChars: big)
        hits += makeHits(count: 1, contentChars: 500)  // doesn't fit (500 > 100)
        hits += makeHits(count: 1, contentChars: 50)   // would fit, must NOT ride
        let out = SwiftToolDispatcher.recallHitsJSON(hits)
        #expect(contentString(out[0])?.count == big)
        #expect(contentString(out[1]) == nil)
        #expect(noteString(out[1]) != nil)
        #expect(contentString(out[2]) == nil)
        #expect(noteString(out[2]) != nil)
    }

    @Test func smallResultSetsAreUntouched() {
        let hits = makeHits(count: 5, contentChars: 300) // 1.5k total, well under budget
        let out = SwiftToolDispatcher.recallHitsJSON(hits)
        for row in out {
            #expect(contentString(row)?.count == 300)
            #expect(noteString(row) == nil)
        }
    }

    @Test func chatVisibleRecallOmitsTimestampAndSourceNoise() {
        let hit = MemoryRecallHit(
            score: 0.9,
            sessionId: "session",
            role: "user",
            ts: "2026-06-10T00:00:00Z",
            preview: "the user prefers clean memory facts.",
            content: "the user prefers clean memory facts.",
            source: "swift-native",
            extras: .object(["id": .string("mem-1")])
        )
        let out = SwiftToolDispatcher.recallHitsJSON([hit])
        let obj = object(out[0])
        #expect(obj["id"] == .string("mem-1"))
        #expect(obj["preview"] == .string("the user prefers clean memory facts."))
        #expect(obj["content"] == .string("the user prefers clean memory facts."))
        #expect(obj["ts"] == nil)
        #expect(obj["source"] == nil)
        #expect(obj["session_id"] == nil)
        #expect(obj["role"] == nil)
    }

    @Test func hitsWithoutContentNeverGetANote() {
        // KG-fallback-shaped rows (no content field) stay preview-only with
        // no note — the note is strictly "budget spent", not "no content".
        let hits = [MemoryRecallHit(score: 0.5, preview: "kg row", content: nil)]
        let out = SwiftToolDispatcher.recallHitsJSON(hits)
        #expect(contentString(out[0]) == nil)
        #expect(noteString(out[0]) == nil)
    }

    /// Flipped 2026-07-24 (User approved): a persona SLOT id is
    /// PRESENTATION-ONLY, so the recall_memory tool reads the ONE shared memory
    /// store for every persona. This test used to pin the opposite — with the
    /// turn persona and the record persona bound to the SAME literal "Agent",
    /// which made an id-vocabulary mismatch look like working isolation.
    ///
    /// Now the two sides carry the LIVE, mismatched vocabularies: the turn
    /// holds a persona slot id ("Agent", a persona subdirectory name) while the
    /// records hold agent names — the only `personaId` vocabulary in the live
    /// store. Both records must come back. Surface disclosure remains the real
    /// boundary and is covered by RecallSurfaceDisclosureSuite below.
    @Test func explicitRecallReadsTheSharedStoreForAnyPersonaSlot() async throws {
        let embedder = MockEmbeddingProvider(dimensions: 32)
        let storage = InMemoryMemoryStorage()
        let query = "shared retrieval phrase"
        let vector = try #require(try await embedder.embed([query]).first)
        let createdAt = "2026-07-14T00:00:00Z"
        for persona in ["Agent", "Other"] {
            _ = try await storage.insert(
                record: MemoryRecord(
                    id: "memory-\(persona.lowercased())",
                    text: "\(persona) private memory",
                    personaId: persona,
                    lifecycle: MemoryLifecycle.confirmed,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    status: "active"
                ),
                embedding: vector,
                embeddingEpoch: embedder.embeddingEpoch
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecallPersona-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(
            dataRoot: root,
            memoryV2: SwiftNativeMemoryV2(embedder: embedder, storage: storage),
            allowProcessGlobalTools: false
        )

        let result = try await ChatTurnRuntimeContext.$current.withValue(
            .init(model: "fixture", surface: "chat", personaID: "Agent")
        ) {
            try await dispatcher.dispatch(
                tool: "recall_memory",
                input: ["query": .string(query), "k": .int(5)],
                surface: "chat"
            )
        }
        guard case .object(let object) = result,
              case .array(let hits)? = object["hits"] else {
            Issue.record("recall_memory did not return a hit array")
            return
        }
        let ids = hits.compactMap { hit -> String? in
            guard case .object(let row) = hit,
                  case .string(let id)? = row["id"] else { return nil }
            return id
        }
        // Both agent-name-scoped records reach a custom persona slot. Compared
        // as a set: the two rows share one embedding, so their relative rank is
        // a tie and asserting an order would be flaky.
        #expect(Set(ids) == ["memory-agent", "memory-other"])
        #expect(object["disclosure_filtered_count"] == .int(0))
    }
}

@Suite("recall_memory surface disclosure (2026-07-20 telegram/bridge blackout)")
struct RecallSurfaceDisclosureSuite {
    private func makeDispatcher(
        insertText: String,
        query: String
    ) async throws -> (SwiftToolDispatcher, URL) {
        let embedder = MockEmbeddingProvider(dimensions: 32)
        let storage = InMemoryMemoryStorage()
        let vector = try #require(try await embedder.embed([query]).first)
        let createdAt = "2026-07-14T00:00:00Z"
        _ = try await storage.insert(
            record: MemoryRecord(
                id: "memory-agent",
                text: insertText,
                personaId: "Agent",
                lifecycle: MemoryLifecycle.confirmed,
                createdAt: createdAt,
                updatedAt: createdAt,
                status: "active"
            ),
            embedding: vector,
            embeddingEpoch: embedder.embeddingEpoch
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecallSurface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (SwiftToolDispatcher(
            dataRoot: root,
            memoryV2: SwiftNativeMemoryV2(embedder: embedder, storage: storage),
            allowProcessGlobalTools: false
        ), root)
    }

    private func recall(
        _ dispatcher: SwiftToolDispatcher, query: String, surface: String
    ) async throws -> (ids: [String], filtered: JSONValue?) {
        let result = try await ChatTurnRuntimeContext.$current.withValue(
            .init(model: "fixture", surface: surface, personaID: "Agent")
        ) {
            try await dispatcher.dispatch(
                tool: "recall_memory",
                input: ["query": .string(query), "k": .int(5)],
                surface: surface
            )
        }
        guard case .object(let object) = result,
              case .array(let hits)? = object["hits"] else {
            Issue.record("recall_memory did not return a hit array")
            return ([], nil)
        }
        let ids = hits.compactMap { hit -> String? in
            guard case .object(let row) = hit,
                  case .string(let id)? = row["id"] else { return nil }
            return id
        }
        return (ids, object["disclosure_filtered_count"])
    }

    @Test func telegramSurfaceRecallsLocalPrivateMemories() async throws {
        // The live 2026-07-20 blackout: a default (localPrivate) memory must be
        // recallable on User's Telegram surface — its absence from
        // localPrivateSurfaces filtered EVERY hit (40/40, 64/64 live).
        let query = "user sleep schedule"
        let (dispatcher, root) = try await makeDispatcher(
            insertText: "User sleeps 19:00-03:00", query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = try await recall(dispatcher, query: query, surface: "telegram")
        #expect(out.ids == ["memory-agent"])
        #expect(out.filtered == .int(0))
    }

    @Test func claudeBridgeSurfaceAliasRecalls() async throws {
        // The bridge dispatches with surface "claude-bridge"; unmapped it
        // fail-closed every bridge recall (live-reproduced via tool.sh).
        let query = "user sleep schedule"
        let (dispatcher, root) = try await makeDispatcher(
            insertText: "User sleeps 19:00-03:00", query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = try await recall(dispatcher, query: query, surface: "claude-bridge")
        #expect(out.ids == ["memory-agent"])
        #expect(out.filtered == .int(0))
    }

    @Test func slackSurfaceStaysFilteredAndReportsHonestCount() async throws {
        // Slack remains outside local_private: hits stay empty, the count is
        // honest, and the KG fallback deliberately does NOT fire on a
        // filtered-empty result (KG has no disclosure check — falling back
        // would leak the denied content through the side door).
        let query = "user sleep schedule"
        let (dispatcher, root) = try await makeDispatcher(
            insertText: "User sleeps 19:00-03:00", query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = try await recall(dispatcher, query: query, surface: "slack")
        #expect(out.ids.isEmpty)
        #expect(out.filtered == .int(1))
    }
}
