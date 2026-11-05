import Foundation
import NativeAgentShared
// Blueprint: | `SessionMessageProvenance.swift` | `SessionMessageProvenance` |

/// Interpret only recorded ingress; unknown origins remain automated.
public enum SessionMessageProvenance: Sendable, Equatable {
    case telegram, slack, iPhone, scheduled, automated

    public var isAutomated: Bool {
        switch self {
        case .telegram, .slack, .iPhone: false
        case .scheduled, .automated: true
        }
    }

    /// Use the persisted transport envelope, not reconstructed routing state.
    public static func make(role: String, source: String?, hasEnvelope: Bool, surface: String?, agent: String?) -> SessionMessageProvenance? {
        guard role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" else {
            return nil
        }
        // The envelope records the ingress surface; a row without one names only its transcript source, which crosses to its surface here.
        // An unreadable envelope stays unattributed. Only an unsaved local bubble is treated as the person until persistence replaces it.
        let recorded: String
        if hasEnvelope {
            recorded = normalized(surface) ?? "unreadable"
        } else {
            guard let fromSource = normalized(source) else { return nil }
            recorded = ChatThreadKind.surface(transcriptSource: fromSource)
        }

        switch recorded {
        case "chat":
            // A local window belongs to the person unless its envelope names an agent route.
            return normalized(agent) == nil ? nil : .automated
        case "telegram":
            guard humanTransportHasNoAgent(hasEnvelope: hasEnvelope, agent: agent) else { return .automated }
            return .telegram
        case "slack":
            guard humanTransportHasNoAgent(hasEnvelope: hasEnvelope, agent: agent) else { return .automated }
            return .slack
        case "ios":
            guard humanTransportHasNoAgent(hasEnvelope: hasEnvelope, agent: agent) else { return .automated }
            return .iPhone
        case "scheduler":
            return .scheduled
        default:
            // Unrecognized ingress, and every bridge lane (agent-bridge, <sender>-bridge), remains machine-authored without repeating its identity claim.
            return .automated
        }
    }

    /// Human labels require a recorded person-facing envelope without a contradictory machine-agent claim.
    private static func humanTransportHasNoAgent(
        hasEnvelope: Bool, agent: String?
    ) -> Bool {
        guard hasEnvelope else { return false }
        return normalized(agent) == nil
    }

    /// Normalize blanks and case only; the allowlist, not normalization, rejects hostile input.
    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
