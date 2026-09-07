import Foundation
import NativeAgentCore
import PersistenceCore

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
    func acceptReviewedMoment(id: String, review: ReviewedMomentAcceptance) async throws -> MemoryRecord
    func updateProposalStatus(id: String, status: String, rejectionReason: String?) async throws
    /// 2026-07-21 audit fix: metadata merge target for propose()'s
    /// pending-proposal content-hash dedup. Pending-only semantics — a
    /// resolved proposal must never have its metadata rewritten.
    func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> ProposalRecord
    func listProposals(status: String?) async throws -> [ProposalRecord]
}

/// Optional storage capability: stage a proposal with the pending-dedup match,
/// merge and insert done under ONE storage write lock (User, 2026-09-06 — the
/// read-merge-write in `propose` lost evidence and double-inserted when two
/// observations of the same fact raced). Kept OFF `MemoryStorageProtocol`, like
/// the other refinements, so lightweight fixtures keep the old path.
public protocol AtomicProposalStagingStorage: MemoryStorageProtocol {
    /// Returns the merged existing proposal, the freshly inserted one, or nil
    /// when nothing matched and `insertIfAbsent` was false.
    /// A throwing merge aborts staging before changing the matched row.
    func stagePendingProposal(
        _ proposal: ProposalRecord,
        embedding: [Float]?,
        embeddingEpoch: MemoryEmbeddingEpoch?,
        insertIfAbsent: Bool,
        foldedKey: @Sendable (String) -> String,
        merge: @Sendable (ProposalRecord) throws -> JSONValue?
    ) async throws -> ProposalRecord?
}

/// Optional storage capability: COUNT the moments lane without materializing
/// it. The per-turn nudge line needs one number, and `listProposals` is
/// `SELECT *` + a full row decode + a Swift-side JSON filter — a real per-turn
/// cost for a scalar. Kept as a refinement (not a `MemoryStorageProtocol`
/// requirement) so lightweight fixtures stay minimal; callers fall back to the
/// list path when a storage seam does not implement it.
public protocol MomentProposalCountingStorage: MemoryStorageProtocol {
    /// Proposals in the moments lane, optionally scoped to one status
    /// ("pending"/"accepted"/"rejected"); nil counts every status.
    func countMomentProposals(status: String?) async throws -> Int
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
    /// 2026-09-06: the same recall, plus whether it degraded to the keyword
    /// lane. That decision is made inside storage, below the layer that owns
    /// provenance, so without this the hits went out labelled as semantic ones.
    func recallReportingKeywordFallback(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> (hits: [ScoredMemoryRecord], usedKeywordFallback: Bool)
}

/// Optional storage capability: lexical-only recall for when no usable query
/// embedding exists. Kept OFF `MemoryStorageProtocol` (like
/// `HybridMemoryStorageProtocol`) so lightweight fixtures are unaffected —
/// a storage that does not implement it simply has no fallback, which is the
/// pre-sweep behavior.
public protocol KeywordRecallStorageProtocol: MemoryStorageProtocol {
    func recallByKeyword(
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> [ScoredMemoryRecord]
}

/// Exact canonical lookup for supported stores only. No list-all fallback:
/// disclosure/lifecycle/quality remain enforced by the MemoryV2 read boundary.
protocol MemoryRecordLookupStorage: MemoryStorageProtocol {
    func lookupMemoryRecord(id: String) async throws -> MemoryRecord?
}

public extension MemoryStorageProtocol {
    func acceptReviewedMoment(id: String, review: ReviewedMomentAcceptance) async throws -> MemoryRecord {
        throw MemoryV2Error.underlying("storage does not support atomic moment review")
    }

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

    /// Default: a storage with no lexical lane can never degrade into one.
    func recallReportingKeywordFallback(
        embedding: [Float],
        embeddingEpoch: MemoryEmbeddingEpoch?,
        queryText: String,
        topK: Int,
        persona: String?
    ) async throws -> (hits: [ScoredMemoryRecord], usedKeywordFallback: Bool) {
        (try await recall(
            embedding: embedding,
            embeddingEpoch: embeddingEpoch,
            queryText: queryText,
            topK: topK,
            persona: persona
        ), false)
    }
}
