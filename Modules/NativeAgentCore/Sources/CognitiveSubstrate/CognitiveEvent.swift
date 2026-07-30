import Foundation
import PersistenceCore

public enum CognitiveEventKind: String, Sendable, Equatable, CaseIterable {
    case userMessageReceived
    case assistantTurnCompleted
    case toolStarted
    case toolSucceeded
    case toolFailed
    case toolCancelled
    case userCorrection
    case providerFailure
    /// INTEROCEPTION (prerelease campaign): a provider crossed a health BAND
    /// boundary (nominal ⇄ sluggish ⇄ degraded). The graded, continuous sibling
    /// of `.providerFailure` — minted only on a band transition, never per call.
    /// Direction/band travel in metadata; the somatic adapter reads them to
    /// grade sluggishness vs relief.
    case providerVitalsShift
    case workshopExecutionCompleted = "missionCompleted" // compatibility wire ID
    case appWake
    case appSleep
    /// Round 3 Wave A2 — a bodily resolution the organism felt strongly
    /// enough to remember: relief (braced expectation landed fine) or earned
    /// disappointment (counted-on expectation fell through). Minted ONLY by
    /// the runtime's kernel drain; carries feltValence/feltArousal metadata.
    case organismResolutionFelt

    var nodeKind: CognitiveNodeKind {
        switch self {
        case .userMessageReceived, .assistantTurnCompleted:
            return .conversationFocus
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled:
            return .toolObservation
        case .userCorrection:
            return .correction
        case .providerFailure, .providerVitalsShift:
            return .providerHealth
        case .workshopExecutionCompleted:
            return .workshopExecution
        case .appWake, .appSleep:
            return .appLifecycle
        case .organismResolutionFelt:
            return .feltResolution
        }
    }
}

public enum CognitiveTurnKind: String, Sendable, Equatable, CaseIterable {
    case live
    case system
    case debug
    case verification

    /// Whether this event is part of Agent's lived state rather than
    /// diagnostic/verification traffic. Non-live events may remain available
    /// for bounded audit and health evidence, but they must not change affect,
    /// mood, relational presence, or somatic chemistry.
    public var contributesToLivedState: Bool {
        switch self {
        case .live, .system:
            true
        case .debug, .verification:
            false
        }
    }

    static let metadataKey = "turnKind"

    public static func from(metadataValue: JSONValue?) -> CognitiveTurnKind? {
        guard case .string(let raw)? = metadataValue else { return nil }
        return CognitiveTurnKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func inferred(fromSignals signals: [String]) -> CognitiveTurnKind {
        let haystack = signals
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !haystack.isEmpty else { return .live }

        let verificationMarkers = [
            "ctx-snapshot-verify",
            "snapshot-verify",
            "snapshot verify",
            "bridge-passthrough",
            "bridge passthrough",
            "passthrough ping",
            "subconscious-switch",
            "subconscious switch",
            "verification ping",
            "codex bridge test",
            "codex_message bridge test",
        ]
        if verificationMarkers.contains(where: { haystack.contains($0) }) {
            return .verification
        }

        let debugMarkers = [
            "[from: codex",
            "from codex",
            "via bridge] codex",
            "codex replied to your message",
            "codex landed",
            "codex can read this through the local nativeagent bridge inbox",
            "codex_bridge",
            "codex-nativeagent-bridge",
            "codex-health",
            "codex's second receipt",
            "debug-filter probe",
            "snapshot clean, codex",
            "inner-state capsule reads clean",
            "capsule is my private inner read",
            "not a log of what the app or tools did",
            "nothing leaking into the durable log",
            "final inspector check",
            "inspector check after",
            "subconscious-innerstate",
            "bridge message landed clean",
            "bridge message came through clean",
            "bridge passthrough holding steady",
            "bridge passthrough solid",
            "passes bridge messages through",
        ]
        if debugMarkers.contains(where: { haystack.contains($0) }) {
            return .debug
        }

        let systemMarkers = [
            "observatory",
            "reflection",
            "background loop",
            "background_loop",
            "scheduler",
            "doctor",
        ]
        if systemMarkers.contains(where: { haystack.contains($0) }) {
            return .system
        }

        return .live
    }
}

public struct CognitiveEvent: Sendable, Equatable {
    public var id: String
    public var kind: CognitiveEventKind
    public var subject: CognitiveSubjectReference
    public var sourceClass: CognitiveSourceClass
    public var occurredAt: Date
    public var summary: String
    public var importance: Double
    public var turnKind: CognitiveTurnKind
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        kind: CognitiveEventKind,
        subject: CognitiveSubjectReference,
        sourceClass: CognitiveSourceClass,
        occurredAt: Date,
        summary: String,
        importance: Double = 0.5,
        turnKind: CognitiveTurnKind? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferredTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            safeID,
            kind.rawValue,
            subject.type,
            subject.id,
            subject.label ?? "",
            summary,
        ] + Self.metadataSignals(metadata))
        let defaultTurnKind: CognitiveTurnKind
        if inferredTurnKind != .live {
            defaultTurnKind = inferredTurnKind
        } else {
            switch kind {
            case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled, .providerFailure, .providerVitalsShift, .workshopExecutionCompleted, .appWake, .appSleep, .organismResolutionFelt:
                defaultTurnKind = .system
            case .userMessageReceived, .assistantTurnCompleted, .userCorrection:
                defaultTurnKind = .live
            }
        }
        let resolvedTurnKind = turnKind
            ?? CognitiveTurnKind.from(metadataValue: metadata[CognitiveTurnKind.metadataKey])
            ?? defaultTurnKind
        var enrichedMetadata = metadata
        enrichedMetadata[CognitiveTurnKind.metadataKey] = .string(resolvedTurnKind.rawValue)
        // Continuity nodes intentionally collapse several event kinds into one
        // node kind. Preserve the closed event class so later appraisal never
        // has to infer success/failure/cancellation from human-readable prose.
        enrichedMetadata["eventKind"] = .string(kind.rawValue)

        self.id = safeID
        self.kind = kind
        self.subject = subject
        self.sourceClass = sourceClass
        self.occurredAt = occurredAt
        self.summary = summary
        self.importance = (importance).clamped01()
        self.turnKind = resolvedTurnKind
        self.metadata = enrichedMetadata
    }

    var deduplicationKey: String {
        if !id.isEmpty { return id }
        return [
            kind.rawValue,
            subject.stableKey,
            String(Int64(occurredAt.timeIntervalSince1970 * 1000)),
            summary,
        ].joined(separator: "|")
    }

    /// Exact terminal direction when this event's closed kind/metadata can
    /// establish one. `workshopExecutionCompleted` is a legacy wire name for
    /// every Workshop terminal event, so its canonical `status` must decide
    /// whether the outcome helped, hurt, or remains unknown. Treating the enum
    /// case itself as success made failed/cancelled work reduce uncertainty in
    /// the resident affect path while the organism signal path correctly
    /// reported a block.
    var terminalOutcomePolarity: Int {
        switch kind {
        case .toolSucceeded:
            return 1
        case .toolFailed, .providerFailure, .userCorrection:
            return -1
        case .workshopExecutionCompleted:
            guard case .string(let rawStatus)? = metadata["status"] else {
                // Backward compatibility for historical `missionCompleted`
                // events written before canonical status metadata existed.
                return 1
            }
            switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "completed", "done", "succeeded":
                return 1
            case "failed", "blocked", "cancelled", "canceled":
                return -1
            default:
                return 0
            }
        default:
            return 0
        }
    }

    var isPositiveTerminalOutcome: Bool { terminalOutcomePolarity > 0 }
    var isNegativeTerminalOutcome: Bool { terminalOutcomePolarity < 0 }

    private static func metadataSignals(_ metadata: [String: JSONValue]) -> [String] {
        metadata.keys.sorted().flatMap { key -> [String] in
            [key] + stringSignals(from: metadata[key] ?? .null)
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
