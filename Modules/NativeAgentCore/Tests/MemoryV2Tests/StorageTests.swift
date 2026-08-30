import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

@Suite("MemoryStorage")
struct MemoryStorageTests {
    @Test func insertReadUpdateDeleteMemory() async throws {
        let store = try MemoryStorage()
        let mem = StoredMemory(content: "the user prefers Opus 4.8", source: "chat")
        _ = try await store.insertMemory(mem)

        let fetched = try await store.memory(id: mem.id)
        #expect(fetched?.content == "the user prefers Opus 4.8")
        #expect(fetched?.source == "chat")
        #expect(fetched?.personaId == MemoryV2Defaults.personaID)
        #expect(fetched?.lifecycle == MemoryLifecycle.confirmed)

        let updated = try await store.updateMemory(
            id: mem.id,
            patch: MemoryPatch(
                content: "the user prefers Opus 4.8 for impl",
                confidence: 0.85,
                lifecycle: MemoryLifecycle.inferred
            )
        )
        #expect(updated?.content == "the user prefers Opus 4.8 for impl")
        #expect(updated?.confidence == 0.85)
        #expect(updated?.lifecycle == MemoryLifecycle.inferred)
        #expect((updated?.updatedAt ?? "") >= (fetched?.updatedAt ?? ""))

        let listed = try await store.listMemories()
        #expect(listed.count == 1)

        let deleted = try await store.deleteMemory(id: mem.id)
        #expect(deleted == true)
        let after = try await store.memory(id: mem.id)
        #expect(after == nil)
        let tombstoned = try await store.isTombstoned(content: "the user prefers Opus 4.8 for impl")
        #expect(tombstoned == true)
    }

    @Test func lifecycleFiltersInactiveFactsFromRecallAndActiveList() async throws {
        let store = try MemoryStorage()
        let confirmed = StoredMemory(
            id: "confirmed",
            content: "confirmed project fact",
            embedding: [1, 0, 0],
            lifecycle: MemoryLifecycle.confirmed
        )
        let corrected = StoredMemory(
            id: "corrected",
            content: "corrected old project fact",
            embedding: [1, 0, 0],
            lifecycle: MemoryLifecycle.corrected
        )
        let contradicted = StoredMemory(
            id: "contradicted",
            content: "contradicted old project fact",
            embedding: [1, 0, 0],
            lifecycle: MemoryLifecycle.contradicted
        )
        let deleted = StoredMemory(
            id: "deleted",
            content: "deleted old project fact",
            embedding: [1, 0, 0],
            lifecycle: MemoryLifecycle.deleted
        )

        _ = try await store.insertMemory(confirmed)
        _ = try await store.insertMemory(corrected)
        _ = try await store.insertMemory(contradicted)
        _ = try await store.insertMemory(deleted)

        let activeIds = try await store.listMemories(status: "active").map(\.id)
        #expect(activeIds == ["confirmed"])

        let recallIds = try await store.recall(embedding: [1, 0, 0], topK: 10).map { $0.memory.id }
        #expect(recallIds == ["confirmed"])

        let allIds = try await store.listMemories(status: nil).map(\.id).sorted()
        #expect(allIds == ["confirmed", "contradicted", "corrected", "deleted"])
    }

    @Test func hardBoundEvictsLowValueRowsAndPreservesPinnedIdentity() async throws {
        let store = try MemoryStorage(memoryLimit: 3)
        let recorder = ProjectionHookRecorder()
        await store.attachSpotlightHook { memory, deleted in
            recorder.record(target: "spotlight", memory: memory, deleted: deleted)
        }
        await store.attachKnowledgeGraphHook { memory, deleted in
            recorder.record(target: "knowledgeGraph", memory: memory, deleted: deleted)
        }
        let old = "2024-01-01T00:00:00.000Z"
        _ = try await store.insertMemory(StoredMemory(
            id: "temporary-old", content: "temporary", createdAt: old,
            lifecycle: MemoryLifecycle.temporary
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "ordinary-old", content: "ordinary", createdAt: old
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "pinned-old", content: "pinned", createdAt: old,
            metadata: .object(["pinned": .bool(true)])
        ))

        _ = try await store.insertMemory(StoredMemory(
            id: "new-fact", content: "new fact"
        ))

        let ids = Set(try await store.listMemories(status: nil).map(\.id))
        #expect(ids == Set(["ordinary-old", "pinned-old", "new-fact"]))
        #expect(try await store.memory(id: "temporary-old") == nil)
        let events = recorder.events()
        #expect(events.contains(ProjectionHookEvent(
            target: "spotlight", memoryId: "temporary-old", deleted: true
        )))
        #expect(events.contains(ProjectionHookEvent(
            target: "knowledgeGraph", memoryId: "temporary-old", deleted: true
        )))
        let memoryPath = await store.path
        let receiptPath = memoryPath.deletingLastPathComponent()
            .appendingPathComponent("retention_receipts.jsonl")
        #expect(try String(contentsOf: receiptPath, encoding: .utf8)
            .contains("temporary-old"))
    }

    @Test func proposalAcceptanceEnforcesSameHardBound() async throws {
        let store = try MemoryStorage(memoryLimit: 2)
        _ = try await store.insertMemory(StoredMemory(
            id: "pinned", content: "protected",
            metadata: .object(["pinned": .bool(true)])
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "stale", content: "stale", lifecycle: MemoryLifecycle.stale
        ))
        let proposal = StoredProposal(id: "accepted-new", content: "new accepted fact")
        _ = try await store.insertProposal(proposal)

        let accepted = try await store.acceptProposal(id: proposal.id)

        #expect(accepted.id == "accepted-new")
        let ids = Set(try await store.listMemories(status: nil).map(\.id))
        #expect(ids == Set(["pinned", "accepted-new"]))
    }

    @Test func storeOpenRepairsLegacyOverflowAndReplaysProjectionDeletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBoundOpen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try MemoryStorage(dataRoot: root, memoryLimit: 4)
        _ = try await writer.insertMemory(StoredMemory(
            id: "archived", content: "archived", status: "archived"
        ))
        _ = try await writer.insertMemory(StoredMemory(
            id: "stale", content: "stale", lifecycle: MemoryLifecycle.stale
        ))
        _ = try await writer.insertMemory(StoredMemory(
            id: "ordinary", content: "ordinary"
        ))
        _ = try await writer.insertMemory(StoredMemory(
            id: "identity", content: "identity",
            metadata: .object(["kind": .string("identity")])
        ))

        let reopened = try MemoryStorage(dataRoot: root, memoryLimit: 2)
        let recorder = ProjectionHookRecorder()
        await reopened.attachSpotlightHook { memory, deleted in
            recorder.record(target: "spotlight", memory: memory, deleted: deleted)
        }
        await reopened.attachKnowledgeGraphHook { memory, deleted in
            recorder.record(target: "knowledgeGraph", memory: memory, deleted: deleted)
        }

        let ids = Set(try await reopened.listMemories(status: nil).map(\.id))
        #expect(ids == Set(["ordinary", "identity"]))
        let deletedIDs = Set(recorder.events().filter(\.deleted).map(\.memoryId))
        #expect(deletedIDs == Set(["archived", "stale"]))
    }

    @Test func lifecycleExcludedUpdateEmitsProjectionDeleteHooks() async throws {
        let store = try MemoryStorage()
        let recorder = ProjectionHookRecorder()
        await store.attachSpotlightHook { memory, deleted in
            recorder.record(target: "spotlight", memory: memory, deleted: deleted)
        }
        await store.attachKnowledgeGraphHook { memory, deleted in
            recorder.record(target: "knowledgeGraph", memory: memory, deleted: deleted)
        }

        _ = try await store.insertMemory(StoredMemory(
            id: "old-fact",
            content: "the user's old project fact",
            embedding: [1, 0, 0],
            lifecycle: MemoryLifecycle.confirmed
        ))
        _ = try await store.updateMemory(
            id: "old-fact",
            patch: MemoryPatch(lifecycle: MemoryLifecycle.corrected)
        )

        let activeIds = try await store.listMemories(status: "active").map(\.id)
        #expect(activeIds.isEmpty)

        let events = recorder.events()
        #expect(events.contains(ProjectionHookEvent(target: "spotlight", memoryId: "old-fact", deleted: false)))
        #expect(events.contains(ProjectionHookEvent(target: "knowledgeGraph", memoryId: "old-fact", deleted: false)))
        #expect(events.contains(ProjectionHookEvent(target: "spotlight", memoryId: "old-fact", deleted: true)))
        #expect(events.contains(ProjectionHookEvent(target: "knowledgeGraph", memoryId: "old-fact", deleted: true)))
    }

    @Test func asynchronousProjectionHooksPreserveCanonicalMutationOrder() async throws {
        let store = try MemoryStorage()
        let recorder = OrderedProjectionHookRecorder()
        await store.attachSpotlightHook { memory, deleted in
            // Make the older live projection slower than the newer delete. An
            // unsequenced pair of Tasks completes in the wrong order.
            if !deleted {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await recorder.record(memoryID: memory.id, deleted: deleted)
        }

        _ = try await store.insertMemory(StoredMemory(
            id: "ordered-projection",
            content: "a fact that is immediately corrected"
        ))
        _ = try await store.updateMemory(
            id: "ordered-projection",
            patch: MemoryPatch(lifecycle: MemoryLifecycle.corrected)
        )
        await store.flushProjectionHooks()

        #expect(await recorder.events() == [
            ProjectionHookEvent(target: "ordered", memoryId: "ordered-projection", deleted: false),
            ProjectionHookEvent(target: "ordered", memoryId: "ordered-projection", deleted: true),
        ])
    }

    @Test func archiveEmitsProjectionDeleteHooks() async throws {
        let store = try MemoryStorage()
        let recorder = ProjectionHookRecorder()
        await store.attachSpotlightHook { memory, deleted in
            recorder.record(target: "spotlight", memory: memory, deleted: deleted)
        }
        await store.attachKnowledgeGraphHook { memory, deleted in
            recorder.record(target: "knowledgeGraph", memory: memory, deleted: deleted)
        }

        _ = try await store.insertMemory(StoredMemory(
            id: "archive-me",
            content: "low-value fact",
            embedding: [1, 0, 0],
            lifecycle: MemoryLifecycle.confirmed
        ))

        #expect(try await store.archiveIfStillUnused(id: "archive-me") == true)

        let activeIds = try await store.listMemories(status: "active").map(\.id)
        #expect(activeIds.isEmpty)

        let events = recorder.events()
        #expect(events.contains(ProjectionHookEvent(target: "spotlight", memoryId: "archive-me", deleted: false)))
        #expect(events.contains(ProjectionHookEvent(target: "knowledgeGraph", memoryId: "archive-me", deleted: false)))
        #expect(events.contains(ProjectionHookEvent(target: "spotlight", memoryId: "archive-me", deleted: true)))
        #expect(events.contains(ProjectionHookEvent(target: "knowledgeGraph", memoryId: "archive-me", deleted: true)))
    }

    @Test func lifecycleDownranksTemporaryAndInferredBelowConfirmed() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(StoredMemory(
            id: "temporary",
            content: "same recall geometry",
            embedding: [1, 0],
            lifecycle: MemoryLifecycle.temporary
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "inferred",
            content: "same recall geometry",
            embedding: [1, 0],
            lifecycle: MemoryLifecycle.inferred
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "confirmed",
            content: "same recall geometry",
            embedding: [1, 0],
            lifecycle: MemoryLifecycle.confirmed
        ))

        let hits = try await store.recall(embedding: [1, 0], topK: 3)
        #expect(hits.first?.memory.id == "confirmed")
        let confirmedScore = hits.first(where: { $0.memory.id == "confirmed" })?.similarity ?? 0
        let inferredScore = hits.first(where: { $0.memory.id == "inferred" })?.similarity ?? 0
        let temporaryScore = hits.first(where: { $0.memory.id == "temporary" })?.similarity ?? 0
        #expect(confirmedScore > inferredScore)
        #expect(confirmedScore > temporaryScore)
    }

    @Test func recallSkipsExactDuplicateContentAndFillsTopK() async throws {
        let store = try MemoryStorage()
        _ = try await store.insertMemory(StoredMemory(
            id: "dup-a",
            content: "the user likes crisp concise answers",
            embedding: [1, 0]
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "dup-b",
            content: "the user likes   crisp concise answers",
            embedding: [1, 0]
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "unique",
            content: "the user likes direct status reports",
            embedding: [0.9, 0.1]
        ))

        let hits = try await store.recall(embedding: [1, 0], topK: 2)
        #expect(hits.count == 2)
        #expect(hits.map(\.memory.id).contains("unique"))
        #expect(hits.filter { $0.memory.id == "dup-a" || $0.memory.id == "dup-b" }.count == 1)
    }

    @Test func recallKeepsUsefulFactsFromBeingCrowdedOutBySkillHints() async throws {
        let store = try MemoryStorage()
        for index in 1...6 {
            _ = try await store.insertMemory(StoredMemory(
                id: "skill-pointer:\(index)",
                content: "Skill discovery hint \(index)",
                embedding: [1, 0],
                metadata: .object(["kind": .string("skill")])
            ))
        }
        _ = try await store.insertMemory(StoredMemory(
            id: "nativeagent-identity",
            content: "NativeAgent is User's Swift-native living-agent runtime.",
            embedding: [0.99, 0.1],
            metadata: .object(["kind": .string("identity")])
        ))

        let hits = try await store.recall(embedding: [1, 0], topK: 5)
        let ids = hits.map(\.memory.id)

        #expect(hits.count == 5)
        #expect(ids.contains("nativeagent-identity"))
        #expect(ids.contains { $0.hasPrefix("skill-pointer:") })
    }

    @Test func skillHintSlotCapIsAThirdOfTopKNotHalf() async throws {
        // B3 pin (2026-08-28 audit): the crowding test above passes under the
        // old (k+1)/2 formula too, so the k/3 cap needs its own discriminating
        // counts — topK 9 admits 3 hints (old formula admitted 5), topK 3
        // admits 1 (old admitted 2). Hints outscore facts so the cap, not the
        // ranking, is what holds them back.
        let store = try MemoryStorage()
        for index in 1...6 {
            _ = try await store.insertMemory(StoredMemory(
                id: "skill-pointer:\(index)",
                content: "Skill discovery hint \(index)",
                embedding: [1, 0],
                metadata: .object(["kind": .string("skill")])
            ))
        }
        for index in 1...8 {
            _ = try await store.insertMemory(StoredMemory(
                id: "fact-\(index)",
                content: "Ordinary durable fact number \(index)",
                embedding: [0.9, 0.1],
                metadata: .object(["kind": .string("general")])
            ))
        }

        let nine = try await store.recall(embedding: [1, 0], topK: 9)
        #expect(nine.count == 9)
        #expect(nine.map(\.memory.id).filter { $0.hasPrefix("skill-pointer:") }.count == 3)

        let three = try await store.recall(embedding: [1, 0], topK: 3)
        #expect(three.map(\.memory.id).filter { $0.hasPrefix("skill-pointer:") }.count == 1)
    }

    @Test func proposeAcceptLandsInMemories() async throws {
        let store = try MemoryStorage()
        let p = StoredProposal(content: "Agent uses dry sharp voice", source: "dream")
        _ = try await store.insertProposal(p)

        let pending = try await store.listProposals(status: "pending")
        #expect(pending.count == 1)

        let accepted = try await store.acceptProposal(id: p.id)
        #expect(accepted.content == "Agent uses dry sharp voice")
        #expect(accepted.status == "active")

        let memInList = try await store.listMemories()
        #expect(memInList.contains(where: { $0.id == p.id }))

        let stillPending = try await store.listProposals(status: "pending")
        #expect(stillPending.isEmpty)
        let resolved = try await store.listProposals(status: "accepted")
        #expect(resolved.count == 1)
    }

    @Test func acceptProposalStampsConfidenceAndKind() async throws {
        // #1 signal-leak: a proposal carrying the extractor's confidence + kind
        // must promote to a memory that KEEPS them — not hardcoded 1.0 / nil.
        let store = try MemoryStorage()
        let p = StoredProposal(
            content: "user's favorite tea is genmaicha",
            source: "adaptive-promoter:s1",
            metadata: .object(["confidence": .double(0.85), "kind": .string("preference")])
        )
        _ = try await store.insertProposal(p)

        let accepted = try await store.acceptProposal(id: p.id)
        #expect(accepted.confidence == 0.85)
        if case .object(let meta)? = accepted.metadata, case .string(let k)? = meta["kind"] {
            #expect(k == "preference")
        } else {
            Issue.record("accepted memory lost its kind metadata")
        }

        // A proposal with NO confidence metadata still defaults to 1.0 (legacy /
        // consolidator durability path must not break).
        let bare = StoredProposal(content: "plain fact", source: "x")
        _ = try await store.insertProposal(bare)
        let acceptedBare = try await store.acceptProposal(id: bare.id)
        #expect(acceptedBare.confidence == 1.0)

        // String-typed confidence parses (gpt-5.5 finding 2: "0.85" must not
        // silently overtrust to 1.0), and out-of-range values clamp to 0...1.
        let stringConf = StoredProposal(
            content: "string-confidence fact", source: "x",
            metadata: .object(["confidence": .string("0.7")])
        )
        _ = try await store.insertProposal(stringConf)
        #expect(try await store.acceptProposal(id: stringConf.id).confidence == 0.7)

        let overConf = StoredProposal(
            content: "overconfident fact", source: "x",
            metadata: .object(["confidence": .double(7.5)])
        )
        _ = try await store.insertProposal(overConf)
        #expect(try await store.acceptProposal(id: overConf.id).confidence == 1.0)
    }

    /// B6: the ordinary delete path writes tombstones with NO embedding, and
    /// `tombstoneMatch` selects `embedding IS NOT NULL` — so those tombstones
    /// block only their own exact hash and are invisible to the semantic gate.
    /// The backfill fills the missing key; the 0.92 threshold is untouched.
    @Test func tombstoneEmbeddingBackfillMakesLegacyTombstonesVisibleToTheGate() async throws {
        let store = try MemoryStorage()
        let embedder = MockEmbeddingProvider(dimensions: 384)
        let claim = "the user lives in Atlantis"

        // Written the way every real deletion writes it: content, no vector.
        try await store.addTombstone(content: claim, reason: "deleted")
        let vector = try #require(try await embedder.embed([claim]).first)
        #expect(try await store.matchesTombstone(embedding: vector) == false)

        let filled = try await store.backfillTombstoneEmbeddings(using: embedder)
        #expect(filled == 1)
        // Same claim now matches itself (cosine 1.0), far above the threshold.
        #expect(try await store.matchesTombstone(embedding: vector) == true)
        // An unrelated claim still walks in — the gate got sight, not teeth.
        let other = try #require(try await embedder.embed(["the user owns a canoe"]).first)
        #expect(try await store.matchesTombstone(embedding: other) == false)

        // Idempotent: a second pass finds nothing left to fill.
        #expect(try await store.backfillTombstoneEmbeddings(using: embedder) == 0)
        // And it never overwrites an embedding a real write already set.
        #expect(try await store.matchesTombstone(embedding: vector) == true)
    }

    @Test func semanticTombstoneGateBlocksParaphraseAdmitsContradiction() async throws {
        // Wave1 T-lane. Controlled vectors: tombstone at [1,0,0].
        let store = try MemoryStorage()
        try await store.addTombstone(content: "the user likes tea", reason: "deleted", embedding: [1, 0, 0])

        // Near-identical direction (cosine ≈ 0.995) → paraphrase, blocked.
        #expect(try await store.matchesTombstone(embedding: [0.995, 0.1, 0]) == true)
        // Distant direction (cosine ≈ 0.7) → below 0.95, admitted.
        #expect(try await store.matchesTombstone(embedding: [0.7, 0.714, 0]) == false)

        // Legacy tombstone with NO embedding: semantic gate skips it (hash-only).
        try await store.addTombstone(content: "legacy claim", reason: "old")
        #expect(try await store.matchesTombstone(embedding: [0, 1, 0]) == false)

        // acceptProposal gate: a proposal whose embedding paraphrases the
        // tombstone is rejected — and the rejection COMMITS (status persisted,
        // not rolled back by the throw).
        let p = StoredProposal(content: "the user enjoys tea", source: "x", embedding: [0.99, 0.14, 0])
        _ = try await store.insertProposal(p)
        var thrown = false
        do { _ = try await store.acceptProposal(id: p.id) } catch { thrown = true }
        #expect(thrown)
        let rejected = try await store.listProposals(status: "rejected")
        #expect(rejected.contains(where: { $0.id == p.id }))
        let mems = try await store.listMemories()
        #expect(!mems.contains(where: { $0.id == p.id }))
    }

    @Test(arguments: [false, true])
    func proposalAdmissionRechecksExactTombstoneWithoutTombstoneEmbedding(proposalHasEmbedding: Bool) async throws {
        let store = try MemoryStorage()
        let content = "The orchard gate opens at dusk."
        let proposal = StoredProposal(content: content, embedding: proposalHasEmbedding ? [1, 0, 0] : nil)
        _ = try await store.insertProposal(proposal)
        // The earlier caller check passes, then forgetting commits before
        // the canonical acceptance transaction. No sleeps or concurrent race.
        #expect(!(try await store.isTombstoned(content: content)))
        try await store.addTombstone(content: content, reason: "forgotten")
        do {
            _ = try await store.acceptProposal(id: proposal.id)
            Issue.record("exact tombstone must veto canonical admission")
        } catch MemoryStorageError.tombstoned(let id) {
            #expect(id == proposal.id)
        }
        let rejected = try #require(try await store.listProposals(status: "rejected").first { $0.id == proposal.id })
        #expect(rejected.resolvedAt != nil)
        #expect(rejected.rejectionReason == "tombstoned: exact match to a rejected claim")
        #expect(try await store.listMemories().isEmpty)

        let independent = StoredProposal(content: "The orchard fence is painted blue.")
        _ = try await store.insertProposal(independent)
        let accepted = try await store.acceptProposal(id: independent.id)
        #expect(accepted.content == independent.content)
        #expect(try await store.listMemories().map(\.id) == [accepted.id])
    }

    @Test func storeGateFiresThroughProtocolExistential() async throws {
        // gpt-5.5 wave1 finding 1 (Critical): matchesTombstone declared only in
        // a protocol EXTENSION dispatched to the default `false` through
        // `any MemoryStorageProtocol`, leaving store()'s semantic gate inert in
        // production. This test goes through the REAL existential chain
        // (SwiftNativeMemoryV2 → MemoryStorageBridge → MemoryStorage) and must
        // fail if the requirement ever degrades back to extension-only.
        let store = try MemoryStorage()
        let bridge = MemoryStorageBridge(storage: store)
        let embedder = MockEmbeddingProvider()
        let memory = SwiftNativeMemoryV2(embedder: embedder, storage: bridge)

        // Tombstone claim "X" keyed with the EXACT vector the mock will produce
        // for "Y": hashes differ (exact gate passes), semantic match is cosine
        // 1.0 (semantic gate must block) — isolates the semantic path.
        let yVec = try await embedder.embed(["the user enjoys tea"]).first!
        try await store.addTombstone(content: "the user likes tea", reason: "deleted", embedding: yVec)

        var blocked = false
        do {
            _ = try await memory.store(content: "the user enjoys tea", source: "test")
        } catch {
            blocked = String(describing: error).contains("paraphrase")
        }
        #expect(blocked)
    }

    @Test func addTombstonePreservesEmbeddingOnEmbeddinglessRewrite() async throws {
        // The double-write path (rejectProposal writes embedded tombstone, then
        // protocol recordTombstone re-writes the same hash WITHOUT one) must not
        // wipe the semantic key — COALESCE keeps it.
        let store = try MemoryStorage()
        try await store.addTombstone(content: "claim", reason: "first", embedding: [1, 0, 0])
        try await store.addTombstone(content: "claim", reason: "second")  // no embedding
        #expect(try await store.matchesTombstone(embedding: [0.999, 0.04, 0]) == true)
    }

    @Test func proposeRejectLandsInTombstones() async throws {
        let store = try MemoryStorage()
        let p = StoredProposal(content: "the user likes ALL CAPS reports", source: "chat")
        _ = try await store.insertProposal(p)

        let tomb = try await store.rejectProposal(id: p.id, reason: "factually wrong")
        #expect(tomb.reason == "factually wrong")
        #expect(tomb.contentHash == MemoryStorage.contentHash("the user likes ALL CAPS reports"))

        let tombstoned = try await store.isTombstoned(content: "the user likes ALL CAPS reports")
        #expect(tombstoned == true)

        // Whitespace + case normalization
        let normalized = try await store.isTombstoned(content: "  the  user  LIKES   all caps reports  ")
        #expect(normalized == true)

        let untouched = try await store.isTombstoned(content: "the user likes terse reports")
        #expect(untouched == false)
    }

    @Test func sqliteBridgeRejectPreservesReasonAndTombstone() async throws {
        let store = try MemoryStorage()
        let bridge = MemoryStorageBridge(storage: store)
        let proposal = ProposalRecord(
            id: "bridge-reject-1",
            content: "the user lives in Atlantis",
            source: "unit",
            createdAt: MemoryStorage.nowISO8601()
        )
        try await bridge.insertProposal(proposal)

        try await bridge.updateProposalStatus(
            id: proposal.id,
            status: "rejected",
            rejectionReason: "wrong city"
        )

        let rejected = try await bridge.listProposals(status: "rejected")
        #expect(rejected.first?.rejectionReason == "wrong city")
        #expect(try await store.isTombstoned(content: "the user lives in Atlantis") == true)
    }

    @Test func swiftNativeProposalStagesEmbeddingInSQLite() async throws {
        let store = try MemoryStorage()
        let bridge = MemoryStorageBridge(storage: store)
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 384),
            storage: bridge
        )

        let proposal = try await memory.propose(
            content: "the user uses NativeAgent memory on Swift",
            source: "unit"
        )
        let pending = try await store.listProposals(status: "pending")
        let staged = try #require(pending.first { $0.id == proposal.id })

        #expect(staged.embedding?.count == 384)
        #expect(staged.embedding?.allSatisfy { $0.isFinite } == true)
    }

    @Test func recallReturnsTopKByCosine() async throws {
        let store = try MemoryStorage()
        let a = StoredMemory(content: "alpha", embedding: [1, 0, 0, 0])
        let b = StoredMemory(content: "beta",  embedding: [0, 1, 0, 0])
        let c = StoredMemory(content: "gamma", embedding: [0.7, 0.7, 0, 0])
        let d = StoredMemory(content: "delta", embedding: [0, 0, 1, 0])
        _ = try await store.insertMemory(a)
        _ = try await store.insertMemory(b)
        _ = try await store.insertMemory(c)
        _ = try await store.insertMemory(d)

        let query: [Float] = [1, 0, 0, 0]
        let hits = try await store.recall(embedding: query, topK: 3)
        #expect(hits.count == 3)
        #expect(hits[0].memory.id == a.id)
        // c shares an axis with the query → ranks above b which is orthogonal.
        #expect(hits[1].memory.id == c.id)
        // Cosine sim of orthogonal vectors is ~0.
        #expect(abs(hits.last!.similarity) < 1e-5)
        // Top match is exact alignment, cosine ≈ 1.0.
        #expect(hits[0].similarity > 0.999)
    }

    @Test func hybridRecallUsesBM25ToRecoverExactAnchors() async throws {
        let store = try MemoryStorage()
        let query: [Float] = [1, 0, 0, 0]
        _ = try await store.insertMemory(StoredMemory(
            id: "dense-only",
            content: "generic assistant continuity note",
            embedding: [1, 0, 0, 0]
        ))
        _ = try await store.insertMemory(StoredMemory(
            id: "lexical-anchor",
            content: "Agent dream cycle repair plan belongs in Swift memory",
            embedding: [0.92, 0.392, 0, 0]
        ))

        let denseOnly = try await store.recall(embedding: query, topK: 2)
        #expect(denseOnly.first?.memory.id == "dense-only")

        let hybrid = try await store.recall(
            embedding: query,
            queryText: "Agent dream cycle",
            topK: 2
        )
        #expect(hybrid.first?.memory.id == "lexical-anchor")
        #expect((hybrid.first?.similarity ?? 0) > (hybrid.last?.similarity ?? 0))
    }

    @Test func addTombstoneDirectlyAndCheck() async throws {
        let store = try MemoryStorage()
        try await store.addTombstone(content: "stop calling me chief", reason: "name preference")
        #expect(try await store.isTombstoned(content: "Stop Calling Me Chief") == true)
        #expect(try await store.isTombstoned(content: "different content") == false)
    }

    @Test func bridgeRoundTripsPinTagsImportanceKind() async throws {
        // Audit 2026-06-09: the bridge silently amputated pinned/tags/
        // importance/kind in BOTH directions (pinning in the Mac UI was a
        // no-op that still returned ok), and listMemory(kind:) filtered on
        // STATUS == kind, so every real kind returned [].
        let store = try MemoryStorage()
        let bridge = MemoryStorageBridge(storage: store)
        let rec = MemoryRecord(
            id: "round-trip-1",
            text: "the user prefers dry wit",
            memoryKind: "preference",
            createdAt: MemoryStorage.nowISO8601(),
            importance: 0.8,
            tags: ["persona-feedback"]
        )
        _ = try await bridge.insert(record: rec, embedding: nil)

        let listed = try await bridge.listMemory(kind: "preference")
        #expect(listed.count == 1)
        #expect(listed.first?.memoryKind == "preference")
        #expect(listed.first?.tags == ["persona-feedback"])
        #expect(listed.first?.importance == 0.8)
        #expect(try await bridge.listMemory(kind: "no-such-kind").isEmpty)

        // Pin patch (the exact Mac UI shape) must persist, not silently drop.
        let pinned = try await bridge.updateMemory(
            id: "round-trip-1",
            patch: .object(["pinned": .bool(true)]),
            newEmbedding: nil
        )
        #expect(pinned.pinned == true)
        let again = try await bridge.listMemory(kind: "preference")
        #expect(again.first?.pinned == true)
        // ...and the merge must not clobber sibling metadata keys.
        #expect(again.first?.tags == ["persona-feedback"])
    }

    @Test func metadataMergePreservesCanonicalSiblingKeysInsideStorageTransaction() async throws {
        let store = try MemoryStorage()
        let original = StoredMemory(
            id: "metadata-merge-1",
            content: "User prefers concise release notes.",
            metadata: .object([
                "kind": .string("preference"),
                "canonical_owner_note": .string("keep-me"),
            ])
        )
        _ = try await store.insertMemory(original)

        let updated = try #require(try await store.updateMemory(
            id: original.id,
            patch: MemoryPatch(metadataMerge: ["pinned": .bool(true)])
        ))
        guard case .object(let metadata)? = updated.metadata else {
            Issue.record("expected merged metadata object")
            return
        }
        #expect(metadata["pinned"] == .bool(true))
        #expect(metadata["kind"] == .string("preference"))
        #expect(metadata["canonical_owner_note"] == .string("keep-me"))
    }
}

private struct ProjectionHookEvent: Equatable, Sendable {
    var target: String
    var memoryId: String
    var deleted: Bool
}

private final class ProjectionHookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProjectionHookEvent] = []

    func record(target: String, memory: StoredMemory, deleted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(ProjectionHookEvent(target: target, memoryId: memory.id, deleted: deleted))
    }

    func events() -> [ProjectionHookEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor OrderedProjectionHookRecorder {
    private var stored: [ProjectionHookEvent] = []

    func record(memoryID: String, deleted: Bool) {
        stored.append(ProjectionHookEvent(
            target: "ordered",
            memoryId: memoryID,
            deleted: deleted
        ))
    }

    func events() -> [ProjectionHookEvent] { stored }
}
