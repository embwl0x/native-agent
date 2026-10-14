import Foundation

/// Closed interpretation of recorded ingress; unknown origins remain automated.
public enum SessionMessageProvenance: Sendable, Equatable {
    case claude, codex, telegram, slack, iPhone, scheduled, automated

    public var isAutomated: Bool {
        switch self {
        case .telegram, .slack, .iPhone: false
        case .claude, .codex, .scheduled, .automated: true
        }
    }

    public static func make(role: String, source: String?, hasOrigin: Bool, surface: String?, agent: String?) -> SessionMessageProvenance? {
        guard role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" else {
            return nil
        }
        // The out-of-band origin record wins when present: it is written by the
        // persistence seam and, unlike `source`, is not overloaded to also mean
        // "tool authorization surface". The bridges legitimately run with
        // source "app" precisely so they keep chat's tool permissions, so
        // `source` alone cannot distinguish them.
        //
        // The PRESENCE of the record is itself the signal, independent of what
        // it says. `surface` is Optional, so `{"origin":{}}` and
        // `{"origin":{"agent":"claude"}}` both decode cleanly with a nil
        // surface. Falling back to `source` there would read "app" and render
        // NO badge — a bridge row displayed as though User typed it, which is
        // precisely the trust leak this file exists to close. An origin with no
        // readable surface is UNATTRIBUTED, not human, so it resolves to the
        // same "unreadable" sentinel the undecodable case uses in
        // ChatMessageMetadata.init(from:) and lands on "Automated" below.
        // Once an origin record exists, this function can never return nil.
        let recorded: String
        if hasOrigin {
            recorded = normalized(surface) ?? "unreadable"
        } else {
            guard let fromSource = normalized(source) else { return nil }
            recorded = fromSource
        }

        switch recorded {
        case "app", "chat", "mac", "default":
            // A local source is human only when there is NO explicit origin
            // record. Once an origin object exists, even
            // {"surface":"app"}, suppressing the badge would turn malformed
            // provenance back into a human-looking row.
            return !hasOrigin ? nil : .automated
        case "claude-bridge", "claude_bridge", "claude":
            guard bridgeAgentMatches("claude", hasOrigin: hasOrigin, agent: agent) else {
                return .automated
            }
            return .claude
        case "codex-bridge", "codex_bridge", "codex":
            guard bridgeAgentMatches("codex", hasOrigin: hasOrigin, agent: agent) else {
                return .automated
            }
            return .codex
        case "telegram":
            guard humanTransportHasNoAgent(hasOrigin: hasOrigin, agent: agent) else { return .automated }
            return .telegram
        case "slack":
            guard humanTransportHasNoAgent(hasOrigin: hasOrigin, agent: agent) else { return .automated }
            return .slack
        case "ios", "mobile", "iphone", "icloud":
            guard humanTransportHasNoAgent(hasOrigin: hasOrigin, agent: agent) else { return .automated }
            return .iPhone
        case "cron", "scheduler", "scheduled":
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
        hasOrigin: Bool, agent: String?
    ) -> Bool {
        // `source` alone is routing/display data. A named bridge badge requires
        // the explicit server-written origin object and an agreeing pair. The
        // bridge currently shares one bearer across routes, so this is route
        // provenance rather than independent caller-identity attestation.
        guard hasOrigin else { return false }
        return normalized(agent) == expected
    }

    /// Human transport labels describe the person-facing ingress, so an
    /// explicit machine-agent claim contradicts them. Source-only legacy rows
    /// and explicit origins without an agent remain valid human transports.
    private static func humanTransportHasNoAgent(
        hasOrigin: Bool, agent: String?
    ) -> Bool {
        guard hasOrigin else { return true }
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
