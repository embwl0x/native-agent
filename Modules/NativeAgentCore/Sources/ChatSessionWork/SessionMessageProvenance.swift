import Foundation
// Blueprint: | `SessionMessageProvenance.swift` | `SessionMessageProvenance` |

/// Closed interpretation of recorded ingress; unknown origins remain automated.
public enum SessionMessageProvenance: Sendable, Equatable {
    case claude, codex, telegram, slack, iPhone, scheduled, automated

    public var isAutomated: Bool {
        switch self {
        case .telegram, .slack, .iPhone: false
        case .claude, .codex, .scheduled, .automated: true
        }
    }

    /// `envelope` is the row's recorded turn envelope (`metadata.envelope`), which the
    /// persistence seam writes on every message row from the transport that admitted it.
    public static func make(role: String, source: String?, hasEnvelope: Bool, surface: String?, agent: String?) -> SessionMessageProvenance? {
        guard role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" else {
            return nil
        }
        // The recorded envelope is the provenance: the transport named itself
        // and any bridge lane when it admitted the turn. `source` is overloaded
        // to also mean "tool authorization surface" (the bridges run with
        // source "app" to keep chat's tool permissions), so it never decides
        // provenance for a recorded row.
        //
        // An envelope with no readable surface is UNATTRIBUTED, not human: it
        // resolves to the same "unreadable" sentinel an undecodable envelope
        // gets in ChatMessageMetadata(fields:) and lands on "Automated" below.
        // Only an unsaved local bubble has no envelope; it is the person at
        // this Mac until the canonical row replaces it.
        let recorded: String
        if hasEnvelope {
            recorded = normalized(surface) ?? "unreadable"
        } else {
            guard let fromSource = normalized(source) else { return nil }
            recorded = fromSource
        }

        switch recorded {
        case "app", "chat", "mac", "default":
            // The local window is the person at this Mac unless the envelope
            // names an agent lane (a bridge, her own native work).
            return normalized(agent) == nil ? nil : .automated
        case "claude-bridge", "claude_bridge", "claude":
            guard bridgeAgentMatches("claude", hasEnvelope: hasEnvelope, agent: agent) else {
                return .automated
            }
            return .claude
        case "codex-bridge", "codex_bridge", "codex":
            guard bridgeAgentMatches("codex", hasEnvelope: hasEnvelope, agent: agent) else {
                return .automated
            }
            return .codex
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
            // Unrecognized. Say that it is machine-authored and say NOTHING
            // about what it claims to be.
            return .automated
        }
    }

    /// A named bridge badge describes the server-selected route. The surface
    /// and lane fields must agree; a contradictory or incomplete object is
    /// still visibly automated, but it cannot borrow another route's label.
    private static func bridgeAgentMatches(
        _ expected: String,
        hasEnvelope: Bool, agent: String?
    ) -> Bool {
        // `source` alone is routing/display data. A named bridge badge requires
        // the recorded envelope and an agreeing pair. The
        // bridge currently shares one bearer across routes, so this is route
        // provenance rather than independent caller-identity attestation.
        guard hasEnvelope else { return false }
        return normalized(agent) == expected
    }

    /// Human transport labels describe the person-facing ingress, so an
    /// explicit machine-agent claim contradicts them. A remote-human label
    /// requires the recorded envelope; source alone proves no human authorship.
    private static func humanTransportHasNoAgent(
        hasEnvelope: Bool, agent: String?
    ) -> Bool {
        guard hasEnvelope else { return false }
        return normalized(agent) == nil
    }

    /// Trim and case-fold, and treat blank as absent. Does not attempt to make
    /// hostile input safe — that is the allowlist's job, not this function's.
    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
