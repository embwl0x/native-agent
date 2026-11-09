import Foundation
import PersistenceCore
// Blueprint: | `OrganismModels.swift` | `SomaticSignalKind` enum |

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
    case deskItemCancelled
    case memoryCommitted
    case memoryCorrected
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
    /// Horizon refresh changes prediction rows only, without chemistry, body facts, field associations or intrinsic valence.
    case horizonRefresh
    /// One of the agent's organs broke from its record (missed, failed, stuck or off record), felt once at its onset and again as it grows.
    case organDeviated
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
        self.intensity = intensity.clamped01()
        self.valence = valence.map { $0.clampedSigned() }
        self.arousal = arousal.map { $0.clamped01() }
        self.metadata = Self.boundedMetadata(metadata, bounds: bounds)
    }

    public static func boundedMetadata(
        _ metadata: [String: JSONValue],
        bounds: OrganismMetadataBounds = .defaults
    ) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in metadata.keys.sorted().prefix(bounds.maximumKeys) {
            let cleanKey = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !cleanKey.isEmpty else { continue }
            // Share metadata redaction and depth bounds across organism, substrate and continuity paths.
            out[cleanKey] = JSONValueBounding.bounded(
                metadata[key] ?? .null,
                bounds: bounds,
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
        self.warmth = warmth.clamped01()
        self.vigilance = vigilance.clamped01()
        self.curiosity = curiosity.clamped01()
        self.fatigue = fatigue.clamped01()
        self.coherence = coherence.clamped01()
        self.agency = agency.clamped01()
        self.tenderness = tenderness.clamped01()
        self.confidence = confidence.clamped01()
        self.novelty = novelty.clamped01()
        self.urgency = urgency.clamped01()
    }

    public static let neutral = ChemicalState()

    public var isNeutral: Bool {
        self == .neutral
    }
}

public enum OrganismResourcePressure: String, Codable, Sendable, Equatable, CaseIterable {
    case nominal
    case elevated
    case high
    case critical

    static func from(metadata: [String: JSONValue]) -> Self? {
        guard case .string(let raw)? = metadata["resourcePressure"] else { return nil }
        return Self(rawValue: raw)
    }
}

public struct BodySchema: Codable, Sendable, Equatable {
    public var macAwake: Bool
    public var iPhoneReachable: Bool
    public var providersHealthy: Bool
    /// Configuration availability is exact; path health remains an evidence-derived projection.
    public var providersAvailable: Bool
    /// Typed provider reads carry uncertainty; absent reads retain exact body-sample fields without granting provider-selection authority.
    public var providerPathBelief: ProviderPathEstimate?
    /// Transient domain-owned reads. They are rebuilt from canonical evidence after restart and intentionally omitted from organism persistence.
    public var peerPresenceBelief: PeerPresenceBelief?
    public var notificationDeliveryBelief: NotificationDeliveryBelief?
    public var memoryIntegrityReading: MemoryIntegrityReading?
    public var dreamIntegrityReading: DreamIntegrityReading?
    public var toolCapabilityReading: ToolCapabilityReading?
    /// Transient projection of canonical tool receipts; absent evidence makes no recovery claim.
    public var handPain: [OrganismHandPain] = []
    public var approvalPathReading: ApprovalPathReading?
    public var resourcePressureReading: ResourcePressureReading?
    public var memoryHealthy: Bool
    public var dreamHealthy: Bool
    public var toolHandsAvailable: Bool
    public var approvalChannelsOpen: Bool
    /// Delivery evidence only; nil means no current delivery verdict.
    public var notificationPathHealthy: Bool?
    public var resourcePressure: OrganismResourcePressure

    public init(
        macAwake: Bool = true,
        iPhoneReachable: Bool = false,
        providersHealthy: Bool = true,
        providersAvailable: Bool = true,
        providerPathBelief: ProviderPathEstimate? = nil,
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
        notificationPathHealthy: Bool? = nil,
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

    /// Observational typed metadata alone cannot make a neutral projection active.
    public var compatibilityIsNeutral: Bool {
        macAwake
            && !iPhoneReachable
            && providersHealthy
            && providersAvailable
            && memoryHealthy
            && dreamHealthy
            && toolHandsAvailable
            && approvalChannelsOpen
            && notificationPathHealthy != false
            && resourcePressure == .nominal
    }

    /// Persist exact body facts only; rebuild uncertain domain reads from their canonical owners after restart.
    private enum CodingKeys: String, CodingKey {
        case macAwake, iPhoneReachable, providersHealthy, providersAvailable, memoryHealthy
        case dreamHealthy, toolHandsAvailable, approvalChannelsOpen
        case notificationPathHealthy, resourcePressure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            macAwake: try container.decode(Bool.self, forKey: .macAwake),
            iPhoneReachable: try container.decode(Bool.self, forKey: .iPhoneReachable),
            providersHealthy: try container.decode(Bool.self, forKey: .providersHealthy),
            providersAvailable: try container.decode(Bool.self, forKey: .providersAvailable),
            providerPathBelief: nil,
            peerPresenceBelief: nil,
            notificationDeliveryBelief: nil,
            memoryIntegrityReading: nil,
            dreamIntegrityReading: nil,
            toolCapabilityReading: nil,
            approvalPathReading: nil,
            resourcePressureReading: nil,
            memoryHealthy: try container.decode(Bool.self, forKey: .memoryHealthy),
            dreamHealthy: try container.decode(Bool.self, forKey: .dreamHealthy),
            toolHandsAvailable: try container.decode(Bool.self, forKey: .toolHandsAvailable),
            approvalChannelsOpen: try container.decode(Bool.self, forKey: .approvalChannelsOpen),
            notificationPathHealthy: try container.decodeIfPresent(Bool.self, forKey: .notificationPathHealthy),
            resourcePressure: try container.decode(OrganismResourcePressure.self, forKey: .resourcePressure)
        )
    }
}

public struct OrganismReadout: Sendable, Equatable {
    public var generatedAt: Date
    public var bodyLine: String?
    public var chemicalState: ChemicalState
    public var bodySchema: BodySchema
    /// The fingerprint reads the body's diurnal clock here; nil means no configured clock or a disabled organism.
    public var diurnal: OrganismDiurnalRead?

    public init(
        generatedAt: Date,
        bodyLine: String? = nil,
        chemicalState: ChemicalState = .neutral,
        bodySchema: BodySchema = .neutral,
        diurnal: OrganismDiurnalRead? = nil
    ) {
        self.generatedAt = generatedAt
        self.bodyLine = bodyLine
        self.chemicalState = chemicalState
        self.bodySchema = bodySchema
        self.diurnal = diurnal
    }

    /// A clock alone is not a feeling; unchanged chemistry remains neutral and silent.
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
        self.residualRepairOpportunity = residualRepairOpportunity ?? .empty(at: generatedAt)
        self.capabilityBeliefs = Array(capabilityBeliefs.prefix(OrganismPredictionKind.allCases.count))
        self.projectedBodyLine = projectedBodyLine
        self.signalCount = max(0, signalCount)
        self.lastSignalAt = lastSignalAt
    }
}

/// Fixed-time projection, posture and horizon from copied continuity. Nonpersistent and advisory; reading never mutates the live kernel.
public struct OrganismFrozenRead: Sendable, Equatable {
    public let fixedAt: Date
    public let snapshot: OrganismSnapshot
    public let projection: OrganismReadout
    public let posture: OrganismBehaviorPosture?
    public let toward: OrganismTowardRead?

    public init(
        fixedAt: Date,
        snapshot: OrganismSnapshot,
        projection: OrganismReadout,
        posture: OrganismBehaviorPosture?,
        toward: OrganismTowardRead?
    ) {
        self.fixedAt = fixedAt
        self.snapshot = snapshot
        self.projection = projection
        self.posture = posture
        self.toward = toward
    }
}

public struct OrganismConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var metadataBounds: OrganismMetadataBounds
    /// The app supplies quiet hours; a nil clock disables the diurnal curve.
    public var diurnalClock: OrganismDiurnalClock?

    public init(
        enabled: Bool = false,
        metadataBounds: OrganismMetadataBounds = .defaults,
        diurnalClock: OrganismDiurnalClock? = nil
    ) {
        self.enabled = enabled
        self.metadataBounds = metadataBounds
        self.diurnalClock = diurnalClock
    }

    public static let disabled = OrganismConfiguration(enabled: false)
    public static let enabled = OrganismConfiguration(enabled: true)
}

// MARK: - The body's clock
// Shared quiet_hours supplies the only diurnal window; without it there is no clock.

/// Interpret the user's declared day in the Mac's current local zone; never retain a separate zone.
public struct OrganismDiurnalClock: Sendable, Equatable {
    /// The declared quiet window in LOCAL wall-clock hours; `start > end` wraps midnight. Only a complete, nondegenerate window supplies a clock.
    public let quietStartHour: Int
    public let quietEndHour: Int

    public init?(
        quietStartHour: Int,
        quietEndHour: Int
    ) {
        guard (0...23).contains(quietStartHour), (0...23).contains(quietEndHour),
              quietStartHour != quietEndHour else { return nil }
        self.quietStartHour = quietStartHour
        self.quietEndHour = quietEndHour
    }

}

/// The clock publishes local phase (0 midnight, 0.5 noon) and nightliness (1 trough, 0 peak). Consumers add/clamp arousal offset without creating arousal from
/// silence; curiosity offset is already applied and must not be applied twice.
public struct OrganismDiurnalRead: Sendable, Equatable, Codable {
    public var timeOfDayPhase: Double
    public var nightliness: Double
    public var arousalOffset: Double
    public var curiosityOffset: Double

    public init(
        timeOfDayPhase: Double,
        nightliness: Double,
        arousalOffset: Double,
        curiosityOffset: Double
    ) {
        self.timeOfDayPhase = timeOfDayPhase.clamped01()
        self.nightliness = nightliness.clamped01()
        self.arousalOffset = arousalOffset.clampedSigned()
        self.curiosityOffset = curiosityOffset.clampedSigned()
    }
}
