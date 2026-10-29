import Foundation
import PersistenceCore

// Blueprint: | `CognitiveEvent.swift` | `CognitiveEvent` and event/turn-kind vocabularies: typed cognition observations, mechanical-row classification and metadata signals |

public enum CognitiveEventKind: String, Codable, Sendable, Equatable, CaseIterable {
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

/// Templated writers identify themselves by closed provenance; text matching must never exclude real prose.
/// Raw values persist under `metadataKey` on both chat rows and cognitive events.
public enum CognitiveMechanicalRowKind: String, Sendable, Equatable, CaseIterable {
    /// The inline-interaction lane's stock sentence — the consequence copy said
    /// in her voice when a connector is missing or a permission is refused.
    /// This is also where the CONNECTOR FALLBACK text comes from: the card's own
    /// `cardLaneProse`, spoken on a route that cannot draw the card.
    case cardLane
    /// A provider/transport failure recorded as an assistant row ("Chat error:
    /// …"). The machine reporting that it broke, not her saying so.
    case systemRow
    /// Notification and attention boilerplate — a row the attention lane posts
    /// so the person sees something happened.
    case attentionNotice
    /// A bot's receipt or headline row, including history imported from the
    /// shelf. The bot ran; she did not live it.
    case botReceipt
    /// Transport bookkeeping on a bridge-routed row — the wake/notice rows whose
    /// whole content is the receipt header, with no words under it. Determined
    /// structurally (the transcript renderer's own answer to "what did this row
    /// say"), never by matching the header's wording.
    case transportNotice
    /// A compaction summary — the mechanical fold of older turns. Text about
    /// turns, not a turn.
    case compactionSummary

    public static let metadataKey = "mechanicalKind"

    /// The row kinds already stamped on disk by writers that never knew about
    /// this enum, read back so history is skipped without being re-scored.
    /// `compaction_summary` is `ChatSessionRecollections.rowKind`.
    static let legacyRowKindValues: Set<String> = ["compaction_summary"]

    /// TRUE FOR A ROW NO APPRAISAL SHOULD READ AS A MOMENT SHE LIVED.
    ///
    /// Read off metadata and nothing else — never the summary text. Two
    /// channels, in order:
    ///
    ///   1. `mechanicalKind` — stamped at the write seam by the writer itself.
    ///      Every row written from now on.
    ///   2. `kind` — the row-kind string writers were already stamping before
    ///      this enum existed (`compaction_summary`). This is the READ-SIDE
    ///      half of Agent's ruling: rows already on disk are skipped by what
    ///      they carry, and NOTHING IS RE-SCORED — the affect already recorded
    ///      on those nodes stands untouched. History stays as scored; it simply
    ///      stops being read back as a moment.
    public static func marksMechanicalRow(_ metadata: [String: JSONValue]) -> Bool {
        if case .string(let raw)? = metadata[metadataKey],
           CognitiveMechanicalRowKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return true
        }
        if case .string(let raw)? = metadata["kind"],
           legacyRowKindValues.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }
        return false
    }
}

public enum CognitiveTurnKind: String, Codable, Sendable, Equatable, CaseIterable {
    case live
    case system
    case debug
    case verification
    /// Templated product copy belongs in the transcript but never counts as a lived experience or diagnostic traffic.
    case mechanical

    /// Whether this event is part of Agent's lived state rather than
    /// diagnostic/verification traffic. Non-live events may remain available
    /// for bounded audit and health evidence, but they must not change affect,
    /// mood, relational presence, or somatic chemistry.
    public var contributesToLivedState: Bool {
        switch self {
        case .live, .system:
            true
        case .debug, .verification, .mechanical:
            false
        }
    }

    static let metadataKey = "turnKind"

    public static func from(metadataValue: JSONValue?) -> CognitiveTurnKind? {
        guard case .string(let raw)? = metadataValue else { return nil }
        return CognitiveTurnKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

}

public struct CognitiveEvent: Codable, Sendable, Equatable {
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
        let defaultTurnKind: CognitiveTurnKind
        switch kind {
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled, .providerFailure, .providerVitalsShift, .workshopExecutionCompleted, .appWake, .appSleep, .organismResolutionFelt:
            defaultTurnKind = .system
        case .userMessageReceived, .assistantTurnCompleted, .userCorrection:
            defaultTurnKind = .live
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
            String(format: "%.0f", (occurredAt.timeIntervalSince1970 * 1000).rounded(.towardZero) + 0),
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



}
