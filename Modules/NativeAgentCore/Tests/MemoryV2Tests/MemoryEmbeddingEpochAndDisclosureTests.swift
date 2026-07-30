import Foundation
import MemoryV2
import PersistenceCore
import Testing

@Suite("Memory embedding epoch and disclosure convergence")
struct MemoryEmbeddingEpochAndDisclosureTests {
    private func epoch(
        model: String = "model-a",
        tokenizer: String = "tokenizer-a",
        preprocessing: String = "normalize-a"
    ) -> MemoryEmbeddingEpoch {
        MemoryEmbeddingEpoch(
            backend: "test",
            modelID: model,
            modelArtifactDigest: model,
            tokenizerArtifactDigest: tokenizer,
            preprocessing: preprocessing,
            pooling: "mean",
            normalization: "l2",
            dimensions: 3,
            maximumSequenceLength: 32
        )
    }

    @Test("same dimensions do not imply the same vector space")
    func exactIdentityIncludesArtifactsAndPreprocessing() {
        let baseline = epoch()
        #expect(baseline != epoch(model: "model-b"))
        #expect(baseline != epoch(tokenizer: "tokenizer-b"))
        #expect(baseline != epoch(preprocessing: "normalize-b"))
    }

    @Test("full corpus activates atomically and mismatched queries are ineligible")
    func fullCorpusActivation() async throws {
        let store = try MemoryStorage(inMemoryName: "epoch-activation")
        _ = try await store.insertMemory(StoredMemory(
            id: "memory-a", content: "User likes exact architecture maps.", embedding: [1, 0, 0]
        ))
        _ = try await store.insertProposal(StoredProposal(
            id: "proposal-a", content: "User may prefer short release notes.", embedding: [0, 1, 0]
        ))
        try await store.addTombstone(
            content: "User likes noisy dashboards.", reason: "rejected", embedding: [0, 0, 1]
        )

        let rows = try await store.embeddingCorpusSnapshot()
        let active = epoch()
        let staged = rows.map { row -> MemoryEmbeddingStagedRow in
            let vector: [Float]
            switch row.kind {
            case .memory: vector = [1, 0, 0]
            case .proposal: vector = [0, 1, 0]
            case .tombstone: vector = [0, 0, 1]
            }
            return MemoryEmbeddingStagedRow(row: row, vector: vector)
        }
        let report = try await store.activateEmbeddingEpoch(active, staged: staged)
        #expect(report.memories == 1)
        #expect(report.proposals == 1)
        #expect(report.tombstones == 1)
        #expect(try await store.embeddingEpochState().activeEpoch == active.rawValue)
        #expect(try await store.memory(id: "memory-a")?.embeddingEpoch == active.rawValue)
        #expect(try await store.getProposal(id: "proposal-a")?.embeddingEpoch == active.rawValue)

        let hits = try await store.recall(
            embedding: [1, 0, 0], embeddingEpoch: active, topK: 3
        )
        #expect(hits.map(\.memory.id) == ["memory-a"])
        #expect(try await store.recall(
            embedding: [1, 0, 0], embeddingEpoch: epoch(model: "model-b"), topK: 3
        ).isEmpty)
        #expect(try await store.matchesTombstone(
            embedding: [0, 0, 1], embeddingEpoch: active
        ))
        await #expect(throws: MemoryStorageError.self) {
            try await store.matchesTombstone(
                embedding: [0, 0, 1], embeddingEpoch: self.epoch(model: "model-b")
            )
        }
        await #expect(throws: MemoryStorageError.self) {
            _ = try await store.insertMemory(StoredMemory(
                id: "unlabeled", content: "Must not contaminate active epoch.", embedding: [1, 0, 0]
            ))
        }
    }

    @Test("drift refuses activation and prior vectors remain canonical")
    func driftRefusesActivation() async throws {
        let store = try MemoryStorage(inMemoryName: "epoch-drift")
        _ = try await store.insertMemory(StoredMemory(
            id: "memory-a", content: "Original content", embedding: [1, 0, 0]
        ))
        let snapshot = try await store.embeddingCorpusSnapshot()
        _ = try await store.updateMemory(
            id: "memory-a",
            patch: MemoryPatch(content: "Changed after snapshot")
        )
        await #expect(throws: MemoryStorageError.self) {
            _ = try await store.activateEmbeddingEpoch(
                self.epoch(),
                staged: snapshot.map { MemoryEmbeddingStagedRow(row: $0, vector: [0, 1, 0]) }
            )
        }
        #expect(try await store.embeddingEpochState().activeEpoch == nil)
        #expect(try await store.memory(id: "memory-a")?.embedding == [1, 0, 0])
    }

    @Test("activation retains an exact immediate rollback")
    func rollback() async throws {
        let store = try MemoryStorage(inMemoryName: "epoch-rollback")
        _ = try await store.insertMemory(StoredMemory(
            id: "memory-a", content: "Rollback content", embedding: [1, 0, 0]
        ))
        let snapshot = try await store.embeddingCorpusSnapshot()
        _ = try await store.activateEmbeddingEpoch(
            epoch(),
            staged: snapshot.map { MemoryEmbeddingStagedRow(row: $0, vector: [0, 1, 0]) }
        )
        let rolledBack = try await store.rollbackEmbeddingEpochActivation()
        #expect(rolledBack.activeEpoch == nil)
        #expect(rolledBack.rollbackAvailable == false)
        #expect(try await store.memory(id: "memory-a")?.embedding == [1, 0, 0])
        #expect(try await store.memory(id: "memory-a")?.embeddingEpoch == nil)
    }

    @Test("one disclosure decision handles privacy persona lifecycle and surface aliases")
    func sharedDisclosurePolicy() {
        let privateRecord = MemoryRecord(
            id: "private",
            text: "Private local fact",
            // Record persona ids are AGENT NAMES — the only vocabulary in the
            // live store ("Agent", "NativeAgent"). Never a persona slot id.
            personaId: "ResidentAgent",
            lifecycle: MemoryLifecycle.confirmed,
            createdAt: "2026-07-14T00:00:00Z",
            updatedAt: "2026-07-14T00:00:00Z",
            status: "active"
        )
        let privateDecision = MemoryRecordDisclosurePolicy.classify(privateRecord)
        #expect(privateDecision?.permits(surface: "chat", personaID: "ResidentAgent") == true)
        #expect(privateDecision?.permits(surface: "workshop", personaID: "ResidentAgent") == true)
        #expect(privateDecision?.permittedSurfaces.contains("missions") == true)
        // Telegram is User's authenticated personal surface — local_private
        // includes it (2026-07-20: its absence silently blanked every semantic
        // recall on Telegram). Slack stays outside the local_private fence.
        #expect(privateDecision?.permits(surface: "telegram", personaID: "ResidentAgent") == true)
        #expect(privateDecision?.permits(surface: "slack", personaID: "ResidentAgent") == false)
        // The agent bridges dispatch with surfaces "claude-bridge" /
        // "codex-bridge"; their policy identity is "bridge" (unmapped, they
        // fail-closed every bridge recall).
        #expect(privateDecision?.permits(surface: "claude-bridge", personaID: "ResidentAgent") == true)
        #expect(privateDecision?.permits(surface: "codex-bridge", personaID: "ResidentAgent") == true)
        // An unrecognized surface still fails closed.
        #expect(privateDecision?.permits(surface: "mystery-surface", personaID: "ResidentAgent") == false)
        // Persona half (rewritten 2026-07-24): the old assertions bound ONE
        // literal ("Agent") on both sides, so they proved nothing about the
        // vocabulary the requester actually carries. The requested persona id
        // arrives from memoryRecallPersonaFilter: nil for the resident slot,
        // and a persona SLOT id for every custom persona. Bind the two sides to
        // the MISMATCHED live shapes.
        //
        // The lane EVERY persona slot uses since 2026-07-24: a slot id is
        // presentation-only, so memoryRecallPersonaFilter resolves resident and
        // custom slots alike to nil and an agent-name record discloses.
        #expect(privateDecision?.permits(surface: "chat", personaID: nil) == true)
        // A slot id arriving here unmapped is structurally unmatchable against
        // an agent name. Production no longer produces this, but THIS layer —
        // per-record disclosure — is where genuine compartmentalization would
        // live if it is ever wanted, so its persona semantics stay pinned.
        #expect(privateDecision?.permits(surface: "chat", personaID: "CustomPersona") == false)
        // The default persona SLOT id, spelled out. PersonaEngine resolves
        // "canonical" when no custom persona is active; MemoryV2 cannot import
        // Context, so the literal is pinned here and by the ChatOrchestration
        // conformance test (personaEngineDefaultPersonaIdMatchesContextResident).
        // If this ever reaches MemoryV2 unmapped, every recall zero-hits.
        #expect(privateDecision?.permits(surface: "chat", personaID: "canonical") == false)
        // A different agent name is still a different persona.
        #expect(privateDecision?.permits(surface: "chat", personaID: "NativeAgent") == false)

        var publicRecord = privateRecord
        publicRecord.tags = ["privacy:public_safe"]
        #expect(MemoryRecordDisclosurePolicy.classify(publicRecord)?
            .permits(surface: "telegram", personaID: "ResidentAgent") == true)

        var corrected = privateRecord
        corrected.lifecycle = MemoryLifecycle.corrected
        #expect(MemoryRecordDisclosurePolicy.classify(corrected) == nil)
    }

    @Test("temporal validity and evidence are canonical, nullable, and validated")
    func temporalEvidence() async throws {
        let store = try MemoryStorage(inMemoryName: "temporal-evidence")
        let inserted = StoredMemory(
            id: "temporal",
            content: "User worked on Atlas during the spring release.",
            validFrom: "2026-03-01T00:00:00Z",
            validTo: "2026-05-31T23:59:59Z",
            observedAt: "2026-06-01T12:00:00Z",
            evidence: .object([
                "kind": .string("session_receipt"),
                "id": .string("session-42"),
            ])
        )
        _ = try await store.insertMemory(inserted)
        let read = try #require(try await store.memory(id: "temporal"))
        #expect(read.validFrom == inserted.validFrom)
        #expect(read.validTo == inserted.validTo)
        #expect(read.observedAt == inserted.observedAt)
        #expect(read.evidence == inserted.evidence)
        guard case .object(let projected)? = read.projectionMetadata else {
            Issue.record("projection metadata missing")
            return
        }
        #expect(projected["valid_from"] == .string("2026-03-01T00:00:00Z"))
        #expect(projected["evidence"] == inserted.evidence)

        await #expect(throws: MemoryStorageError.self) {
            _ = try await store.insertMemory(StoredMemory(
                id: "invalid-time",
                content: "Invalid interval",
                validFrom: "2026-07-02T00:00:00Z",
                validTo: "2026-07-01T00:00:00Z"
            ))
        }
    }
}
