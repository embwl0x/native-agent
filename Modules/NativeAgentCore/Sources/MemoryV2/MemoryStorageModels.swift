import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorageModels.swift` | `MemoryV2Defaults` enum |

public enum MemoryV2Defaults {
    public static let personaID = "NativeAgent"
}

/// Hard bound on canonical MemoryV2 fact rows. Enforced inside every canonical
/// insert/accept transaction and during store open for legacy overflow.
public let memoryStoredRowCap = 2_000

public enum MemoryLifecycle {
    public static let confirmed = "confirmed"
    public static let temporary = "temporary"
    public static let inferred = "inferred"
    public static let stale = "stale"
    public static let corrected = "corrected"
    public static let contradicted = "contradicted"
    public static let deleted = "deleted"
    /// A standing lesson approved into GROWTH: kept as history (and in the
    /// miss ledger), no longer recalled — the prefix carries it now.
    public static let graduated = "graduated"

    public static let recallExcluded: Set<String> = [corrected, contradicted, deleted, graduated]
    /// `recallExcluded` as the SQL list every store query filters with.
    public static let recallExcludedSQL = "(" + recallExcluded.sorted().map { "'\($0)'" }.joined(separator: ", ") + ")"

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
        case corrected, contradicted, deleted, graduated:
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
    /// Truth interval, validated on write. A passed validTo excludes the row
    /// from current recall, disclosure and USER.md while retaining history.
    public var validFrom: String?
    public var validTo: String?
    public var observedAt: String?
    public var evidence: JSONValue?
    public var metadata: JSONValue?
    /// `recordRecallHits` atomically counts access; `metadata.recall_count` counts merge evidence.
    /// Capacity retention uses access recency; disuse alone never archives a row.
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
    /// so a service-side read/replace cannot overwrite a concurrent owner write.
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
    case capacityExceeded
    case pinOrderExhausted

    /// Only `corpusDrift` warrants re-embedding on refusal; `unusableCandidate` requires fixing the vectors.
    public enum EmbeddingActivationRefusal: String, Sendable {
        case corpusDrift
        case unusableCandidate
    }

    public var failure: ToolFailureError {
        switch self {
        case .notFound(let id):
            return ToolFailureError("Memory record not found: \(id)", effects: .none,
                nextCall: ToolFailureError.call("app", ["page": .string("memories")]),
                code: "memory_record_not_found", instruction: "Read current memories and proposals before selecting an id.", recovery: .inspect)
        case .alreadyResolved(let id):
            return ToolFailureError("Memory proposal already resolved: \(id)", effects: .none,
                code: "memory_proposal_resolved", status: .refused,
                instruction: "Keep the recorded decision; do not resolve this proposal again.", recovery: .terminal)
        case .databaseUnavailable(let msg):
            return MemoryV2Error.storeFailure("Memory store unavailable: \(msg)", code: "memory_store_unavailable")
        case .tombstoned(let id):
            return MemoryV2Error.forgottenContent("Content matches a forgotten or rejected memory: \(id)")
        case .embeddingEpochMismatch:
            return Self.searchFailure("The memory search model and memory store use different search indexes.", code: "memory_search_index_mismatch",
                instruction: "Rebuild the memory search index for the selected model; inspect Doctor for model or memory store errors first.")
        case .embeddingActivationInvalid(let refusal, let reason):
            return Self.searchFailure("Memory search index activation refused: \(reason)",
                code: refusal == .corpusDrift ? "memory_search_corpus_changed" : "memory_search_vectors_invalid", instruction: refusal == .corpusDrift
                    ? "Index the current memory store; inspect Doctor if indexing cannot complete."
                    : "Repair the reported model or vector defect before rebuilding the index; read Doctor for model evidence.")
        case .invalidTemporalEvidence(let reason):
            return ToolFailureError("Invalid memory date evidence: \(reason)", argumentPath: "valid_from / valid_to / observed_at",
                accepted: "valid ISO 8601 dates; valid_from must not follow valid_to", effects: .none,
                nextCall: ToolFailureError.call("app", ["page": .string("memories")]),
                code: "memory_dates_invalid", status: .refused,
                instruction: "Correct the named date evidence in the original call.", recovery: .correctArguments)
        case .capacityExceeded:
            return ToolFailureError("The memory store limit cannot be met without removing protected memories.", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
                code: "memory_capacity_reached", status: .refused,
                instruction: "Review saved memories; leave this candidate unsaved unless you deliberately choose a memory to forget.", recovery: .inspect)
        case .pinOrderExhausted:
            return ToolFailureError("Memory pin ordering reached its integer limit.", effects: .none, owner: "memory store",
                tap: "Memories ▸ Upkeep and details ▸ Advanced Diagnostics", code: "memory_pin_order_exhausted",
                instruction: "Repair pin-order values in their existing order, preserving all memories and pins; freeing memory capacity cannot fix this.")
        }
    }

    static func searchFailure(_ detail: String, code: String, instruction: String) -> ToolFailureError {
        ToolFailureError(detail, effects: .none, owner: "memory search model",
            nextCall: ToolFailureError.call("app", ["action": .string("doctor.run")]), code: code, instruction: instruction)
    }

    /// Technical index identity stays separate from the plain failure detail.
    public var epochEvidence: JSONValue? {
        if case .embeddingEpochMismatch(let expected, let actual) = self {
            return .object(["expected_epoch": .string(expected), "actual_epoch": actual.map(JSONValue.string) ?? .null])
        }
        return nil
    }

    public var errorDescription: String? {
        let detail = MemoryV2Error.describe(failure)
        if case .embeddingEpochMismatch(let expected, let actual) = self {
            return "\(detail)\nEpoch evidence: expected \(expected), actual \(actual ?? "unknown")"
        }
        return detail
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
