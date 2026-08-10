import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct WorkshopExecutionRecord: Identifiable, Codable, Hashable {
    var id: String
    var deskHandle: String?
    var projectSpaceId: String?
    var title: String
    var objective: String
    var status: String
    var phase: String
    var priority: String?
    var autonomyLevel: String?
    var permissionProfile: String?
    var summary: String?
    var createdAt: String
    var updatedAt: String?
    var completedAt: String?
    var receiptCount: Int?

    // PATCH-2026-05-07: execution-decode-tolerance The daemon has two execution
    // stores: the new queue (snake_case `created_at` / `updated_at`, no
    // `phase` field) and the legacy store (camelCase). Both flow through
    // GET /v1/missions. This custom decoder accepts either casing and
    // gives queue executions a sensible default phase, so the dashboard
    // doesn't silently go empty after a queue submission.
    enum CodingKeys: String, CodingKey {
        case id, title, objective, status, phase, priority, deskHandle, projectSpaceId
        case autonomyLevel, permissionProfile, summary
        case createdAt, updatedAt, completedAt, receiptCount
        // snake_case fallbacks
        case created_at, updated_at, completed_at, desk_handle, project_space_id
        case autonomy_level, permission_profile, receipt_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(String.self, forKey: .id)
        self.deskHandle = try c.decodeIfPresent(String.self, forKey: .deskHandle)
                        ?? c.decodeIfPresent(String.self, forKey: .desk_handle)
        self.projectSpaceId = try c.decodeIfPresent(String.self, forKey: .projectSpaceId)
                           ?? c.decodeIfPresent(String.self, forKey: .project_space_id)
        self.title     = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.objective = try c.decodeIfPresent(String.self, forKey: .objective) ?? ""
        self.status    = try c.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        // Queue Workshop executions have no phase; default to status-derived value.
        if let p = try c.decodeIfPresent(String.self, forKey: .phase) {
            self.phase = p
        } else {
            self.phase = self.status   // queue items repeat status as phase
        }
        self.priority           = try c.decodeIfPresent(String.self, forKey: .priority)
        self.autonomyLevel      = try c.decodeIfPresent(String.self, forKey: .autonomyLevel)
                                ?? c.decodeIfPresent(String.self, forKey: .autonomy_level)
        self.permissionProfile  = try c.decodeIfPresent(String.self, forKey: .permissionProfile)
                                ?? c.decodeIfPresent(String.self, forKey: .permission_profile)
        self.summary            = try c.decodeIfPresent(String.self, forKey: .summary)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
                       ?? c.decodeIfPresent(String.self, forKey: .created_at)
                       ?? ""
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
                       ?? c.decodeIfPresent(String.self, forKey: .updated_at)
        self.completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
                         ?? c.decodeIfPresent(String.self, forKey: .completed_at)
        self.receiptCount = try c.decodeIfPresent(Int.self, forKey: .receiptCount)
                          ?? c.decodeIfPresent(Int.self, forKey: .receipt_count)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(deskHandle, forKey: .deskHandle)
        try c.encodeIfPresent(projectSpaceId, forKey: .projectSpaceId)
        try c.encode(title, forKey: .title)
        try c.encode(objective, forKey: .objective)
        try c.encode(status, forKey: .status)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(autonomyLevel, forKey: .autonomyLevel)
        try c.encodeIfPresent(permissionProfile, forKey: .permissionProfile)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(receiptCount, forKey: .receiptCount)
    }
}

extension WorkshopExecutionRecord {
    /// Direct construction. `init(from decoder:)` above suppresses the
    /// memberwise init, which forced UI bridges to round-trip through
    /// JSONSerialization + JSONDecoder just to build a record in memory —
    /// a path whose only totality guarantee was a `try!` on an interpolated
    /// JSON string. `phase` defaults to `status`, matching the decoder's
    /// rule for queue Workshop executions that carry no phase of their own.
    init(
        id: String,
        deskHandle: String? = nil,
        projectSpaceId: String? = nil,
        title: String = "",
        objective: String = "",
        status: String = "queued",
        phase: String? = nil,
        priority: String? = nil,
        autonomyLevel: String? = nil,
        permissionProfile: String? = nil,
        summary: String? = nil,
        createdAt: String = "",
        updatedAt: String? = nil,
        completedAt: String? = nil,
        receiptCount: Int? = nil
    ) {
        self.id = id
        self.deskHandle = deskHandle
        self.projectSpaceId = projectSpaceId
        self.title = title
        self.objective = objective
        self.status = status
        self.phase = phase ?? status
        self.priority = priority
        self.autonomyLevel = autonomyLevel
        self.permissionProfile = permissionProfile
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.receiptCount = receiptCount
    }
}

// WorkshopCounts, ConnectorSummary, TrustSummary moved to NativeAgentShared.

struct CommandSummary: Codable, Hashable {
    var health: RuntimeHealth
    var codexAuth: CodexAuthStatus
    var executionCounts: WorkshopCounts
    var activeExecutions: [WorkshopExecutionRecord]
    var recentActivity: [ActivityEvent]
    var nextJobs: [SchedulerJob]
    var connectorSummary: ConnectorSummary
    var autonomyCommandCenter: AutonomyCommandCenterSummary?
    var coordinationSummary: CoordinationSummary?
    var trustSummary: TrustSummary
    var latestEval: EvalRun?

    enum CodingKeys: String, CodingKey {
        case health, codexAuth, recentActivity, nextJobs, connectorSummary
        case autonomyCommandCenter, coordinationSummary, trustSummary, latestEval
        case executionCounts = "missionCounts" // compatibility wire ID
        case activeExecutions = "activeMissions" // compatibility wire ID
    }
}

struct CoordinationSummary: Codable, Hashable {
    var status: String?
    var intentRouter: CoordinationIntentRouter?
    var receiptQuality: CoordinationReceiptQuality?
    var memoryConfidence: CoordinationMemoryConfidence?
    var selfImprovementScoreboard: CoordinationScoreboard?
    var commandPalette: CoordinationCommandPalette?
    var operatingMap: CoordinationOperatingMap?
    var lazyContract: AutonomyLazyContract?
    var createdAt: String?
}

struct CoordinationIntentRouter: Codable, Hashable {
    var status: String?
    var turnTypes: [CoordinationTurnType]?
    var defaultRule: String?
    var lazyContract: CoordinationLazyManifest?
}

struct CoordinationLazyManifest: Codable, Hashable {
    var chatInjection: String?
    var manifestRouted: Bool?
    var heavyBodiesLoaded: String?
}

struct CoordinationTurnType: Identifiable, Codable, Hashable {
    var id: String
    var contextMode: String?
    var pulls: [String]?
    var policy: String?
}

struct CoordinationReceiptQuality: Codable, Hashable {
    var status: String?
    var latest: [CoordinationReceipt]?
    var coverage: CoordinationReceiptCoverage?
    var standard: [String]?
    var createdAt: String?
}

struct CoordinationReceipt: Identifiable, Codable, Hashable {
    var id: String
    var kind: String?
    var title: String?
    var whatChanged: [String]?
    var why: String?
    var proof: String?
    var status: String?
    var permanence: String?
    var createdAt: String?
}

struct CoordinationReceiptCoverage: Codable, Hashable {
    var totalSampled: Int?
    var withProof: Int?
    var provisional: Int?
    var permanent: Int?
}

struct CoordinationMemoryConfidence: Codable, Hashable {
    var status: String?
    var counts: [String: Int]?
    var byLayer: [String: Int]?
    var total: Int?
    var attentionSamples: [CoordinationMemorySample]?
    var rules: [String]?
    var createdAt: String?
}

struct CoordinationMemorySample: Identifiable, Codable, Hashable {
    var id: String?
    var bucket: String?
    var layer: String?
    var confidence: Double?
    var status: String?
    var text: String?
}

struct CoordinationScoreboard: Codable, Hashable {
    var status: String?
    var metrics: [CoordinationMetric]?
    var evidence: CoordinationScoreboardEvidence?
    var regressionPolicy: CoordinationRegressionPolicy?
    var latestLearningReceipts: [HarnessLearningReceipt]?
    var createdAt: String?
}

struct CoordinationMetric: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var value: Double?
    var unit: String?
    var direction: String?
    var source: String?
}

struct CoordinationScoreboardEvidence: Codable, Hashable {
    var totalRuns: Int?
    var succeededRuns: Int?
    var failedRuns: Int?
    var interruptedRuns: Int?
    var stagedRuns: Int?
    var learningProposalCounts: [String: Int]?
    var measuredLearnings: Int?
    var positiveUplift: Int?
    var negativeUplift: Int?
}

struct CoordinationRegressionPolicy: Codable, Hashable {
    var weakImprovements: String?
    var permanentDemotion: String?
    var promotion: String?
}

struct CoordinationCommandPalette: Codable, Hashable {
    var status: String?
    var query: String?
    var entries: [CoordinationCommandEntry]?
    var lazyContract: CoordinationPaletteLazyContract?
    var createdAt: String?
}

struct CoordinationPaletteLazyContract: Codable, Hashable {
    var chatInjection: String?
    var inventoryMode: String?
    var opens: String?
}

struct CoordinationCommandEntry: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var subtitle: String?
    var category: String?
    var systemImage: String?
    var route: String?
    var endpoint: String?
    var keywords: [String]?
    var status: String?
    var count: Int?
}

struct CoordinationOperatingMap: Codable, Hashable {
    var status: String?
    var summary: CoordinationOperatingSummary?
    var policy: UnifiedAutonomyPolicySummary?
    var recentLearning: [HarnessLearningReceipt]?
    var canBuild: [String]?
    var brokenOrDisabled: [AutonomyCommandOpenLoop]?
    var promptBrief: String?
}

struct CoordinationOperatingSummary: Codable, Hashable {
    var features: Int?
    var capabilities: Int?
    var active: Int?
    var skills: Int?
    var tools: Int?
    var workflows: Int?
    var mcpServers: Int?
    var catalogItems: Int?
    var memories: Int?
    var byKind: [String: Int]?
}

struct AutonomyCommandCenterSummary: Codable, Hashable {
    var status: String?
    var headline: String?
    var counts: AutonomyCommandCounts?
    var lanes: [AutonomyCommandLane]?
    var latestIdeas: [AutonomyCommandIdea]?
    var openLoops: [AutonomyCommandOpenLoop]?
    var nextActions: [AutonomyCommandAction]?
    var policy: UnifiedAutonomyPolicySummary?
    var promotionStandard: AutonomyPromotionStandard?
    var lazyContract: AutonomyLazyContract?
    var createdAt: String?
}

struct AutonomyCommandCounts: Codable, Hashable {
    var ideas: Int?
    var outcomes: Int?
    var pendingApprovals: Int?
    var unreadInbox: Int?
    var openLoops: Int?
    var foundryReview: Int?
    var foundryActive: Int?
    var skillDrafts: Int?
    var toolDrafts: Int?
    var learningPending: Int?
    var learningPermanent: Int?
    var learningArchived: Int?
    var improvementRunning: Int?
    var improvementStaged: Int?
    var improvementFailed: Int?
    var proactiveJobs: Int?
    var improveJobs: Int?
    var provisional: Int?
    var permanent: Int?
}

struct AutonomyCommandLane: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var status: String?
    var count: Int?
    var detail: String?
    var endpoint: String?
}

struct AutonomyCommandIdea: Identifiable, Codable, Hashable {
    var id: String
    var kind: String?
    var title: String?
    var summary: String?
    var decision: String?
    var risk: String?
    var score: Double?
    var createdAt: String?
}

struct AutonomyCommandOpenLoop: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var count: Int?
    var status: String?
    var endpoint: String?
}

struct AutonomyCommandAction: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var detail: String?
    var status: String?
    var endpoint: String?
}

struct UnifiedAutonomyPolicySummary: Codable, Hashable {
    var status: String?
    var permissionLevel: String?
    var fullMacMode: String?
    var gates: [UnifiedAutonomyPolicyGate]?
    var attentionCount: Int?
    var hardStops: [String]?
    var protectedPathPrefixes: [String]?
    var sources: [String]?
    var createdAt: String?
}

struct UnifiedAutonomyPolicyGate: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var enabled: Bool?
    var value: String?
    var status: String?
    var detail: String?
    var source: String?
}

struct AutonomyPromotionStandard: Codable, Hashable {
    var status: String?
    var principle: String?
    var stages: [AutonomyPromotionStage]?
    var layers: [AutonomyPromotionLayer]?
    var riskClasses: [AutonomyPromotionRiskClass]?
    var createdAt: String?
}

struct AutonomyPromotionStage: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var gate: String?
    var evidence: String?
}

struct AutonomyPromotionLayer: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var currentCount: Int?
    var standard: String?
}

struct AutonomyPromotionRiskClass: Identifiable, Codable, Hashable {
    var id: String
    var title: String?
    var permissions: [String]?
    var rule: String?
}

struct AutonomyLazyContract: Codable, Hashable {
    var chatInjection: String?
    var inventoryMode: String?
    var bodiesLoaded: String?
    var readouts: [String]?
}

// MultimodalAttachment moved to NativeAgentShared.
