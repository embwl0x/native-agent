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
            [key] + Self.stringSignals(from: metadata[key] ?? .null)
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

    private static func stringSignals(from value: JSONValue) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .array(let values):
            return values.flatMap(stringSignals(from:))
        case .object(let object):
            return object.keys.sorted().flatMap { key in
                [key] + stringSignals(from: object[key] ?? .null)
            }
        default:
            return []
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

public struct CognitiveFrozenRead: Sendable, Equatable {
    public let fixedAt: Date
    public let stateRevision: UInt64
    public let thoughtSeedRevision: UInt64
    public let configuration: CognitiveConfiguration
    public let snapshot: CognitiveSubstrateSnapshot
    public let workspace: CognitiveWorkspaceSnapshot
    public let affect: CognitiveAffectState
    public let mood: CognitiveMoodReading
    public let thoughtSeeds: [CognitiveThoughtSeed]
    public let standingViewInnerLine: String?
    public let soundEchoLine: String?
    public let feltProxies: CognitiveFeltProxyReads

    public init(
        fixedAt: Date,
        stateRevision: UInt64,
        thoughtSeedRevision: UInt64,
        configuration: CognitiveConfiguration,
        snapshot: CognitiveSubstrateSnapshot,
        workspace: CognitiveWorkspaceSnapshot,
        affect: CognitiveAffectState = CognitiveAffectState(),
        mood: CognitiveMoodReading = CognitiveMoodReading(valence: 0, basis: 0),
        thoughtSeeds: [CognitiveThoughtSeed] = [],
        standingViewInnerLine: String? = nil,
        soundEchoLine: String? = nil,
        feltProxies: CognitiveFeltProxyReads = .absent
    ) {
        self.fixedAt = fixedAt
        self.stateRevision = stateRevision
        self.thoughtSeedRevision = thoughtSeedRevision
        self.configuration = configuration
        self.snapshot = snapshot
        self.workspace = workspace
        self.affect = affect
        self.mood = mood
        self.thoughtSeeds = thoughtSeeds
        self.standingViewInnerLine = standingViewInnerLine
        self.soundEchoLine = soundEchoLine
        self.feltProxies = feltProxies
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
