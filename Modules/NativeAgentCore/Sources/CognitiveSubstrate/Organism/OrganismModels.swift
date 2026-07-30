import Foundation
import PersistenceCore

public enum SomaticSignalKind: String, Codable, Sendable, Equatable, CaseIterable {
    case userSpoke
    case assistantSpoke
    case correctionReceived
    case toolStarted
    case toolSucceeded
    case toolFailed
    case toolCancelled
    case providerStarted
    case providerSucceeded
    case providerFailed
    case providerCancelled
    case providerRecovered
    case deskItemCreated
    case deskItemBlocked
    case deskItemClosed
    case memoryCommitted
    case memoryCorrected
    case memoryHygieneCompleted
    case dreamCompleted
    case remIntegrated
    case iPhoneReachable
    case iPhoneStale
    case phoneDeliveryStarted
    case phoneDeliveryReceived
    case phoneDeliveryFailed
    case approvalRequested
    case approvalResolved
    case appWake
    case appSleep
    case resourcePressureChanged
}

public struct SomaticSignal: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: SomaticSignalKind
    public var sourceOrgan: String
    public var occurredAt: Date
    public var intensity: Double
    public var valence: Double?
    public var arousal: Double?
    public var metadata: [String: JSONValue]

    public init(
        id: UUID,
        kind: SomaticSignalKind,
        sourceOrgan: String,
        occurredAt: Date,
        intensity: Double = 0.5,
        valence: Double? = nil,
        arousal: Double? = nil,
        metadata: [String: JSONValue] = [:],
        bounds: OrganismMetadataBounds = .defaults
    ) {
        self.id = id
        self.kind = kind
        let cleanSource = sourceOrgan.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceOrgan = cleanSource.isEmpty ? "unknown" : String(cleanSource.prefix(80))
        self.occurredAt = occurredAt
        self.intensity = Self.clamp01(intensity)
        self.valence = valence.map(Self.clampSigned)
        self.arousal = arousal.map(Self.clamp01)
        self.metadata = Self.boundedMetadata(metadata, bounds: bounds)
    }

    static func clamp01(_ value: Double) -> Double { value.clamped01() }
    static func clampSigned(_ value: Double) -> Double { value.clampedSigned() }

    public static func boundedMetadata(
        _ metadata: [String: JSONValue],
        bounds: OrganismMetadataBounds = .defaults
    ) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in metadata.keys.sorted().prefix(bounds.maximumKeys) {
            let cleanKey = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !cleanKey.isEmpty else { continue }
            // Routed through the shared JSONValueBounding (audit C9) — same
            // redaction + depth-cap this organism path already applied, now the
            // single source the substrate/continuity-field paths share too.
            out[cleanKey] = JSONValueBounding.bounded(
                metadata[key] ?? .null,
                bounds: bounds,
                redactSecrets: true,
                keyPath: cleanKey.lowercased(),
                depth: 0
            )
        }
        return out
    }
}

public struct OrganismMetadataBounds: Sendable, Equatable {
    public var maximumKeys: Int
    public var maximumStringCharacters: Int
    public var maximumArrayItems: Int
    public var maximumDepth: Int

    public init(
        maximumKeys: Int = 12,
        maximumStringCharacters: Int = 240,
        maximumArrayItems: Int = 8,
        maximumDepth: Int = 3
    ) {
        self.maximumKeys = max(0, maximumKeys)
        self.maximumStringCharacters = max(0, maximumStringCharacters)
        self.maximumArrayItems = max(0, maximumArrayItems)
        self.maximumDepth = max(1, maximumDepth)
    }

    public static let defaults = OrganismMetadataBounds()
}

public struct ChemicalState: Codable, Sendable, Equatable {
    public var warmth: Double
    public var vigilance: Double
    public var curiosity: Double
    public var fatigue: Double
    public var coherence: Double
    public var agency: Double
    public var tenderness: Double
    public var confidence: Double
    public var novelty: Double
    public var urgency: Double

    public init(
        warmth: Double = 0,
        vigilance: Double = 0,
        curiosity: Double = 0,
        fatigue: Double = 0,
        coherence: Double = 0.5,
        agency: Double = 0,
        tenderness: Double = 0,
        confidence: Double = 0.5,
        novelty: Double = 0,
        urgency: Double = 0
    ) {
        self.warmth = Self.clamp(warmth)
        self.vigilance = Self.clamp(vigilance)
        self.curiosity = Self.clamp(curiosity)
        self.fatigue = Self.clamp(fatigue)
        self.coherence = Self.clamp(coherence)
        self.agency = Self.clamp(agency)
        self.tenderness = Self.clamp(tenderness)
        self.confidence = Self.clamp(confidence)
        self.novelty = Self.clamp(novelty)
        self.urgency = Self.clamp(urgency)
    }

    public static let neutral = ChemicalState()

    public static func clamp(_ value: Double) -> Double {
        (value).clamped01()
    }

    public var isNeutral: Bool {
        self == .neutral
    }
}

public enum OrganismResourcePressure: String, Codable, Sendable, Equatable, CaseIterable {
    case nominal
    case elevated
    case high
    case critical
}

public struct BodySchema: Codable, Sendable, Equatable {
    public var macAwake: Bool
    public var iPhoneReachable: Bool
    public var providersHealthy: Bool
    /// Exact configured/credential availability, deliberately distinct from
    /// the evidence-derived `providersHealthy` compatibility projection.
    public var providersAvailable: Bool
    /// Typed, uncertainty-bearing read projection when a provider evidence
    /// assembler supplied one. Nil preserves compatibility with legacy exact
    /// body samples; this never becomes provider-selection authority.
    public var providerPathBelief: ProviderPathBeliefProjection?
    /// Transient domain-owned reads. They are rebuilt from canonical evidence
    /// after restart and intentionally omitted from organism persistence.
    public var peerPresenceBelief: PeerPresenceBelief?
    public var notificationDeliveryBelief: NotificationDeliveryBelief?
    public var memoryIntegrityReading: MemoryIntegrityReading?
    public var dreamIntegrityReading: DreamIntegrityReading?
    public var toolCapabilityReading: ToolCapabilityReading?
    public var approvalPathReading: ApprovalPathReading?
    public var resourcePressureReading: ResourcePressureReading?
    public var memoryHealthy: Bool
    public var dreamHealthy: Bool
    public var toolHandsAvailable: Bool
    public var approvalChannelsOpen: Bool
    public var notificationPathHealthy: Bool
    public var resourcePressure: OrganismResourcePressure

    public init(
        macAwake: Bool = true,
        iPhoneReachable: Bool = false,
        providersHealthy: Bool = true,
        providersAvailable: Bool = true,
        providerPathBelief: ProviderPathBeliefProjection? = nil,
        peerPresenceBelief: PeerPresenceBelief? = nil,
        notificationDeliveryBelief: NotificationDeliveryBelief? = nil,
        memoryIntegrityReading: MemoryIntegrityReading? = nil,
        dreamIntegrityReading: DreamIntegrityReading? = nil,
        toolCapabilityReading: ToolCapabilityReading? = nil,
        approvalPathReading: ApprovalPathReading? = nil,
        resourcePressureReading: ResourcePressureReading? = nil,
        memoryHealthy: Bool = true,
        dreamHealthy: Bool = true,
        toolHandsAvailable: Bool = true,
        approvalChannelsOpen: Bool = true,
        notificationPathHealthy: Bool = true,
        resourcePressure: OrganismResourcePressure = .nominal
    ) {
        self.macAwake = macAwake
        self.iPhoneReachable = iPhoneReachable
        self.providersHealthy = providersHealthy
        self.providersAvailable = providersAvailable
        self.providerPathBelief = providerPathBelief
        self.peerPresenceBelief = peerPresenceBelief
        self.notificationDeliveryBelief = notificationDeliveryBelief
        self.memoryIntegrityReading = memoryIntegrityReading
        self.dreamIntegrityReading = dreamIntegrityReading
        self.toolCapabilityReading = toolCapabilityReading
        self.approvalPathReading = approvalPathReading
        self.resourcePressureReading = resourcePressureReading
        self.memoryHealthy = memoryHealthy
        self.dreamHealthy = dreamHealthy
        self.toolHandsAvailable = toolHandsAvailable
        self.approvalChannelsOpen = approvalChannelsOpen
        self.notificationPathHealthy = notificationPathHealthy
        self.resourcePressure = resourcePressure
    }

    public static let neutral = BodySchema()

    /// Typed read metadata is observational and must not make an otherwise
    /// neutral organism projection look active. Only compatibility state that
    /// can shape posture/capsule/compute participates in this check.
    public var compatibilityIsNeutral: Bool {
        macAwake
            && !iPhoneReachable
            && providersHealthy
            && providersAvailable
            && memoryHealthy
            && dreamHealthy
            && toolHandsAvailable
            && approvalChannelsOpen
            && notificationPathHealthy
            && resourcePressure == .nominal
    }

    /// Typed beliefs/readings are transient projections and intentionally
    /// excluded from persistence. Exact compatibility facts survive restart;
    /// every uncertain domain read must be rebuilt from its canonical evidence
    /// under the injected data root.
    private enum CodingKeys: String, CodingKey {
        case macAwake, iPhoneReachable, providersHealthy, providersAvailable, memoryHealthy
        case dreamHealthy, toolHandsAvailable, approvalChannelsOpen
        case notificationPathHealthy, resourcePressure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            macAwake: try container.decodeIfPresent(Bool.self, forKey: .macAwake) ?? true,
            iPhoneReachable: try container.decodeIfPresent(Bool.self, forKey: .iPhoneReachable) ?? false,
            providersHealthy: try container.decodeIfPresent(Bool.self, forKey: .providersHealthy) ?? true,
            providersAvailable: try container.decodeIfPresent(Bool.self, forKey: .providersAvailable)
                ?? (try container.decodeIfPresent(Bool.self, forKey: .providersHealthy) ?? true),
            providerPathBelief: nil,
            peerPresenceBelief: nil,
            notificationDeliveryBelief: nil,
            memoryIntegrityReading: nil,
            dreamIntegrityReading: nil,
            toolCapabilityReading: nil,
            approvalPathReading: nil,
            resourcePressureReading: nil,
            memoryHealthy: try container.decodeIfPresent(Bool.self, forKey: .memoryHealthy) ?? true,
            dreamHealthy: try container.decodeIfPresent(Bool.self, forKey: .dreamHealthy) ?? true,
            toolHandsAvailable: try container.decodeIfPresent(Bool.self, forKey: .toolHandsAvailable) ?? true,
            approvalChannelsOpen: try container.decodeIfPresent(Bool.self, forKey: .approvalChannelsOpen) ?? true,
            notificationPathHealthy: try container.decodeIfPresent(Bool.self, forKey: .notificationPathHealthy) ?? true,
            resourcePressure: try container.decodeIfPresent(OrganismResourcePressure.self, forKey: .resourcePressure) ?? .nominal
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(macAwake, forKey: .macAwake)
        try container.encode(iPhoneReachable, forKey: .iPhoneReachable)
        try container.encode(providersHealthy, forKey: .providersHealthy)
        try container.encode(providersAvailable, forKey: .providersAvailable)
        try container.encode(memoryHealthy, forKey: .memoryHealthy)
        try container.encode(dreamHealthy, forKey: .dreamHealthy)
        try container.encode(toolHandsAvailable, forKey: .toolHandsAvailable)
        try container.encode(approvalChannelsOpen, forKey: .approvalChannelsOpen)
        try container.encode(notificationPathHealthy, forKey: .notificationPathHealthy)
        try container.encode(resourcePressure, forKey: .resourcePressure)
    }
}

public struct OrganismProjection: Sendable, Equatable {
    public var generatedAt: Date
    public var bodyLine: String?
    public var chemicalState: ChemicalState
    public var bodySchema: BodySchema

    public init(
        generatedAt: Date,
        bodyLine: String? = nil,
        chemicalState: ChemicalState = .neutral,
        bodySchema: BodySchema = .neutral
    ) {
        self.generatedAt = generatedAt
        self.bodyLine = bodyLine
        self.chemicalState = chemicalState
        self.bodySchema = bodySchema
    }

    public var isNeutral: Bool {
        bodyLine == nil && chemicalState.isNeutral && bodySchema.compatibilityIsNeutral
    }
}

public struct OrganismSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    public var enabled: Bool
    public var chemicalState: ChemicalState
    public var bodySchema: BodySchema
    public var fieldSummary: OrganismFieldSummary
    public var predictionSummary: OrganismPredictionSummary
    public var dreamRepairSummary: OrganismDreamRepairSummary
    public var reflexSummary: OrganismReflexSummary
    public var reflexCandidates: [OrganismReflexCandidate]
    public var reflexReviewReceipts: [OrganismReflexReviewReceipt]
    public var residualRepairOpportunity: OrganismResidualRepairOpportunity
    public var capabilityBeliefs: [OrganismCapabilityBelief]
    public var projectedBodyLine: String?
    public var signalCount: Int
    public var lastSignalAt: Date?

    public init(
        generatedAt: Date,
        enabled: Bool,
        chemicalState: ChemicalState,
        bodySchema: BodySchema,
        fieldSummary: OrganismFieldSummary = .empty,
        predictionSummary: OrganismPredictionSummary = .empty,
        dreamRepairSummary: OrganismDreamRepairSummary = .empty,
        reflexSummary: OrganismReflexSummary = .empty,
        reflexCandidates: [OrganismReflexCandidate] = [],
        reflexReviewReceipts: [OrganismReflexReviewReceipt] = [],
        residualRepairOpportunity: OrganismResidualRepairOpportunity? = nil,
        capabilityBeliefs: [OrganismCapabilityBelief] = [],
        projectedBodyLine: String? = nil,
        signalCount: Int,
        lastSignalAt: Date?
    ) {
        self.generatedAt = generatedAt
        self.enabled = enabled
        self.chemicalState = chemicalState
        self.bodySchema = bodySchema
        self.fieldSummary = fieldSummary
        self.predictionSummary = predictionSummary
        self.dreamRepairSummary = dreamRepairSummary
        self.reflexSummary = reflexSummary
        // The compiler itself is bounded to 64 candidates. Keep that complete
        // bounded set in the runtime snapshot: truncating to 12 before behavior
        // posture was derived hid approved reflexes whenever review-required
        // candidates sorted ahead of them, and also made omitted candidates
        // impossible to review through the runtime-owned path.
        self.reflexCandidates = Array(reflexCandidates.prefix(64))
        self.reflexReviewReceipts = Array(reflexReviewReceipts.prefix(24))
        self.residualRepairOpportunity = residualRepairOpportunity ?? .empty(at: generatedAt)
        self.capabilityBeliefs = Array(capabilityBeliefs.prefix(OrganismPredictionKind.allCases.count))
        self.projectedBodyLine = projectedBodyLine
        self.signalCount = max(0, signalCount)
        self.lastSignalAt = lastSignalAt
    }
}

/// Fixed-time organism read created by decaying a copied persistent state.
/// It is nonpersistent and carries no authority; provider experiments consume
/// only its projection/posture while the live kernel remains untouched.
public struct OrganismFrozenRead: Sendable, Equatable {
    public let fixedAt: Date
    public let revisionFingerprint: String
    public let snapshot: OrganismSnapshot
    public let projection: OrganismProjection
    public let posture: OrganismBehaviorPosture?

    public init(
        fixedAt: Date,
        revisionFingerprint: String,
        snapshot: OrganismSnapshot,
        projection: OrganismProjection,
        posture: OrganismBehaviorPosture?
    ) {
        self.fixedAt = fixedAt
        self.revisionFingerprint = revisionFingerprint
        self.snapshot = snapshot
        self.projection = projection
        self.posture = posture
    }
}

public struct OrganismConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var metadataBounds: OrganismMetadataBounds
    public var fieldLimits: OrganismFieldLimits
    public var predictionLimits: OrganismPredictionLimits
    public var dreamRepairLimits: OrganismDreamRepairLimits
    public var reflexLimits: OrganismReflexLimits

    public init(
        enabled: Bool = false,
        metadataBounds: OrganismMetadataBounds = .defaults,
        fieldLimits: OrganismFieldLimits = .defaults,
        predictionLimits: OrganismPredictionLimits = .defaults,
        dreamRepairLimits: OrganismDreamRepairLimits = .defaults,
        reflexLimits: OrganismReflexLimits = .defaults
    ) {
        self.enabled = enabled
        self.metadataBounds = metadataBounds
        self.fieldLimits = fieldLimits
        self.predictionLimits = predictionLimits
        self.dreamRepairLimits = dreamRepairLimits
        self.reflexLimits = reflexLimits
    }

    public static let disabled = OrganismConfiguration(enabled: false)
    public static let enabled = OrganismConfiguration(enabled: true)
}
