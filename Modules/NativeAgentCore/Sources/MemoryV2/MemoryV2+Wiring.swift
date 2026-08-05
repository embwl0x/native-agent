import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Phase B wiring: storage + embedder + proposal lifecycle
//
// `MemoryV2.swift` keeps the legacy `MemoryV2Protocol` (listMemory/recallMemory/
// updateMemory/deleteMemory/v2Status) that the daemon-cutover tests pin. This
// file adds the Phase B surface the brief specifies — `recall(query:)`,
// `store(content:source:metadata:)`, the proposal lifecycle, and tombstone
// checks — composed against an `EmbeddingProvider` and a `MemoryStorageProtocol`.
//
// `MemoryStorageProtocol` is the seam sister worker m1's `MemoryStorage` actor
// (in `MemoryV2+Storage.swift`) conforms to. We define it here so this file
// compiles standalone; the integration round either keeps this protocol and
// adapts m1's actor to it, or replaces it with m1's concrete shape — either
// way the actor methods below stay valid.

// MARK: - Request / response types

public struct MemoryV2RecallRequest: Sendable, Codable, Equatable {
    public var text: String
    public var topK: Int
    public var persona: String?
    public var surface: String?

    public init(
        text: String,
        topK: Int = 10,
        persona: String? = nil,
        surface: String? = nil
    ) {
        self.text = text
        self.topK = topK
        self.persona = persona
        self.surface = surface
    }
}

public struct ScoredMemoryRecord: Sendable, Equatable {
    public var record: MemoryRecord
    public var score: Double
    public init(record: MemoryRecord, score: Double) {
        self.record = record
        self.score = score
    }
}

public struct MemoryV2RecallResponse: Sendable, Equatable {
    public var hits: [MemoryRecallHit]
    public var scored: [ScoredMemoryRecord]
    public var total: Int
    public var disclosureFilteredCount: Int
    public init(
        hits: [MemoryRecallHit],
        scored: [ScoredMemoryRecord],
        total: Int,
        disclosureFilteredCount: Int = 0
    ) {
        self.hits = hits
        self.scored = scored
        self.total = total
        self.disclosureFilteredCount = disclosureFilteredCount
    }
}

// MARK: - ProposalRecord (memory promotion lifecycle)

public struct ProposalRecord: Sendable, Codable, Equatable {
    public var id: String
    public var content: String
    public var source: String?
    /// "pending" | "accepted" | "rejected".
    public var status: String
    public var createdAt: String
    public var rejectionReason: String?
    /// Carries the extractor's per-fact signal (confidence, kind) from staging
    /// through promotion so `acceptProposal` can stamp it on the memory instead
    /// of discarding it. Previously dropped at the bridge → every memory landed
    /// at confidence 1.0 / kind nil (#1 signal-leak).
    public var metadata: JSONValue?

    public init(
        id: String,
        content: String,
        source: String? = nil,
        status: String = "pending",
        createdAt: String,
        rejectionReason: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.rejectionReason = rejectionReason
        self.metadata = metadata
    }
}

// MARK: - Patch contract (fixture and SQLite must agree)

/// THE ONE PLACE that says which untyped patch keys a storage backend keeps.
///
/// WHY IT IS A SHARED CONSTANT (gpt-5.5 review, 2026-08-02): the SQLite bridge
/// (`MemoryStorageBridge.updateMemory`) merged an ALLOWLIST of untyped keys into
/// `metadata_json` and dropped the rest, while the in-memory fixture
/// (`InMemoryMemoryStorage.updateMemory`) merged EVERY untyped key into
/// `extras`. So `patch(["foo": "bar"])` persisted in every test and was silently
/// dropped in production — a test could pass against behaviour production does
/// not have. That is the same defect class as the `recall_count` bug this
/// allowlist was grown to fix, one layer up.
///
/// The SQLite side is the contract: a patch key that reaches `metadata_json` is
/// a key some caller can later read back, and an open merge lets any caller
/// mint arbitrary metadata (including keys the semantics layer owns). Adding a
/// key here is a deliberate act — do it once, and both backends change together.
public enum MemoryPatchContract {
    /// Untyped keys that round-trip through metadata on BOTH backends.
    ///
    /// `pinned` — the Mac UI pin path (audit 2026-06-09; pin was a silent no-op).
    /// `tags` / `importance` — surfaced back into typed slots by `toMemoryRecord`.
    /// `recall_count` — `store()`'s duplicate guard bumps it (2026-07-24).
    /// `source_history` / `duplicate_occurrences` — byte-identical collapse
    /// provenance (2026-08-02).
    ///
    /// `kind` is deliberately ABSENT: it is semantics-owned (kind-scoped decay)
    /// and no UI path patches it.
    public static let untypedPassthroughKeys: Set<String> = [
        "pinned", "tags", "importance", "recall_count",
        "source_history", "duplicate_occurrences",
    ]
}

// MARK: - MemoryStorageProtocol (the m1 seam)

public protocol MemoryStorageProtocol: Sendable {
    func listMemory(kind: String?) async throws -> [MemoryRecord]
    func insert(record: MemoryRecord, embedding: [Float]?) async throws -> MemoryRecord
    func insert(
        record: MemoryRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> MemoryRecord
    func updateMemory(id: String, patch: JSONValue, newEmbedding: [Float]?) async throws -> MemoryRecord
    func updateMemory(
        id: String,
        patch: JSONValue,
        newEmbedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> MemoryRecord
    func deleteMemory(id: String) async throws -> Bool

    /// Newest-first identity handles for one writing lane's own rows (matched
    /// by `source` prefix), ACTIVE only, bounded by `limit`. A REQUIREMENT with
    /// a default implementation in `MemoryV2+LaneRetention` for the same
    /// existential-dispatch reason as `matchesTombstone` below: extension-only,
    /// the SQLite bridge's bounded query would never win over the fixture
    /// default when reached through `any MemoryStorageProtocol`.
    func memoryHandles(sourcePrefix: String, limit: Int?) async throws -> [MemoryLaneHandle]

    /// Dense-vector recall over the embeddings table. Returns the matching
    /// `MemoryRecord`s alongside their cosine score (higher = better).
    /// `persona` is forwarded to the storage layer so per-persona partitions
    /// stay isolated; nil means "across all personas".
    func recall(embedding: [Float], topK: Int, persona: String?) async throws -> [ScoredMemoryRecord]
    func recall(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord]

    /// Tombstone API used by the rejection-denylist hygiene path
    /// (see `nativeagent-memory-promotion`). `isTombstoned` is consulted on
    /// every `store(...)` so an accepted-then-reverted fact can't sneak back in.
    func isTombstoned(content: String) async throws -> Bool
    func recordTombstone(content: String, reason: String?) async throws

    /// Bump the access counter (`use_count`) + `last_used_at` for memories just
    /// returned by recall. Called fire-and-forget AFTER recall returns, so it
    /// adds nothing to read latency. Default no-op for storages that don't track
    /// access (e.g. minimal test fixtures).
    func recordRecallHits(ids: [String]) async throws

    /// Semantic tombstone gate: does this embedding paraphrase a tombstoned
    /// claim? MUST be a protocol REQUIREMENT (not extension-only) — existential
    /// dispatch through `any MemoryStorageProtocol` otherwise always hits the
    /// default `false` and the store() gate goes inert (gpt-5.5 wave1 finding 1).
    func matchesTombstone(embedding: [Float]) async throws -> Bool
    func matchesTombstone(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> Bool

    /// U3 wave-2 item 4: top-1 nearest ACTIVE neighbor by RAW cosine — no
    /// decay/rank shaping — for the WRITE-path shadow dedup gate. A protocol
    /// REQUIREMENT for the same existential-dispatch reason as
    /// `matchesTombstone` above: the bridge's raw-cosine implementation must
    /// win over the extension default. The default (below) derives from
    /// `recall(embedding:topK:)`, which is exact for fixtures whose recall
    /// is a plain cosine sweep (e.g. `InMemoryMemoryStorage`).
    /// `excluding` skips one row id: the shadow observation now runs AFTER
    /// the insert (detached — fix-round finding 2), so the scan must not
    /// pair the just-inserted row with itself.
    func nearestNeighbor(embedding: [Float], excluding excludedId: String?) async throws -> (record: MemoryRecord, cosine: Double)?
    func nearestNeighbor(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        excluding excludedId: String?
    ) async throws -> (record: MemoryRecord, cosine: Double)?

    /// R13: mark `id` corrected by `newerId` — lifecycle → 'corrected'
    /// (recall-excluded) with queryable lineage, in one transaction. A
    /// protocol REQUIREMENT for the same existential-dispatch reason as
    /// `matchesTombstone`; the extension default returns false (honest
    /// not-applied, surfaced in the tool envelope) for minimal fixtures
    /// without lifecycle support.
    @discardableResult
    func markCorrected(id: String, by newerId: String, reason: String?) async throws -> Bool

    // Proposal lifecycle (staging area before USER.md promotion).
    func insertProposal(_ proposal: ProposalRecord, embedding: [Float]?) async throws
    func insertProposal(
        _ proposal: ProposalRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws
    func getProposal(id: String) async throws -> ProposalRecord?
    func acceptProposal(id: String) async throws -> MemoryRecord
    func updateProposalStatus(id: String, status: String, rejectionReason: String?) async throws
    /// 2026-07-21 audit fix: metadata merge target for propose()'s
    /// pending-proposal content-hash dedup. Pending-only semantics — a
    /// resolved proposal must never have its metadata rewritten.
    func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> ProposalRecord
    func listProposals(status: String?) async throws -> [ProposalRecord]
}

/// Optional storage capability for hybrid memory retrieval. Kept separate from
/// `MemoryStorageProtocol` so lightweight fixtures and older storage seams can
/// keep dense-only recall while the production SQLite store can blend the raw
/// query text with embedding similarity.
public protocol HybridMemoryStorageProtocol: MemoryStorageProtocol {
    func recall(
        embedding: [Float],
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord]
    func recall(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord]
}

public extension MemoryStorageProtocol {
    func insert(
        record: MemoryRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> MemoryRecord {
        try await insert(record: record, embedding: embedding)
    }

    func updateMemory(
        id: String,
        patch: JSONValue,
        newEmbedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> MemoryRecord {
        try await updateMemory(id: id, patch: patch, newEmbedding: newEmbedding)
    }

    func recall(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord] {
        try await recall(embedding: embedding, topK: topK, persona: persona)
    }

    func matchesTombstone(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws -> Bool {
        try await matchesTombstone(embedding: embedding)
    }

    func nearestNeighbor(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        excluding excludedId: String?
    ) async throws -> (record: MemoryRecord, cosine: Double)? {
        try await nearestNeighbor(embedding: embedding, excluding: excludedId)
    }

    func insertProposal(
        _ proposal: ProposalRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?
    ) async throws {
        try await insertProposal(proposal, embedding: embedding)
    }

    func insertProposal(_ proposal: ProposalRecord) async throws {
        try await insertProposal(proposal, embedding: nil)
    }

    /// Default: storages that don't track access ignore the bump.
    func recordRecallHits(ids: [String]) async throws {}

    /// Default: fixtures without lifecycle support report not-applied.
    @discardableResult
    func markCorrected(id: String, by newerId: String, reason: String?) async throws -> Bool { false }

    /// Default: storages without semantic tombstones never match (hash gate
    /// still applies via isTombstoned).
    func matchesTombstone(embedding: [Float]) async throws -> Bool { false }

    /// Default top-1 NN via the storage's own recall. NOTE: only raw-cosine
    /// for storages whose recall applies no rank shaping (true of the test
    /// fixtures); `MemoryStorageBridge` overrides with a genuinely raw sweep.
    /// With an exclusion, fetch top-2 so the survivor after filtering is
    /// still the true nearest non-excluded row.
    func nearestNeighbor(embedding: [Float], excluding excludedId: String?) async throws -> (record: MemoryRecord, cosine: Double)? {
        let topK = excludedId == nil ? 1 : 2
        let hits = try await recall(embedding: embedding, topK: topK, persona: nil)
        guard let top = hits.first(where: { $0.record.id != excludedId }) else {
            return nil
        }
        return (record: top.record, cosine: top.score)
    }
}

public extension HybridMemoryStorageProtocol {
    func recall(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord] {
        try await recall(
            embedding: embedding,
            queryText: queryText,
            topK: topK,
            persona: persona
        )
    }
}

// MARK: - SwiftNativeMemoryV2 — Phase B method surface

extension SwiftNativeMemoryV2 {

    /// Access-signal bump for records served OUTSIDE the recall lane (the
    /// fluid-context serve path, task #42). Same storage write as recall's
    /// fire-and-forget bump; unwired actors fail closed like every other
    /// storage-backed method.
    public func recordRecallHits(ids: [String]) async throws {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        try await storage.recordRecallHits(ids: ids)
    }

    /// Embed the query via the wired `EmbeddingProvider` (MiniLM on the Neural
    /// Engine in production), then ask `MemoryStorage` for the top-K nearest
    /// records by cosine. Hits are sorted by score descending; `total` reflects
    /// how many records the storage layer returned (≤ topK).
    public func recall(_ query: MemoryV2RecallRequest) async throws -> MemoryV2RecallResponse {
        guard !query.text.isEmpty else { throw MemoryV2Error.invalidQuery }
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let queryEmbedding = try await embedOneWithEpoch(query.text)
        let qvec = queryEmbedding.vector
        let topK = max(1, query.topK)
        // Disclosure filtering happens before results leave MemoryV2. Fetch a
        // bounded wider candidate window so private/disallowed high scorers do
        // not crowd authorized records out of the caller's requested top-K.
        // The SQLite path already scans/sorts the same bounded canonical set;
        // this only retains more rows from that existing pass.
        let storageTopK = (query.surface != nil || query.persona != nil)
            ? min(memoryStoredRowCap, max(topK, topK * 8))
            : topK
        let scored: [ScoredMemoryRecord]
        if let hybrid = storage as? any HybridMemoryStorageProtocol {
            scored = try await hybrid.recall(
                embedding: qvec,
                embeddingEpoch: queryEmbedding.epoch,
                queryText: query.text,
                topK: storageTopK,
                persona: query.persona
            )
        } else {
            scored = try await storage.recall(
                embedding: qvec,
                embeddingEpoch: queryEmbedding.epoch,
                topK: storageTopK,
                persona: query.persona
            )
        }
        let disclosed = scored.filter { scoredRecord in
            guard let classification = MemoryRecordDisclosurePolicy.classify(scoredRecord.record) else {
                return false
            }
            return classification.permits(surface: query.surface, personaID: query.persona)
        }
        let sorted = Array(disclosed.sorted { $0.score > $1.score }.prefix(topK))
        // Dead-lane alarm (2026-07-24): `persona` is an exact-equality filter
        // over RECORD persona ids (configured agent names). A
        // caller that hands it a persona SLOT id can never match a row, so the
        // whole recall lane silently returns nothing. Only fires on the zero-hit
        // path, at most once per (persona, surface), and only after proving the
        // persona filter — not disclosure, not an empty store — is to blame.
        if query.persona != nil, sorted.isEmpty {
            await reportPersonaRecallStarvation(
                query: query,
                personaFilteredCandidateCount: scored.count,
                embedding: qvec,
                epoch: queryEmbedding.epoch,
                storage: storage
            )
        }
        // Fire-and-forget access bump: record that these memories were used,
        // AFTER we've computed the answer, WITHOUT awaiting — so recall's read
        // latency is unchanged (Agent's zero-read-cost constraint). This is the
        // signal that stops archiveStale from evicting hot-but-never-merged
        // memories as "unused" (#0).
        let usedIds = sorted.map { $0.record.id }
        if !usedIds.isEmpty {
            let storageRef = storage
            Task {
                do {
                    try await storageRef.recordRecallHits(ids: usedIds)
                } catch {
                    // Don't swallow silently: use_count is eviction-protective
                    // (gpt-5.5 review finding 3). A dropped bump self-heals on
                    // any later recall within the 365d window, so logging (not
                    // retry machinery) is the proportionate response here.
                    FileHandle.standardError.write(
                        Data("MemoryV2: recall-hit bump failed for \(usedIds.count) ids: \(error)\n".utf8)
                    )
                }
            }
        }
        // U3 wave-1 item 1: carry the FULL text (sentence-safe capped) on
        // every hit — the 200-char preview was the felt truncation. Pure
        // output shaping on rows already selected: ranking and row set are
        // untouched, and no extra storage round-trip happens (zero added
        // read latency).
        let hits: [MemoryRecallHit] = sorted.map { sr in
            let displayText = MemoryTextClip.memoryDisplayText(
                sr.record.text,
                kind: sr.record.memoryKind
            )
            return MemoryRecallHit(
                score: sr.score,
                sessionId: sr.record.sourceRunId,
                role: nil,
                ts: sr.record.createdAt,
                preview: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallPreviewCap),
                content: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallContentCap),
                source: "swift-native",
                rankingSignals: nil,
                extras: .object(["id": .string(sr.record.id)])
            )
        }
        return MemoryV2RecallResponse(
            hits: hits,
            scored: sorted,
            total: sorted.count,
            disclosureFilteredCount: scored.count - disclosed.count
        )
    }

    /// Zero-hit path: decide whether the PERSONA FILTER specifically emptied
    /// this recall, and say so at most once per (persona, surface).
    ///
    /// The original probe only proved "the unfiltered store has a candidate",
    /// which is true in two perfectly healthy situations and made the alarm a
    /// wolf-cry. Both are now ruled out before anything is logged:
    ///
    ///   1. SURFACE DISCLOSURE emptied the recall. `scored` is the
    ///      persona-filtered, pre-disclosure candidate set. If it is NON-empty
    ///      the persona filter matched rows just fine and disclosure dropped
    ///      them — a different subsystem, and not a dead lane. Stay quiet.
    ///   2. NOTHING DISCLOSABLE exists anyway. The unfiltered probe is run
    ///      through the SAME `MemoryRecordDisclosurePolicy` gate as the real
    ///      recall. If no probe row would have been disclosable to this
    ///      surface/persona, the persona filter cost the caller nothing.
    ///
    /// What survives both gates is provable: rows exist, they are disclosable
    /// here, and the persona filter matched none of them. That is the claim the
    /// message now makes — it names the record persona ids it actually saw and
    /// offers the slot-id diagnosis as the leading explanation rather than
    /// asserting it. (A brand-new agent-name persona with no rows yet is
    /// observationally identical inside one recall; the once-per-signature memo
    /// keeps that case to a single line instead of a per-call stream.)
    private func reportPersonaRecallStarvation(
        query: MemoryV2RecallRequest,
        personaFilteredCandidateCount: Int,
        embedding: [Float],
        epoch: MemoryEmbeddingEpoch?,
        storage: any MemoryStorageProtocol
    ) async {
        guard let persona = query.persona else { return }
        // Gate 1 — the persona filter DID match rows; disclosure emptied the
        // result. Not this diagnostic's business.
        guard personaFilteredCandidateCount == 0 else { return }
        // Bound: a tool loop repeating the same starving recall used to print an
        // error on every call. Same shape as
        // ContextFlowCoordinator.PrecoverageFailureReporter — one line per
        // distinct signature, not one per turn.
        //
        // HONEST SCOPE (gpt-5.5 review 2026-07-24 LOW): this bounds the LOG, and
        // it bounds the probe only once a signature has actually REPORTED — the
        // insert happens after a disclosable probe row is found. A repeat recall
        // whose probe keeps finding nothing disclosable (e.g. wrong-vocabulary
        // persona on a surface with no permitted rows) stays correctly silent but
        // re-pays the probe each call. Left as-is deliberately: post-2026-07-24
        // policy `memoryRecallPersonaFilter` always returns nil, so reaching here
        // at all requires a caller that bypasses the helper with a non-nil
        // persona — rare enough that memoizing a never-reported signature would
        // trade a real diagnostic for an imaginary saving.
        let signature = "\(persona)|\(query.surface ?? "nil")"
        guard !reportedStarvationSignatures.contains(signature) else { return }

        let probe: [ScoredMemoryRecord]
        do {
            if let hybrid = storage as? any HybridMemoryStorageProtocol {
                probe = try await hybrid.recall(
                    embedding: embedding,
                    embeddingEpoch: epoch,
                    queryText: query.text,
                    topK: personaStarvationProbeTopK,
                    persona: nil
                )
            } else {
                probe = try await storage.recall(
                    embedding: embedding,
                    embeddingEpoch: epoch,
                    topK: personaStarvationProbeTopK,
                    persona: nil
                )
            }
        } catch {
            return
        }
        // Gate 2 — the same disclosure gate the real recall applies, asked with
        // `personaID: nil` on purpose. `permits` enforces persona equality
        // ITSELF, so passing the queried persona here would fold the very cause
        // we are trying to isolate back into the test and make the alarm
        // unreachable. Nil asks the one question that is left: would SURFACE
        // disclosure have released this row?
        let disclosable = probe.filter { scoredRecord in
            guard let classification = MemoryRecordDisclosurePolicy.classify(scoredRecord.record) else {
                return false
            }
            return classification.permits(surface: query.surface, personaID: nil)
        }
        guard !disclosable.isEmpty else { return }

        let observedPersonaIDs = Set(disclosable.map { $0.record.personaId ?? "nil" }).sorted()
        reportedStarvationSignatures.insert(signature)
        emitDiagnostic(
            "[memory-v2] ERROR persona recall starvation: persona filter "
            + "\"\(persona)\" (surface \(query.surface ?? "nil")) matched 0 records while "
            + "\(disclosable.count) disclosable row(s) sit in the store under persona id(s) "
            + "[\(observedPersonaIDs.joined(separator: ", "))]. Disclosure is not the cause — "
            + "the persona filter is. Record persona ids are agent names; if \"\(persona)\" is "
            + "a persona SLOT id, this lane can never fill."
        )
    }

    // MARK: - Byte-identical collapse: keep the collapse, keep BOTH identities

    /// How many occurrences of one collapsed memory keep their provenance.
    /// Bounded because a lane that repeats forever must not grow one row's
    /// metadata forever; the oldest occurrences fall off, `recall_count` keeps
    /// counting past the cap.
    static let duplicateProvenanceCap = 10

    /// Metadata keys that are POLICY or shape, not the identity of a
    /// particular occurrence. Merging these would just restate the row.
    static let duplicateProvenanceIgnoredKeys: Set<String> = [
        "kind", "permittedSurfaces", "tags", "recall_count", "confidence",
        "importance", "pinned", "source_history", "duplicate_occurrences",
    ]

    /// What to patch onto an existing row when a byte-identical write lands, so
    /// the repeat is traceable to BOTH runs (gpt-5.5 review A3).
    ///
    /// Pure, and deliberately generic: it merges whatever scalar metadata the
    /// new write carries that the row does not already say, plus the new
    /// source, plus the newer observation time. Nothing here knows about
    /// Workshop — an execution's `workshop_execution_id` / `workshop_status` are
    /// just the first caller's identity fields.
    static func duplicateProvenancePatch(
        existing: MemoryRecord,
        newSource: String?,
        newMetadata: JSONValue?
    ) -> [String: JSONValue] {
        func scalar(_ value: JSONValue) -> JSONValue? {
            switch value {
            case .string(let s): return .string(String(s.prefix(200)))
            case .int, .double, .bool: return value
            default: return nil
            }
        }
        var extras: [String: JSONValue] = [:]
        if case .object(let m)? = existing.extras { extras = m }
        var newMeta: [String: JSONValue] = [:]
        if case .object(let m)? = newMetadata { newMeta = m }
        let source = (newSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var out: [String: JSONValue] = [:]

        // 1. Source lineage — every distinct writer of this text, oldest first,
        //    seeded from the row's own `source` so run #1 is never implied away.
        var sources: [String] = []
        if case .array(let arr)? = extras["source_history"] {
            sources = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        if sources.isEmpty, let first = existing.sourceRunId, !first.isEmpty {
            sources = [first]
        }
        if !source.isEmpty, !sources.contains(source) {
            sources.append(source)
        }
        if sources.count > duplicateProvenanceCap {
            sources = Array(sources.suffix(duplicateProvenanceCap))
        }
        if !sources.isEmpty {
            out["source_history"] = .array(sources.map { .string($0) })
        }

        // 2. This occurrence's identity: the scalar metadata it carries that the
        //    row does not already say, plus its source.
        var identity: [String: JSONValue] = [:]
        for (key, value) in newMeta where !duplicateProvenanceIgnoredKeys.contains(key) {
            guard let value = scalar(value) else { continue }
            if extras[key] == value { continue }
            identity[key] = value
        }
        if !source.isEmpty { identity["source"] = .string(source) }
        if !identity.isEmpty {
            var occurrences: [JSONValue] = []
            if case .array(let arr)? = extras["duplicate_occurrences"] { occurrences = arr }
            let entry = JSONValue.object(identity)
            // A literal re-write of the SAME occurrence (same ids, same times)
            // is a retry, not a second run — count it, don't list it twice.
            if occurrences.last != entry {
                occurrences.append(entry)
                if occurrences.count > duplicateProvenanceCap {
                    occurrences = Array(occurrences.suffix(duplicateProvenanceCap))
                }
                out["duplicate_occurrences"] = .array(occurrences)
            }
        }

        // 3. Observation time: the newest occurrence is when this was last true.
        //    First-class column (the bridge maps `observed_at` → observedAt);
        //    only ever moves FORWARD, and only for a parseable timestamp.
        if case .string(let raw)? = newMeta["observed_at"],
           MemoryRecallScoring.parseTimestamp(raw) != nil {
            let current = existing.observedAt ?? ""
            if raw > current { out["observed_at"] = .string(raw) }
        }
        return out
    }

    /// Store a new memory record. Refuses (with `.underlying("tombstoned")`) if
    /// the content matches a rejection tombstone — the denylist gate. Otherwise
    /// embeds the content, inserts into storage, and returns the resulting
    /// `MemoryRecord` with its storage-assigned id.
    public func store(
        content: String,
        source: String? = nil,
        metadata: JSONValue? = nil
    ) async throws -> MemoryRecord {
        let content = MemoryTextClip.memoryDisplayText(
            content,
            kind: Self.metadataKind(metadata)
        )
        guard !content.isEmpty else { throw MemoryV2Error.invalidQuery }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: content,
            source: source,
            kind: Self.metadataKind(metadata)
        ) {
            throw MemoryV2Error.underlying("not durable memory: \(reason)")
        }
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        if try await storage.isTombstoned(content: content) {
            throw MemoryV2Error.underlying("tombstoned: content matches a rejection denylist entry")
        }
        // Taste pass 2026-07-24: write-time exact-duplicate guard. A repeated
        // commit_memory (retry loop, re-asserted fact) used to insert a fresh
        // identical active row each time — 4 copies of one fact landed in 49s
        // on 2026-07-22 and sat visible until the weekly hygiene pass. Same
        // normalization as hygiene's exact-dup collapse, so "duplicate" means
        // one thing. Idempotent: return the existing record and count the
        // re-assertion as corroborating evidence (metadata.recall_count, the
        // same bump mergeProposal applies — a merge is evidence, not access).
        // Checked BEFORE embedding: a duplicate never pays the embed cost.
        let contentKey = MemoryConsolidator.normalizedContentKey(content)
        let existingRows = try await storage.listMemory(kind: nil)
        if let existing = existingRows.first(where: {
            ($0.status ?? "active") == "active"
                && MemoryConsolidator.normalizedContentKey($0.text) == contentKey
        }) {
            var currentCount: Int64 = 0
            if case .object(let m)? = existing.extras {
                if case .int(let n)? = m["recall_count"] { currentCount = n }
                if case .double(let d)? = m["recall_count"] { currentCount = Int64(d) }
            }
            // Unknown patch keys merge into metadata_json (bridge contract).
            var patch: [String: JSONValue] = ["recall_count": .int(currentCount + 1)]
            // gpt-5.5 review A3 (2026-08-02): the collapse itself is deliberate
            // and stays — repetition should be evidence, not clutter. What was
            // WRONG is that the later occurrence lost its identity: two
            // genuinely different events producing the same prose left the row
            // pointing only at the first one, so the second was unrecoverable.
            // The provenance of every occurrence now accumulates alongside the
            // count, bounded, in metadata.
            for (key, value) in Self.duplicateProvenancePatch(
                existing: existing,
                newSource: source,
                newMetadata: metadata
            ) {
                patch[key] = value
            }
            return try await storage.updateMemory(
                id: existing.id,
                patch: .object(patch),
                newEmbedding: nil
            )
        }
        // Embed ONCE; the same vector serves the semantic tombstone gate and
        // the insert. Wave1 T3: a paraphrase of a deleted claim blocks here at
        // write time (the read path never pays); contradictions score below the
        // high threshold and are admitted as new information.
        let embedded = try await embedOneWithEpoch(content)
        if try await storage.matchesTombstone(
            embedding: embedded.vector,
            embeddingEpoch: embedded.epoch
        ) {
            throw MemoryV2Error.underlying("tombstoned: content is a paraphrase of a rejected claim")
        }
        let now = Self.iso8601Now()
        // commit_memory review fix (2026-06-11): lift confidence/importance/
        // tags out of caller metadata into the record's FIRST-CLASS fields —
        // the SQLite bridge reads record.confidence (?? 1.0) and recall
        // surfaces the fields, not the extras blob. Absent in metadata →
        // nil, exactly as before (additive; no caller behavior change).
        var liftedConfidence: Double?
        var liftedImportance: Double?
        var liftedTags: [String]?
        var liftedValidFrom: String?
        var liftedValidTo: String?
        var liftedObservedAt: String?
        var liftedEvidence: JSONValue?
        if case .object(let metaObj)? = metadata {
            if case .double(let c)? = metaObj["confidence"] { liftedConfidence = c }
            if case .double(let i)? = metaObj["importance"] { liftedImportance = i }
            if case .array(let t)? = metaObj["tags"] {
                let strings = t.compactMap { v -> String? in
                    if case .string(let s) = v { return s } else { return nil }
                }
                if !strings.isEmpty { liftedTags = strings }
            }
            if case .string(let value)? = metaObj["valid_from"] { liftedValidFrom = value }
            if case .string(let value)? = metaObj["validFrom"] { liftedValidFrom = value }
            if case .string(let value)? = metaObj["valid_to"] { liftedValidTo = value }
            if case .string(let value)? = metaObj["validTo"] { liftedValidTo = value }
            if case .string(let value)? = metaObj["observed_at"] { liftedObservedAt = value }
            if case .string(let value)? = metaObj["observedAt"] { liftedObservedAt = value }
            liftedEvidence = metaObj["evidence"]
        }
        let record = MemoryRecord(
            id: UUID().uuidString,
            text: content,
            layer: "semantic",
            memoryKind: nil,
            personaId: MemoryV2Defaults.personaID,
            lifecycle: MemoryLifecycle.confirmed,
            createdAt: now,
            updatedAt: now,
            sourceRunId: source,
            status: "active",
            confidence: liftedConfidence,
            importance: liftedImportance,
            tags: liftedTags,
            validFrom: liftedValidFrom,
            validTo: liftedValidTo,
            observedAt: liftedObservedAt,
            evidence: liftedEvidence,
            // U3 wave-2 item 5a — every new write carries metadata.kind.
            // Caller-provided kinds pass through verbatim; absent a signal,
            // the semantics-neutral default ("general", decayFactor 1.0,
            // no supersession) is stamped. See MemoryKindStamp.
            extras: MemoryKindStamp.stampingDefaultKind(metadata)
        )
        let inserted = try await storage.insert(
            record: record,
            embedding: embedded.vector,
            embeddingEpoch: embedded.epoch
        )
        await flushDerivedMemoryChanges()
        return inserted
    }

    /// Convenience tombstone check used by upstream filters (e.g. the chat-fact
    /// promoter) before calling `store(...)`.
    public func isRejected(content: String) async throws -> Bool {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.isTombstoned(content: content)
    }

    // MARK: Proposal lifecycle

    public func propose(
        content: String,
        source: String? = nil,
        confidence: Double? = nil,
        kind: String? = nil,
        supportingSessionIDs: [String] = [],
        recurrenceCount: Int? = nil
    ) async throws -> ProposalRecord {
        let content = MemoryTextClip.memoryDisplayText(content, kind: kind)
        guard !content.isEmpty else { throw MemoryV2Error.invalidQuery }
        if let reason = MemoryCandidateQuality.rejectionReason(text: content, source: source, kind: kind) {
            throw MemoryV2Error.underlying("not durable memory: \(reason)")
        }
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        // Carry the extractor's confidence + kind so acceptProposal stamps them
        // on the memory instead of discarding them (#1). nil → empty metadata.
        let sessions = Array(Set(supportingSessionIDs.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })).sorted().prefix(32)
        // 2026-07-21 audit fix: content-hash dedup on PENDING proposals.
        // observeTurn re-stages the same extracted fact every turn with a
        // fresh UUID, flooding the review queue with duplicates of one fact.
        // A pending proposal with the same normalized content hash (persona
        // is the store constant — the bridge stamps
        // MemoryV2Defaults.personaID on every proposal insert) is updated in
        // place instead: session evidence unions, recurrence accrues,
        // confidence keeps the max, and the canonical row's id is returned
        // so the auto-accept lane still fires on it. Resolved proposals are
        // untouched — their rows are audit trail.
        let newContentHash = MemoryStorage.contentHash(content)
        if let existing = try await storage.listProposals(status: "pending")
            .first(where: { MemoryStorage.contentHash($0.content) == newContentHash }) {
            var merged: [String: JSONValue]
            if case .object(let m)? = existing.metadata { merged = m } else { merged = [:] }
            var sessionSet = Set<String>()
            if case .array(let arr)? = merged["supporting_session_ids"] {
                for case .string(let s) in arr { sessionSet.insert(s) }
            }
            sessionSet.formUnion(sessions)
            if !sessionSet.isEmpty {
                merged["supporting_session_ids"] = .array(sessionSet.sorted().prefix(32).map(JSONValue.string))
            }
            func intMeta(_ object: [String: JSONValue], _ key: String) -> Int64? {
                switch object[key] {
                case .int(let i)?: return i
                case .double(let d)?: return Int64(d)
                case .string(let s)?: return Int64(s.trimmingCharacters(in: .whitespaces))
                default: return nil
                }
            }
            let priorRecurrence = intMeta(merged, "recurrence_count") ?? 1
            let incomingRecurrence = Int64(max(1, recurrenceCount ?? 1))
            merged["recurrence_count"] = .int(priorRecurrence + incomingRecurrence)
            if let confidence {
                let prior: Double? = {
                    switch merged["confidence"] {
                    case .double(let d)?: return d
                    case .int(let i)?: return Double(i)
                    default: return nil
                    }
                }()
                merged["confidence"] = .double(max(confidence, prior ?? 0))
            }
            if merged["kind"] == nil, let kind, !kind.isEmpty {
                merged["kind"] = .string(kind)
            }
            return try await storage.updateProposalMetadata(
                id: existing.id,
                metadata: merged.isEmpty ? nil : .object(merged)
            )
        }
        var meta: [String: JSONValue] = [:]
        if let confidence { meta["confidence"] = .double(confidence) }
        if let kind, !kind.isEmpty { meta["kind"] = .string(kind) }
        if !sessions.isEmpty {
            meta["supporting_session_ids"] = .array(sessions.map(JSONValue.string))
        }
        if let recurrenceCount {
            meta["recurrence_count"] = .int(Int64(max(1, recurrenceCount)))
        }
        let proposal = ProposalRecord(
            id: UUID().uuidString,
            content: content,
            source: source,
            status: "pending",
            createdAt: Self.iso8601Now(),
            metadata: meta.isEmpty ? nil : .object(meta)
        )
        let embedded = try await embedOneWithEpoch(content)
        try await storage.insertProposal(
            proposal,
            embedding: embedded.vector,
            embeddingEpoch: embedded.epoch
        )
        return proposal
    }

    public func acceptProposal(id: String) async throws -> MemoryRecord {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let proposal = try await storage.getProposal(id: id) else {
            throw MemoryV2Error.recordNotFound
        }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: proposal.content,
            source: proposal.source,
            kind: Self.metadataKind(proposal.metadata)
        ) {
            let rejection = "quality gate at acceptance: \(reason)"
            try await storage.updateProposalStatus(
                id: id,
                status: "rejected",
                rejectionReason: rejection
            )
            throw MemoryV2Error.underlying("not durable memory: \(reason)")
        }
        // The tombstone gate runs at acceptance too, not just at proposal time —
        // a proposal that was queued before the denylist entry landed must still
        // be rejected when it tries to promote.
        if try await storage.isTombstoned(content: proposal.content) {
            try await storage.updateProposalStatus(id: id, status: "rejected", rejectionReason: "tombstoned at acceptance")
            throw MemoryV2Error.underlying("tombstoned: proposal content matches a rejection denylist entry")
        }
        let accepted = try await storage.acceptProposal(id: id)
        await flushDerivedMemoryChanges()
        return accepted
    }

    @discardableResult
    public func rejectProposal(id: String, reason: String? = nil) async throws -> Bool {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let proposal = try await storage.getProposal(id: id) else {
            throw MemoryV2Error.recordNotFound
        }
        try await storage.updateProposalStatus(id: id, status: "rejected", rejectionReason: reason)
        // Rejection writes a tombstone so the same fact can't re-enter via a future
        // proposal — matches the Python promoter's denylist semantics.
        try await storage.recordTombstone(content: proposal.content, reason: reason)
        return true
    }

    public func listProposals(status: String? = nil) async throws -> [ProposalRecord] {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.listProposals(status: status)
    }

    // MARK: - utilities

    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    private static func metadataKind(_ metadata: JSONValue?) -> String? {
        guard case .object(let obj)? = metadata,
              case .string(let kind)? = obj["kind"] else {
            return nil
        }
        let trimmed = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - InMemoryMemoryStorage (test fixture)
//
// A trivial in-memory `MemoryStorageProtocol` for tests and any callsite that
// wants to exercise the actor before m1's SQLite-backed `MemoryStorage` lands.
// NOT for production use.
public actor InMemoryMemoryStorage: MemoryStorageProtocol {
    private var records: [String: MemoryRecord] = [:]
    private var embeddings: [String: [Float]] = [:]
    private var personas: [String: String] = [:]
    private var tombstones: Set<String> = []
    private var proposals: [String: ProposalRecord] = [:]
    private var proposalEmbeddings: [String: [Float]] = [:]

    public init() {}

    public func listMemory(kind: String?) async throws -> [MemoryRecord] {
        let all = Array(records.values)
        guard let kind else { return all }
        return all.filter { $0.memoryKind == kind || $0.layer == kind }
    }

    public func insert(record: MemoryRecord, embedding: [Float]?) async throws -> MemoryRecord {
        records[record.id] = record
        if let embedding { embeddings[record.id] = embedding }
        if let persona = record.personaId { personas[record.id] = persona }
        else { personas.removeValue(forKey: record.id) }
        return record
    }

    public func updateMemory(id: String, patch: JSONValue, newEmbedding: [Float]?) async throws -> MemoryRecord {
        guard var rec = records[id] else { throw MemoryV2Error.recordNotFound }
        if case .object(let obj) = patch {
            if case .string(let s)? = obj["text"] { rec.text = s }
            if case .string(let s)? = obj["content"] { rec.text = s }
            if case .string(let s)? = obj["status"] { rec.status = s }
            if case .double(let d)? = obj["confidence"] { rec.confidence = d }
            if case .int(let i)? = obj["confidence"] { rec.confidence = Double(i) }
            if case .string(let s)? = obj["validFrom"] { rec.validFrom = s }
            if case .string(let s)? = obj["valid_from"] { rec.validFrom = s }
            if case .string(let s)? = obj["validTo"] { rec.validTo = s }
            if case .string(let s)? = obj["valid_to"] { rec.validTo = s }
            if case .string(let s)? = obj["observed_at"] { rec.observedAt = s }
            if case .string(let s)? = obj["observedAt"] { rec.observedAt = s }
            if let evidence = obj["evidence"] { rec.evidence = evidence }
            // UNTYPED KEYS FOLLOW THE SQLITE CONTRACT, NOT A WIDER ONE.
            //
            // This fixture used to merge EVERY untyped key into `extras`, while
            // `MemoryStorageBridge` (production SQLite) merges only
            // `MemoryPatchContract.untypedPassthroughKeys` and DROPS the rest.
            // So `patch(["foo": "bar"])` persisted here and vanished there — a
            // test could pass against behaviour production does not have, which
            // is exactly how the `recall_count` no-op survived (2026-07-24).
            // The SQLite side is the contract; the allowlist is shared so the
            // two cannot drift again (gpt-5.5 review, 2026-08-02).
            let passthrough = obj.filter {
                MemoryPatchContract.untypedPassthroughKeys.contains($0.key)
            }
            if !passthrough.isEmpty {
                var meta: [String: JSONValue] = [:]
                if case .object(let m)? = rec.extras { meta = m }
                for (k, v) in passthrough { meta[k] = v }
                rec.extras = .object(meta)
                // …and surfaced back into the typed slots the same way
                // `MemoryStorageBridge.toMemoryRecord` surfaces them, so a
                // read-back through the fixture matches a read-back through
                // SQLite instead of only agreeing about storage.
                if case .bool(let b)? = passthrough["pinned"] { rec.pinned = b }
                if case .double(let d)? = passthrough["importance"] { rec.importance = d }
                if case .int(let i)? = passthrough["importance"] { rec.importance = Double(i) }
                if case .array(let arr)? = passthrough["tags"] {
                    let strings = arr.compactMap { value -> String? in
                        if case .string(let t) = value { return t } else { return nil }
                    }
                    if !strings.isEmpty { rec.tags = strings }
                }
            }
        }
        rec.updatedAt = ISO8601DateFormatter().string(from: Date())
        records[id] = rec
        if let newEmbedding { embeddings[id] = newEmbedding }
        return rec
    }

    public func deleteMemory(id: String) async throws -> Bool {
        let removed = records.removeValue(forKey: id)
        if let removed {
            tombstones.insert(Self.normalize(removed.text))
        }
        embeddings.removeValue(forKey: id)
        personas.removeValue(forKey: id)
        return removed != nil
    }

    public func recall(embedding: [Float], topK: Int, persona: String?) async throws -> [ScoredMemoryRecord] {
        var scored: [ScoredMemoryRecord] = []
        for (id, vec) in embeddings {
            if let persona, personas[id] != persona { continue }
            guard let rec = records[id] else { continue }
            let s = Self.cosine(embedding, vec)
            scored.append(ScoredMemoryRecord(record: rec, score: Double(s)))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(max(0, topK)))
    }

    public func isTombstoned(content: String) async throws -> Bool {
        tombstones.contains(Self.normalize(content))
    }

    public func recordTombstone(content: String, reason: String?) async throws {
        _ = reason
        tombstones.insert(Self.normalize(content))
    }

    public func insertProposal(_ proposal: ProposalRecord, embedding: [Float]? = nil) async throws {
        proposals[proposal.id] = proposal
        if let embedding {
            proposalEmbeddings[proposal.id] = embedding
        } else {
            proposalEmbeddings.removeValue(forKey: proposal.id)
        }
    }

    public func getProposal(id: String) async throws -> ProposalRecord? {
        proposals[id]
    }

    public func acceptProposal(id: String) async throws -> MemoryRecord {
        guard var proposal = proposals[id] else { throw MemoryV2Error.recordNotFound }
        guard proposal.status == "pending" else {
            throw MemoryV2Error.underlying("proposal already resolved: \(id)")
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let record = MemoryRecord(
            id: proposal.id,
            text: proposal.content,
            layer: "semantic",
            memoryKind: nil,
            createdAt: now,
            updatedAt: now,
            sourceRunId: proposal.source,
            status: "active"
        )
        records[record.id] = record
        if let embedding = proposalEmbeddings[id] {
            embeddings[record.id] = embedding
        }
        proposal.status = "accepted"
        proposals[id] = proposal
        return record
    }

    public func updateProposalStatus(id: String, status: String, rejectionReason: String?) async throws {
        guard var p = proposals[id] else { throw MemoryV2Error.recordNotFound }
        p.status = status
        if let rejectionReason { p.rejectionReason = rejectionReason }
        proposals[id] = p
    }

    public func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> ProposalRecord {
        guard var p = proposals[id], p.status == "pending" else {
            throw MemoryV2Error.recordNotFound
        }
        p.metadata = metadata
        proposals[id] = p
        return p
    }

    public func listProposals(status: String?) async throws -> [ProposalRecord] {
        let all = Array(proposals.values)
        guard let status else { return all }
        return all.filter { $0.status == status }
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        let d = sqrtf(na) * sqrtf(nb)
        return d > 0 ? dot / d : 0
    }
}
