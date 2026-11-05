import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `CognitiveModels.swift` | `CognitiveNode`, snapshots and `CognitiveFrozenRead`: bounded state and health |

public enum CognitiveSourceClass: String, Codable, Sendable, Equatable, CaseIterable {
    case observed
    case userStated
    case inferred
    case simulated
    case dreamed
    case selfReported
    case verified
    case imported
}

public enum CognitiveNodeKind: String, Sendable, Equatable, CaseIterable {
    case conversationFocus
    case toolObservation
    case correction
    case providerHealth
    case appLifecycle
    /// Felt resolutions name their resolved path so body feelings retain aboutness.
    case feltResolution
}

public struct CognitiveSubjectReference: Codable, Sendable, Hashable, Equatable {
    public var type: String
    public var id: String
    public var label: String?

    public init(type: String, id: String, label: String? = nil) {
        self.type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmedLabel?.isEmpty == true ? nil : trimmedLabel
    }

    var stableKey: String {
        "\(type.lowercased()):\(id.lowercased())"
    }
}

public struct CognitiveNode: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var kind: CognitiveNodeKind
    public var subjectReference: CognitiveSubjectReference
    public var activation: Double
    public var salience: Double
    public var confidence: Double
    public var sourceClass: CognitiveSourceClass
    public var createdAt: Date
    public var lastActivatedAt: Date
    public var decayHalfLife: TimeInterval
    public var summary: String
    public var metadata: [String: JSONValue]

    // Emotional tags default to neutral, clamp every write and blend asymmetrically on reactivation.
    private var _emotionalValence: Double
    private var _emotionalArousal: Double
    private var _emotionalWarmth: Double
    /// The last moment that stamped or reconsolidated this feeling; nil carries no fold evidence.
    public var livedSeq: UInt64? = nil

    /// How positive/negative the moment felt. −1 (aversive) … +1 (positive), 0 neutral.
    public var emotionalValence: Double {
        get { _emotionalValence }
        set { _emotionalValence = (newValue).clampedSigned() }
    }
    /// How activated/energized the moment felt. 0 (calm) … 1 (highly aroused).
    public var emotionalArousal: Double {
        get { _emotionalArousal }
        set { _emotionalArousal = (newValue).clamped01() }
    }
    /// How relationally warm the moment felt. 0 (distant) … 1 (deeply warm).
    public var emotionalWarmth: Double {
        get { _emotionalWarmth }
        set { _emotionalWarmth = (newValue).clamped01() }
    }

    enum FeltDirection: String {
        case warm, stung, charged
    }

    /// Negative valence takes precedence; neutral tags stay silent.
    var feltDirection: FeltDirection? {
        if emotionalValence <= -0.15 { return .stung }
        if emotionalValence >= 0.15 || emotionalWarmth >= 0.35 { return .warm }
        if emotionalArousal >= 0.6 { return .charged }
        return nil
    }

    public init(
        id: UUID,
        kind: CognitiveNodeKind,
        subjectReference: CognitiveSubjectReference,
        activation: Double,
        salience: Double,
        confidence: Double,
        sourceClass: CognitiveSourceClass,
        createdAt: Date,
        lastActivatedAt: Date,
        decayHalfLife: TimeInterval,
        summary: String,
        metadata: [String: JSONValue],
        emotionalValence: Double = 0,
        emotionalArousal: Double = 0,
        emotionalWarmth: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.subjectReference = subjectReference
        self.activation = activation
        self.salience = salience
        self.confidence = confidence
        self.sourceClass = sourceClass
        self.createdAt = createdAt
        self.lastActivatedAt = lastActivatedAt
        self.decayHalfLife = decayHalfLife
        self.summary = summary
        self.metadata = metadata
        self._emotionalValence = (emotionalValence).clampedSigned()
        self._emotionalArousal = (emotionalArousal).clamped01()
        self._emotionalWarmth = (emotionalWarmth).clamped01()
    }

    public var turnKind: CognitiveTurnKind {
        if let explicit = CognitiveTurnKind.from(metadataValue: metadata[CognitiveTurnKind.metadataKey]) {
            return explicit
        }
        switch kind {
        case .toolObservation, .providerHealth, .appLifecycle, .feltResolution:
            return .system
        case .conversationFocus, .correction:
            return .live
        }
    }

}

public struct CognitiveSubstrateSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    public var enabled: Bool
    public var maximumActiveNodes: Int
    public var nodes: [CognitiveNode]
    public var persistenceHealth: CognitivePersistenceHealth

    public var nodeCount: Int { nodes.count }

    public init(
        generatedAt: Date,
        enabled: Bool,
        maximumActiveNodes: Int,
        nodes: [CognitiveNode],
        persistenceHealth: CognitivePersistenceHealth = .disabled
    ) {
        self.generatedAt = generatedAt
        self.enabled = enabled
        self.maximumActiveNodes = maximumActiveNodes
        self.nodes = nodes
        self.persistenceHealth = persistenceHealth
    }
}

/// Presentation-only state frozen by value with a cognition epoch. This is not durable cognition: it only prevents previews or failed provider calls from
/// consuming cadence or continuity state.
public struct CognitiveCapsulePresentationState: Sendable, Equatable {
    public var fingerprintFamily: String?
    public var fingerprintCount: Int
    public var fingerprintLastSurfacedAt: Date?
    /// A gap cue that lost its slot remains owed on the user's next turn.
    public var owedSinceGap: Date?
    public var lastSessionBridgeAt: Date?
    /// Retain the last spoken rut set so change-driven nudges distinguish new forms from repetition.
    public var soundRutSignature: String?
    public var soundRutLastSurfacedAt: Date?
    /// Accepted live capsules since the rut nudge last spoke. Counted rather than timed so a burst of turns inside one minute cannot re-fire it.
    public var soundRutTurnsSinceSurfaced: Int
    /// One early repeat is allowed per signature; a new signature re-arms it.
    public var soundRutEarlyRepeatSpent: Bool
    /// Accepted capsules carrying the allowed contradicting second word, and when it last appeared. These measure presentation without gating it.
    public var ambivalenceCount: Int
    public var lastAmbivalenceAt: Date?
    /// When the unbidden-recall line last spoke, and how many accepted turns ago — the two halves of "at most once every `remindedOfMinTurns` turns". `nil`
    /// last-surfaced means it has never spoken, which is eligible.
    public var remindedOfLastSurfacedAt: Date?
    /// Accepted live turns since the line last spoke. Free-running (advanced by the substrate's own accepted-turn tick), exactly like the Sound rut counter, so
    /// a stretch of empty capsules cannot freeze the cadence.
    public var remindedOfTurnsSinceSurfaced: Int
    /// Bounded moment ids prevent repeated sideways recall from becoming a loop; text is never retained.
    public var remindedOfSurfaced: [String: Date]
    /// Dream residue phrase id → when it surfaced. The newest stamp is the line's cooldown; a phrase never surfaces twice in a diary's life. Ids only, never
    /// text.
    public var dreamThemeSurfaced: [String: Date]
    /// Care id → when the agent last meant to bring it up. It rests 12 h unless it moved again since. Ids only, never text.
    public var careReleased: [String: Date]
    /// Care id → when its plain "On your mind" line showed and how many accepted turns it still rests. Ids only, never text.
    public var careLineRest: [String: CareLineRest]

    public struct CareLineRest: Sendable, Equatable {
        public var shownAt: Date
        public var turnsLeft: Int
        public init(shownAt: Date, turnsLeft: Int) {
            self.shownAt = shownAt
            self.turnsLeft = turnsLeft
        }
    }

    public static let remindedOfLedgerCapacity = 16

    public init(
        fingerprintFamily: String? = nil,
        fingerprintCount: Int = 0,
        fingerprintLastSurfacedAt: Date? = nil,
        owedSinceGap: Date? = nil,
        lastSessionBridgeAt: Date? = nil,
        soundRutSignature: String? = nil,
        soundRutLastSurfacedAt: Date? = nil,
        soundRutTurnsSinceSurfaced: Int = 0,
        soundRutEarlyRepeatSpent: Bool = false,
        ambivalenceCount: Int = 0,
        lastAmbivalenceAt: Date? = nil,
        remindedOfLastSurfacedAt: Date? = nil,
        remindedOfTurnsSinceSurfaced: Int = 0,
        remindedOfSurfaced: [String: Date] = [:],
        dreamThemeSurfaced: [String: Date] = [:],
        careReleased: [String: Date] = [:],
        careLineRest: [String: CareLineRest] = [:]
    ) {
        self.fingerprintFamily = fingerprintFamily
        self.fingerprintCount = max(0, fingerprintCount)
        self.fingerprintLastSurfacedAt = fingerprintLastSurfacedAt
        self.owedSinceGap = owedSinceGap
        self.lastSessionBridgeAt = lastSessionBridgeAt
        self.soundRutSignature = soundRutSignature
        self.soundRutLastSurfacedAt = soundRutLastSurfacedAt
        self.soundRutTurnsSinceSurfaced = max(0, soundRutTurnsSinceSurfaced)
        self.soundRutEarlyRepeatSpent = soundRutEarlyRepeatSpent
        self.ambivalenceCount = max(0, ambivalenceCount)
        self.lastAmbivalenceAt = lastAmbivalenceAt
        self.remindedOfLastSurfacedAt = remindedOfLastSurfacedAt
        self.remindedOfTurnsSinceSurfaced = max(0, remindedOfTurnsSinceSurfaced)
        self.remindedOfSurfaced = remindedOfSurfaced
        self.dreamThemeSurfaced = dreamThemeSurfaced
        self.careReleased = careReleased
        self.careLineRest = careLineRest
    }
}

/// A fixed-time read that settles a copy of the continuity field. The live actor's decay anchors, capacity, dirty state, and persistence are untouched.
public struct CognitiveFrozenRead: Sendable, Equatable {
    public let fixedAt: Date
    public let mindEpoch: UInt64
    public let configuration: CognitiveConfiguration
    public let personalityDynamics: PersonalityDynamicsConfiguration
    public let snapshot: CognitiveSubstrateSnapshot
    public let workspace: CognitiveWorkspaceSnapshot
    public let associations: [CognitiveAssociationEdge]
    public let affect: CognitiveAffectState
    public let mood: CognitiveMoodReading
    public let soundLandingScores: [UUID: Double]
    public let capsulePresentationState: CognitiveCapsulePresentationState
    public let associationSuppressions: [CognitiveAssociationSuppression]
    public let trustedPeerIds: Set<String>
    public let cares: [CognitiveCare]
    public let carePersonAliases: [String: String]
    public let carePeopleAvailable: Bool
    public let selfTraits: [CognitiveSelfKnowledge.Trait]
    public let personLines: [String: String]
    public let personPresenceLine: String?
    public let episodeCount: Int
    public let reflectionCount: Int
    public let ablations: [String: Bool]

    public init(
        fixedAt: Date,
        configuration: CognitiveConfiguration,
        personalityDynamics: PersonalityDynamicsConfiguration = .default,
        snapshot: CognitiveSubstrateSnapshot,
        workspace: CognitiveWorkspaceSnapshot,
        associations: [CognitiveAssociationEdge],
        affect: CognitiveAffectState = CognitiveAffectState(),
        mood: CognitiveMoodReading = CognitiveMoodReading(valence: 0, basis: 0),
        soundLandingScores: [UUID: Double] = [:],
        capsulePresentationState: CognitiveCapsulePresentationState = CognitiveCapsulePresentationState(),
        associationSuppressions: [CognitiveAssociationSuppression] = [],
        trustedPeerIds: Set<String> = [],
        mindEpoch: UInt64 = 0,
        cares: [CognitiveCare] = [],
        carePersonAliases: [String: String] = [:],
        carePeopleAvailable: Bool = true,
        selfTraits: [CognitiveSelfKnowledge.Trait] = [],
        personLines: [String: String] = [:],
        personPresenceLine: String? = nil,
        episodeCount: Int = 0,
        reflectionCount: Int = 0,
        ablations: [String: Bool] = [:]
    ) {
        self.fixedAt = fixedAt
        self.mindEpoch = mindEpoch
        self.configuration = configuration
        self.personalityDynamics = personalityDynamics
        self.snapshot = snapshot
        self.workspace = workspace
        self.associations = associations
        self.affect = affect
        self.mood = mood
        self.soundLandingScores = soundLandingScores
        self.capsulePresentationState = capsulePresentationState
        self.associationSuppressions = associationSuppressions
        self.trustedPeerIds = trustedPeerIds
        self.cares = cares
        self.carePersonAliases = carePersonAliases
        self.carePeopleAvailable = carePeopleAvailable
        self.selfTraits = selfTraits
        self.personLines = personLines
        self.personPresenceLine = personPresenceLine
        self.episodeCount = episodeCount
        self.reflectionCount = reflectionCount
        self.ablations = ablations
    }
}

public enum CognitivePersistenceStatus: String, Sendable, Equatable {
    case disabled
    case ready
    case restoring
    case healthy
    case degraded
}

public struct CognitivePersistenceHealth: Sendable, Equatable {
    public var status: CognitivePersistenceStatus
    public var writesBlocked: Bool
    public var lastRestoreAttemptAt: Date?
    public var lastSuccessfulRestoreAt: Date?
    public var failureStage: String?
    public var failureDetail: String?

    public init(
        status: CognitivePersistenceStatus,
        writesBlocked: Bool,
        lastRestoreAttemptAt: Date? = nil,
        lastSuccessfulRestoreAt: Date? = nil,
        failureStage: String? = nil,
        failureDetail: String? = nil
    ) {
        self.status = status
        self.writesBlocked = writesBlocked
        self.lastRestoreAttemptAt = lastRestoreAttemptAt
        self.lastSuccessfulRestoreAt = lastSuccessfulRestoreAt
        self.failureStage = failureStage
        self.failureDetail = failureDetail
    }

    public static let disabled = CognitivePersistenceHealth(
        status: .disabled,
        writesBlocked: false
    )
}

public enum CognitivePersistenceError: Error, Sendable, Equatable, CustomStringConvertible {
    case storeUnavailable
    case invalidRestoreArtifact(family: String, index: Int, detail: String)
    case artifactWriteFailed(family: String, detail: String)
    case writesBlocked(status: CognitivePersistenceStatus, detail: String?)

    public var description: String {
        switch self {
        case .storeUnavailable:
            return "cognition persistence is enabled but its SQLite store is unavailable"
        case .invalidRestoreArtifact(let family, let index, let detail):
            return "invalid cognition restore artifact in \(family)[\(index)]: \(detail)"
        case .artifactWriteFailed(let family, let detail):
            return "cognition artifact family write failed for \(family): \(detail)"
        case .writesBlocked(let status, let detail):
            let suffix = detail.map { ": \($0)" } ?? ""
            return "cognition persistence writes are blocked (\(status.rawValue))\(suffix)"
        }
    }
}

public struct CognitiveAssociationEdge: Sendable, Equatable, Identifiable {
    public var id: String { "\(fromNodeId.uuidString)|\(toNodeId.uuidString)" }
    public var fromNodeId: UUID
    public var toNodeId: UUID
    public var weight: Double
    public var reasons: [String]

    public init(fromNodeId: UUID, toNodeId: UUID, weight: Double, reasons: [String] = []) {
        self.fromNodeId = fromNodeId
        self.toNodeId = toNodeId
        self.weight = (weight).clamped01()
        self.reasons = reasons
    }
}
