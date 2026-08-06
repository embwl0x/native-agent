// Swift-native cutover/fix-memory-wiring: process-wide SwiftNativeMemoryV2 instance
// rooted at <dataRoot>/memory/memory.sqlite (the same SQLite store
// MemoryConsolidator / UserMDGenerator / proposal flows write through).
//
// The production chat path used to recall from a SwiftNativeMemoryRecaller
// over <dataRoot>/memory_embeddings.jsonl with MockEmbeddingProvider — a
// different on-disk store than everything else. This file plugs the chat
// path into the same SQLite-backed store every other MemoryV2 caller uses.
//
// MemoryStorage (the SQLite actor) doesn't naturally conform to
// MemoryStorageProtocol — the protocol uses MemoryRecord/ProposalRecord and
// the storage uses StoredMemory/StoredProposal. MemoryStorageBridge wraps
// MemoryStorage and translates the two schemas. The production embedder is a
// managed Swift runtime that lazy-loads CoreML MiniLM and honors Settings'
// on/off + memory-mode files. When CoreML can't load and the user hasn't
// explicitly opted into mock (config backend=mock OR
// NATIVE_AGENT_EMBEDDING_MOCK=1), the runtime fails closed — embed() throws
// instead of silently producing random vectors.

import Foundation
import KnowledgeGraph
import NativeAgentCore
import PersistenceCore

// MARK: - MemoryStorageBridge — MemoryStorage actor → MemoryStorageProtocol

public actor MemoryStorageBridge: HybridMemoryStorageProtocol, KeywordRecallStorageProtocol {
    private let storage: MemoryStorage

    public init(storage: MemoryStorage) {
        self.storage = storage
    }

    public func underlyingStorage() -> MemoryStorage { storage }

    public func listMemory(kind: String?) async throws -> [MemoryRecord] {
        // R13 (review HIGH): status:nil deliberately includes archived rows,
        // but lifecycle-TERMINAL rows (corrected/contradicted/deleted) must
        // never surface through the public list — this path feeds dream
        // context and active re-embedding, and a corrected fact leaking back
        // in defeats the whole correction. memory(id:) stays unfiltered for
        // lineage/admin walks.
        let mems = try await storage.listMemories(persona: nil, status: nil, limit: nil)
            .filter { !MemoryLifecycle.recallExcluded.contains(MemoryLifecycle.normalized($0.lifecycle)) }
        let filtered: [StoredMemory]
        if let kind {
            // Kind lives in metadata_json under "kind" (same convention as
            // kind-scoped decay). This used to filter on STATUS == kind, so
            // every real kind ("preference", "semantic") returned [] —
            // memory looked empty, not broken (audit 2026-06-09).
            filtered = mems.filter { Self.metadataString($0.metadata, "kind") == kind }
        } else {
            filtered = mems
        }
        return filtered.map(Self.toMemoryRecord)
    }

    public func insert(record: MemoryRecord, embedding: [Float]?) async throws -> MemoryRecord {
        try await insert(record: record, embedding: embedding, embeddingEpoch: nil)
    }

    public func insert(
        record: MemoryRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> MemoryRecord {
        // Fold the typed MemoryRecord fields that StoredMemory has no column
        // for into metadata_json so they round-trip (they were silently
        // amputated in transit — pin/tags/importance/kind all lost; audit
        // 2026-06-09). Existing metadata keys win — never overwrite what a
        // caller already stamped.
        var meta: [String: JSONValue]
        if case .object(let m)? = record.extras { meta = m } else { meta = [:] }
        if meta["kind"] == nil, let k = record.memoryKind { meta["kind"] = .string(k) }
        if meta["tags"] == nil, let t = record.tags, !t.isEmpty {
            meta["tags"] = .array(t.map { .string($0) })
        }
        if meta["importance"] == nil, let imp = record.importance { meta["importance"] = .double(imp) }
        if meta["pinned"] == nil, let pin = record.pinned { meta["pinned"] = .bool(pin) }
        let stored = StoredMemory(
            id: record.id,
            content: record.text,
            personaId: record.personaId ?? MemoryV2Defaults.personaID,
            source: record.sourceRunId,
            confidence: record.confidence ?? 1.0,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            embedding: embedding,
            embeddingEpoch: embeddingEpoch?.rawValue,
            status: record.status ?? "active",
            lifecycle: record.lifecycle ?? MemoryLifecycle.confirmed,
            validFrom: record.validFrom,
            validTo: record.validTo,
            observedAt: record.observedAt,
            evidence: record.evidence,
            metadata: meta.isEmpty ? nil : .object(meta)
        )
        let inserted = try await storage.insertMemory(stored)
        return Self.toMemoryRecord(inserted)
    }

    public func updateMemory(id: String, patch: JSONValue, newEmbedding: [Float]?) async throws -> MemoryRecord {
        try await updateMemory(
            id: id,
            patch: patch,
            newEmbedding: newEmbedding,
            embeddingEpoch: nil
        )
    }

    public func updateMemory(
        id: String,
        patch: JSONValue,
        newEmbedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> MemoryRecord {
        var p = MemoryPatch()
        if case .object(let obj) = patch {
            if case .string(let s)? = obj["text"] { p.content = s }
            if case .string(let s)? = obj["content"] { p.content = s }
            if case .string(let s)? = obj["status"] { p.status = s }
            if case .double(let d)? = obj["confidence"] { p.confidence = d }
            if case .int(let i)? = obj["confidence"] { p.confidence = Double(i) }
            if case .string(let value)? = obj["validFrom"] { p.validFrom = value }
            if case .string(let value)? = obj["valid_from"] { p.validFrom = value }
            if case .string(let value)? = obj["validTo"] { p.validTo = value }
            if case .string(let value)? = obj["valid_to"] { p.validTo = value }
            if case .string(let value)? = obj["observedAt"] { p.observedAt = value }
            if case .string(let value)? = obj["observed_at"] { p.observedAt = value }
            if let evidence = obj["evidence"] { p.evidence = evidence }
            // Keys with no typed MemoryPatch slot (the Mac UI pin path sends
            // "pinned") round-trip through metadata_json. This bridge used to
            // DROP them and still return ok — pin was a silent no-op (audit
            // 2026-06-09). patch.metadata replaces wholesale in storage, so
            // merge over the existing record's metadata. "kind" is
            // deliberately NOT passthrough — it's semantics-owned (kind-scoped
            // decay) and no UI path patches it (gpt-5.5 review). KNOWN narrow
            // race: a consolidator metadata write between this read and the
            // storage write loses that write — flagged NEEDS-USER for a
            // storage-transaction merge; pin was 100% broken before this.
            // recall_count added 2026-07-24 (gpt-5.5 BLOCKING): store()'s
            // write-time duplicate guard bumps it as merge-corroboration
            // evidence; without passthrough the bump silently no-oped on
            // production SQLite while the in-memory fixture hid it.
            // source_history / duplicate_occurrences added 2026-08-02 (gpt-5.5
            // review A3): store()'s byte-identical collapse writes the LATER
            // run's provenance here. Without passthrough the second run's
            // identity is dropped on production SQLite exactly the way the
            // recall_count bump was.
            // The allowlist lives in `MemoryPatchContract` so the in-memory
            // fixture cannot drift from it (gpt-5.5 review, 2026-08-02): the
            // fixture used to merge EVERY untyped key, so a test could pass on
            // behaviour this bridge does not have.
            let passthrough = obj.filter {
                MemoryPatchContract.untypedPassthroughKeys.contains($0.key)
            }
            if !passthrough.isEmpty {
                guard let existing = try await storage.memory(id: id) else {
                    throw MemoryV2Error.recordNotFound
                }
                var meta: [String: JSONValue]
                if case .object(let m)? = existing.metadata { meta = m } else { meta = [:] }
                for (k, v) in passthrough { meta[k] = v }
                p.metadata = .object(meta)
            }
        }
        if let newEmbedding {
            p.embedding = newEmbedding
            p.embeddingEpoch = embeddingEpoch?.rawValue
        }
        guard let updated = try await storage.updateMemory(id: id, patch: p) else {
            throw MemoryV2Error.recordNotFound
        }
        return Self.toMemoryRecord(updated)
    }

    public func deleteMemory(id: String) async throws -> Bool {
        try await storage.deleteMemory(id: id)
    }

    /// Bounded, two-column lane enumeration straight from SQLite — overrides
    /// the protocol's list-and-filter default (gpt-5.5 review A4).
    public func memoryHandles(sourcePrefix: String, limit: Int?) async throws -> [MemoryLaneHandle] {
        try await storage.laneHandles(sourcePrefix: sourcePrefix, limit: limit)
    }

    public func recall(embedding: [Float], topK: Int, persona: String?) async throws -> [ScoredMemoryRecord] {
        let hits = try await storage.recall(embedding: embedding, topK: topK, persona: persona)
        return hits.map { ScoredMemoryRecord(record: Self.toMemoryRecord($0.memory), score: $0.similarity) }
    }

    public func recall(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord] {
        let hits = try await storage.recall(
            embedding: embedding,
            embeddingEpoch: embeddingEpoch,
            topK: topK,
            persona: persona
        )
        return hits.map { ScoredMemoryRecord(record: Self.toMemoryRecord($0.memory), score: $0.similarity) }
    }

    public func recall(
        embedding: [Float],
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord] {
        let hits = try await storage.recall(
            embedding: embedding,
            queryText: queryText,
            topK: topK,
            persona: persona
        )
        return hits.map { ScoredMemoryRecord(record: Self.toMemoryRecord($0.memory), score: $0.similarity) }
    }

    public func recall(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord] {
        let hits = try await storage.recall(
            embedding: embedding,
            embeddingEpoch: embeddingEpoch,
            queryText: queryText,
            topK: topK,
            persona: persona
        )
        return hits.map { ScoredMemoryRecord(record: Self.toMemoryRecord($0.memory), score: $0.similarity) }
    }

    /// Sweep R4 A5: lexical-only lane used when no usable query embedding
    /// exists (cold embedder on the first turn after launch).
    public func recallByKeyword(
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord] {
        let hits = try await storage.recallByKeyword(
            queryText: queryText,
            topK: topK,
            persona: persona
        )
        return hits.map { ScoredMemoryRecord(record: Self.toMemoryRecord($0.memory), score: $0.similarity) }
    }

    public func isTombstoned(content: String) async throws -> Bool {
        try await storage.isTombstoned(content: content)
    }

    public func recordTombstone(content: String, reason: String?) async throws {
        try await storage.addTombstone(content: content, reason: reason)
    }

    public func recordRecallHits(ids: [String]) async throws {
        try await storage.recordRecallHits(ids: ids)
    }

    /// R13: mark an existing memory corrected by a newer one (single
    /// transaction, lineage in metadata; corrected rows drop out of recall).
    @discardableResult
    public func markCorrected(id: String, by newerId: String, reason: String? = nil) async throws -> Bool {
        try await storage.markCorrected(id: id, by: newerId, reason: reason)
    }

    public func matchesTombstone(embedding: [Float]) async throws -> Bool {
        try await storage.matchesTombstone(embedding: embedding)
    }

    public func matchesTombstone(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> Bool {
        try await storage.matchesTombstone(
            embedding: embedding,
            embeddingEpoch: embeddingEpoch
        )
    }

    /// U3 wave-2 item 4: raw-cosine top-1 NN for the shadow dedup gate —
    /// overrides the protocol default (which would return recall's
    /// decay-shaped score) with MemoryStorage's genuinely raw sweep.
    /// `excluding` skips the just-inserted row (the shadow observation runs
    /// detached AFTER the insert — fix-round finding 2).
    public func nearestNeighbor(embedding: [Float], excluding excludedId: String?) async throws -> (record: MemoryRecord, cosine: Double)? {
        guard let hit = try await storage.nearestActiveNeighbor(embedding: embedding, excluding: excludedId) else { return nil }
        return (record: Self.toMemoryRecord(hit.memory), cosine: hit.cosine)
    }

    public func nearestNeighbor(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        excluding excludedId: String?
    ) async throws -> (record: MemoryRecord, cosine: Double)? {
        guard let hit = try await storage.nearestActiveNeighbor(
            embedding: embedding,
            embeddingEpoch: embeddingEpoch,
            excluding: excludedId
        ) else { return nil }
        return (record: Self.toMemoryRecord(hit.memory), cosine: hit.cosine)
    }

    public func insertProposal(_ proposal: ProposalRecord, embedding: [Float]? = nil) async throws {
        try await insertProposal(proposal, embedding: embedding, embeddingEpoch: nil)
    }

    public func insertProposal(
        _ proposal: ProposalRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws {
        let stored = StoredProposal(
            id: proposal.id,
            content: proposal.content,
            personaId: MemoryV2Defaults.personaID,
            source: proposal.source,
            stagedAt: proposal.createdAt,
            status: proposal.status,
            resolvedAt: nil,
            rejectionReason: proposal.rejectionReason,
            embedding: embedding,
            embeddingEpoch: embeddingEpoch?.rawValue,
            // Carry the extractor's confidence/kind through to storage so
            // acceptProposal can stamp it on the memory (#1) — was hardcoded nil.
            metadata: proposal.metadata
        )
        _ = try await storage.insertProposal(stored)
    }

    public func getProposal(id: String) async throws -> ProposalRecord? {
        // U5 W-G fix (2026-06-11): by-id SQL lookup instead of a full
        // listProposals(status: nil) scan per call — the auto-accept sweep
        // calls this once per proposal, so the scan made it O(N²).
        guard let p = try await storage.getProposal(id: id) else { return nil }
        return Self.toProposalRecord(p)
    }

    public func acceptProposal(id: String) async throws -> MemoryRecord {
        let accepted = try await storage.acceptProposal(id: id)
        return Self.toMemoryRecord(accepted)
    }

    public func updateProposalStatus(id: String, status: String, rejectionReason: String?) async throws {
        if status == "rejected" {
            _ = try await storage.rejectProposal(id: id, reason: rejectionReason)
            return
        }
        try await storage.markProposalStatus(id: id, status: status, resolvedAt: MemoryStorage.nowISO8601())
    }

    public func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> ProposalRecord {
        guard let updated = try await storage.updateProposalMetadata(id: id, metadata: metadata) else {
            throw MemoryV2Error.recordNotFound
        }
        return Self.toProposalRecord(updated)
    }

    public func listProposals(status: String?) async throws -> [ProposalRecord] {
        let list = try await storage.listProposals(status: status)
        return list.map(Self.toProposalRecord)
    }

    private static func toMemoryRecord(_ s: StoredMemory) -> MemoryRecord {
        // Surface the metadata-carried fields back into the typed slots so
        // the UI/consumers see what was stored (the reverse of insert's fold).
        var kind: String? = nil
        var tags: [String]? = nil
        var importance: Double? = nil
        var pinned: Bool? = nil
        if case .object(let m)? = s.metadata {
            if case .string(let k)? = m["kind"] { kind = k }
            if case .array(let arr)? = m["tags"] {
                let strs = arr.compactMap { v -> String? in
                    if case .string(let t) = v { return t } else { return nil }
                }
                if !strs.isEmpty { tags = strs }
            }
            if case .double(let i)? = m["importance"] { importance = i }
            if case .int(let i)? = m["importance"] { importance = Double(i) }
            if case .bool(let b)? = m["pinned"] { pinned = b }
        }
        return MemoryRecord(
            id: s.id,
            text: s.content,
            layer: "semantic",
            memoryKind: kind,
            personaId: s.personaId,
            lifecycle: s.lifecycle,
            createdAt: s.createdAt,
            updatedAt: s.updatedAt,
            sourceRunId: s.source,
            status: s.status,
            pinned: pinned,
            confidence: s.confidence,
            importance: importance,
            tags: tags,
            validFrom: s.validFrom,
            validTo: s.validTo,
            observedAt: s.observedAt,
            evidence: s.evidence,
            extras: s.metadata
        )
    }

    private static func metadataString(_ metadata: JSONValue?, _ key: String) -> String? {
        guard case .object(let obj)? = metadata, case .string(let v)? = obj[key] else { return nil }
        return v
    }

    private static func toProposalRecord(_ p: StoredProposal) -> ProposalRecord {
        ProposalRecord(
            id: p.id,
            content: p.content,
            source: p.source,
            status: p.status,
            createdAt: p.stagedAt,
            rejectionReason: p.rejectionReason,
            metadata: p.metadata
        )
    }
}

// MARK: - SwiftNativeMemoryV2.shared

extension SwiftNativeMemoryV2 {
    /// R13: mark an existing memory corrected by a newer one. Routes to the
    /// storage protocol requirement (production bridge → single-transaction
    /// lineage write; minimal fixtures honestly report not-applied).
    @discardableResult
    public func markCorrected(id: String, by newerId: String, reason: String? = nil) async throws -> Bool {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let corrected = try await storage.markCorrected(id: id, by: newerId, reason: reason)
        await flushDerivedMemoryChanges()
        return corrected
    }

    /// Process-wide instance rooted at the default data root. Uses the same
    /// SQLite store the rest of MemoryV2 writes through. Uses the
    /// `ManagedEmbeddingProvider` which tries CoreML MiniLM
    /// (bundled minilm.mlpackage) first; if the model fails to load it
    /// **fails closed** (embed() throws) unless the user explicitly opted
    /// into mock vectors via config (`config/embeddings.json::backend = "mock"`)
    /// or the developer-test env var `NATIVE_AGENT_EMBEDDING_MOCK=1`.
    /// Also installs a Spotlight indexing hook on the underlying
    /// MemoryStorage so insert/update/delete/acceptProposal all reflect into
    /// the system index.
    public static let shared: SwiftNativeMemoryV2 = {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let storage: MemoryStorage
        do {
            storage = try MemoryStorage(dataRoot: dataRoot)
        } catch {
            // Fail LOUD, then closed. A migration/open failure here (e.g. busy
            // lock during the v3 column add) must not silently hand back an
            // unwired instance that throws storageUnavailable everywhere with
            // no breadcrumb (gpt-5.5 review finding 4). The unwired fallback
            // preserves the existing fail-closed contract; the log makes it
            // diagnosable.
            NSLog("[MemoryV2] FATAL: MemoryStorage open/migration failed — memory is UNWIRED this session: %@", String(describing: error))
            return SwiftNativeMemoryV2()
        }
        let bridge = MemoryStorageBridge(storage: storage)
        let embedder = ManagedEmbeddingProvider(dataRoot: dataRoot)
        // Spotlight indexing hook: every memory mutation (insert/update/
        // delete/acceptProposal) reflects into the Spotlight index so the
        // system surfaces them. Built lazily to avoid retaining the indexer
        // when CoreSpotlight is unavailable (Linux).
        #if canImport(CoreSpotlight) && !os(Linux)
        let spotClient: any SpotlightIndexClient = SystemSpotlightIndexClient()
        #else
        let spotClient: any SpotlightIndexClient = MockSpotlightIndexClient()
        #endif
        let indexer = SwiftNativeMemoryIndexer(client: spotClient)
        let kgIndexer = try? SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: storage.path)
        Task {
            await storage.attachSpotlightHook { stored, deleted in
                Task {
                    // Skill pointers are recall-only rows (skills-recall
                    // rework 2026-07-03): keep them out of Spotlight.
                    if stored.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) { return }
                    if deleted {
                        try? await indexer.remove(id: stored.id)
                    } else {
                        try? await indexer.indexRecord(id: stored.id, text: stored.content, kind: stored.status)
                    }
                }
            }
            if let kgIndexer {
                await storage.attachKnowledgeGraphHook { stored, deleted in
                    Task {
                        // Recall-only skill pointers never enter the KG —
                        // entity extraction over "Skill available: ..." rows
                        // mints junk entities (gpt-5.5 review HIGH,
                        // 2026-07-03).
                        if stored.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) { return }
                        try? await kgIndexer.indexMemory(
                            KnowledgeGraphMemoryFact(
                                id: stored.id,
                                content: stored.content,
                                source: stored.source,
                                status: stored.status,
                                createdAt: stored.createdAt,
                                updatedAt: stored.updatedAt,
                                metadata: stored.projectionMetadata
                            ),
                            deleted: deleted
                        )
                    }
                }
                // Reconcile the rebuildable projection once from canonical
                // MemoryV2 instead of replaying N independent index calls.
                // This also retracts proven indexer-owned rows whose source
                // memory disappeared before a delete hook completed. Manual
                // and legacy graph content lacks the indexer stamp and is preserved.
                do {
                    _ = try await kgIndexer.rebuildMemoryDerivedGraphFromCanonicalStore()
                } catch {
                    NSLog("[MemoryV2] Knowledge Graph startup rebuild failed: %@", String(describing: error))
                }
            }
        }
        return SwiftNativeMemoryV2(
            embedder: embedder,
            storage: bridge
        )
    }()

    /// Bridge access for callers that need to attach the UserMDGenerator
    /// to the same underlying MemoryStorage instance — write-side hook
    /// callers (insertMemory / acceptProposal) only fire pokeUserMDRegen
    /// on the MemoryStorage that holds the generator reference.
    public func underlyingBridge() -> MemoryStorageBridge? {
        return storage as? MemoryStorageBridge
    }
}

// MARK: - MemoryRecalling adapter

/// MemoryRecalling impl backed by SwiftNativeMemoryV2.shared. Use this in
/// the chat-orchestration factory instead of SwiftNativeMemoryRecaller so
/// recall hits the same SQLite store the rest of MemoryV2 uses.
public struct SwiftNativeMemoryV2Recaller: Sendable {
    private let memory: SwiftNativeMemoryV2
    public init(memory: SwiftNativeMemoryV2 = .shared) {
        self.memory = memory
    }
    public func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        let response = try await memory.recall(MemoryV2RecallRequest(text: query, topK: k, persona: nil))
        return response.hits
    }

    public func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit] {
        let response = try await memory.recall(MemoryV2RecallRequest(
            text: query,
            topK: k,
            persona: persona,
            surface: surface
        ))
        return response.hits
    }
}
