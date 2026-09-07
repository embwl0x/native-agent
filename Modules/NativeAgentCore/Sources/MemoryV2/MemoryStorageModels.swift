import Foundation
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
    /// Keys merged into the row's current metadata inside the same SQLite
    /// transaction as the rest of the patch. Narrow metadata updates use this
    /// so a bridge-side read/replace cannot overwrite a concurrent owner write.
    public var metadataMerge: [String: JSONValue]?

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
        metadata: JSONValue? = nil,
        metadataMerge: [String: JSONValue]? = nil
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
        self.metadataMerge = metadataMerge
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
    case embeddingActivationInvalid(EmbeddingActivationRefusal, String)
    case invalidTemporalEvidence(String)

    /// 2026-09-06: why an activation was refused. The launch reconciler retries
    /// a refusal by re-embedding the entire corpus, which is the right answer
    /// only for `corpusDrift` — the rows moved under the candidate snapshot, so
    /// a fresh snapshot can succeed. `unusableCandidate` says the vectors
    /// themselves (or the retained rollback set) are wrong; retrying spends
    /// three full corpus embeddings to reach the same refusal.
    public enum EmbeddingActivationRefusal: String, Sendable {
        case corpusDrift
        case unusableCandidate
    }

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "MemoryStorage: not found — \(id)"
        case .alreadyResolved(let id): return "MemoryStorage: proposal already resolved — \(id)"
        case .databaseUnavailable(let msg): return "MemoryStorage: database unavailable — \(msg)"
        case .tombstoned(let id): return "MemoryStorage: content matches a tombstoned claim — \(id)"
        case .embeddingEpochMismatch(let expected, let actual):
            return "MemoryStorage: embedding epoch mismatch — expected \(expected), got \(actual ?? "unknown")"
        case .embeddingActivationInvalid(let refusal, let reason):
            return "MemoryStorage: embedding epoch activation refused (\(refusal.rawValue)) — \(reason)"
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
