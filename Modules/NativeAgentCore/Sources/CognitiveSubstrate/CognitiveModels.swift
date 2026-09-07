import Foundation
import PersistenceCore

public enum CognitiveSourceClass: String, Sendable, Equatable, CaseIterable {
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
    case workshopExecution = "mission" // compatibility wire ID
    case appLifecycle
    /// Round 3 Wave A2 — bodily resolutions (relief/disappointment) with the
    /// resolved path as aboutness. Additive wire string; felt-tissue eligible.
    case feltResolution
}

public struct CognitiveSubjectReference: Sendable, Hashable, Equatable {
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

    // MARK: - Emotional tag (Wave A)
    // A persistent per-node FEELING, stamped from the substrate's live affect at
    // encode and asymmetrically blended toward the current moment on re-activation.
    // Backed by private storage so every write clamps into its welfare-bounded range
    // (a tag can never leave its range no matter how it's mutated). Defaults are the
    // neutral 0 point so pre-tag nodes restored from an older schema are fully
    // backward-compatible.
    private var _emotionalValence: Double
    private var _emotionalArousal: Double
    private var _emotionalWarmth: Double

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
        let inferred = CognitiveTurnKind.inferred(fromSignals: [
            kind.rawValue,
            subjectReference.type,
            subjectReference.id,
            subjectReference.label ?? "",
            summary,
        ] + metadata.keys.sorted().flatMap { key -> [String] in
            [key] + CognitiveMetadataSignals.stringSignals(from: metadata[key] ?? .null)
        })
        // H3 (2026-08-02): an explicit classification is honored in BOTH
        // directions. This used to discard an explicit `.live` whenever the
        // inference disagreed, which made the escape hatch one-way: a turn the
        // originator KNEW was live got re-inferred from its own words and
        // demoted, while an explicit `.debug` was always respected. Since
        // `CognitiveEvent.init` stamps the resolved kind into
        // `metadata["turnKind"]`, that demotion re-fired on every node read,
        // silently overriding the event's own resolved provenance.
        if let explicit = CognitiveTurnKind.from(metadataValue: metadata[CognitiveTurnKind.metadataKey]) {
            return explicit
        }

        if inferred != .live { return inferred }
        switch kind {
        case .toolObservation, .providerHealth, .workshopExecution, .appLifecycle, .feltResolution:
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

/// A fixed-time read that settles a copy of the continuity field. The live
/// actor's decay anchors, capacity, dirty state, and persistence are untouched.
/// The three substrate-native felt proxies (W4/P2), CAPTURED at freeze time.
///
/// They must ride in the frozen read rather than be recomputed: they are derived
/// from live actor state (`field` timestamps, `pendingCompletion`, the live
/// configuration), so a frozen re-render that recomputed them would drift from
/// the capsule it is supposed to reproduce byte for byte — which is exactly what
/// "a frozen capsule retains every captured render input" exists to catch.
/// nil means the proxy had no honest evidence, and stays absent.
public struct CognitiveFeltProxyReads: Sendable, Equatable {
    public var fatigue: Double?
    public var curiosity: Double?
    public var clarity: Double?

    public init(fatigue: Double? = nil, curiosity: Double? = nil, clarity: Double? = nil) {
        self.fatigue = fatigue
        self.curiosity = curiosity
        self.clarity = clarity
    }

    public static let absent = CognitiveFeltProxyReads()
}

/// Immutable presentation-only inputs captured with a frozen cognition epoch.
/// This is not durable cognition: it only prevents previews or failed provider
/// calls from consuming cadence, continuity, or Sound-brake state.
public struct CognitiveCapsulePresentationState: Sendable, Equatable {
    public var fingerprintFamily: String?
    public var fingerprintCount: Int
    public var fingerprintLastSurfacedAt: Date?
    public var lastLiveCapsuleAt: Date?
    public var lastSessionBridgeAt: Date?
    public var negativeSoundEchoRun: Int
    /// Consecutive accepted turns the "- Settling:" line was presented. Capped
    /// so a long warm phase over old negative nodes cannot turn the line into a
    /// standing instruction (W4/P4).
    public var settlingRun: Int
    /// The worn-token SET the rut nudge last spoke for, and when. The nudge is
    /// change-driven, so it needs to remember what it already said rather than
    /// re-deriving "a rut exists" every turn (2026-09-01).
    public var soundRutSignature: String?
    public var soundRutLastSurfacedAt: Date?
    /// Accepted live capsules since the rut nudge last spoke. Counted rather
    /// than timed so a burst of turns inside one minute cannot re-fire it.
    public var soundRutTurnsSinceSurfaced: Int
    /// Per-inner-line cadence ledger, keyed by the line's stable key.
    /// A non-negative value counts capsules this line has LED; a negative value
    /// counts the capsules of rest it still owes. Bounded by
    /// `innerLineLedgerCapacity`; the whole map is presentation-only.
    public var innerLineRuns: [String: Int]
    /// PRESENTATION RECEIPTS for the two 2026-09-02 felt-line organs. Both are
    /// counters, never text: how many accepted capsules carried an OBJECT on the
    /// felt line, and how many carried the one allowed contradicting second
    /// word, plus when that last happened. They gate nothing — they exist so
    /// "did the ambivalence exception ever actually fire, and how often" is a
    /// measurement rather than a story, which is the failure mode every other
    /// line on this capsule has already had once.
    public var feltObjectCount: Int
    public var ambivalenceCount: Int
    public var lastAmbivalenceAt: Date?
    /// REMINDED-OF (2026-09-02). When the unbidden-recall line last spoke, and
    /// how many accepted turns ago — the two halves of "at most once every
    /// `remindedOfMinTurns` turns". `nil` last-surfaced means it has never
    /// spoken, which is eligible.
    public var remindedOfLastSurfacedAt: Date?
    /// Accepted live turns since the line last spoke. Free-running (advanced by
    /// the substrate's own accepted-turn tick), exactly like the Sound rut
    /// counter, so a stretch of empty capsules cannot freeze the cadence.
    public var remindedOfTurnsSinceSurfaced: Int
    /// Moment ids this path has already put in front of her, and when. A memory
    /// that arrived sideways yesterday arriving sideways again today is not a
    /// second unbidden recall, it is a loop. Bounded by
    /// `remindedOfLedgerCapacity`; ids only, never text.
    public var remindedOfSurfaced: [String: Date]

    public static let innerLineLedgerCapacity = 24
    public static let remindedOfLedgerCapacity = 16

    public init(
        fingerprintFamily: String? = nil,
        fingerprintCount: Int = 0,
        fingerprintLastSurfacedAt: Date? = nil,
        lastLiveCapsuleAt: Date? = nil,
        lastSessionBridgeAt: Date? = nil,
        negativeSoundEchoRun: Int = 0,
        settlingRun: Int = 0,
        soundRutSignature: String? = nil,
        soundRutLastSurfacedAt: Date? = nil,
        soundRutTurnsSinceSurfaced: Int = 0,
        innerLineRuns: [String: Int] = [:],
        feltObjectCount: Int = 0,
        ambivalenceCount: Int = 0,
        lastAmbivalenceAt: Date? = nil,
        remindedOfLastSurfacedAt: Date? = nil,
        remindedOfTurnsSinceSurfaced: Int = 0,
        remindedOfSurfaced: [String: Date] = [:]
    ) {
        self.fingerprintFamily = fingerprintFamily
        self.fingerprintCount = max(0, fingerprintCount)
        self.fingerprintLastSurfacedAt = fingerprintLastSurfacedAt
        self.lastLiveCapsuleAt = lastLiveCapsuleAt
        self.lastSessionBridgeAt = lastSessionBridgeAt
        self.negativeSoundEchoRun = max(0, negativeSoundEchoRun)
        self.settlingRun = max(0, settlingRun)
        self.soundRutSignature = soundRutSignature
        self.soundRutLastSurfacedAt = soundRutLastSurfacedAt
        self.soundRutTurnsSinceSurfaced = max(0, soundRutTurnsSinceSurfaced)
        self.innerLineRuns = innerLineRuns
        self.feltObjectCount = max(0, feltObjectCount)
        self.ambivalenceCount = max(0, ambivalenceCount)
        self.lastAmbivalenceAt = lastAmbivalenceAt
        self.remindedOfLastSurfacedAt = remindedOfLastSurfacedAt
        self.remindedOfTurnsSinceSurfaced = max(0, remindedOfTurnsSinceSurfaced)
        self.remindedOfSurfaced = remindedOfSurfaced
    }
}

/// One frozen standing-view line plus the exact concern vocabulary captured
/// for it. Selection can therefore use the current turn without rereading live
/// standing views or concern state.
public struct CognitiveStandingViewCapsuleCandidate: Sendable, Equatable {
    public let id: UUID
    public let line: String
    public let concernKeywords: [String]
    public let updatedAt: Date
    /// Which TIER this candidate belongs to (2026-09-02). A held view — one she
    /// adopted herself, unsigned — is ranked strictly below every user-approved
    /// active view rather than competing with them on relevance score, so the
    /// tier has to survive the freeze into the frozen read.
    public let isHeld: Bool

    public init(
        id: UUID,
        line: String,
        concernKeywords: [String],
        updatedAt: Date,
        isHeld: Bool = false
    ) {
        self.id = id
        self.line = line
        self.concernKeywords = concernKeywords
        self.updatedAt = updatedAt
        self.isHeld = isHeld
    }
}

public struct CognitiveFrozenRead: Sendable, Equatable {
    public let fixedAt: Date
    public let stateRevision: UInt64
    public let thoughtSeedRevision: UInt64
    public let configuration: CognitiveConfiguration
    public let personalityDynamics: PersonalityDynamicsConfiguration
    public let snapshot: CognitiveSubstrateSnapshot
    public let workspace: CognitiveWorkspaceSnapshot
    public let affect: CognitiveAffectState
    public let mood: CognitiveMoodReading
    public let thoughtSeeds: [CognitiveThoughtSeed]
    public let standingViewInnerLine: String?
    public let soundEchoLine: String?
    public let feltProxies: CognitiveFeltProxyReads
    public let standingViewCapsuleCandidates: [CognitiveStandingViewCapsuleCandidate]
    public let soundLandingScores: [UUID: Double]
    public let capsulePresentationState: CognitiveCapsulePresentationState
    public let pendingCompletionOpen: Bool

    public init(
        fixedAt: Date,
        stateRevision: UInt64,
        thoughtSeedRevision: UInt64,
        configuration: CognitiveConfiguration,
        personalityDynamics: PersonalityDynamicsConfiguration = .default,
        snapshot: CognitiveSubstrateSnapshot,
        workspace: CognitiveWorkspaceSnapshot,
        affect: CognitiveAffectState = CognitiveAffectState(),
        mood: CognitiveMoodReading = CognitiveMoodReading(valence: 0, basis: 0),
        thoughtSeeds: [CognitiveThoughtSeed] = [],
        standingViewInnerLine: String? = nil,
        soundEchoLine: String? = nil,
        feltProxies: CognitiveFeltProxyReads = .absent,
        standingViewCapsuleCandidates: [CognitiveStandingViewCapsuleCandidate] = [],
        soundLandingScores: [UUID: Double] = [:],
        capsulePresentationState: CognitiveCapsulePresentationState = CognitiveCapsulePresentationState(),
        pendingCompletionOpen: Bool = false
    ) {
        self.fixedAt = fixedAt
        self.stateRevision = stateRevision
        self.thoughtSeedRevision = thoughtSeedRevision
        self.configuration = configuration
        self.personalityDynamics = personalityDynamics
        self.snapshot = snapshot
        self.workspace = workspace
        self.affect = affect
        self.mood = mood
        self.thoughtSeeds = thoughtSeeds
        self.standingViewInnerLine = standingViewInnerLine
        self.soundEchoLine = soundEchoLine
        self.feltProxies = feltProxies
        self.standingViewCapsuleCandidates = standingViewCapsuleCandidates
        self.soundLandingScores = soundLandingScores
        self.capsulePresentationState = capsulePresentationState
        self.pendingCompletionOpen = pendingCompletionOpen
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
