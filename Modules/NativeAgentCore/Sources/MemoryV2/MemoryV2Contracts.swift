import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Request / response types

public struct MemoryV2RecallRequest: Sendable, Codable, Equatable {
    public var text: String
    public var topK: Int
    public var persona: String?
    public var surface: String?
    public var requiresRelevance: Bool?

    public init(
        text: String,
        topK: Int = 10,
        persona: String? = nil,
        surface: String? = nil,
        requiresRelevance: Bool? = nil
    ) {
        self.text = text
        self.topK = topK
        self.persona = persona
        self.surface = surface
        self.requiresRelevance = requiresRelevance
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
    public var timings: [String: Double]
    public init(
        hits: [MemoryRecallHit],
        scored: [ScoredMemoryRecord],
        total: Int,
        disclosureFilteredCount: Int = 0,
        timings: [String: Double] = [:]
    ) {
        self.hits = hits
        self.scored = scored
        self.total = total
        self.disclosureFilteredCount = disclosureFilteredCount
        self.timings = timings
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
    /// When the row left `pending`. Carried through the conversion so the launch
    /// supersession-link recovery can anchor on the moment of retirement (Astra
    /// comb 4, lane5 finding 2); nil for a row still pending.
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
    /// `pinned` — the Mac UI pin path (audit 2026-06-09; pin was a silent no-op).
    /// `tags` / `importance` — surfaced back into typed slots by `toMemoryRecord`.
    /// `recall_count` — `store()`'s duplicate guard bumps it (2026-07-24).
    /// `source_history` / `duplicate_occurrences` — byte-identical collapse
    /// provenance (2026-08-02).
    /// `owner_restored` — stamped when the agent restores an archived row; the
    /// hygiene duplicate pass leaves such a row alone (2026-10-01).
    ///
    /// `kind` is deliberately ABSENT: it is semantics-owned (kind-scoped decay)
    /// and no UI path patches it.
    public static let untypedPassthroughKeys: Set<String> = [
        "pinned", "tags", "importance", "recall_count",
        "source_history", "duplicate_occurrences", "owner_restored", "untrusted_sources", "peer_data_sources", "peer_sources",
    ]

}

/// One validated replacement: the memory an accepted update demotes, and the
/// fingerprint that row had when the proposal was staged.
public struct SupersedingAcceptance: Sendable, Equatable {
    public let targetId: String
    /// Always present: a supersession with no fingerprint to check is not a
    /// supersession, it is an unrelated demotion waiting to happen. Legacy
    /// proposals staged before the fingerprint existed are refused at
    /// acceptance and left pending for re-review (2026-09-11 review item 1).
    public let expectedContentHash: String
    public let reason: String
    public init(targetId: String, expectedContentHash: String, reason: String) {
        self.targetId = targetId
        self.expectedContentHash = expectedContentHash
        self.reason = reason
    }
}
