import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct TrainingArtifact: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var title: String?
    var sourceId: String?
    var sensitivity: String?
    var status: String?
    var createdAt: String?
    var summary: String?
}

struct FailureExplanation: Codable, Hashable {
    var category: String
    var summary: String
    var safeToRetry: Bool
    var nextAction: String
}

struct ResearchResult: Identifiable, Codable, Hashable {
    var id: String { url }
    var title: String
    var url: String
    var snippet: String
    var source: String?
}

struct ImprovementRun: Identifiable, Codable, Hashable {
    var id: String
    var objective: String
    var status: String
    var phase: String
    var createdAt: String
    var summary: String?
    var completedAt: String?
    var model: String?
    var worktree: String?
    var exitReason: String?
    var promotedCommitSha: String?
    var revertCommitSha: String?
}

struct ImprovementRevertResult: Codable, Hashable {
    var ok: Bool
    var revertCommitSha: String?
    var originalCommitSha: String?
    var warning: String?
    var error: String?
}

struct SchedulerJob: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: String
    var intervalSeconds: Int?
    var enabled: Bool
    var nextRunAt: String?
    var lastRunAt: String?
}

struct ImprovementFailureEntry: Codable, Hashable, Identifiable {
    var id: String { runId ?? UUID().uuidString }
    var runId: String?
    var createdAt: String?
    var status: String?
    var failureClass: String?
    var summary: String?
    enum CodingKeys: String, CodingKey {
        case runId = "id"
        case createdAt
        case status
        case failureClass
        case summary
    }
}

struct ImprovementSummary: Codable, Hashable {
    var enabled: Bool
    var processEnabled: Bool?
    var trustEnabled: Bool?
    var disabledReason: String?
    var status: String
    var runningCount: Int
    var succeededCount: Int
    var failedCount: Int
    var interruptedCount: Int
    var totalCount: Int
    var stagedCount: Int
    var stagedRuns: [ImprovementRun]?
    var latestRun: ImprovementRun?
    var latestFailure: ImprovementRun?
    var failureBreakdown: [String: Int]?
    var recentFailures: [ImprovementFailureEntry]?
    var nextImproveJob: SchedulerJob?
    var recurringImproveJobs: [SchedulerJob]
    var personalityGrowthEntries: Int
    var latestPersonalityGrowthEntries: [String]?
    var smokeJobCount: Int
    var oldInterruptedCount: Int
    var repairableReceiptFailureCount: Int
    var learningReceiptCount: Int?
    var latestLearningReceipts: [HarnessLearningReceipt]?
    var learningProposalCount: Int?
    var latestLearningProposals: [HarnessLearningProposal]?
    var learningProposalCounts: [String: Int]?
    var harnessBenchmark: HarnessBenchmarkSummary?
    var learningStandard: HarnessLearningStandard?
    var dataRoot: String
    var createdAt: String
}

struct HarnessLearningStandard: Codable, Hashable {
    var activeHints: Int?
    var provenHints: Int?
    var watchHints: Int?
    var probationHints: Int?
    var archivedHints: Int?
    var archiveBelowConfidence: Double?
    var promoteAfterSuccesses: Int?
    var promoteAfterUses: Int?
}

struct HarnessLearningReceipt: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var title: String
    var summary: String
    var why: String?
    var changes: [String]?
    var runId: String?
    var source: String?
    var impact: String?
    var createdAt: String
}

struct HarnessLearningProposal: Identifiable, Codable, Hashable {
    var id: String
    var type: String?
    var status: String?
    var problem: String?
    var proposedChange: String?
    var expectedBenefit: String?
    var evidenceRuns: [String]?
    var riskTier: String?
    var approvalRequired: Bool?
    var approvalReasons: [String]?
    var promotionMode: String?
    var implementationStatus: String?
    var implementedAt: String?
    var implementationEvidenceGrade: String?
    var implementationUseCount: Int?
    var implementationSuccessCount: Int?
    var implementationConfidence: Double?
    var permanentAt: String?
    var requiredEvalGate: String?
    var seenCount: Int?
    var createdAt: String?
    var updatedAt: String?
}

struct HarnessBenchmarkSummary: Codable, Hashable {
    var status: String?
    var latest: HarnessBenchmarkRun?
    var runCount: Int?
    var weeklyJob: SchedulerJob?
    var manualRunEndpoint: String?
    var chatPathImpact: String?
    var createdAt: String?
}

struct HarnessBenchmarkRun: Identifiable, Codable, Hashable {
    var id: String
    var name: String?
    var status: String?
    var checks: [HarnessBenchmarkCheck]?
    var durationSeconds: Double?
    var schedule: String?
    var manualRunnable: Bool?
    var chatPathImpact: String?
    var createdAt: String?
}

struct HarnessBenchmarkCheck: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var passed: Bool?
    var detail: String?
}

struct ImprovementCleanupResult: Codable, Hashable {
    var removedJobs: Int
    var removedInterruptedTestRuns: Int
    var repairedReceiptFailures: Int
    var createdAt: String
}

// PATCH-2026-05-08: improve-review-loop — diff/promote/discard types
struct ImprovementDiffFile: Codable, Hashable, Identifiable {
    var path: String
    var status: String      // "M", "A", "D", "??"
    var additions: Int
    var deletions: Int
    var id: String { path }
}

struct ImprovementDiffPayload: Codable, Hashable {
    // Fix 9: keep identity/status fields required; make content fields optional so older
    // daemon responses missing them don't cause a decode failure.
    var runId: String
    var objective: String
    var phase: String
    var status: String
    var worktree: String?
    var worktreeExists: Bool?
    var receipt: String?
    var diffText: String?
    var files: [ImprovementDiffFile]?

    // Convenience accessors so call-sites that expect non-optional still compile
    var worktreeExistsBool: Bool { worktreeExists ?? false }
    var receiptValue: String { receipt ?? "" }
    var diffTextValue: String { diffText ?? "" }
    var filesValue: [ImprovementDiffFile] { files ?? [] }
}

struct ImprovementPromoteResult: Codable, Hashable {
    var ok: Bool
    var commitSha: String?
    var filesChanged: Int?
    var error: String?
    var warning: String?
    var swiftChanged: Bool?
}

// PATCH-2026-05-08: no-terminal-moments — result types for rebuild/push/stash-recover
struct SystemRebuildResult: Codable, Hashable {
    var ok: Bool
    var message: String?
    var error: String?
}

struct GitPushResult: Codable, Hashable {
    var ok: Bool
    var branch: String?
    var output: String?
    var error: String?
}

struct GitStashRecoverResult: Codable, Hashable {
    var ok: Bool
    var stashRef: String?
    var output: String?
    var error: String?
}
