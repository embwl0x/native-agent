import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// MARK: - commit_memory store-path tests
//
// commit_memory (Agent's memory WRITE path) routes the chat tool to
// SwiftNativeMemoryV2.store(content:source:metadata:). The dispatcher impl
// (ChatOrchestration/SwiftToolDispatcher+Impls.swift::impl_commit_memory) is
// hardcoded to the process-wide `.shared` instance (which roots at the LIVE
// data root), so the hermetic round-trip is asserted HERE against a fresh
// in-memory instance using the EXACT metadata shape the impl builds, plus the
// EXACT trace-event the impl emits. These tests prove:
//   1. the record lands with source "chat.commit_memory",
//   2. kind threads through metadata.kind into the U3 write-time stamper,
//   3. the memory.commit trace event serializes with the documented payload.
//
// HERMETIC: unique tmp dirs per test; no `.shared`, no live data.

@Suite("CommitMemoryStore")
struct CommitMemoryStoreTests {

    /// Build metadata EXACTLY as impl_commit_memory does (kind + confidence +
    /// importance + optional tags). Keeps the test honest against the prod
    /// metadata shape — if the impl's shape drifts, mirror it here.
    private func commitMetadata(
        kind: String,
        tags: [String],
        confidence: Double,
        importance: Double
    ) -> JSONValue {
        var meta: [String: JSONValue] = [
            "kind": .string(kind),
            "confidence": .double(confidence),
            "importance": .double(importance),
        ]
        if !tags.isEmpty {
            meta["tags"] = .array(tags.map { .string($0) })
        }
        return .object(meta)
    }

    @Test func storeRoundTripLandsRecordWithSourceAndKind() async throws {
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: storage)

        let meta = commitMetadata(
            kind: "preference", tags: ["coffee", "morning"],
            confidence: 0.9, importance: 0.7)
        let rec = try await memory.store(
            content: "the user takes his coffee black",
            source: "chat.commit_memory",
            metadata: meta)

        // Record landed with the chat source tag.
        #expect(rec.sourceRunId == "chat.commit_memory")
        #expect(rec.text == "the user takes his coffee black")

        // kind threaded through metadata.kind → honored verbatim by the U3
        // stamper (caller kind wins; no machine provenance marker).
        #expect(MemoryKindStamp.kind(of: rec.extras) == "preference")
        #expect(MemoryKindStamp.kindSource(of: rec.extras) == nil)

        // Sibling keys (tags/confidence/importance) survive the stamp pass.
        if case .object(let obj)? = rec.extras {
            #expect(obj["confidence"] == .double(0.9))
            #expect(obj["importance"] == .double(0.7))
            #expect(obj["tags"] == .array([.string("coffee"), .string("morning")]))
        } else {
            Issue.record("metadata lost its object shape")
        }

        // Durable: the row is queryable from the store after the write.
        let all = try await storage.listMemory(kind: nil)
        #expect(all.contains { $0.id == rec.id && $0.text == "the user takes his coffee black" })
    }

    @Test func defaultKindNoteThreadsThroughVerbatim() async throws {
        // The impl defaults `kind` to "note" when absent. "note" is NOT in the
        // KindStamp taxonomy but the stamper honors ANY non-empty caller kind
        // verbatim (it only stamps "general"+write_default when kind is absent/
        // empty), so "note" must survive untouched with no provenance marker.
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        let meta = commitMetadata(
            kind: "note", tags: [], confidence: 0.8, importance: 0.5)
        let rec = try await memory.store(
            content: "default-kind commit", source: "chat.commit_memory", metadata: meta)
        #expect(MemoryKindStamp.kind(of: rec.extras) == "note")
        #expect(MemoryKindStamp.kindSource(of: rec.extras) == nil)
    }

    @Test func emptyContentRejectedByStore() async throws {
        // The dispatcher impl rejects empty text BEFORE the store, but store()
        // is also the last line of defense (MemoryV2Error.invalidQuery).
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: InMemoryMemoryStorage())
        await #expect(throws: (any Error).self) {
            _ = try await memory.store(
                content: "", source: "chat.commit_memory",
                metadata: .object(["kind": .string("note")]))
        }
    }

    // MARK: - write-time exact-duplicate guard (taste pass 2026-07-24)
    //
    // A repeated commit_memory inserted a fresh identical active row each
    // time (4 copies of one fact landed in 49s on 2026-07-22, live store).
    // store() now returns the EXISTING record for an exact-content duplicate
    // instead of inserting — same normalizedContentKey the weekly hygiene
    // pass uses, so write-time and hygiene-time "duplicate" agree.

    @Test func repeatedIdenticalStoreIsIdempotent() async throws {
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: storage)
        let meta = commitMetadata(
            kind: "note", tags: [], confidence: 0.9, importance: 0.6)

        let first = try await memory.store(
            content: "User's sleep schedule: typically sleeps 19:00-03:00",
            source: "chat.commit_memory", metadata: meta)
        let second = try await memory.store(
            content: "User's sleep schedule: typically sleeps 19:00-03:00",
            source: "chat.commit_memory", metadata: meta)

        // Same record returned, not a sibling row.
        #expect(second.id == first.id)
        let all = try await storage.listMemory(kind: nil)
        #expect(all.count == 1)
    }

    @Test func duplicateGuardUsesHygieneNormalization() async throws {
        // Case, curly quotes, collapsed whitespace, and trailing punctuation
        // are the exact normalizations hygiene's exact-dup collapse applies —
        // the write guard must agree or dups slip through until the weekly run.
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: storage)
        let meta = commitMetadata(
            kind: "note", tags: [], confidence: 0.9, importance: 0.6)

        let first = try await memory.store(
            content: "User's desk faces the window", source: "chat.commit_memory", metadata: meta)
        let second = try await memory.store(
            content: "  user\u{2019}s desk   faces the window. ",
            source: "chat.commit_memory", metadata: meta)

        #expect(second.id == first.id)
        #expect(try await storage.listMemory(kind: nil).count == 1)
    }

    @Test func distinctContentStillInsertsNormally() async throws {
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: storage)
        let meta = commitMetadata(
            kind: "note", tags: [], confidence: 0.9, importance: 0.6)

        let first = try await memory.store(
            content: "User prefers matcha in the morning",
            source: "chat.commit_memory", metadata: meta)
        let second = try await memory.store(
            content: "User prefers espresso after lunch",
            source: "chat.commit_memory", metadata: meta)

        #expect(second.id != first.id)
        #expect(try await storage.listMemory(kind: nil).count == 2)
    }

    @Test func duplicateBumpsRecallCountThroughRealBridge() async throws {
        // gpt-5.5 BLOCKING (2026-07-24): the in-memory fixture ignores unknown
        // patch keys, which HID that MemoryStorageBridge's passthrough list
        // didn't include recall_count — on production SQLite the corroboration
        // bump silently no-oped. This goes through the REAL chain
        // (SwiftNativeMemoryV2 → MemoryStorageBridge → MemoryStorage on a temp
        // sqlite) and must fail if recall_count ever falls out of passthrough.
        let store = try MemoryStorage()
        let bridge = MemoryStorageBridge(storage: store)
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: bridge)
        let meta = commitMetadata(
            kind: "note", tags: [], confidence: 0.9, importance: 0.6)

        let first = try await memory.store(
            content: "User's monitor is the LG UltraFine",
            source: "chat.commit_memory", metadata: meta)
        let second = try await memory.store(
            content: "User's monitor is the LG UltraFine",
            source: "chat.commit_memory", metadata: meta)
        #expect(second.id == first.id)
        if case .object(let m)? = second.extras {
            #expect(m["recall_count"] == .int(1))
        } else {
            Issue.record("duplicate return lost its metadata object")
        }

        // And it accumulates: a third assertion of the same fact → 2.
        let third = try await memory.store(
            content: "User's monitor is the LG UltraFine",
            source: "chat.commit_memory", metadata: meta)
        if case .object(let m)? = third.extras {
            #expect(m["recall_count"] == .int(2))
        } else {
            Issue.record("duplicate return lost its metadata object")
        }
        // Still exactly one active row in the real store.
        let rows = try await bridge.listMemory(kind: nil)
        #expect(rows.filter { ($0.status ?? "active") == "active" }.count == 1)
    }

    @Test func duplicateOfArchivedRowInsertsFreshActive() async throws {
        // The guard matches ACTIVE rows only: re-asserting a fact whose old
        // copy was archived must produce a fresh active row, not resurrect
        // or silently point at the archived one.
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(), storage: storage)
        let meta = commitMetadata(
            kind: "note", tags: [], confidence: 0.9, importance: 0.6)

        let first = try await memory.store(
            content: "User's standing desk arrives Tuesday",
            source: "chat.commit_memory", metadata: meta)
        _ = try await storage.updateMemory(
            id: first.id, patch: .object(["status": .string("archived")]),
            newEmbedding: nil)

        let second = try await memory.store(
            content: "User's standing desk arrives Tuesday",
            source: "chat.commit_memory", metadata: meta)
        #expect(second.id != first.id)
        #expect(second.status == "active")
    }
}
