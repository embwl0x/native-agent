import Foundation
import PersistenceCore

// Blueprint: | `CognitiveEvent.swift` | `CognitiveEvent`: typed observations, turn kinds and mechanical-row metadata |

public enum CognitiveEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case userMessageReceived
    case assistantTurnCompleted
    case toolStarted
    case toolSucceeded
    case toolFailed
    case toolCancelled
    case userCorrection
    case providerFailure
    /// Emitted only on provider health-band transitions; metadata carries band and direction so the body can distinguish sluggishness from relief.
    case providerVitalsShift
    case appWake
    case appSleep
    /// Runtime-owned, care-gated felt resolutions carry measured valence and arousal rather than inferring them from event kind.
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
        case .appWake, .appSleep:
            return .appLifecycle
        case .organismResolutionFelt:
            return .feltResolution
        }
    }
}

/// Templated writers identify themselves by closed provenance; text matching must never exclude real prose. Raw values persist under `metadataKey` on both chat
/// rows and cognitive events.
public enum CognitiveMechanicalRowKind: String, Sendable, Equatable, CaseIterable {
    /// Connector and permission consequence copy is mechanical, including `cardLaneProse` on surfaces without cards.
    case cardLane
    /// A provider/transport failure recorded as an assistant row ("Chat error: …"). The machine reporting that it broke, not the agent saying so.
    case systemRow
    case attentionNotice
    /// A bot's receipt or headline row, including history imported from the shelf. The bot ran; the agent did not live it.
    case botReceipt
    /// Receipt-only bridge rows are identified structurally, never by header wording.
    case transportNotice
    public static let metadataKey = "mechanicalKind"

    /// Only provenance metadata excludes a row: `mechanicalKind`. Stored affect remains untouched; wording is never evidence.
    public static func marksMechanicalRow(_ metadata: [String: JSONValue]) -> Bool {
        if case .string(let raw)? = metadata[metadataKey],
           CognitiveMechanicalRowKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
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

    /// Diagnostic traffic may remain observable but must not change lived affect, mood, relational presence or body chemistry.
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
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled, .providerFailure, .providerVitalsShift, .appWake, .appSleep, .organismResolutionFelt:
            defaultTurnKind = .system
        case .userMessageReceived, .assistantTurnCompleted, .userCorrection:
            defaultTurnKind = .live
        }
        let resolvedTurnKind = turnKind
            ?? CognitiveTurnKind.from(metadataValue: metadata[CognitiveTurnKind.metadataKey])
            ?? defaultTurnKind
        var enrichedMetadata = metadata
        enrichedMetadata[CognitiveTurnKind.metadataKey] = .string(resolvedTurnKind.rawValue)
        // Continuity nodes intentionally collapse several event kinds into one node kind. Preserve the closed event class so later appraisal never has to infer
        // success/failure/cancellation from human-readable prose.
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

    /// Exact terminal direction established by the event's current kind.
    var terminalOutcomePolarity: Int {
        switch kind {
        case .toolSucceeded:
            return 1
        case .toolFailed, .providerFailure, .userCorrection:
            return -1
        default:
            return 0
        }
    }

    var isPositiveTerminalOutcome: Bool { terminalOutcomePolarity > 0 }
    var isNegativeTerminalOutcome: Bool { terminalOutcomePolarity < 0 }



}
