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

public actor MemoryStorageBridge: HybridMemoryStorageProtocol, KeywordRecallStorageProtocol, MemoryRecordLookupStorage, MomentProposalCountingStorage, AtomicProposalStagingStorage, AtomicSupersedingAcceptanceStorage {
    private let storage: MemoryStorage
    /// The SQLite file this bridge fronts; `profile.json` lives beside it.
    public var path: URL { storage.path }

    public init(storage: MemoryStorage) {
        self.storage = storage
    }

    public func underlyingStorage() -> MemoryStorage { storage }

    func lookupMemoryRecord(id: String) async throws -> MemoryRecord? {
        guard let stored = try await storage.memory(id: id) else { return nil }
        return Self.toMemoryRecord(stored)
    }

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
            // 2026-06-09). Storage merges these keys inside the same SQLite
            // transaction as the row update. "kind" is
            // deliberately NOT passthrough — it's semantics-owned (kind-scoped
            // decay) and no UI path patches it (gpt-5.5 review).
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
                p.metadataMerge = passthrough
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
        try await recallReportingKeywordFallback(
            embedding: embedding,
            embeddingEpoch: embeddingEpoch,
            queryText: queryText,
            topK: topK,
            persona: persona
        ).hits
    }

    /// 2026-09-06: carries storage's own "this answer came from the keyword
    /// lane" flag up to the recall wiring, which owns every downstream label.
    public func recallReportingKeywordFallback(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> (hits: [ScoredMemoryRecord], usedKeywordFallback: Bool) {
        let result = try await storage.recallReportingKeywordFallback(
            embedding: embedding,
            embeddingEpoch: embeddingEpoch,
            queryText: queryText,
            topK: topK,
            persona: persona
        )
        return (
            result.hits.map {
                ScoredMemoryRecord(record: Self.toMemoryRecord($0.memory), score: $0.similarity)
            },
            result.usedKeywordFallback
        )
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
    public func removeTombstone(content: String) async throws {
        try await storage.removeTombstone(content: content)
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

    /// User, 2026-09-06: one write lock for match + merge + insert. See
    /// `MemoryStorage.stagePendingProposal`.
    public func stagePendingProposal(
        _ proposal: ProposalRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?,
        insertIfAbsent: Bool,
        foldedKey: @Sendable (String) -> String,
        merge: @Sendable (ProposalRecord) throws -> JSONValue?
    ) async throws -> ProposalRecord? {
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
            metadata: proposal.metadata
        )
        let result = try await storage.stagePendingProposal(
            stored,
            insertIfAbsent: insertIfAbsent,
            foldedKey: foldedKey,
            merge: { try merge(Self.toProposalRecord($0)) }
        )
        return result.map(Self.toProposalRecord)
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

    /// `AtomicSupersedingAcceptanceStorage`: accept + demote in one transaction.
    public func acceptProposal(
        id: String,
        superseding: SupersedingAcceptance
    ) async throws -> MemoryRecord {
        Self.toMemoryRecord(try await storage.acceptProposal(id: id, superseding: superseding))
    }

    public func acceptReviewedMoment(id: String, review: ReviewedMomentAcceptance) async throws -> MemoryRecord {
        Self.toMemoryRecord(try await storage.acceptProposal(id: id, review: review))
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

    /// One scalar out of SQLite instead of every pending row through the
    /// decoder — this runs on the turn path (the moments nudge line).
    public func countMomentProposals(status: String?) async throws -> Int {
        try await storage.countMomentProposals(status: status)
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
            resolvedAt: p.resolvedAt,
            rejectionReason: p.rejectionReason,
            metadata: p.metadata
        )
    }
}

// MARK: - SwiftNativeMemoryV2.shared

extension SwiftNativeMemoryV2 {
    /// True when `dataRoot` names the process-wide production store.
    ///
    /// Keep this comparison in one place. Long-lived app factories used to
    /// spell it several different ways (`==`, `standardizedFileURL`, or no
    /// check at all), which could create a second MemoryV2 actor, SQLite pool,
    /// embedding cache, and projection-hook owner over the live database.
    public static func usesDefaultDataRoot(_ dataRoot: URL) -> Bool {
        canonicalRootIdentity(dataRoot)
            == canonicalRootIdentity(PersistenceCore.defaultDataRoot())
    }

    /// Resolve the MemoryV2 owner for an injected data root without introducing
    /// a process-wide registry.
    ///
    /// The default root always returns ``shared`` so normal app composition has
    /// one actor and one underlying `MemoryStorage`. Alternate roots remain
    /// hermetic and receive a private actor rooted exactly at the injected URL.
    /// Failure to open an alternate store returns the existing unwired,
    /// fail-closed actor; it never borrows the user's live memory.
    public static func resolvedOwner(
        dataRoot: URL,
        alternateRootEmbedder: (any EmbeddingProvider)? = nil
    ) -> SwiftNativeMemoryV2 {
        guard !usesDefaultDataRoot(dataRoot) else { return .shared }
        let root = dataRoot.standardizedFileURL
        guard let storage = try? MemoryStorage(dataRoot: root) else {
            return SwiftNativeMemoryV2()
        }
        return SwiftNativeMemoryV2(
            embedder: alternateRootEmbedder ?? ManagedEmbeddingProvider(dataRoot: root),
            storage: MemoryStorageBridge(storage: storage)
        )
    }

    /// Resolve the concrete storage actor for operations that need canonical
    /// administrative APIs not exposed by `MemoryV2Protocol`. Default-root
    /// callers receive the exact storage beneath ``shared``; alternate roots
    /// open an isolated store. An unavailable shared actor fails closed rather
    /// than quietly constructing a hookless second owner over live memory.
    public static func resolvedStorage(dataRoot: URL) async throws -> MemoryStorage {
        if usesDefaultDataRoot(dataRoot) {
            guard let bridge = await SwiftNativeMemoryV2.shared.underlyingBridge() else {
                throw MemoryV2Error.storageUnavailable
            }
            return await bridge.underlyingStorage()
        }
        return try MemoryStorage(dataRoot: dataRoot.standardizedFileURL)
    }

    /// Build and attach the USER.md projection hook to this actor's exact
    /// underlying storage. The caller gets the generator only after the hook is
    /// installed, so launch cannot regenerate through one SQLite owner and then
    /// attach mutations to another.
    public func bindUserMDGenerator(
        dataRoot: URL,
        personaRoot: URL? = nil,
        debounceInterval: TimeInterval = 30
    ) async -> UserMDGenerator? {
        guard let bridge = storage as? MemoryStorageBridge else { return nil }
        let underlying = await bridge.underlyingStorage()
        let storagePath = underlying.path
        let storageDataRoot = storagePath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard Self.canonicalRootIdentity(storageDataRoot)
            == Self.canonicalRootIdentity(dataRoot) else {
            return nil
        }
        let generator = UserMDGenerator(
            storage: underlying,
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            debounceInterval: debounceInterval
        )
        await underlying.attachUserMDGenerator(generator)
        return generator
    }

    /// Reconcile the rebuildable Knowledge Graph projection from the exact
    /// canonical MemoryV2 database owned by this actor. This is the launch and
    /// post-migration convergence seam; it does not create a second fact owner.
    @discardableResult
    public func reconcileKnowledgeGraphProjection() async throws -> KnowledgeGraphMemoryRebuildReport {
        guard let bridge = storage as? MemoryStorageBridge else {
            throw MemoryV2Error.storageUnavailable
        }
        let underlying = await bridge.underlyingStorage()
        let sqlitePath = underlying.path
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
        return try await indexer.rebuildMemoryDerivedGraphFromCanonicalStore()
    }

    private static func canonicalRootIdentity(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

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
                // Skill pointers are recall-only rows (skills-recall
                // rework 2026-07-03): keep them out of Spotlight.
                if stored.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) { return }
                if deleted {
                    try? await indexer.remove(id: stored.id)
                } else {
                    try? await indexer.indexRecord(id: stored.id, text: stored.content, kind: stored.status)
                }
            }
            if let kgIndexer {
                await storage.attachKnowledgeGraphHook { stored, deleted in
                    // Recall-only skill pointers never enter the KG —
                    // entity extraction over "Skill available: ..." rows
                    // mints junk entities (gpt-5.5 review HIGH,
                    // 2026-07-03).
                    if stored.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) { return }
                    // Settings ▸ "Knowledge graph": off means no graph is
                    // PRODUCED. A delete still reaches the graph, and a write
                    // while off retires the row's node, so a rewritten or
                    // forgotten memory never lingers with old text (reviewer,
                    // 2026-09-05). Read fresh per mutation.
                    let deleted = deleted || !MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot)
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
                // Healthy launches only repair rows missed by a fire-and-forget
                // mutation hook. The migration task owns the one full rebuild
                // when the canonical migration actually runs; starting this
                // additive pass before that boundary would race the importer.
                let migrationMarker = dataRoot
                    .appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent(".migrated_to_sqlite_v2_approved_only")
                // Settings ▸ "Knowledge graph": the startup backfill is graph
                // production too — off means it does not run.
                if MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot),
                   FileManager.default.fileExists(atPath: migrationMarker.path) {
                    do {
                        _ = try await kgIndexer.backfillMissingMemoryIndexRows()
                    } catch {
                        NSLog("[MemoryV2] Knowledge Graph startup backfill failed: %@", String(describing: error))
                    }
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
    /// User, 2026-09-06: retrieves WITHOUT crediting `use_count`. This adapter
    /// feeds the chat turn's legacy recall lane, which then drops rows a REM
    /// pin already states and trims the rest to the prompt's row/character
    /// budget — so crediting here made rows the model never saw look used, and
    /// use_count is the signal that vetoes eviction. The turn engine reports
    /// what it actually delivered through `recordServedContextHits`.
    public func recall(_ query: String, k: Int) async throws -> [MemoryRecallHit] {
        let request = MemoryV2RecallRequest(text: query, topK: k, persona: nil)
        let response = try await memory.recall(request, recordingUsage: false)
        return await annotatedWithRelatedEntities(response, query: request)
    }

    public func recall(
        _ query: String,
        k: Int,
        persona: String?,
        surface: String?
    ) async throws -> [MemoryRecallHit] {
        let request = MemoryV2RecallRequest(
            text: query,
            topK: k,
            persona: persona,
            surface: surface
        )
        // Same contract as the overload above: retrieve, do not credit.
        let response = try await memory.recall(request, recordingUsage: false)
        return await annotatedWithRelatedEntities(response, query: request)
    }

    /// B4 (2026-08-28): attach each hit's one-hop Knowledge Graph entities under
    /// `extras["kg_related"]`, for the prompt renderer to fold into a single
    /// `related:` line.
    ///
    /// ── WHY HERE ─────────────────────────────────────────────────────────────
    /// This adapter is the narrowest place that has both halves: recall has
    /// already applied `MemoryRecordDisclosurePolicy`, and the shared instance
    /// can still reach the SQLite file the graph lives in. The renderer
    /// downstream is a pure `nonisolated static` function with no handles, and
    /// giving it a database would be a far larger change than the feature is
    /// worth.
    ///
    /// ── DISCLOSURE ───────────────────────────────────────────────────────────
    /// The classification is re-asserted here rather than inherited. `hits` is
    /// already disclosure-filtered upstream, so this is belt-and-braces — but it
    /// is the check that makes the privacy argument local and readable: only
    /// memories that classify AND permit this exact surface/persona are used to
    /// seed the graph hop, and each memory's entities were extracted from that
    /// memory's own text. A memory that fails the check contributes no seed and
    /// therefore no entity names.
    ///
    /// ── FAIL-OPEN ────────────────────────────────────────────────────────────
    /// Any failure — no bridge, missing database, unreadable graph — returns the
    /// hits exactly as recall produced them. The `related:` line is an
    /// enrichment; it must never be able to cost a turn its memories.
    private func annotatedWithRelatedEntities(
        _ response: MemoryV2RecallResponse,
        query: MemoryV2RecallRequest
    ) async -> [MemoryRecallHit] {
        // Settings ▸ "Knowledge graph": off means the graph is not USED either
        // — recall gets no one-hop entity enrichment. Read fresh per recall.
        guard MemoryPolicyGate.knowledgeGraphEnabled() else { return response.hits }
        guard !response.hits.isEmpty else { return response.hits }
        let disclosedIDs: Set<String> = Set(
            response.scored.compactMap { scoredRecord in
                guard let classification =
                        MemoryRecordDisclosurePolicy.classify(scoredRecord.record),
                      classification.permits(
                        surface: query.surface, personaID: query.persona
                      ) else { return nil }
                return scoredRecord.record.id
            }
        )
        guard !disclosedIDs.isEmpty else { return response.hits }
        guard let bridge = await memory.underlyingBridge() else { return response.hits }
        let related: [String: [String]]
        do {
            let sqlitePath = await bridge.underlyingStorage().path
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlitePath)
            related = try await indexer.relatedEntityNames(
                forMemoryIDs: Array(disclosedIDs)
            )
        } catch {
            return response.hits
        }
        guard !related.isEmpty else { return response.hits }
        return response.hits.map { hit in
            // Recall stamps the record id into `extras["id"]`; that is the only
            // link back from a hit to the memory it came from.
            guard case .object(var extras)? = hit.extras,
                  case .string(let id)? = extras["id"],
                  disclosedIDs.contains(id),
                  let names = related[id], !names.isEmpty else { return hit }
            var annotated = hit
            extras["kg_related"] = .array(names.map { .string($0) })
            annotated.extras = .object(extras)
            return annotated
        }
    }
}
