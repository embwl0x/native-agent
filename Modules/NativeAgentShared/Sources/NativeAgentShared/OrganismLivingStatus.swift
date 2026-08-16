import Foundation

/// Rebuildable, read-only organism projection shared by the Mac snapshot
/// writer and the iOS display client. Cognition remains Mac-owned; this DTO is
/// transport tissue only and deliberately carries no behavior.
public struct OrganismLivingStatusFile: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var enabled: Bool
    public var posture: String
    public var bodyLine: String?
    public var behaviorLine: String
    public var needsUser: Bool
    public var needsAttention: Bool?
    public var signalCount: Int
    public var lastSignalAt: Date?
    public var body: OrganismLivingBodyFile
    public var counters: OrganismLivingCountersFile
    public var reflexCandidates: [OrganismLivingReflexCandidateFile]?
    public var standingViewProposals: [OrganismLivingStandingViewProposalFile]?

    public init(
        generatedAt: Date,
        enabled: Bool,
        posture: String,
        bodyLine: String?,
        behaviorLine: String,
        needsUser: Bool,
        needsAttention: Bool?,
        signalCount: Int,
        lastSignalAt: Date?,
        body: OrganismLivingBodyFile,
        counters: OrganismLivingCountersFile,
        reflexCandidates: [OrganismLivingReflexCandidateFile]?,
        standingViewProposals: [OrganismLivingStandingViewProposalFile]?
    ) {
        self.generatedAt = generatedAt
        self.enabled = enabled
        self.posture = posture
        self.bodyLine = bodyLine
        self.behaviorLine = behaviorLine
        self.needsUser = needsUser
        self.needsAttention = needsAttention
        self.signalCount = signalCount
        self.lastSignalAt = lastSignalAt
        self.body = body
        self.counters = counters
        self.reflexCandidates = reflexCandidates
        self.standingViewProposals = standingViewProposals
    }
}

public struct OrganismLivingBodyFile: Codable, Hashable, Sendable {
    public var macAwake: Bool
    public var iPhoneReachable: Bool
    public var providersHealthy: Bool
    public var memoryHealthy: Bool
    public var dreamHealthy: Bool
    public var toolHandsAvailable: Bool
    public var approvalChannelsOpen: Bool
    public var notificationPathHealthy: Bool
    public var resourcePressure: String

    public init(
        macAwake: Bool,
        iPhoneReachable: Bool,
        providersHealthy: Bool,
        memoryHealthy: Bool,
        dreamHealthy: Bool,
        toolHandsAvailable: Bool,
        approvalChannelsOpen: Bool,
        notificationPathHealthy: Bool,
        resourcePressure: String
    ) {
        self.macAwake = macAwake
        self.iPhoneReachable = iPhoneReachable
        self.providersHealthy = providersHealthy
        self.memoryHealthy = memoryHealthy
        self.dreamHealthy = dreamHealthy
        self.toolHandsAvailable = toolHandsAvailable
        self.approvalChannelsOpen = approvalChannelsOpen
        self.notificationPathHealthy = notificationPathHealthy
        self.resourcePressure = resourcePressure
    }
}

public struct OrganismLivingCountersFile: Codable, Hashable, Sendable {
    public var fieldNodes: Int
    public var pendingPredictions: Int
    public var dreamRepairs: Int
    public var reflexCandidates: Int
    public var reflexesNeedReview: Int
    public var approvedReflexBiases: Int?
    public var standingViewProposals: Int?

    public init(
        fieldNodes: Int,
        pendingPredictions: Int,
        dreamRepairs: Int,
        reflexCandidates: Int,
        reflexesNeedReview: Int,
        approvedReflexBiases: Int?,
        standingViewProposals: Int?
    ) {
        self.fieldNodes = fieldNodes
        self.pendingPredictions = pendingPredictions
        self.dreamRepairs = dreamRepairs
        self.reflexCandidates = reflexCandidates
        self.reflexesNeedReview = reflexesNeedReview
        self.approvedReflexBiases = approvedReflexBiases
        self.standingViewProposals = standingViewProposals
    }
}

public struct OrganismLivingReflexCandidateFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pattern: String
    public var trustClass: String
    public var confidence: Double
    public var reviewRequired: Bool
    public var autoActivationAllowed: Bool
    public var approvedAt: Date?

    public init(
        id: String,
        pattern: String,
        trustClass: String,
        confidence: Double,
        reviewRequired: Bool,
        autoActivationAllowed: Bool,
        approvedAt: Date?
    ) {
        self.id = id
        self.pattern = pattern
        self.trustClass = trustClass
        self.confidence = confidence
        self.reviewRequired = reviewRequired
        self.autoActivationAllowed = autoActivationAllowed
        self.approvedAt = approvedAt
    }
}

public struct OrganismLivingStandingViewProposalFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var rationale: String
    public var evidenceIDs: [String]
    public var reviewRequired: Bool

    public init(
        id: String,
        title: String,
        rationale: String,
        evidenceIDs: [String],
        reviewRequired: Bool
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.evidenceIDs = evidenceIDs
        self.reviewRequired = reviewRequired
    }
}
