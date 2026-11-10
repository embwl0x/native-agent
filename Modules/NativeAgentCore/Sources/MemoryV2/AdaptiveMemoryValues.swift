import Transcripts
import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
import TrustCenter
import CognitiveSubstrate
import ChatTurnContracts
import TurnTrace
// Blueprint: | `AdaptiveMemoryValues.swift` | Adaptive candidates, extraction evidence, observation and shared hygiene vocabulary |
public struct AdaptiveCandidate: Sendable, Equatable {
    public let content: String
    public let score: Double
    public let kind: String
    public init(content: String, score: Double, kind: String) {
        self.content = content
        self.score = score
        self.kind = kind
    }
}
public enum MemorySemanticExtractionStatus: String, Sendable {
    case unavailable, disabled, emptyInput, succeeded, failed, timedOut, unreported, skipped
    /// Not the person's turn: left owed, judged when she is idle.
    case deferred
}
/// Payload-free evidence, not a claim that an extracted candidate is true.
public struct AdaptiveExtractionReport: Sendable {
    public let candidates: [AdaptiveCandidate]
    public let semanticStatus: MemorySemanticExtractionStatus
    public let semanticCandidateCount: Int
    public let failure: AfterTurnMemoryFailure?
    public init(candidates: [AdaptiveCandidate], semanticStatus: MemorySemanticExtractionStatus,
                semanticCandidateCount: Int = 0, failure: AfterTurnMemoryFailure? = nil) {
        self.candidates = candidates
        self.semanticStatus = semanticStatus
        self.semanticCandidateCount = max(0, semanticCandidateCount)
        self.failure = failure
    }
}
public struct AdaptiveMemoryObservation: Sendable {
    public let proposals: [ProposalRecord]
    public internal(set) var extraction: AdaptiveExtractionReport
    /// Keep explicit refusal evidence for confidence, quality, duplicates, tombstones and staging failures.
    public let hygieneRejectedCount: Int
    public let savedCorrectionCount: Int
    public let pendingCorrectionCount: Int
    public let failedCorrectionCount: Int
    var stagingFailed = false
    init(
        proposals: [ProposalRecord],
        extraction: AdaptiveExtractionReport,
        hygieneRejectedCount: Int = 0,
        savedCorrectionCount: Int = 0,
        pendingCorrectionCount: Int = 0,
        failedCorrectionCount: Int = 0,
        stagingFailed: Bool = false
    ) {
        self.proposals = proposals
        self.extraction = extraction
        self.hygieneRejectedCount = max(0, hygieneRejectedCount)
        self.savedCorrectionCount = savedCorrectionCount
        self.pendingCorrectionCount = pendingCorrectionCount
        self.failedCorrectionCount = failedCorrectionCount
        self.stagingFailed = stagingFailed
    }
}
// MARK: - Shared candidate vocabulary
/// Names used only to keep correction subject identifiers neutral. Semantic eligibility and grounding belong to the shared interpretation, in any language.
public enum AdaptiveCandidateHygiene {
    /// Launch adds the persona's lowercased display name; `assistant` is always recognized.
    private static let names = Mutex<Set<String>>(["assistant"])
    /// A locked snapshot; iterate this, never the storage.
    public static var assistantNames: Set<String> {
        names.withLock { $0 }
    }
    public static func insertAssistantName(_ name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        _ = names.withLock { $0.insert(normalized) }
    }
}
