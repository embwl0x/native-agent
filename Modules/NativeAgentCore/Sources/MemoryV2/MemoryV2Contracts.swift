import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `MemoryV2Contracts.swift` | `MemoryCommitArguments`, `MemoryProposalEvidence`, `MemoryPatchContract` |

// MARK: - Request / response types

/// The explicit save's scope contract, shared with its advertised bounds.
public enum MemoryCommitArguments {
    public static let topicLimit = 8
    public static let topicCharacterLimit = 120

    public static func contextTopics(_ value: JSONValue, kind: String?) throws -> [JSONValue]? {
        guard case .array(let values) = value, values.count <= topicLimit else {
            throw MemoryV2Error.underlying("'context_topics' must be an array of at most \(topicLimit) scope phrases")
        }
        var topics: [JSONValue] = []
        for value in values {
            guard case .string(let raw) = value else {
                throw MemoryV2Error.underlying("every context_topics entry must be a string")
            }
            let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty, topic.count <= topicCharacterLimit else {
                throw MemoryV2Error.underlying("every context_topics entry must contain 1...\(topicCharacterLimit) characters")
            }
            topics.append(.string(topic))
        }
        if !topics.isEmpty, let kind,
           !["correction", "instruction", "preference", MemoryKindStamp.genericCommitKind].contains(kind) {
            throw MemoryV2Error.underlying("context_topics is not supported for kind \(kind)")
        }
        return topics.isEmpty ? nil : topics
    }
}

/// Evidence is recorded by `propose`, never inferred from a source label.
public struct MemoryProposalEvidence: Sendable {
    public let sessionIDs: [String]
    public let recurrenceCount: Int?
    public let error: String?

    public static func confidence(in metadata: JSONValue?) throws -> Double {
        guard case .object(let fields)? = metadata,
              let value = fields["confidence"]?.numberValue(coercingStrings: false, finiteOnly: true),
              (0...1).contains(value) else {
            throw MemoryV2Error.underlying("Proposal confidence is missing or invalid; expected a finite number in 0...1. Its saved evidence is unchanged.")
        }
        return value
    }

    public static func recurrence(in metadata: [String: JSONValue]) throws -> Int? {
        guard let value = metadata["recurrence_count"] else { return nil }
        guard case .int(let raw) = value, let count = Int(exactly: raw), count > 0 else {
            throw MemoryV2Error.underlying("recurrence_count must be a positive integer")
        }
        return count
    }

    public init(metadata: JSONValue?) {
        var sessions: [String] = []
        var count: Int?
        var failures: [String] = []
        if let metadata {
            if case .object(let fields) = metadata {
                do { count = try Self.recurrence(in: fields) }
                catch { failures.append(String(describing: error)) }
                if let value = fields["supporting_session_ids"] {
                    if case .array(let values) = value,
                       values.allSatisfy({
                           if case .string(let id) = $0 { return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty };
                           return false
                       }) {
                        sessions = Array(Set(values.compactMap(\.stringValue))).sorted()
                    } else { failures.append("supporting_session_ids must contain only nonempty session ids") }
                }
            } else { failures.append("proposal evidence metadata is not an object") }
        }
        sessionIDs = sessions
        recurrenceCount = count
        error = failures.isEmpty ? nil : failures.joined(separator: "; ")
    }
}

extension ProposalRecord {
    public var evidence: MemoryProposalEvidence { MemoryProposalEvidence(metadata: metadata) }
    public var evidenceSummary: String {
        let recorded = evidence
        return MemoryProposalRecord.evidenceDescription(sessionCount: recorded.sessionIDs.count,
            recurrenceCount: recorded.recurrenceCount, error: recorded.error)
    }
}

public struct MemoryV2RecallRequest: Sendable, Codable, Equatable {
    public var text: String
    public var topK: Int
    public var persona: String?
    public var surface: String?
    public var requiresRelevance: Bool?
    /// Count examined disclosed candidates from the same nextOffset.
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
    public var status: String
    public var createdAt: String
    /// When the row left `pending`, anchoring supersession-link recovery; nil while pending.
    public var resolvedAt: String?
    public var rejectionReason: String?
    /// Carry extractor confidence and kind through promotion so acceptance preserves the original signal.
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

public enum MemoryPatchContract {
    /// Untyped metadata round-trips pinning, tags, importance, duplicate counts and provenance. Exclude kind: semantic classification and approved backfill own
    /// its typed writer.
    public static let untypedPassthroughKeys: Set<String> = [
        "pinned", "tags", "importance", "recall_count",
        "source_history", "duplicate_occurrences", "untrusted_sources", "peer_data_sources", "peer_sources",
    ]

}

/// Retain the reviewed replacement target and its staging-time fingerprint.
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
