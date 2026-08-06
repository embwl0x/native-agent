// Swift-native cutover mem-m1: SQLite + GRDB storage layer for MemoryV2.
//
// Drops a GRDB-backed sqlite database under <dataRoot>/memory/memory.sqlite
// behind a `MemoryStorage` actor that owns CRUD for memories, proposals, and
// rejection tombstones. Replaces the JSON-file scattershot (memory.json,
// memory_proposals/*.json, .rejected_tombstones) with one durable store.

import Foundation
import CryptoKit
import GRDB
import NativeAgentCore
import PersistenceCore

public enum MemoryV2Defaults {
    public static let personaID = "NativeAgent"
}

/// Hard bound on canonical MemoryV2 fact rows. Enforced inside every canonical
/// insert/accept transaction, during store open for legacy overflow, and inside
/// approved consolidation table swaps. This is storage physiology, not a
/// periodic cleanup promise.
public let memoryStoredRowCap = 2_000

public enum MemoryLifecycle {
    public static let confirmed = "confirmed"
    public static let temporary = "temporary"
    public static let inferred = "inferred"
    public static let stale = "stale"
    public static let corrected = "corrected"
    public static let contradicted = "contradicted"
    public static let deleted = "deleted"

    public static let recallExcluded: Set<String> = [corrected, contradicted, deleted]

    public static func normalized(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? confirmed : trimmed
    }

    public static func isRecallEligible(_ value: String?) -> Bool {
        !recallExcluded.contains(normalized(value))
    }

    public static func rankingFactor(_ value: String?) -> Double {
        switch normalized(value) {
        case temporary, inferred:
            return 0.85
        case stale:
            return 0.5
        case corrected, contradicted, deleted:
            return 0.0
        default:
            return 1.0
        }
    }
}

// MARK: - Records

public struct StoredMemory: Sendable {
    public var id: String
    public var content: String
    public var personaId: String
    public var source: String?
    public var confidence: Double
    public var createdAt: String
    public var updatedAt: String
    public var embedding: [Float]?
    /// Exact identity of the vector space that produced `embedding`. Nil is
    /// legacy/unverified and is never presented as epoch-protected.
    public var embeddingEpoch: String?
    public var status: String
    public var lifecycle: String
    public var validFrom: String?
    public var validTo: String?
    public var observedAt: String?
    public var evidence: JSONValue?
    public var metadata: JSONValue?
    /// Access counter — incremented by `recordRecallHits` when this memory is
    /// returned by recall. DISTINCT from `metadata.recall_count` (merge
    /// corroboration): a recall is access, a merge is evidence (Agent's ruling,
    /// 2026-06-09). `archiveStale` consults both. Real column for atomic +1.
    public var useCount: Int64
    public var lastUsedAt: String?

    public init(
        id: String = UUID().uuidString,
        content: String,
        personaId: String = MemoryV2Defaults.personaID,
        source: String? = nil,
        confidence: Double = 1.0,
        createdAt: String = MemoryStorage.nowISO8601(),
        updatedAt: String? = nil,
        embedding: [Float]? = nil,
        embeddingEpoch: String? = nil,
        status: String = "active",
        lifecycle: String = MemoryLifecycle.confirmed,
        validFrom: String? = nil,
        validTo: String? = nil,
        observedAt: String? = nil,
        evidence: JSONValue? = nil,
        metadata: JSONValue? = nil,
        useCount: Int64 = 0,
        lastUsedAt: String? = nil
    ) {
        self.id = id
        self.content = content
        self.personaId = personaId
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.embedding = embedding
        self.embeddingEpoch = embeddingEpoch
        self.status = status
        self.lifecycle = MemoryLifecycle.normalized(lifecycle)
        self.validFrom = validFrom
        self.validTo = validTo
        self.observedAt = observedAt
        self.evidence = evidence
        self.metadata = metadata
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    /// Metadata view for derived graph/device projections. Canonical temporal
    /// and evidence columns remain first-class; this is a rebuildable outward
    /// representation for consumers whose schema is metadata-shaped.
    public var projectionMetadata: JSONValue? {
        var object: [String: JSONValue] = [:]
        if case .object(let existing)? = metadata { object = existing }
        if let validFrom { object["valid_from"] = .string(validFrom) }
        if let validTo { object["valid_to"] = .string(validTo) }
        if let observedAt { object["observed_at"] = .string(observedAt) }
        if let evidence { object["evidence"] = evidence }
        return object.isEmpty ? nil : .object(object)
    }
}

public struct StoredProposal: Sendable {
    public var id: String
    public var content: String
    public var personaId: String
    public var source: String?
    public var stagedAt: String
    public var status: String
    public var resolvedAt: String?
    public var rejectionReason: String?
    public var embedding: [Float]?
    public var embeddingEpoch: String?
    public var metadata: JSONValue?

    public init(
        id: String = UUID().uuidString,
        content: String,
        personaId: String = MemoryV2Defaults.personaID,
        source: String? = nil,
        stagedAt: String = MemoryStorage.nowISO8601(),
        status: String = "pending",
        resolvedAt: String? = nil,
        rejectionReason: String? = nil,
        embedding: [Float]? = nil,
        embeddingEpoch: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.content = content
        self.personaId = personaId
        self.source = source
        self.stagedAt = stagedAt
        self.status = status
        self.resolvedAt = resolvedAt
        self.rejectionReason = rejectionReason
        self.embedding = embedding
        self.embeddingEpoch = embeddingEpoch
        self.metadata = metadata
    }
}

public struct StoredTombstone: Sendable {
    public var contentHash: String
    public var content: String
    public var rejectedAt: String
    public var reason: String?
    /// Embedding of the rejected/deleted claim. Enables the semantic tombstone
    /// gate (Agent's canon: a deletion is the CLAIM, not the topic — paraphrases
    /// block at a high cosine threshold; contradictions walk in). Nullable:
    /// legacy tombstones without one stay exact-hash-only.
    public var embedding: [Float]?
    public var embeddingEpoch: String?

    public init(
        contentHash: String,
        content: String,
        rejectedAt: String,
        reason: String?,
        embedding: [Float]? = nil,
        embeddingEpoch: String? = nil
    ) {
        self.contentHash = contentHash
        self.content = content
        self.rejectedAt = rejectedAt
        self.reason = reason
        self.embedding = embedding
        self.embeddingEpoch = embeddingEpoch
    }
}

// MARK: - Wave-1 semantics tunables (Agent's canon, 2026-06-09)

/// Cosine at/above which a candidate memory counts as a PARAPHRASE of a
/// tombstoned claim and is blocked. High on purpose: only true restatements of
/// the deleted claim match; contradictions ("hates" after deleting "likes")
/// score lower and walk in as new information. Config constant per Agent —
/// tuned on REAL MiniLM output (2026-06-09 calibration, see
/// realMiniLM_tombstone_threshold_calibration): paraphrase=0.945,
/// narrower-claim=0.895, contradiction=0.890. Agent's initial 0.95 estimate
/// sat ABOVE the paraphrase — gate inert; 0.92 splits the measured gap so the
/// paraphrase blocks while contradiction + narrower claims walk in.
public let memoryTombstoneMatchThreshold: Double = 0.92

/// Single-valued kinds for the narrow supersession pass: two values can't both
/// be true, so a NEWER active fact of the same kind archives the older one.
/// Multi-valued kinds (preference, attribute, ...) coexist by design.
public let memorySupersessionSingleValuedKinds: Set<String> = ["location", "employment", "identity"]

/// Mechanism guard inside Agent's narrow lane: same-kind alone could collide
/// unrelated facts (employment carries both work-at and work-as). Supersession
/// additionally requires this cosine floor so only same-topic facts collide.
public let memorySupersessionCosineFloor: Double = 0.55

/// Kind-scoped recency decay (Agent's canon): half-life in DAYS per kind.
/// Shapes RANK only — never existence (eviction stays the consolidator's job).
/// Kinds absent from this table — identity/relationship/preference AND
/// nil/legacy — are exempt (factor 1.0): decay only acts on data that carries
/// the volatile-class kind signal.
public let memoryDecayHalfLifeDays: [String: Double] = [
    "volatile": 60, "project": 60, "operational": 60,
]

/// Additive lexical boost used by hybrid recall. The base dense cosine remains
/// intact, then normalized BM25 can add up to this amount before kind-recency
/// decay is applied. This keeps old cosine score semantics mostly stable while
/// giving exact names/keywords enough authority to recover short Telegram turns.
public let memoryBM25LexicalBoost: Double = 0.25

/// Pure decay math, separated for testability.
public enum MemoryRecallScoring {
    // Cached formatters — this runs per-candidate inside the recall hot loop;
    // allocating ISO8601DateFormatter per call is the only real cost there
    // (gpt-5.5 wave1 finding 5). ISO8601DateFormatter is documented
    // thread-safe.
    // nonisolated(unsafe): ISO8601DateFormatter is documented thread-safe
    // (unlike DateFormatter pre-iOS7); the class just isn't marked Sendable.
    // Configured once here and never mutated after init.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse either ISO8601 variant the codebase writes (fractional + plain).
    public static func parseTimestamp(_ s: String) -> Date? {
        fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }

    /// Multiplier in (0, 1]: pow(0.5, age/halfLife) for kinds with a configured
    /// half-life; 1.0 (exempt) for everything else or unparseable timestamps.
    public static func decayFactor(kind: String?, updatedAt: String, now: Date = Date()) -> Double {
        guard let kind, let halfLifeDays = memoryDecayHalfLifeDays[kind] else { return 1.0 }
        guard let updated = parseTimestamp(updatedAt) else { return 1.0 }
        let ageDays = max(0, now.timeIntervalSince(updated)) / 86_400
        return pow(0.5, ageDays / halfLifeDays)
    }

    /// Extract the kind stamped by the #1 signal-carry (metadata.kind).
    public static func kind(of metadata: JSONValue?) -> String? {
        guard case .object(let obj)? = metadata, case .string(let k)? = obj["kind"] else { return nil }
        return k.isEmpty ? nil : k
    }

    public static func lexicalTokens(_ text: String) -> [String] {
        text.lowercased()
            .split { character in
                !(character.isLetter || character.isNumber)
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// BM25 over the already-loaded candidate set. Recall already performs a
    /// full candidate sweep for cosine, so this avoids a schema migration while
    /// restoring the daemon-era lexical signal.
    public static func normalizedBM25Scores(
        query: String?,
        documents: [String],
        k1: Double = 1.2,
        b: Double = 0.75
    ) -> [Double] {
        guard let query else { return Array(repeating: 0, count: documents.count) }
        let queryTerms = Array(Set(lexicalTokens(query)))
        guard !queryTerms.isEmpty, !documents.isEmpty else {
            return Array(repeating: 0, count: documents.count)
        }

        let docTokens = documents.map(lexicalTokens)
        let docLengths = docTokens.map(\.count)
        let avgLength = Double(max(1, docLengths.reduce(0, +))) / Double(max(1, documents.count))

        var docFreq: [String: Int] = [:]
        for tokens in docTokens {
            for term in Set(tokens) where queryTerms.contains(term) {
                docFreq[term, default: 0] += 1
            }
        }

        let n = Double(documents.count)
        var rawScores: [Double] = []
        rawScores.reserveCapacity(documents.count)
        for (index, tokens) in docTokens.enumerated() {
            guard !tokens.isEmpty else {
                rawScores.append(0)
                continue
            }
            var tf: [String: Int] = [:]
            for token in tokens where queryTerms.contains(token) {
                tf[token, default: 0] += 1
            }
            let dl = Double(max(1, docLengths[index]))
            var score = 0.0
            for term in queryTerms {
                guard let fInt = tf[term], fInt > 0 else { continue }
                let df = Double(docFreq[term] ?? 0)
                guard df > 0 else { continue }
                let idf = log(1.0 + ((n - df + 0.5) / (df + 0.5)))
                let f = Double(fInt)
                let denom = f + k1 * (1.0 - b + b * (dl / avgLength))
                if denom > 0 {
                    score += idf * ((f * (k1 + 1.0)) / denom)
                }
            }
            rawScores.append(score)
        }

        guard let maxScore = rawScores.max(), maxScore > 0 else {
            return Array(repeating: 0, count: documents.count)
        }
        return rawScores.map { $0 / maxScore }
    }
}

public struct MemoryPatch: Sendable {
    public var content: String?
    public var source: String?
    public var confidence: Double?
    public var embedding: [Float]?
    public var embeddingEpoch: String?
    public var status: String?
    public var lifecycle: String?
    public var validFrom: String?
    public var validTo: String?
    public var observedAt: String?
    public var evidence: JSONValue?
    public var metadata: JSONValue?

    public init(
        content: String? = nil,
        source: String? = nil,
        confidence: Double? = nil,
        embedding: [Float]? = nil,
        embeddingEpoch: String? = nil,
        status: String? = nil,
        lifecycle: String? = nil,
        validFrom: String? = nil,
        validTo: String? = nil,
        observedAt: String? = nil,
        evidence: JSONValue? = nil,
        metadata: JSONValue? = nil
    ) {
        self.content = content
        self.source = source
        self.confidence = confidence
        self.embedding = embedding
        self.embeddingEpoch = embeddingEpoch
        self.status = status
        self.lifecycle = lifecycle
        self.validFrom = validFrom
        self.validTo = validTo
        self.observedAt = observedAt
        self.evidence = evidence
        self.metadata = metadata
    }
}

// MARK: - Errors

public enum MemoryStorageError: Error, LocalizedError {
    case notFound(String)
    case alreadyResolved(String)
    case databaseUnavailable(String)
    /// The candidate content is a paraphrase of a tombstoned claim (semantic
    /// gate) — blocked at store/accept time per the rejection denylist.
    case tombstoned(String)
    case embeddingEpochMismatch(expected: String, actual: String?)
    case embeddingActivationInvalid(String)
    case invalidTemporalEvidence(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "MemoryStorage: not found — \(id)"
        case .alreadyResolved(let id): return "MemoryStorage: proposal already resolved — \(id)"
        case .databaseUnavailable(let msg): return "MemoryStorage: database unavailable — \(msg)"
        case .tombstoned(let id): return "MemoryStorage: content matches a tombstoned claim — \(id)"
        case .embeddingEpochMismatch(let expected, let actual):
            return "MemoryStorage: embedding epoch mismatch — expected \(expected), got \(actual ?? "unknown")"
        case .embeddingActivationInvalid(let reason):
            return "MemoryStorage: embedding epoch activation refused — \(reason)"
        case .invalidTemporalEvidence(let reason):
            return "MemoryStorage: invalid temporal evidence — \(reason)"
        }
    }
}

public enum MemoryEmbeddingCorpusKind: String, Sendable, Codable, CaseIterable {
    case memory
    case proposal
    case tombstone
}

public struct MemoryEmbeddingCorpusRow: Sendable, Equatable {
    public let kind: MemoryEmbeddingCorpusKind
    public let id: String
    public let content: String
    public let contentHash: String

    public init(kind: MemoryEmbeddingCorpusKind, id: String, content: String) {
        self.kind = kind
        self.id = id
        self.content = content
        self.contentHash = MemoryStorage.contentHash(content)
    }
}

public struct MemoryEmbeddingStagedRow: Sendable {
    public let row: MemoryEmbeddingCorpusRow
    public let vector: [Float]

    public init(row: MemoryEmbeddingCorpusRow, vector: [Float]) {
        self.row = row
        self.vector = vector
    }
}

public struct MemoryEmbeddingEpochState: Sendable, Equatable {
    public let activeEpoch: String?
    public let previousEpoch: String?
    public let activatedAt: String?
    public let rollbackAvailable: Bool

    public var protected: Bool { activeEpoch != nil }
}

public struct MemoryEmbeddingEpochActivationReport: Sendable, Equatable {
    public let epoch: String
    public let memories: Int
    public let proposals: Int
    public let tombstones: Int
    public let previousEpoch: String?
    public let activatedAt: String

    public var total: Int { memories + proposals + tombstones }
}

// MARK: - MemoryStorage actor

public actor MemoryStorage {
    // `internal`, not `private`, so same-module storage extensions in other
    // files (e.g. `MemoryV2+LaneRetention`) can issue their own queries
    // against the SAME pool rather than re-opening the database.
    let dbPool: DatabasePool
    public let path: URL
    private let memoryLimit: Int
    private var startupBoundEvictions: [StoredMemory]
    private var replayedStartupUserProjection = false
    private var replayedStartupSpotlightProjection = false
    private var replayedStartupKnowledgeGraphProjection = false
    private var userMDGenerator: UserMDGenerator?
    private var spotlightHook: (@Sendable (StoredMemory, Bool) -> Void)?
    private var knowledgeGraphHook: (@Sendable (StoredMemory, Bool) -> Void)?

    // MARK: - R5 fast recall: in-actor candidate cache + data_version net
    //
    // recall() and nearestActiveNeighbor() both brute-force scan the SAME
    // active-embedded candidate set every call (SELECT + row decode + embedding
    // Data->[Float] decode + per-row l2norm). That set changes only when a
    // `memories` row mutates, so decode it ONCE, precompute each norm, and reuse
    // it until the table changes. Ranking stays byte-identical: only the SOURCE
    // of candidates+norms changes (cache vs. re-decode). Two-layer invalidation:
    //   (1) a generation counter bumped by every in-actor write to `memories`
    //       (the explicit belt — see invalidateRecallCache() call sites), and
    //   (2) a `PRAGMA data_version` snapshot (see recallCandidates()). SQLite
    //       bumps data_version whenever ANOTHER connection commits to the file —
    //       which catches BOTH the actor's own dbPool writes AND the out-of-band
    //       consolidation swap (MemoryConsolidationGate.transactionalTableSwap
    //       runs on its OWN DatabaseQueue on the live path and holds no reference
    //       to this actor, so the counter alone cannot see it). The cache is
    //       reused only when BOTH the generation AND data_version match.
    //
    // Why a dedicated `versionProbe` connection rather than dbPool.read for the
    // pragma: SQLite's data_version integer is per-connection and NOT comparable
    // across different connections. dbPool serves reads from a pool of reader
    // connections, so two sequential dbPool.read pragma calls can land on
    // different connections and return incomparable values — yielding either
    // false rebuilds (breaking the exact-one-rebuild guarantee) or, worse, a
    // false match after an external swap. A single serialized DatabaseQueue
    // guarantees a stable, comparable data_version sequence. It only ever reads.
    private struct RecallCandidate {
        let memory: StoredMemory
        let norm: Float            // precomputed Self.l2norm(embedding) — bit-identical to per-turn recompute
    }
    private struct RecallCache {
        let candidates: [RecallCandidate]
        let generation: Int
        let dataVersion: Int64
        let embeddingEpoch: String?
    }
    private let versionProbe: DatabaseQueue
    private var recallCache: RecallCache?
    private var recallGeneration: Int = 0
    /// Test-only observability (internal getter, reached via @testable): how many
    /// times the candidate cache was (re)built from SQL. A cache hit does NOT bump it.
    private(set) var recallCacheRebuildCount: Int = 0

    /// Attach a USER.md generator so mutations debounce-regenerate the file.
    public func attachUserMDGenerator(_ generator: UserMDGenerator) {
        self.userMDGenerator = generator
        if !replayedStartupUserProjection {
            replayedStartupUserProjection = true
            for persona in Set(startupBoundEvictions.map(\.personaId)) {
                pokeUserMDRegen(persona: persona)
            }
        }
    }

    /// Install a Spotlight-index hook. Fires for every insert/update/
    /// acceptProposal/archive/delete with `deleted` derived from final row
    /// projection eligibility.
    public func attachSpotlightHook(_ hook: @escaping @Sendable (StoredMemory, Bool) -> Void) {
        self.spotlightHook = hook
        if !replayedStartupSpotlightProjection {
            replayedStartupSpotlightProjection = true
            for evicted in startupBoundEvictions { hook(evicted, true) }
        }
    }

    /// Install a Knowledge Graph indexing hook. Fires for every insert/update/
    /// acceptProposal/archive/delete with `deleted` derived from final row
    /// projection eligibility.
    public func attachKnowledgeGraphHook(_ hook: @escaping @Sendable (StoredMemory, Bool) -> Void) {
        self.knowledgeGraphHook = hook
        if !replayedStartupKnowledgeGraphProjection {
            replayedStartupKnowledgeGraphProjection = true
            for evicted in startupBoundEvictions { hook(evicted, true) }
        }
    }

    private func pokeUserMDRegen(persona: String) {
        guard let gen = userMDGenerator else { return }
        Task { try? await gen.requestRegeneration(persona: persona) }
    }

    private func pokeSpotlight(_ stored: StoredMemory, deleted: Bool) {
        spotlightHook?(stored, deleted)
    }

    private func pokeKnowledgeGraph(_ stored: StoredMemory, deleted: Bool) {
        knowledgeGraphHook?(stored, deleted)
    }

    private func pokeDerivedState(_ stored: StoredMemory, deleted: Bool) async {
        let change = DerivedSourceChange(
            namespace: "memory-v2",
            stableID: stored.id,
            operation: deleted ? .removed : .changed,
            reason: deleted ? "memory_projection_removed" : "memory_projection_changed"
        )
        await DerivedStateInvalidationCenter.shared.publish(change)
    }

    private static func projectionEligible(_ stored: StoredMemory) -> Bool {
        stored.status == "active" && MemoryLifecycle.isRecallEligible(stored.lifecycle)
    }

    private func pokeProjectionHooks(_ stored: StoredMemory) async {
        let deleted = !Self.projectionEligible(stored)
        pokeSpotlight(stored, deleted: deleted)
        pokeKnowledgeGraph(stored, deleted: deleted)
        await pokeDerivedState(stored, deleted: deleted)
    }

    public init(dataRoot: URL, memoryLimit: Int = memoryStoredRowCap) throws {
        let dir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.sqlite")
        self.path = path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(2)
        // Bound the WAL: without a journal_size_limit the -wal file persists
        // at its high-water mark after checkpoints (observed 2026-07-02: 3 MB
        // WAL against a 1.5 MB database). 4 MB never truncates mid-burst at
        // Agent-scale but stops unbounded high-water growth. Set via
        // prepareDatabase so every pool connection carries it.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_size_limit = 4194304")
        }
        let pool = try DatabasePool(path: path.path, configuration: config)
        try MemoryStorage.migrator.migrate(pool)
        let boundedLimit = max(1, memoryLimit)
        let startupEvictions = try pool.write { db in
            try Self.pruneMemoriesToBound(in: db, limit: boundedLimit)
        }
        self.dbPool = pool
        self.memoryLimit = boundedLimit
        self.startupBoundEvictions = startupEvictions
        // Dedicated single connection for the recall-cache data_version net.
        self.versionProbe = try DatabaseQueue(path: path.path, configuration: config)
        Self.publishStartupBoundEvictions(startupEvictions, memoryPath: path)
    }

    /// Ephemeral store for tests.
    public init(
        inMemoryName: String = "MemoryStorage-\(UUID().uuidString)",
        memoryLimit: Int = memoryStoredRowCap
    ) throws {
        let safeName = inMemoryName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.sqlite")
        self.path = path
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(2)
        let pool = try DatabasePool(path: path.path, configuration: config)
        try MemoryStorage.migrator.migrate(pool)
        let boundedLimit = max(1, memoryLimit)
        let startupEvictions = try pool.write { db in
            try Self.pruneMemoriesToBound(in: db, limit: boundedLimit)
        }
        self.dbPool = pool
        self.memoryLimit = boundedLimit
        self.startupBoundEvictions = startupEvictions
        // Dedicated single connection for the recall-cache data_version net.
        self.versionProbe = try DatabaseQueue(path: path.path, configuration: config)
        Self.publishStartupBoundEvictions(startupEvictions, memoryPath: path)
    }

    // MARK: - Migrator

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // F3 (fix3): v2 migration adds KG tables as ADDITIVE groundwork for the
        // eventual knowledge_graph.json → SQLite cutover. The view + reader still
        // read from the JSON file (daemon co-located, deterministic W04 flush
        // handshake guarantees freshness); flipping the source of truth requires
        // coordinating with daemon writes (cross-process flock contract) and
        // happens in a follow-up wave. Schema is here so a future migrator pass
        // can stream the JSON entities + edges in once the daemon write-path is
        // ported. No code currently reads these tables.
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE memories (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  persona_id TEXT NOT NULL DEFAULT 'NativeAgent',
                  source TEXT,
                  confidence REAL DEFAULT 1.0,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  embedding BLOB,
                  status TEXT NOT NULL DEFAULT 'active',
                  metadata_json TEXT
                );
                CREATE INDEX idx_memories_persona ON memories(persona_id, status);
                CREATE INDEX idx_memories_created ON memories(created_at);
                CREATE INDEX idx_memories_source ON memories(source);

                CREATE TABLE proposals (
                  id TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  persona_id TEXT NOT NULL DEFAULT 'NativeAgent',
                  source TEXT,
                  staged_at TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'pending',
                  resolved_at TEXT,
                  rejection_reason TEXT,
                  embedding BLOB,
                  metadata_json TEXT
                );
                CREATE INDEX idx_proposals_status ON proposals(status, staged_at);

                CREATE TABLE tombstones (
                  content_hash TEXT PRIMARY KEY,
                  content TEXT NOT NULL,
                  rejected_at TEXT NOT NULL,
                  reason TEXT
                );
                CREATE INDEX idx_tombstones_rejected ON tombstones(rejected_at);
            """)
        }
        m.registerMigration("v2_knowledge_graph") { db in
            try db.execute(sql: """
                CREATE TABLE kg_entities (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  type TEXT NOT NULL DEFAULT 'concept',
                  summary TEXT,
                  aliases_json TEXT,
                  mention_count INTEGER DEFAULT 0,
                  first_seen TEXT,
                  last_seen TEXT,
                  provenance TEXT,
                  metadata_json TEXT
                );
                CREATE INDEX idx_kg_entities_type ON kg_entities(type);
                CREATE INDEX idx_kg_entities_last_seen ON kg_entities(last_seen);

                CREATE TABLE kg_relationships (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  from_id TEXT NOT NULL,
                  to_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  weight REAL,
                  mention_count INTEGER DEFAULT 0,
                  provenance TEXT,
                  metadata_json TEXT,
                  UNIQUE(from_id, to_id, type)
                );
                CREATE INDEX idx_kg_rel_from ON kg_relationships(from_id);
                CREATE INDEX idx_kg_rel_to ON kg_relationships(to_id);
            """)
        }
        // v3 (2026-06-09): recall access counters. Additive — existing rows
        // default to use_count 0 / last_used_at NULL, so old code that ignores
        // these columns is unaffected. `use_count` is a real column (not
        // metadata JSON) so recall can increment it atomically without a
        // read-modify-write race under concurrent recalls. See the
        // memory-recall-correctness build plan (#0).
        m.registerMigration("v3_recall_counters") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE memories ADD COLUMN last_used_at TEXT;
                CREATE INDEX idx_memories_last_used ON memories(last_used_at);
            """)
        }
        // v4 (2026-06-09): semantic tombstones. Additive nullable column —
        // legacy tombstone rows keep NULL and remain exact-hash-only; new
        // tombstones store the claim's embedding so paraphrases of a deleted
        // claim can be blocked (memory-semantics-wave1, lane T).
        m.registerMigration("v4_tombstone_embeddings") { db in
            try db.execute(sql: "ALTER TABLE tombstones ADD COLUMN embedding BLOB;")
        }
        // v5 (2026-06-20): explicit lifecycle/confidence hygiene. `status`
        // remains the coarse storage state (active/archived); lifecycle carries
        // fact quality: confirmed, temporary, inferred, stale, corrected,
        // contradicted, or deleted. Additive default keeps legacy rows confirmed.
        m.registerMigration("v5_memory_lifecycle") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'confirmed';
                CREATE INDEX idx_memories_lifecycle ON memories(lifecycle);
            """)
        }
        // v6 (2026-07-14): vector-space identity. Legacy vectors remain
        // nullable/unverified until a full-corpus candidate is embedded and
        // atomically activated; migration never guesses their provenance.
        m.registerMigration("v6_embedding_epochs") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN embedding_epoch TEXT;
                ALTER TABLE proposals ADD COLUMN embedding_epoch TEXT;
                ALTER TABLE tombstones ADD COLUMN embedding_epoch TEXT;
                CREATE INDEX idx_memories_embedding_epoch ON memories(embedding_epoch);
                CREATE INDEX idx_proposals_embedding_epoch ON proposals(embedding_epoch);
                CREATE INDEX idx_tombstones_embedding_epoch ON tombstones(embedding_epoch);

                CREATE TABLE memory_embedding_state (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  active_epoch TEXT,
                  previous_epoch TEXT,
                  activated_at TEXT,
                  rollback_available INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO memory_embedding_state (id) VALUES (1);

                CREATE TABLE memory_embedding_previous (
                  kind TEXT NOT NULL,
                  row_id TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  embedding BLOB,
                  embedding_epoch TEXT,
                  PRIMARY KEY (kind, row_id)
                );
            """)
        }
        // v7: nullable temporal validity and evidence lineage. Additive only;
        // no historical row is assigned invented dates or evidence.
        m.registerMigration("v7_temporal_evidence") { db in
            try db.execute(sql: """
                ALTER TABLE memories ADD COLUMN valid_from TEXT;
                ALTER TABLE memories ADD COLUMN valid_to TEXT;
                ALTER TABLE memories ADD COLUMN observed_at TEXT;
                ALTER TABLE memories ADD COLUMN evidence_json TEXT;
                CREATE INDEX idx_memories_valid_from ON memories(valid_from);
                CREATE INDEX idx_memories_valid_to ON memories(valid_to);
                CREATE INDEX idx_memories_observed_at ON memories(observed_at);
            """)
        }
        return m
    }

    // MARK: - Hard memory bound

    /// Delete the least valuable rows until the table satisfies `limit`.
    /// Capacity eviction is forgetting, not rejection, so it intentionally does
    /// not create tombstones. Call only while already holding the canonical
    /// SQLite write transaction.
    @discardableResult
    static func pruneMemoriesToBound(
        in db: Database,
        limit: Int = memoryStoredRowCap,
        preservingIDs: Set<String> = []
    ) throws -> [StoredMemory] {
        let boundedLimit = max(1, limit)
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
        let overflow = count - boundedLimit
        guard overflow > 0 else { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM memories").map(Self.decodeMemory)

        let ordered = rows.sorted { lhs, rhs in
            let lhsRank = retentionEvictionRank(lhs)
            let rhsRank = retentionEvictionRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsUse = lhs.lastUsedAt ?? lhs.updatedAt
            let rhsUse = rhs.lastUsedAt ?? rhs.updatedAt
            if lhsUse != rhsUse { return lhsUse < rhsUse }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
        var evicted = Array(ordered.filter { !preservingIDs.contains($0.id) }.prefix(overflow))
        if evicted.count < overflow {
            let already = Set(evicted.map(\.id))
            evicted += ordered.filter { !already.contains($0.id) }.prefix(overflow - evicted.count)
        }
        guard !evicted.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: evicted.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM memories WHERE id IN (\(placeholders))",
            arguments: StatementArguments(evicted.map(\.id))
        )
        return evicted
    }

    /// Lower ranks are evicted first. Archived and recall-excluded rows are
    /// disposable before active tissue; temporary/stale facts precede ordinary
    /// confirmed facts; pinned and identity memories are protected until every
    /// other class is exhausted. If protected rows alone exceed the hard cap,
    /// their oldest rows are still evicted so the bound remains real.
    private static func retentionEvictionRank(_ memory: StoredMemory) -> Int {
        if memory.status != "active" { return 0 }
        let lifecycle = MemoryLifecycle.normalized(memory.lifecycle)
        if MemoryLifecycle.recallExcluded.contains(lifecycle) { return 1 }
        if lifecycle == MemoryLifecycle.temporary
            || lifecycle == MemoryLifecycle.inferred
            || lifecycle == MemoryLifecycle.stale {
            return 2
        }
        if case .object(let metadata)? = memory.metadata {
            if case .bool(true)? = metadata["pinned"] { return 4 }
            if case .string(let kind)? = metadata["kind"],
               kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "identity" {
                return 4
            }
        }
        return 3
    }

    private static func publishStartupBoundEvictions(
        _ evicted: [StoredMemory],
        memoryPath: URL
    ) {
        guard !evicted.isEmpty else { return }
        NSLog("MemoryV2 bound: pruned %d overflow row(s) while opening %@",
              evicted.count, memoryPath.lastPathComponent)
        Task {
            for memory in evicted {
                await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                    namespace: "memory-v2",
                    stableID: memory.id,
                    operation: .removed,
                    reason: "memory_capacity_evicted_on_open"
                ))
            }
            await recordBoundEvictions(evicted, memoryPath: memoryPath, reason: "store_open")
        }
    }

    private func handleBoundEvictions(_ evicted: [StoredMemory], reason: String) async {
        guard !evicted.isEmpty else { return }
        invalidateRecallCache()
        for persona in Set(evicted.map(\.personaId)) { pokeUserMDRegen(persona: persona) }
        for memory in evicted {
            pokeSpotlight(memory, deleted: true)
            pokeKnowledgeGraph(memory, deleted: true)
            await pokeDerivedState(memory, deleted: true)
        }
        await Self.recordBoundEvictions(evicted, memoryPath: path, reason: reason)
    }

    static func recordBoundEvictions(
        _ evicted: [StoredMemory],
        memoryPath: URL,
        reason: String
    ) async {
        guard !evicted.isEmpty else { return }
        let receipt: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("memory.capacity_eviction"),
            "reason": .string(reason),
            "count": .int(Int64(evicted.count)),
            "memoryIds": .array(evicted.prefix(100).map { .string($0.id) }),
            "createdAt": .string(nowISO8601()),
        ])
        let receiptPath = memoryPath.deletingLastPathComponent()
            .appendingPathComponent("retention_receipts.jsonl")
        do {
            try await appendJSONLCapped(
                receipt,
                to: receiptPath,
                using: SwiftNativePersistenceCore(),
                maxLines: JSONLLineCaps.memoryRetentionReceipts,
                logLabel: "MemoryV2.retention"
            )
        } catch {
            NSLog("MemoryV2 bound: retention receipt failed: %@", String(describing: error))
        }
    }

    // MARK: - Memory CRUD

    @discardableResult
    public func insertMemory(_ memory: StoredMemory) async throws -> StoredMemory {
        let evicted = try await dbPool.write { db -> [StoredMemory] in
            try Self.validateTemporalEvidence(memory)
            try Self.requireWritableEpoch(
                in: db,
                vector: memory.embedding,
                epoch: memory.embeddingEpoch
            )
            try db.execute(sql: """
                INSERT INTO memories
                  (id, content, persona_id, source, confidence,
                   created_at, updated_at, embedding, status, metadata_json,
                   use_count, last_used_at, lifecycle, embedding_epoch,
                   valid_from, valid_to, observed_at, evidence_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                memory.id, memory.content, memory.personaId, memory.source, memory.confidence,
                memory.createdAt, memory.updatedAt,
                Self.encodeEmbedding(memory.embedding),
                memory.status,
                Self.encodeMetadata(memory.metadata),
                memory.useCount, memory.lastUsedAt,
                MemoryLifecycle.normalized(memory.lifecycle),
                memory.embeddingEpoch,
                memory.validFrom, memory.validTo, memory.observedAt,
                Self.encodeMetadata(memory.evidence)
            ])
            return try Self.pruneMemoriesToBound(
                in: db,
                limit: memoryLimit,
                preservingIDs: [memory.id]
            )
        }
        invalidateRecallCache()
        pokeUserMDRegen(persona: memory.personaId)
        await pokeProjectionHooks(memory)
        await handleBoundEvictions(evicted, reason: "insert")
        return memory
    }

    public func memory(id: String) async throws -> StoredMemory? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return Self.decodeMemory(row)
        }
    }

    public func updateMemory(id: String, patch: MemoryPatch) async throws -> StoredMemory? {
        let updated = try await dbPool.write { db -> StoredMemory? in
            guard var existing = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]).map(Self.decodeMemory) else {
                return nil
            }
            if let c = patch.content { existing.content = c }
            if let s = patch.source { existing.source = s }
            if let conf = patch.confidence { existing.confidence = conf }
            if let e = patch.embedding { existing.embedding = e }
            if patch.embedding != nil { existing.embeddingEpoch = patch.embeddingEpoch }
            if let st = patch.status { existing.status = st }
            if let lifecycle = patch.lifecycle { existing.lifecycle = MemoryLifecycle.normalized(lifecycle) }
            if let validFrom = patch.validFrom { existing.validFrom = validFrom }
            if let validTo = patch.validTo { existing.validTo = validTo }
            if let observedAt = patch.observedAt { existing.observedAt = observedAt }
            if let evidence = patch.evidence { existing.evidence = evidence }
            if let m = patch.metadata { existing.metadata = m }
            existing.updatedAt = Self.nowISO8601()
            try Self.validateTemporalEvidence(existing)
            try Self.requireWritableEpoch(
                in: db,
                vector: patch.embedding,
                epoch: patch.embeddingEpoch
            )
            try db.execute(sql: """
                UPDATE memories SET
                  content = ?, source = ?, confidence = ?,
                  updated_at = ?, embedding = ?, embedding_epoch = ?, status = ?, lifecycle = ?,
                  valid_from = ?, valid_to = ?, observed_at = ?, evidence_json = ?, metadata_json = ?
                WHERE id = ?
            """, arguments: [
                existing.content, existing.source, existing.confidence,
                existing.updatedAt,
                Self.encodeEmbedding(existing.embedding),
                existing.embeddingEpoch,
                existing.status,
                existing.lifecycle,
                existing.validFrom,
                existing.validTo,
                existing.observedAt,
                Self.encodeMetadata(existing.evidence),
                Self.encodeMetadata(existing.metadata),
                existing.id
            ])
            return existing
        }
        if let u = updated {
            invalidateRecallCache()
            pokeUserMDRegen(persona: u.personaId)
            await pokeProjectionHooks(u)
        }
        return updated
    }

    @discardableResult
    public func deleteMemory(id: String) async throws -> Bool {
        // Fetch the row first so the Spotlight + USER.md hooks can fire
        // with the actual persona/content even after deletion.
        let result: (deleted: Bool, row: StoredMemory?) = try await dbPool.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id]).map(Self.decodeMemory)
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            let deleted = db.changesCount > 0
            if deleted, let row {
                // Carry the deleted memory's own embedding into the tombstone so
                // the semantic gate can block paraphrased resurrections (wave1 T2).
                try Self.upsertTombstone(
                    db: db, content: row.content, reason: "deleted_memory",
                    embedding: row.embedding,
                    embeddingEpoch: row.embeddingEpoch
                )
            }
            return (deleted, row)
        }
        if result.deleted, let row = result.row {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            pokeSpotlight(row, deleted: true)
            pokeKnowledgeGraph(row, deleted: true)
            await pokeDerivedState(row, deleted: true)
        }
        return result.deleted
    }

    public func listMemories(
        persona: String? = nil,
        status: String? = "active",
        limit: Int? = nil
    ) async throws -> [StoredMemory] {
        try await dbPool.read { db in
            var sql = "SELECT * FROM memories WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let persona { sql += " AND persona_id = ?"; args.append(persona) }
            if let status { sql += " AND status = ?"; args.append(status) }
            if status == "active" {
                sql += " AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')"
            }
            sql += " ORDER BY created_at DESC"
            if let limit { sql += " LIMIT ?"; args.append(limit) }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(Self.decodeMemory)
        }
    }

    // MARK: - Recall candidate cache (R5)

    /// Bump the in-actor cache generation and drop the cached candidates. Called
    /// after every successful in-actor write that changes the `memories` table.
    /// This is the explicit belt; the data_version net in recallCandidates() is
    /// the suspenders that additionally catches the out-of-band consolidation
    /// swap (and any mutation site missed here).
    private func invalidateRecallCache() {
        recallGeneration += 1
        recallCache = nil
    }

    /// The decoded, norm-precomputed active-embedded candidate set for ALL
    /// personas, rebuilt from SQL only when the table changed. Persona /
    /// `excluding` filtering is applied per-call by the callers, so recall and
    /// nearestActiveNeighbor share ONE cache (persona/excluding are the only
    /// per-call SQL variations and both are pure row filters that preserve the
    /// underlying rowid scan order — behaviour stays identical to the old
    /// per-call scan). Norms are precomputed with the EXISTING scalar l2norm so
    /// cached norms are bit-identical to the old per-turn recompute.
    private func recallCandidates(queryEpoch: MemoryEmbeddingEpoch?) async throws -> [RecallCandidate] {
        let activeEpoch = try await dbPool.read { db in
            try Self.embeddingEpochState(in: db).activeEpoch
        }
        if let activeEpoch, queryEpoch?.rawValue != activeEpoch {
            return []
        }
        // Read data_version BEFORE fetching candidates: this guarantees the
        // recorded version is never NEWER than the candidate snapshot, so a
        // write racing between the two reads (actor reentrancy) can only cause a
        // harmless extra rebuild next time — never a stale-serving false match.
        let liveDataVersion = try await versionProbe.read { db in
            try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0
        }
        if let cache = recallCache,
           cache.generation == recallGeneration,
           cache.dataVersion == liveDataVersion,
           cache.embeddingEpoch == activeEpoch {
            return cache.candidates
        }
        // Rebuild: ONE query — the same candidate SET the old recall/
        // nearestActiveNeighbor scans used, minus the persona / excluding
        // clause. ORDER BY rowid makes the scan order EXPLICIT: the old
        // ORDER-BY-less scans got planner-dependent order (a different index
        // could reorder equal-score ties, dedup preference, and BM25 doc
        // indices between releases) — pinning rowid order makes tie-breaking
        // deterministic and matches the natural full-scan order.
        let candidates = try await dbPool.read { db -> [RecallCandidate] in
            var sql = """
                SELECT * FROM memories
                WHERE embedding IS NOT NULL
                  AND status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
            """
            var arguments: StatementArguments = []
            if let activeEpoch {
                sql += " AND embedding_epoch = ?"
                arguments = [activeEpoch]
            }
            sql += " ORDER BY rowid"
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                let m = Self.decodeMemory(row)
                let norm = m.embedding.map(Self.l2norm) ?? 0
                return RecallCandidate(memory: m, norm: norm)
            }
        }
        // Growth guard: the cache holds the fully-decoded candidate set
        // (embeddings included). At Agent-scale (10³–10⁴ rows ≈ tens of MB)
        // that's the point of R5; past it, skip caching rather than balloon
        // resident memory — recall stays correct via the per-call scan path.
        if candidates.count <= 50_000 {
            recallCache = RecallCache(
                candidates: candidates,
                generation: recallGeneration,
                dataVersion: liveDataVersion,
                embeddingEpoch: activeEpoch
            )
        } else {
            recallCache = nil
        }
        recallCacheRebuildCount += 1
        return candidates
    }

    // MARK: - Recall (hybrid dense + lexical sweep)

    public func recall(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil,
        queryText: String? = nil,
        topK: Int,
        persona: String? = nil
    ) async throws -> [(memory: StoredMemory, similarity: Double)] {
        // R5: pull the shared cached candidate set, then apply the persona
        // filter in-memory. A single-persona equality filter over the full
        // rowid-ordered scan yields the same rows in the same order the old
        // persona-clause SQL returned, so BM25 idx alignment + ranking stay
        // byte-identical.
        let allCandidates = try await recallCandidates(queryEpoch: queryEpoch)
        let candidates = persona == nil
            ? allCandidates
            : allCandidates.filter { $0.memory.personaId == persona }
        let queryNorm = Self.l2norm(query)
        // Sweep R4 A5: a COLD embedder (MiniLM not yet warm on the Neural
        // Engine — reliably the state on the first message after launch) hands
        // us a zero/empty vector, and this used to return [] — total recall
        // silence with nothing but a trace flag to show for it. Degrade to the
        // lexical lane instead: a keyword ranking is worse than semantic, and
        // enormously better than nothing.
        guard queryNorm > 0 else {
            return try await recallByKeyword(
                queryText: queryText, topK: topK, persona: persona
            )
        }
        let now = Date()
        let lexicalScores = MemoryRecallScoring.normalizedBM25Scores(
            query: queryText,
            documents: candidates.map(\.memory.content)
        )
        var scored: [(StoredMemory, Double)] = []
        scored.reserveCapacity(candidates.count)
        for (idx, candidate) in candidates.enumerated() {
            let m = candidate.memory
            guard let e = m.embedding, e.count == query.count else { continue }
            let n = candidate.norm
            guard n > 0 else { continue }
            var dot: Float = 0
            for i in 0..<e.count { dot += e[i] * query[i] }
            let sim = Double(dot) / (Double(queryNorm) * Double(n))
            let lexicalBoost = (idx < lexicalScores.count)
                ? memoryBM25LexicalBoost * lexicalScores[idx]
                : 0
            // Wave1 D-lane: kind-scoped recency decay — RANK only, inside the
            // scan that already runs (zero added read cost). Exempt kinds and
            // legacy nil-kind records get factor 1.0 (unchanged behavior).
            let decay = MemoryRecallScoring.decayFactor(
                kind: MemoryRecallScoring.kind(of: m.metadata),
                updatedAt: m.updatedAt,
                now: now
            )
            scored.append((m, (sim + lexicalBoost) * decay * MemoryLifecycle.rankingFactor(m.lifecycle)))
        }
        scored.sort { $0.1 > $1.1 }
        return Self.uniqueRecallResults(scored, limit: topK)
    }

    // MARK: - Keyword recall fallback (sweep R4, finding A5)

    /// How many candidate rows the LIKE prefilter may pull before BM25 ranking.
    /// The dense lane scans a cached in-memory candidate set; this lane hits
    /// SQL, so it stays explicitly bounded.
    private static let keywordRecallCandidateCap = 400

    /// Lexical-only recall for when NO usable query embedding exists (cold
    /// embedder, embedder failure, epoch mismatch). Selection is a
    /// case-insensitive LIKE over active rows for any query token; ranking is
    /// the SAME normalized BM25 the hybrid lane already blends in, times the
    /// same lifecycle factor. Crucially this does NOT require `embedding IS NOT
    /// NULL`, so it also answers on a store whose vectors have not been
    /// backfilled yet.
    ///
    /// Callers mark these rows as fallback-sourced (see `MemoryV2.recall`) so
    /// the trace never presents keyword hits as semantic ones.
    public func recallByKeyword(
        queryText: String?,
        topK: Int,
        persona: String? = nil
    ) async throws -> [(memory: StoredMemory, similarity: Double)] {
        guard topK > 0 else { return [] }
        let tokens = Array(Set(MemoryRecallScoring.lexicalTokens(queryText ?? "")))
        guard !tokens.isEmpty else { return [] }
        let candidateCap = Self.keywordRecallCandidateCap
        let candidates = try await dbPool.read { db -> [StoredMemory] in
            var sql = """
                SELECT * FROM memories
                WHERE status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
            """
            var arguments: [DatabaseValueConvertible] = []
            if let persona {
                sql += " AND persona_id = ?"
                arguments.append(persona)
            }
            let likeClauses = tokens.map { _ in "content LIKE ? ESCAPE '\\'" }
            sql += " AND (" + likeClauses.joined(separator: " OR ") + ")"
            for token in tokens {
                arguments.append("%" + Self.escapedLikePattern(token) + "%")
            }
            sql += " ORDER BY rowid LIMIT ?"
            arguments.append(candidateCap)
            let rows = try Row.fetchAll(
                db, sql: sql, arguments: StatementArguments(arguments)
            )
            return rows.map(Self.decodeMemory)
        }
        guard !candidates.isEmpty else { return [] }
        let lexicalScores = MemoryRecallScoring.normalizedBM25Scores(
            query: queryText,
            documents: candidates.map(\.content)
        )
        let now = Date()
        var scored: [(StoredMemory, Double)] = []
        scored.reserveCapacity(candidates.count)
        for (idx, memory) in candidates.enumerated() {
            let lexical = idx < lexicalScores.count ? lexicalScores[idx] : 0
            guard lexical > 0 else { continue }
            let decay = MemoryRecallScoring.decayFactor(
                kind: MemoryRecallScoring.kind(of: memory.metadata),
                updatedAt: memory.updatedAt,
                now: now
            )
            scored.append(
                (memory, lexical * decay * MemoryLifecycle.rankingFactor(memory.lifecycle))
            )
        }
        scored.sort { $0.1 > $1.1 }
        return Self.uniqueRecallResults(scored, limit: topK)
    }

    /// Escape LIKE wildcards in a user-derived token so a query containing `%`
    /// or `_` cannot widen the prefilter into a full scan-and-match.
    private static func escapedLikePattern(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// U3 wave-2 item 4: top-1 nearest ACTIVE neighbor by RAW cosine — the
    /// same candidate scan as recall but WITHOUT the kind-scoped decay
    /// shaping, so the shadow dedup ledger records true geometry. (recall's
    /// score is sim * decayFactor; once kinds start carrying half-lives that
    /// product would silently contaminate the threshold-validation data.)
    /// WRITE-path helper only — the recall read path is untouched.
    /// `excluding` skips one row id at the SQL layer: the shadow observation
    /// runs detached AFTER the insert (fix-round finding 2), so the scan
    /// must not pair the just-inserted row with itself.
    public func nearestActiveNeighbor(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil,
        excluding excludedId: String? = nil
    ) async throws -> (memory: StoredMemory, cosine: Double)? {
        // R5: shared cached candidate set, `excluding` applied in-memory. The
        // full rowid-ordered scan minus one id is the same order the old
        // `id != ?` SQL returned, so the strict-`>` first-seen-wins tie-break on
        // raw cosine is preserved.
        let allCandidates = try await recallCandidates(queryEpoch: queryEpoch)
        let candidates = excludedId == nil
            ? allCandidates
            : allCandidates.filter { $0.memory.id != excludedId }
        let queryNorm = Self.l2norm(query)
        guard queryNorm > 0 else { return nil }
        var best: (StoredMemory, Double)? = nil
        for candidate in candidates {
            let m = candidate.memory
            guard let e = m.embedding, e.count == query.count else { continue }
            let n = candidate.norm
            guard n > 0 else { continue }
            var dot: Float = 0
            for i in 0..<e.count { dot += e[i] * query[i] }
            let cosine = Double(dot) / (Double(queryNorm) * Double(n))
            if best == nil || cosine > best!.1 { best = (m, cosine) }
        }
        return best.map { (memory: $0.0, cosine: $0.1) }
    }

    /// Archive a memory ONLY if it is still active and still has use_count == 0
    /// at write time. Closes the TOCTOU between the consolidator's snapshot
    /// read and its archive write: a recall bump landing in that window must
    /// veto the eviction (gpt-5.5 review finding 1). recall_count needs no
    /// re-check here — it is only mutated by the consolidator itself, which is
    /// single-flighted; use_count is the only concurrent writer.
    /// Returns true when the row was actually archived.
    @discardableResult
    public func archiveIfStillUnused(id: String) async throws -> Bool {
        let archivedRow = try await dbPool.write { db -> StoredMemory? in
            try db.execute(
                sql: """
                    UPDATE memories SET status = 'archived', updated_at = ?
                    WHERE id = ? AND status = 'active' AND use_count = 0
                """,
                arguments: [Self.nowISO8601(), id]
            )
            guard db.changesCount > 0 else { return nil }
            return try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                .map(Self.decodeMemory)
        }
        // Same side-effect hooks updateMemory fires — without these the
        // archived memory would stay in Spotlight/KG/USER.md as if active.
        if let row = archivedRow {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return archivedRow != nil
    }

    /// Record that these memories were just returned by recall — bump
    /// `use_count` and stamp `last_used_at`. ONE atomic UPDATE so concurrent
    /// recalls can't lose increments. Called fire-and-forget AFTER recall
    /// returns its hits, so it adds nothing to read latency (Agent's zero-read-
    /// cost constraint). No-op on empty input. Does NOT touch updated_at — a
    /// recall is access, not a content mutation, and bumping updated_at would
    /// corrupt recency ranking and reset the stale-age clock.
    public func recordRecallHits(ids: [String], at when: String = MemoryStorage.nowISO8601()) async throws {
        guard !ids.isEmpty else { return }
        try await dbPool.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var args: [DatabaseValueConvertible] = [when]
            args.append(contentsOf: ids)
            try db.execute(
                sql: "UPDATE memories SET use_count = use_count + 1, last_used_at = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
        // recordRecallHits mutates use_count/last_used_at, which are carried in
        // the cached StoredMemory values — a stale cache would return stale
        // counters. Invalidate so the next recall reflects the bump.
        invalidateRecallCache()
    }

    // MARK: - Proposals

    @discardableResult
    public func insertProposal(_ proposal: StoredProposal) async throws -> StoredProposal {
        try await dbPool.write { db in
            try Self.requireWritableEpoch(
                in: db,
                vector: proposal.embedding,
                epoch: proposal.embeddingEpoch
            )
            try db.execute(sql: """
                INSERT INTO proposals
                  (id, content, persona_id, source, staged_at, status,
                   resolved_at, rejection_reason, embedding, metadata_json, embedding_epoch)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                proposal.id, proposal.content, proposal.personaId, proposal.source,
                proposal.stagedAt, proposal.status,
                proposal.resolvedAt, proposal.rejectionReason,
                Self.encodeEmbedding(proposal.embedding),
                Self.encodeMetadata(proposal.metadata),
                proposal.embeddingEpoch
            ])
        }
        return proposal
    }

    public func acceptProposal(id: String) async throws -> StoredMemory {
        // The semantic-gate rejection must COMMIT, so the write closure returns
        // an outcome instead of throwing mid-transaction (a throw inside
        // dbPool.write rolls back everything — including the rejection row).
        enum AcceptOutcome {
            case accepted(StoredMemory, evicted: [StoredMemory])
            case tombstoned
        }
        let outcome = try await dbPool.write { db -> AcceptOutcome in
            guard let proposal = try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]).map(Self.decodeProposal) else {
                throw MemoryStorageError.notFound(id)
            }
            guard proposal.status == "pending" else {
                throw MemoryStorageError.alreadyResolved(id)
            }
            // Semantic tombstone gate at acceptance, in the SAME transaction
            // (wave1 T3): a proposal that paraphrases a tombstoned claim must
            // not promote even if its exact hash differs. Legacy/no-embedding
            // proposals skip (the exact-hash gate upstream still covers them).
            if let pe = proposal.embedding,
               try Self.tombstoneMatch(
                   db: db,
                   query: pe,
                   queryEpoch: proposal.embeddingEpoch,
                   threshold: memoryTombstoneMatchThreshold
               ) {
                try db.execute(sql: """
                    UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                    WHERE id = ?
                """, arguments: [Self.nowISO8601(), "tombstoned: semantic match to a rejected claim", id])
                return .tombstoned
            }
            let now = Self.nowISO8601()
            // #1: stamp the extractor's real confidence on the memory instead of
            // hardcoding 1.0, and keep `kind` in the memory metadata. The signal
            // rides in proposal.metadata.{confidence,kind}; default to 1.0 when
            // absent (legacy proposals / consolidator durability path).
            let proposalMeta: [String: JSONValue] = {
                if case .object(let o)? = proposal.metadata { return o }
                return [:]
            }()
            let stampedConfidence: Double = {
                // Accept double / int / numeric-string forms and clamp to 0...1
                // (gpt-5.5 review finding 2: a string "0.85" must not silently
                // overtrust to 1.0). Absent or unparseable → 1.0 (legacy default).
                let raw: Double? = {
                    switch proposalMeta["confidence"] {
                    case .double(let d)?: return d
                    case .int(let i)?: return Double(i)
                    case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
                    default: return nil
                    }
                }()
                guard let raw else { return 1.0 }
                return min(max(raw, 0.0), 1.0)
            }()
            let mem = StoredMemory(
                id: proposal.id,
                content: proposal.content,
                personaId: proposal.personaId,
                source: proposal.source,
                confidence: stampedConfidence,
                createdAt: now,
                updatedAt: now,
                embedding: proposal.embedding,
                embeddingEpoch: proposal.embeddingEpoch,
                status: "active",
                validFrom: Self.metadataString(proposalMeta, "valid_from", fallback: "validFrom"),
                validTo: Self.metadataString(proposalMeta, "valid_to", fallback: "validTo"),
                observedAt: Self.metadataString(proposalMeta, "observed_at", fallback: "observedAt"),
                evidence: proposalMeta["evidence"],
                // U3 wave-2 item 5a: promotion is a NEW write — proposals
                // whose extractor carried no kind get the semantics-neutral
                // default ("general" → decayFactor 1.0, no supersession).
                // Extractor-provided kinds pass through untouched.
                metadata: MemoryKindStamp.stampingDefaultKind(proposal.metadata)
            )
            try Self.validateTemporalEvidence(mem)
            try db.execute(sql: """
                INSERT INTO memories
                  (id, content, persona_id, source, confidence,
                   created_at, updated_at, embedding, status, metadata_json, lifecycle, embedding_epoch,
                   valid_from, valid_to, observed_at, evidence_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                mem.id, mem.content, mem.personaId, mem.source, mem.confidence,
                mem.createdAt, mem.updatedAt,
                Self.encodeEmbedding(mem.embedding),
                mem.status,
                Self.encodeMetadata(mem.metadata),
                mem.lifecycle,
                mem.embeddingEpoch,
                mem.validFrom, mem.validTo, mem.observedAt,
                Self.encodeMetadata(mem.evidence)
            ])
            try db.execute(sql: """
                UPDATE proposals SET status = 'accepted', resolved_at = ? WHERE id = ?
            """, arguments: [now, id])
            let evicted = try Self.pruneMemoriesToBound(
                in: db,
                limit: memoryLimit,
                preservingIDs: [mem.id]
            )
            return .accepted(mem, evicted: evicted)
        }
        switch outcome {
        case .tombstoned:
            throw MemoryStorageError.tombstoned(id)
        case .accepted(let result, let evicted):
            invalidateRecallCache()
            pokeUserMDRegen(persona: result.personaId)
            await pokeProjectionHooks(result)
            await handleBoundEvictions(evicted, reason: "proposal_acceptance")
            return result
        }
    }

    /// Wave1 S-lane: archive an older single-valued fact superseded by a newer
    /// one. ARCHIVE, never delete — supersession is demotion, not erasure
    /// (Agent's canon). Provenance {superseded_by, superseded_at} lands in
    /// metadata. Conditional on still-active so a concurrent change vetoes.
    @discardableResult
    public func archiveSuperseded(id: String, by newerId: String) async throws -> Bool {
        let archivedRow = try await dbPool.write { db -> StoredMemory? in
            guard var row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ? AND status = 'active'", arguments: [id]).map(Self.decodeMemory) else {
                return nil
            }
            var meta: [String: JSONValue] = [:]
            if case .object(let existing)? = row.metadata { meta = existing }
            meta["superseded_by"] = .string(newerId)
            meta["superseded_at"] = .string(Self.nowISO8601())
            row.metadata = .object(meta)
            row.status = "archived"
            row.updatedAt = Self.nowISO8601()
            try db.execute(sql: """
                UPDATE memories SET status = 'archived', updated_at = ?, metadata_json = ?
                WHERE id = ? AND status = 'active'
            """, arguments: [row.updatedAt, Self.encodeMetadata(row.metadata), id])
            return db.changesCount > 0 ? row : nil
        }
        if let row = archivedRow {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return archivedRow != nil
    }

    /// R13: first-class correction lineage. Marks `id` CORRECTED by `newerId`
    /// in ONE transaction: lifecycle → 'corrected' (recall-excluded via
    /// MemoryLifecycle.recallExcluded), queryable corrected_by/corrected_at
    /// (+ optional reason) in metadata, and an append-only correction_history
    /// entry so repeated corrections keep their full chain. Status is left
    /// untouched — lifecycle is the single source of correction state, and
    /// correction is demotion, not erasure (same canon as supersession).
    /// Conditional on the row being active and not already lifecycle-terminal;
    /// returns false when there was nothing eligible to correct.
    @discardableResult
    public func markCorrected(id: String, by newerId: String, reason: String? = nil) async throws -> Bool {
        let correctedRow = try await dbPool.write { db -> StoredMemory? in
            guard var row = try Row.fetchOne(db, sql: """
                SELECT * FROM memories
                WHERE id = ? AND status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
            """, arguments: [id]).map(Self.decodeMemory) else {
                return nil
            }
            let now = Self.nowISO8601()
            var meta: [String: JSONValue] = [:]
            if case .object(let existing)? = row.metadata { meta = existing }
            meta["corrected_by"] = .string(newerId)
            meta["corrected_at"] = .string(now)
            if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                meta["correction_reason"] = .string(reason)
            }
            var history: [JSONValue] = []
            if case .array(let existing)? = meta["correction_history"] { history = existing }
            history.append(.object([
                "by": .string(newerId),
                "at": .string(now),
                "reason": reason.map { JSONValue.string($0) } ?? .null,
            ]))
            meta["correction_history"] = .array(history)
            row.metadata = .object(meta)
            row.lifecycle = MemoryLifecycle.corrected
            row.updatedAt = now
            try db.execute(sql: """
                UPDATE memories SET lifecycle = ?, updated_at = ?, metadata_json = ?
                WHERE id = ? AND status = 'active'
                  AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
            """, arguments: [row.lifecycle, row.updatedAt, Self.encodeMetadata(row.metadata), id])
            return db.changesCount > 0 ? row : nil
        }
        if let row = correctedRow {
            invalidateRecallCache()
            pokeUserMDRegen(persona: row.personaId)
            await pokeProjectionHooks(row)
        }
        return correctedRow != nil
    }

    @discardableResult
    public func rejectProposal(id: String, reason: String?) async throws -> StoredTombstone {
        try await dbPool.write { db in
            guard let proposal = try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]).map(Self.decodeProposal) else {
                throw MemoryStorageError.notFound(id)
            }
            guard proposal.status == "pending" else {
                throw MemoryStorageError.alreadyResolved(id)
            }
            let now = Self.nowISO8601()
            let hash = Self.contentHash(proposal.content)
            // Carry the rejected proposal's embedding so paraphrases of the
            // rejected claim block at the semantic gate (wave1 T2).
            let tomb = StoredTombstone(
                contentHash: hash, content: proposal.content,
                rejectedAt: now, reason: reason, embedding: proposal.embedding,
                embeddingEpoch: proposal.embeddingEpoch
            )
            try Self.upsertTombstone(
                db: db, content: tomb.content, reason: tomb.reason,
                embedding: tomb.embedding,
                embeddingEpoch: tomb.embeddingEpoch
            )
            try db.execute(sql: """
                UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                WHERE id = ?
            """, arguments: [now, reason, id])
            return tomb
        }
    }

    /// Set a proposal's `status` (and optional `resolved_at`) without going
    /// through accept/reject. Used by MemoryConsolidator to record 'merged'
    /// outcomes for proposals deduped against existing active memories.
    /// No-op when the proposal id isn't found; doesn't enforce a pending
    /// precondition (consolidator is idempotent and tolerates re-runs).
    public func markProposalStatus(
        id: String,
        status: String,
        resolvedAt: String?
    ) async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE proposals SET status = ?, resolved_at = COALESCE(?, resolved_at)
                WHERE id = ?
            """, arguments: [status, resolvedAt, id])
        }
    }

    /// U5 W-G fix (2026-06-11): direct by-id lookup. `SwiftNativeMemoryV2.
    /// getProposal` used to call `listProposals(status: nil)` (full-table
    /// scan + decode) per lookup, which made the auto-accept sweep O(N²)
    /// over a multi-hundred-proposal backlog.
    public func getProposal(id: String) async throws -> StoredProposal? {
        try await dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM proposals WHERE id = ?",
                arguments: [id]
            ).map(Self.decodeProposal)
        }
    }

    /// 2026-07-21 audit fix: metadata rewrite for the pending-proposal
    /// content-hash dedup (SwiftNativeMemoryV2.propose merges session
    /// evidence / recurrence onto the surviving row instead of inserting a
    /// duplicate). PENDING-ONLY: a resolved proposal's metadata is part of
    /// its audit trail and must not be rewritten — a non-pending or missing
    /// id returns nil so the caller falls back to a fresh insert.
    @discardableResult
    public func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> StoredProposal? {
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE proposals SET metadata_json = ? WHERE id = ? AND status = 'pending'
            """, arguments: [Self.encodeMetadata(metadata), id])
            guard db.changesCount > 0 else { return nil }
            return try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id])
                .map(Self.decodeProposal)
        }
    }

    public func listProposals(status: String? = "pending") async throws -> [StoredProposal] {
        try await dbPool.read { db in
            var sql = "SELECT * FROM proposals"
            var args: [DatabaseValueConvertible] = []
            if let status { sql += " WHERE status = ?"; args.append(status) }
            sql += " ORDER BY staged_at DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(Self.decodeProposal)
        }
    }

    @discardableResult
    public func deleteProposal(id: String) async throws -> Bool {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM proposals WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: - Tombstones

    public func addTombstone(
        content: String,
        reason: String?,
        embedding: [Float]? = nil,
        embeddingEpoch: String? = nil
    ) async throws {
        try await dbPool.write { db in
            try Self.requireWritableEpoch(in: db, vector: embedding, epoch: embeddingEpoch)
            try Self.upsertTombstone(
                db: db,
                content: content,
                reason: reason,
                embedding: embedding,
                embeddingEpoch: embeddingEpoch
            )
        }
    }

    /// THE single tombstone writer (gpt-5.5 wave1 finding 3: every path must
    /// COALESCE-preserve an existing embedding when the new write carries none —
    /// a plain REPLACE from a nil-embedding caller would wipe the semantic key).
    private static func upsertTombstone(
        db: Database,
        content: String,
        reason: String?,
        embedding: [Float]?,
        embeddingEpoch: String?
    ) throws {
        let hash = contentHash(content)
        try db.execute(sql: """
            INSERT OR REPLACE INTO tombstones
              (content_hash, content, rejected_at, reason, embedding, embedding_epoch)
            VALUES (
              ?, ?, ?, ?,
              COALESCE(?, (SELECT embedding FROM tombstones WHERE content_hash = ?)),
              COALESCE(?, (SELECT embedding_epoch FROM tombstones WHERE content_hash = ?))
            )
        """, arguments: [
            hash, content, nowISO8601(), reason,
            encodeEmbedding(embedding), hash,
            embeddingEpoch, hash,
        ])
    }

    public func isTombstoned(content: String) async throws -> Bool {
        let hash = Self.contentHash(content)
        return try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstones WHERE content_hash = ?", arguments: [hash]) ?? 0 > 0
        }
    }

    /// Semantic tombstone gate (wave1 T3): does this candidate embedding match
    /// any tombstoned claim at/above the threshold? Agent's canon: a deletion is
    /// the CLAIM — only true paraphrases block; contradictions score below the
    /// (high) threshold and are admitted as new information. O(N) over the
    /// tombstone set, which is small and write-path-only (store/accept time).
    /// Legacy tombstones with NULL embeddings are skipped (hash gate covers them).
    public func matchesTombstone(
        embedding query: [Float],
        embeddingEpoch queryEpoch: MemoryEmbeddingEpoch? = nil,
        threshold: Double = memoryTombstoneMatchThreshold
    ) async throws -> Bool {
        try await dbPool.read { db in
            try Self.tombstoneMatch(
                db: db,
                query: query,
                queryEpoch: queryEpoch?.rawValue,
                threshold: threshold
            )
        }
    }

    /// Shared matcher usable both standalone and INSIDE a write transaction
    /// (acceptProposal gates in the same txn — nesting pool calls would hang).
    private static func tombstoneMatch(
        db: Database,
        query: [Float],
        queryEpoch: String?,
        threshold: Double
    ) throws -> Bool {
        guard !query.isEmpty else { return false }
        let activeEpoch = try embeddingEpochState(in: db).activeEpoch
        if let activeEpoch, queryEpoch != activeEpoch {
            throw MemoryStorageError.embeddingEpochMismatch(expected: activeEpoch, actual: queryEpoch)
        }
        let qn = l2norm(query)
        guard qn > 0 else { return false }
        var sql = "SELECT embedding FROM tombstones WHERE embedding IS NOT NULL"
        var arguments: StatementArguments = []
        if let activeEpoch {
            sql += " AND embedding_epoch = ?"
            arguments = [activeEpoch]
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        for row in rows {
            guard let e = decodeEmbedding(row["embedding"]), e.count == query.count else { continue }
            let en = l2norm(e)
            guard en > 0 else { continue }
            var dot: Float = 0
            for i in 0..<e.count { dot += e[i] * query[i] }
            if Double(dot) / (Double(qn) * Double(en)) >= threshold { return true }
        }
        return false
    }

    // MARK: - Embedding epoch activation

    /// Snapshot every canonical text-bearing row. Callers embed this immutable
    /// candidate off the turn path, then pass it back to
    /// `activateEmbeddingEpoch`; activation rejects any intervening drift.
    public func embeddingCorpusSnapshot() async throws -> [MemoryEmbeddingCorpusRow] {
        try await dbPool.read { db in try Self.embeddingCorpus(in: db) }
    }

    /// Transactionally consistent evaluation copy. The returned store has its
    /// own root and can be freely probed; canonical live rows and access
    /// counters cannot be mutated by the lab.
    public func frozenCopy(at dataRoot: URL) throws -> MemoryStorage {
        let destinationDirectory = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destination = destinationDirectory.appendingPathComponent("memory.sqlite")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MemoryStorageError.databaseUnavailable("frozen-copy destination already exists")
        }
        try MemoryConsolidationGate.onlineBackup(from: path, to: destination)
        return try MemoryStorage(dataRoot: dataRoot, memoryLimit: memoryLimit)
    }

    public func embeddingEpochState() async throws -> MemoryEmbeddingEpochState {
        try await dbPool.read { db in try Self.embeddingEpochState(in: db) }
    }

    /// Switch all memories, proposals, and tombstones to one vector space in a
    /// single SQLite transaction. Legacy vectors are never stamped in place:
    /// every row is freshly embedded, identity-checked, and content-hash
    /// checked before the canonical switch.
    public func activateEmbeddingEpoch(
        _ epoch: MemoryEmbeddingEpoch,
        staged: [MemoryEmbeddingStagedRow]
    ) async throws -> MemoryEmbeddingEpochActivationReport {
        let activatedAt = Self.nowISO8601()
        let report = try await dbPool.write { db -> MemoryEmbeddingEpochActivationReport in
            let live = try Self.embeddingCorpus(in: db)
            let liveByKey = Dictionary(uniqueKeysWithValues: live.map { (Self.corpusKey($0.kind, $0.id), $0) })
            var stagedByKey: [String: MemoryEmbeddingStagedRow] = [:]
            var dimensions: Int?
            for item in staged {
                let key = Self.corpusKey(item.row.kind, item.row.id)
                guard stagedByKey[key] == nil else {
                    throw MemoryStorageError.embeddingActivationInvalid("duplicate staged row \(key)")
                }
                guard let current = liveByKey[key], current.contentHash == item.row.contentHash else {
                    throw MemoryStorageError.embeddingActivationInvalid("canonical content drifted for \(key)")
                }
                guard !item.vector.isEmpty else {
                    throw MemoryStorageError.embeddingActivationInvalid("empty vector for \(key)")
                }
                if let dimensions, dimensions != item.vector.count {
                    throw MemoryStorageError.embeddingActivationInvalid("mixed vector dimensions")
                }
                dimensions = item.vector.count
                stagedByKey[key] = item
            }
            guard stagedByKey.count == liveByKey.count else {
                let missing = Set(liveByKey.keys).subtracting(stagedByKey.keys).sorted().prefix(3)
                throw MemoryStorageError.embeddingActivationInvalid(
                    "candidate covers \(stagedByKey.count)/\(liveByKey.count) rows; missing \(missing.joined(separator: ", "))"
                )
            }

            let prior = try Self.embeddingEpochState(in: db)
            try db.execute(sql: "DELETE FROM memory_embedding_previous")
            for row in live {
                let existing = try Self.embeddingPayload(in: db, kind: row.kind, id: row.id)
                try db.execute(sql: """
                    INSERT INTO memory_embedding_previous
                      (kind, row_id, content_hash, embedding, embedding_epoch)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    row.kind.rawValue, row.id, row.contentHash,
                    existing.embedding, existing.epoch,
                ])
            }
            for item in staged {
                try Self.updateEmbedding(
                    in: db,
                    kind: item.row.kind,
                    id: item.row.id,
                    embedding: Self.encodeEmbedding(item.vector),
                    epoch: epoch.rawValue
                )
            }
            try db.execute(sql: """
                UPDATE memory_embedding_state
                SET active_epoch = ?, previous_epoch = ?, activated_at = ?, rollback_available = 1
                WHERE id = 1
            """, arguments: [epoch.rawValue, prior.activeEpoch, activatedAt])

            func count(_ kind: MemoryEmbeddingCorpusKind) -> Int {
                staged.lazy.filter { $0.row.kind == kind }.count
            }
            return MemoryEmbeddingEpochActivationReport(
                epoch: epoch.rawValue,
                memories: count(.memory),
                proposals: count(.proposal),
                tombstones: count(.tombstone),
                previousEpoch: prior.activeEpoch,
                activatedAt: activatedAt
            )
        }
        invalidateRecallCache()
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: "embedding-epoch",
            operation: .changed,
            reason: "embedding_epoch_activated"
        ))
        await DerivedStateInvalidationCenter.shared.flush()
        return report
    }

    /// Immediate rollback lane retained for post-activation verification. It
    /// refuses if any canonical row was added, removed, or edited after the
    /// switch; a backup/repair workflow is required once reality has moved on.
    public func rollbackEmbeddingEpochActivation() async throws -> MemoryEmbeddingEpochState {
        let state = try await dbPool.write { db -> MemoryEmbeddingEpochState in
            let currentState = try Self.embeddingEpochState(in: db)
            guard currentState.rollbackAvailable else {
                throw MemoryStorageError.embeddingActivationInvalid("no retained prior epoch")
            }
            let live = try Self.embeddingCorpus(in: db)
            let previous = try Row.fetchAll(db, sql: """
                SELECT kind, row_id, content_hash, embedding, embedding_epoch
                FROM memory_embedding_previous
            """)
            let liveKeys = Set(live.map { Self.corpusKey($0.kind, $0.id) })
            let previousKeys = Set(previous.map {
                Self.corpusKey(
                    MemoryEmbeddingCorpusKind(rawValue: $0["kind"] as String)!,
                    $0["row_id"] as String
                )
            })
            guard liveKeys == previousKeys else {
                throw MemoryStorageError.embeddingActivationInvalid("canonical row set changed after activation")
            }
            let liveByKey = Dictionary(uniqueKeysWithValues: live.map { (Self.corpusKey($0.kind, $0.id), $0) })
            for row in previous {
                guard let kind = MemoryEmbeddingCorpusKind(rawValue: row["kind"] as String) else {
                    throw MemoryStorageError.embeddingActivationInvalid("unknown retained row kind")
                }
                let id: String = row["row_id"]
                let key = Self.corpusKey(kind, id)
                guard liveByKey[key]?.contentHash == (row["content_hash"] as String) else {
                    throw MemoryStorageError.embeddingActivationInvalid("canonical content changed for \(key)")
                }
                try Self.updateEmbedding(
                    in: db,
                    kind: kind,
                    id: id,
                    embedding: row["embedding"],
                    epoch: row["embedding_epoch"]
                )
            }
            try db.execute(sql: """
                UPDATE memory_embedding_state
                SET active_epoch = previous_epoch,
                    previous_epoch = NULL,
                    activated_at = ?,
                    rollback_available = 0
                WHERE id = 1
            """, arguments: [Self.nowISO8601()])
            try db.execute(sql: "DELETE FROM memory_embedding_previous")
            return try Self.embeddingEpochState(in: db)
        }
        invalidateRecallCache()
        return state
    }

    private static func embeddingCorpus(in db: Database) throws -> [MemoryEmbeddingCorpusRow] {
        var result: [MemoryEmbeddingCorpusRow] = []
        result += try Row.fetchAll(db, sql: "SELECT id, content FROM memories ORDER BY id").map {
            MemoryEmbeddingCorpusRow(kind: .memory, id: $0["id"], content: $0["content"])
        }
        result += try Row.fetchAll(db, sql: "SELECT id, content FROM proposals ORDER BY id").map {
            MemoryEmbeddingCorpusRow(kind: .proposal, id: $0["id"], content: $0["content"])
        }
        result += try Row.fetchAll(db, sql: "SELECT content_hash, content FROM tombstones ORDER BY content_hash").map {
            MemoryEmbeddingCorpusRow(kind: .tombstone, id: $0["content_hash"], content: $0["content"])
        }
        return result
    }

    private static func embeddingEpochState(in db: Database) throws -> MemoryEmbeddingEpochState {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_embedding_state WHERE id = 1")
        return MemoryEmbeddingEpochState(
            activeEpoch: row?["active_epoch"],
            previousEpoch: row?["previous_epoch"],
            activatedAt: row?["activated_at"],
            rollbackAvailable: (row?["rollback_available"] as Int? ?? 0) != 0
        )
    }

    private static func corpusKey(_ kind: MemoryEmbeddingCorpusKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    private static func embeddingPayload(
        in db: Database,
        kind: MemoryEmbeddingCorpusKind,
        id: String
    ) throws -> (embedding: Data?, epoch: String?) {
        let table: String
        let key: String
        switch kind {
        case .memory: table = "memories"; key = "id"
        case .proposal: table = "proposals"; key = "id"
        case .tombstone: table = "tombstones"; key = "content_hash"
        }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT embedding, embedding_epoch FROM \(table) WHERE \(key) = ?",
            arguments: [id]
        ) else {
            throw MemoryStorageError.embeddingActivationInvalid("missing canonical row \(corpusKey(kind, id))")
        }
        return (row["embedding"], row["embedding_epoch"])
    }

    private static func updateEmbedding(
        in db: Database,
        kind: MemoryEmbeddingCorpusKind,
        id: String,
        embedding: Data?,
        epoch: String?
    ) throws {
        let table: String
        let key: String
        switch kind {
        case .memory: table = "memories"; key = "id"
        case .proposal: table = "proposals"; key = "id"
        case .tombstone: table = "tombstones"; key = "content_hash"
        }
        try db.execute(
            sql: "UPDATE \(table) SET embedding = ?, embedding_epoch = ? WHERE \(key) = ?",
            arguments: [embedding, epoch, id]
        )
        guard db.changesCount == 1 else {
            throw MemoryStorageError.embeddingActivationInvalid("failed to update \(corpusKey(kind, id))")
        }
    }

    private static func requireWritableEpoch(
        in db: Database,
        vector: [Float]?,
        epoch: String?
    ) throws {
        guard vector != nil else { return }
        let active = try embeddingEpochState(in: db).activeEpoch
        guard let active else { return }
        guard epoch == active else {
            throw MemoryStorageError.embeddingEpochMismatch(expected: active, actual: epoch)
        }
    }

    private static func validateTemporalEvidence(_ memory: StoredMemory) throws {
        func parsed(_ label: String, _ value: String?) throws -> Date? {
            guard let value else { return nil }
            guard let date = MemoryRecallScoring.parseTimestamp(value) else {
                throw MemoryStorageError.invalidTemporalEvidence("\(label) is not ISO-8601")
            }
            return date
        }
        let validFrom = try parsed("valid_from", memory.validFrom)
        let validTo = try parsed("valid_to", memory.validTo)
        _ = try parsed("observed_at", memory.observedAt)
        if let validFrom, let validTo, validTo < validFrom {
            throw MemoryStorageError.invalidTemporalEvidence("valid_to precedes valid_from")
        }
    }

    // MARK: - Helpers

    public static func contentHash(_ s: String) -> String {
        let normalized = s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func nowISO8601() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func l2norm(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += x * x }
        return s.squareRoot()
    }

    private static func metadataString(
        _ object: [String: JSONValue],
        _ key: String,
        fallback: String
    ) -> String? {
        if case .string(let value)? = object[key] { return value }
        if case .string(let value)? = object[fallback] { return value }
        return nil
    }

    private static func uniqueRecallResults(
        _ scored: [(StoredMemory, Double)],
        limit: Int
    ) -> [(memory: StoredMemory, similarity: Double)] {
        let cappedLimit = max(0, limit)
        guard cappedLimit > 0 else { return [] }
        // Skill rows are discovery hints, not the answer corpus. Preserve
        // score order but reserve room for ordinary memories when available;
        // if a query truly has only skill matches, deferred skills fill the
        // remaining slots so discovery behavior is never lost.
        let preferredSkillLimit = cappedLimit == 1 ? 1 : max(1, (cappedLimit + 1) / 2)
        var seen: Set<String> = []
        var out: [(memory: StoredMemory, similarity: Double)] = []
        var deferredSkills: [(memory: StoredMemory, similarity: Double)] = []
        var skillCount = 0
        out.reserveCapacity(min(cappedLimit, scored.count))
        for (memory, similarity) in scored {
            let key = normalizedRecallContent(memory.content)
            if !key.isEmpty {
                guard seen.insert(key).inserted else { continue }
            }
            if isSkillRecallHint(memory), skillCount >= preferredSkillLimit {
                deferredSkills.append((memory, similarity))
                continue
            }
            out.append((memory, similarity))
            if isSkillRecallHint(memory) { skillCount += 1 }
            if out.count >= cappedLimit { break }
        }
        if out.count < cappedLimit {
            out.append(contentsOf: deferredSkills.prefix(cappedLimit - out.count))
        }
        return out
    }

    private static func isSkillRecallHint(_ memory: StoredMemory) -> Bool {
        memory.id.hasPrefix("skill-pointer:")
            || MemoryRecallScoring.kind(of: memory.metadata)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "skill"
    }

    private static func normalizedRecallContent(_ content: String) -> String {
        content
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func encodeEmbedding(_ e: [Float]?) -> Data? {
        guard let e else { return nil }
        var out = Data(capacity: e.count * 4)
        for f in e {
            var le = f.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    private static func decodeEmbedding(_ data: Data?) -> [Float]? {
        guard let data, data.count % 4 == 0 else { return nil }
        let count = data.count / 4
        var out = [Float](); out.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt32.self)
            for i in 0..<count {
                out.append(Float(bitPattern: UInt32(littleEndian: base[i])))
            }
        }
        return out
    }

    private static func encodeMetadata(_ m: JSONValue?) -> String? {
        guard let m else { return nil }
        let enc = JSONEncoder()
        guard let data = try? enc.encode(m), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func decodeMetadata(_ s: String?) -> JSONValue? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func decodeMemory(_ row: Row) -> StoredMemory {
        StoredMemory(
            id: row["id"],
            content: row["content"],
            personaId: row["persona_id"],
            source: row["source"],
            confidence: row["confidence"] ?? 1.0,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            embedding: decodeEmbedding(row["embedding"]),
            embeddingEpoch: row["embedding_epoch"],
            status: row["status"],
            lifecycle: row["lifecycle"] ?? MemoryLifecycle.confirmed,
            validFrom: row["valid_from"],
            validTo: row["valid_to"],
            observedAt: row["observed_at"],
            evidence: decodeMetadata(row["evidence_json"]),
            metadata: decodeMetadata(row["metadata_json"]),
            useCount: row["use_count"] ?? 0,
            lastUsedAt: row["last_used_at"]
        )
    }

    private static func decodeProposal(_ row: Row) -> StoredProposal {
        StoredProposal(
            id: row["id"],
            content: row["content"],
            personaId: row["persona_id"],
            source: row["source"],
            stagedAt: row["staged_at"],
            status: row["status"],
            resolvedAt: row["resolved_at"],
            rejectionReason: row["rejection_reason"],
            embedding: decodeEmbedding(row["embedding"]),
            embeddingEpoch: row["embedding_epoch"],
            metadata: decodeMetadata(row["metadata_json"])
        )
    }
}
