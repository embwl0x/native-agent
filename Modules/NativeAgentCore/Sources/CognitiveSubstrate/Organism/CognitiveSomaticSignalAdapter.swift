import Foundation
import PersistenceCore
// Blueprint: | `CognitiveSomaticSignalAdapter.swift` | `CognitiveSomaticSignals` enum; `signal`, `safeSourceComponent` |

public enum CognitiveSomaticSignals {
    /// Closed producer/adapter contract for cognitive evidence whose somatic
    /// consequence is already owned by the exact ProviderRouting lifecycle.
    /// The cognitive event still circulates through the substrate; only the
    /// second, uncorrelated body signal is suppressed.
    public static let somaticOwnerMetadataKey = "somaticOwner"
    public static let providerLifecycleSomaticOwner = "provider_lifecycle"

    /// Infrastructure evidence updates body health and posture; human causes,
    /// caring, work, sleep and interests move feelings.
    public static func movesFeelings(_ kind: SomaticSignalKind) -> Bool {
        switch kind {
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled,
             .providerStarted, .providerSucceeded, .providerFailed, .providerCancelled, .providerRecovered,
             .iPhoneReachable, .iPhoneStale,
             .phoneDeliveryStarted, .phoneDeliveryReceived, .phoneDeliveryFailed,
             .memoryCommitted, .memoryHygieneCompleted,
             .appWake, .appSleep, .resourcePressureChanged:
            return false
        default:
            return true
        }
    }

    /// Her own outcomes are human causes for agency and
    /// confidence, though their signals are transport-shaped: a verified
    /// action of hers that landed (the motor owner's `verification:
    /// satisfied`), an effectful tool call of hers that succeeded (a canonical
    /// outcome whose risk class is above a read, or that says `effects:
    /// occurred` — a Desk item closed, a message sent, a file written), a
    /// clean skill run, finished Workshop work. Her own work failing lowers
    /// confidence a little. Reads, pings and transport results are nil.
    public static func ownOutcomeDose(_ event: CognitiveEvent) -> (agency: Double, confidence: Double)? {
        guard event.turnKind.contributesToLivedState else { return nil }
        let verification = stringValue(event.metadata["verification"])
        let risk = stringValue(event.metadata["trustRisk"])
        let effectful = ["medium", "high", "critical"].contains(risk ?? "")
            || stringValue(event.metadata["effects"]) == "occurred"
        let skill = (stringValue(event.metadata["toolName"]) ?? "").hasPrefix("skill")
        switch event.kind {
        case .toolSucceeded:
            if verification == "satisfied" { return (0.05, 0.05) }
            if skill && risk != nil { return (0.03, 0.04) }
            return effectful ? (0.04, 0.03) : nil
        case .toolFailed:
            return verification == "failed" || effectful || (skill && risk != nil) ? (0, -0.03) : nil
        case .workshopExecutionCompleted:
            if event.isPositiveTerminalOutcome { return (0.05, 0.04) }
            return event.isNegativeTerminalOutcome ? (0, -0.03) : nil
        default:
            return nil
        }
    }

    public static func signal(
        from event: CognitiveEvent,
        id: UUID,
        bounds: OrganismMetadataBounds = .defaults
    ) -> SomaticSignal? {
        guard event.turnKind.contributesToLivedState else { return nil }
        guard let kind = somaticKind(for: event) else { return nil }
        let valence = kind.canonicalValence

        return SomaticSignal(
            id: id,
            kind: kind,
            sourceOrgan: sourceOrgan(for: event),
            occurredAt: event.occurredAt,
            intensity: event.importance,
            valence: valence == 0 ? nil : valence,
            arousal: arousal(for: event, somaticKind: kind),
            metadata: metadata(from: event),
            bounds: bounds
        )
    }

    private static func somaticKind(for event: CognitiveEvent) -> SomaticSignalKind? {
        switch event.kind {
        case .organismResolutionFelt:
            // Minted FROM the organism's own resolution drain — feeding it
            // back would loop the body into itself.
            return nil
        case .userMessageReceived:
            return .userSpoke
        case .assistantTurnCompleted:
            return .assistantSpoke
        case .toolStarted:
            return .toolStarted
        case .toolSucceeded:
            return .toolSucceeded
        case .toolFailed:
            return .toolFailed
        case .toolCancelled:
            return .toolCancelled
        case .userCorrection:
            return .correctionReceived
        case .providerFailure:
            if stringValue(event.metadata[somaticOwnerMetadataKey])
                == providerLifecycleSomaticOwner {
                return nil
            }
            // Failures outside the ProviderRouting lifecycle still need their
            // fallback body consequence. Suppression requires the explicit
            // closed marker above; absence never implies ownership.
            return .providerFailed
        case .providerVitalsShift:
            // The graded, continuous sibling of `.providerFailure`. A worsening
            // band transition rides the SAME `.providerFailed` axis (its grade
            // carried by the event's importance → signal intensity); a recovery
            // transition reads as relief on `.providerRecovered`. No new somatic
            // kind, no new capsule slot — sluggishness is a value on an axis the
            // body already feels.
            return providerVitalsSignalKind(from: event)
        case .workshopExecutionCompleted:
            return workshopExecutionSignalKind(from: event)
        case .appWake:
            return .appWake
        case .appSleep:
            return .appSleep
        }
    }

    /// Direction key written by the vitals owner. Worsening → felt as
    /// sluggishness on the provider-failed axis; recovering → relief. An absent
    /// or unrecognized direction defaults to worsening (fail-loud: a health
    /// shift with no legible direction is treated as the concerning case).
    public static let vitalsDirectionMetadataKey = "vitalsDirection"

    private static func providerVitalsSignalKind(from event: CognitiveEvent) -> SomaticSignalKind {
        switch stringValue(event.metadata[vitalsDirectionMetadataKey])?.lowercased() {
        case "recovering":
            return .providerRecovered
        default:
            return .providerFailed
        }
    }

    private static func workshopExecutionSignalKind(from event: CognitiveEvent) -> SomaticSignalKind {
        switch stringValue(event.metadata["status"])?.lowercased() {
        case "failed", "cancelled", "blocked":
            return .deskItemBlocked
        default:
            return .deskItemClosed
        }
    }

    private static func sourceOrgan(for event: CognitiveEvent) -> String {
        switch event.kind {
        case .organismResolutionFelt:
            return "organism"
        case .userMessageReceived, .assistantTurnCompleted:
            // Peer organs use out-of-band origin, never message claims; User retains chat/chat.<surface> names.
            if case .peer(let agent) = CognitiveSubstrate.relationalSource(for: event),
               let safePeer = safeSourceComponent(agent) {
                return "chat.peer.\(safePeer)"
            }
            if CognitiveSubstrate.relationalSource(for: event) == .unknown {
                return "chat.unknown"
            }
            if let surface = safeSourceComponent(stringValue(event.metadata["surface"])) {
                return "chat.\(surface)"
            }
            return "chat"
        case .toolStarted, .toolSucceeded, .toolFailed, .toolCancelled:
            if let motorDomain = safeSourceComponent(stringValue(event.metadata["motorDomain"])) {
                return "tool.\(motorDomain)"
            }
            if let toolName = safeSourceComponent(stringValue(event.metadata["toolName"])) {
                return "tool.\(toolName)"
            }
            return "tool"
        case .providerFailure:
            return "provider"
        case .providerVitalsShift:
            if let providerId = safeSourceComponent(stringValue(event.metadata["providerId"])) {
                return "provider.\(providerId)"
            }
            return "provider"
        case .workshopExecutionCompleted:
            return "desk"
        case .userCorrection:
            return "correction"
        case .appWake, .appSleep:
            return "app"
        }
    }

    private static func arousal(for event: CognitiveEvent, somaticKind: SomaticSignalKind) -> Double? {
        switch somaticKind {
        case .toolFailed, .providerFailed, .deskItemBlocked:
            return max(0.55, event.importance)
        case .correctionReceived:
            return max(0.5, event.importance * 0.85)
        case .toolStarted, .approvalRequested:
            return 0.4
        case .appWake:
            return 0.2
        case .appSleep:
            return 0.15
        default:
            return nil
        }
    }

    private static func metadata(from event: CognitiveEvent) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "cognitiveEventId": .string(event.id),
            "cognitiveEventKind": .string(event.kind.rawValue),
            "turnKind": .string(event.turnKind.rawValue),
            "subjectType": .string(event.subject.type),
            "subjectId": .string(event.subject.id),
            "importance": .double(event.importance),
            "summaryCharacters": .int(Int64(event.summary.count)),
        ]
        if let label = event.subject.label, !label.isEmpty {
            metadata["subjectLabel"] = .string(label)
        }
        for key in forwardedMetadataKeys {
            if let value = event.metadata[key] {
                metadata[key] = value
            }
        }
        if let identity = event.metadata["motorActionIdentity"] {
            metadata["predictionCorrelationId"] = identity
        }
        return metadata
    }

    private static let forwardedMetadataKeys = [
        "surface",
        "role",
        "sessionId",
        "messageId",
        "runId",
        "source",
        "toolName",
        "phase",
        "ok",
        "status",
        "provider_id",
        "providerId",
        "approvalId",
        "missionId",
        "stepId",
        "itemId",
        "sourceKey",
        "motorDomain",
        "motorActionIdentity",
        "verification",
        "trustRisk",
        // CognitiveSubstrate supplies semantic expectation keys; absent keys mean no expectation.
        OrganismSemanticExpectation.mintMetadataKey,
        OrganismSemanticExpectation.reactionMetadataKey,
        // Peer identity travels in sourceOrgan, preserving the twelve-key metadata budget.
    ]

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Internal rather than private so the shared-secret-filter pins can assert
    /// this site answers the same way the other two do.
    static func safeSourceComponent(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // One shared secret filter (`JSONValueBounding`), so a source component
        // and a metadata value can never disagree about what a credential is.
        // The private copy this replaces matched `sk-` unanchored, which threw
        // away every ordinary `desk-…` / `task-…` component.
        guard !JSONValueBounding.containsSecretLikeValue(value) else { return nil }
        return String(value.prefix(60))
    }
}
