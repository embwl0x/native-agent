import Foundation
import Testing
@testable import MemoryV2

/// Eval for ledger surface `memory.storage.frozenCopy`
/// (docs/evals/ledger.json, fence core.memory).
///
/// Silent-failure class: vacuous guard upstream. `frozenCopy(at:)` is the
/// isolation the probe lab and the consolidation gate rely on to score a
/// candidate WITHOUT touching canonical rows or their recall counters. Nothing
/// asserted that isolation: if the copy shared a pool with the live store, or
/// were taken non-transactionally, every probe comparison the gate makes would
/// be scored against a store that is wrong or still moving — and the gate would
/// report green while proving nothing.
///
/// Envelope asserted (never exact scores):
///  1. the copy is a POINT-IN-TIME snapshot — later live inserts/deletes/edits
///     are invisible to it, and the copy's own writes are invisible to the live
///     store (isolation in both directions);
///  2. recall against the copy leaves the LIVE `use_count` / `last_used_at`
///     untouched — the exact property that makes a probe run non-destructive;
///  3. the destination guard refuses to overwrite an existing store, so a lab
///     run can never land on top of a real one.
@Suite("MemoryV2 frozen evaluation copy isolation")
struct FrozenCopyIsolationTests {

    private func makeTempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memv2-frozen-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func populate(_ store: MemoryStorage) async throws {
        _ = try await store.insertMemory(StoredMemory(
            id: "canonical-a",
            content: "User wants the worker to return finished, build-tested work",
            embedding: [1, 0, 0]
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "canonical-b",
            content: "the memory store is bounded and prunes on open",
            embedding: [0, 1, 0]
        ))
        _ = try await store.insertProposal(StoredProposal(
            id: "canonical-p", content: "a staged claim awaiting review"
        ))
    }

    @Test("the frozen copy is a point-in-time snapshot, isolated both ways")
    func copyIsPointInTimeAndIsolated() async throws {
        let liveRoot = try makeTempRoot("live")
        let labRoot = try makeTempRoot("lab")
        defer {
            try? FileManager.default.removeItem(at: liveRoot)
            try? FileManager.default.removeItem(at: labRoot)
        }

        let live = try MemoryStorage(dataRoot: liveRoot)
        try await populate(live)

        let copy = try await live.frozenCopy(at: labRoot)

        // The snapshot carries exactly what was canonical at the moment it was
        // taken.
        #expect(Set(try await copy.listMemories(persona: nil, status: nil, limit: nil).map(\.id))
                == ["canonical-a", "canonical-b"])
        #expect(try await copy.listProposals(status: "pending").map(\.id) == ["canonical-p"])

        // Live moves on: an insert, a content edit, and a delete.
        _ = try await live.insertMemory(StoredMemory(
            id: "post-snapshot", content: "written after the copy was taken", embedding: [0, 0, 1]
        ))
        _ = try await live.updateMemory(
            id: "canonical-a",
            patch: MemoryPatch(content: "edited after the copy was taken")
        )
        #expect(try await live.deleteMemory(id: "canonical-b") == true)

        // ...and none of it reaches the copy.
        let copyIDs = Set(try await copy.listMemories(persona: nil, status: nil, limit: nil).map(\.id))
        #expect(copyIDs == ["canonical-a", "canonical-b"],
                "the frozen copy tracked live mutations — it is not a snapshot")
        let copiedA = try #require(try await copy.memory(id: "canonical-a"))
        #expect(copiedA.content == "User wants the worker to return finished, build-tested work",
                "the frozen copy saw a live edit")

        // The other direction: the lab writing through the copy must never
        // reach the canonical store.
        _ = try await copy.insertMemory(StoredMemory(
            id: "lab-only", content: "a probe-lab scratch row", embedding: [1, 1, 0]
        ))
        #expect(try await live.memory(id: "lab-only") == nil,
                "a write through the frozen copy reached the live store")

        // The copy lives at the lab root the caller named, not next to the
        // canonical file.
        #expect(FileManager.default.fileExists(
            atPath: labRoot.appendingPathComponent("memory/memory.sqlite").path
        ))
    }

    @Test("recall against the copy never bumps the live store's access counters")
    func recallOnCopyLeavesLiveCountersUntouched() async throws {
        let liveRoot = try makeTempRoot("live-counters")
        let labRoot = try makeTempRoot("lab-counters")
        defer {
            try? FileManager.default.removeItem(at: liveRoot)
            try? FileManager.default.removeItem(at: labRoot)
        }

        let live = try MemoryStorage(dataRoot: liveRoot)
        try await populate(live)
        // Give the canonical row a non-zero access history first, so the eval
        // can distinguish "unchanged" from "reset to zero".
        try await live.recordRecallHits(ids: ["canonical-a"], at: "2026-08-01T00:00:00Z")
        let before = try #require(try await live.memory(id: "canonical-a"))
        #expect(before.useCount == 1)

        let copy = try await live.frozenCopy(at: labRoot)

        // A probe run: recall through the copy, and record the hits the way the
        // real recall path does.
        let hits = try await copy.recall(embedding: [1, 0, 0], topK: 5)
        #expect(!hits.isEmpty, "the lab copy returned no candidates — the probe would be vacuous")
        try await copy.recordRecallHits(ids: hits.map(\.memory.id))

        let after = try #require(try await live.memory(id: "canonical-a"))
        #expect(after.useCount == before.useCount,
                "a probe run through the frozen copy incremented the LIVE use_count")
        #expect(after.lastUsedAt == before.lastUsedAt,
                "a probe run through the frozen copy moved the LIVE last_used_at")

        // ...and the copy did record them, so the assertion above is about
        // isolation, not about recordRecallHits being a no-op.
        let copied = try #require(try await copy.memory(id: "canonical-a"))
        #expect(copied.useCount > before.useCount)
    }

    @Test("the copy refuses to land on an existing store")
    func destinationGuardRefusesOverwrite() async throws {
        let liveRoot = try makeTempRoot("live-guard")
        let labRoot = try makeTempRoot("lab-guard")
        defer {
            try? FileManager.default.removeItem(at: liveRoot)
            try? FileManager.default.removeItem(at: labRoot)
        }
        let live = try MemoryStorage(dataRoot: liveRoot)
        try await populate(live)

        _ = try await live.frozenCopy(at: labRoot)
        await #expect(throws: MemoryStorageError.self) {
            _ = try await live.frozenCopy(at: labRoot)
        }
    }
}
