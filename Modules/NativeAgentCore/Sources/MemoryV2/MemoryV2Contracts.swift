import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryV2Contracts.swift` | Recall candidate offsets and counted/capped continuations, proposal contracts; `MemoryPatchContract` preserves untrusted sources through rewrites and duplicate collapse |

// MARK: - Request / response types

public struct MemoryV2RecallRequest: Sendable, Codable, Equatable {
    public var text: String
    public var topK: Int
    public var persona: String?
    public var surface: String?
    public var requiresRelevance: Bool?
    /// Ranked disclosed candidates already examined, copied from nextOffset.
    public var offset: Int?

    public init(
        text: String,
        topK: Int = 10,
        persona: String? = nil,
        surface: String? = nil,
        requiresRelevance: Bool? = nil,
        offset: Int? = nil
    ) {
        self.text = text
        self.topK = topK
        self.persona = persona
        self.surface = surface
        self.requiresRelevance = requiresRelevance
        self.offset = offset
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
    /// When true, total is only a lower bound; the remaining ranking is unjudged.
    public var capped: Bool
    public var hasMore: Bool
    public var nextOffset: Int?
    public var disclosureFilteredCount: Int
    public var timings: [String: Double]
    public init(
        hits: [MemoryRecallHit],
        scored: [ScoredMemoryRecord],
        total: Int,
        disclosureFilteredCount: Int = 0,
        timings: [String: Double] = [:],
        capped: Bool = false,
        hasMore: Bool = false,
        nextOffset: Int? = nil
    ) {
        self.hits = hits
        self.scored = scored
        self.total = total
        self.disclosureFilteredCount = disclosureFilteredCount
        self.timings = timings
        self.capped = capped
        self.hasMore = hasMore
        self.nextOffset = nextOffset
    }
}

// MARK: - ProposalRecord (memory promotion lifecycle)

public struct ProposalRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var content: String
    public var personaId: String?
    public var source: String?
    /// "pending" | "accepted" | "rejected".
    public var status: String
    public var createdAt: String
    /// When the row left `pending`, anchoring supersession-link recovery; nil while pending.
    public var resolvedAt: String?
    public var rejectionReason: String?
    /// Carries the extractor's per-fact signal (confidence, kind) from staging
    /// through promotion so `acceptProposal` can stamp it on the memory instead
    /// of discarding it. Previously dropped at the bridge → every memory landed
    /// at confidence 1.0 / kind nil (#1 signal-leak).
    public var metadata: JSONValue?

    public init(
        id: String,
        content: String,
        personaId: String? = nil,
        source: String? = nil,
        status: String = "pending",
        createdAt: String,
        resolvedAt: String? = nil,
        rejectionReason: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.content = content
        self.personaId = personaId
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.rejectionReason = rejectionReason
        self.metadata = metadata
    }
}

// MARK: - Patch contract

/// Metadata keys accepted by the SQLite bridge's untyped patch path.
public enum MemoryPatchContract {
    /// Untyped keys that round-trip through metadata.
    ///
    /// `pinned` — the Mac UI pin path.
    /// `tags` / `importance` — surfaced back into typed slots by `toMemoryRecord`.
    /// `recall_count` — `store()`'s duplicate guard bumps it.
    /// `source_history` / `duplicate_occurrences` — byte-identical collapse provenance.
    /// `owner_restored` — stamped when the agent restores an archived row.
    ///
    /// `kind` is deliberately ABSENT: it is semantics-owned (kind-scoped decay)
    /// and the approval-gated kind backfill uses its dedicated typed writer.
    public static let untypedPassthroughKeys: Set<String> = [
        "pinned", "tags", "importance", "recall_count",
        "source_history", "duplicate_occurrences", "owner_restored", "untrusted_sources", "peer_data_sources", "peer_sources",
    ]

}

/// One validated replacement: the memory an accepted update demotes, and the
/// fingerprint that row had when the proposal was staged.
public struct SupersedingAcceptance: Sendable, Equatable {
    public let targetId: String
    /// Acceptance requires a target fingerprint; proposals without one stay pending for re-review.
    public let expectedContentHash: String
    public let reason: String
    public init(targetId: String, expectedContentHash: String, reason: String) {
        self.targetId = targetId
        self.expectedContentHash = expectedContentHash
        self.reason = reason
    }
}
