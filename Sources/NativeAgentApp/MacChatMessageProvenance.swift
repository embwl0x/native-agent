import Foundation

/// 658.14 — session provenance at the render boundary.
///
/// The problem this solves: a message injected by the claude/codex bridge
/// (a wake payload, an automated follow-up) used to land in the transcript
/// byte-identical to something User typed. The only marking was an in-band
/// `[from: claude, via bridge]` text prefix, which the human can type
/// verbatim and which an untrusted payload can counterfeit inside its own
/// body. Six hours later a reader could not tell the two apart.
///
/// Provenance now travels out-of-band on the message record and is projected
/// here into a fixed, closed set of display labels.
///
/// SECURITY POSTURE — why this is an allowlist and not a sanitizer.
/// A trust indicator that renders attacker-influenced text is not a trust
/// indicator. Recorded origin strings pass through
/// `ChatOrchestrationClient.messageSource(for:)`, whose `default:` branch
/// returns the caller's string unchanged, so the recorded value is not a
/// closed vocabulary. Rendering it raw would admit the whole spoofing class:
/// Unicode bidi overrides (U+202E) that visually reverse a label, newlines and
/// control characters that break out of the badge's line, homoglyphs, and
/// unbounded length. Rather than trying to enumerate and strip those, an
/// unrecognized origin renders as the fixed word "Automated" and its raw text
/// is never shown. Refusing to render is the only reliably safe option here,
/// and it fails in the honest direction: unknown reads as machine-authored,
/// never as the human.
struct MacChatMessageProvenance: Sendable, Equatable {
    /// Fixed display text. Always a compile-time constant from this file —
    /// never interpolated from a recorded value.
    let label: String
    /// SF Symbol name. Also always a constant from this file.
    let symbol: String
    /// True for automated/non-human ingress. This drives the stronger visual
    /// treatment; it is not a cryptographic claim about a named process.
    let isAutomated: Bool

    /// Project a transcript row to its badge, or nil when no badge should show.
    ///
    /// Returns nil for the ordinary case — a user message typed into this Mac
    /// app — because badging every message is noise that trains the eye to
    /// ignore the badge, which defeats the point. Assistant and tool rows also
    /// return nil: an assistant row is hers by construction, and marking it
    /// with the bridge's origin would falsely imply the REPLY came from the
    /// bridge.
    static func make(role: String, source: String?, origin: ChatMessageOriginMetadata?) -> MacChatMessageProvenance? {
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
        if let origin {
            recorded = normalized(origin.surface) ?? "unreadable"
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
            return origin == nil ? nil : automatedFallback
        case "claude-bridge", "claude_bridge", "claude":
            guard bridgeAgentMatches("claude", origin: origin) else {
                return automatedFallback
            }
            return .init(label: "Claude - bridge", symbol: "arrow.triangle.branch", isAutomated: true)
        case "codex-bridge", "codex_bridge", "codex":
            guard bridgeAgentMatches("codex", origin: origin) else {
                return automatedFallback
            }
            return .init(label: "Codex - bridge", symbol: "arrow.triangle.branch", isAutomated: true)
        case "telegram":
            guard humanTransportHasNoAgent(origin) else { return automatedFallback }
            return .init(label: "Telegram", symbol: "paperplane", isAutomated: false)
        case "slack":
            guard humanTransportHasNoAgent(origin) else { return automatedFallback }
            return .init(label: "Slack", symbol: "bubble.left.and.bubble.right", isAutomated: false)
        case "ios", "mobile", "iphone", "icloud":
            guard humanTransportHasNoAgent(origin) else { return automatedFallback }
            return .init(label: "iPhone", symbol: "iphone", isAutomated: false)
        case "cron", "scheduler", "scheduled":
            return .init(label: "Scheduled", symbol: "clock.arrow.circlepath", isAutomated: true)
        default:
            // Unrecognized. Say that it is machine-authored and say NOTHING
            // about what it claims to be. See the security note above.
            return automatedFallback
        }
    }

    /// A named bridge badge describes the server-selected route. The surface
    /// and lane fields must agree; a contradictory or incomplete object is
    /// still visibly automated, but it cannot borrow another route's label.
    private static func bridgeAgentMatches(
        _ expected: String,
        origin: ChatMessageOriginMetadata?
    ) -> Bool {
        // `source` alone is routing/display data. A named bridge badge requires
        // the explicit server-written origin object and an agreeing pair. The
        // bridge currently shares one bearer across routes, so this is route
        // provenance rather than independent caller-identity attestation.
        guard let origin else { return false }
        return normalized(origin.agent) == expected
    }

    /// Human transport labels describe the person-facing ingress, so an
    /// explicit machine-agent claim contradicts them. Source-only legacy rows
    /// and explicit origins without an agent remain valid human transports.
    private static func humanTransportHasNoAgent(
        _ origin: ChatMessageOriginMetadata?
    ) -> Bool {
        guard let origin else { return true }
        return normalized(origin.agent) == nil
    }

    private static var automatedFallback: MacChatMessageProvenance {
        .init(
            label: "Automated",
            symbol: "gearshape.arrow.triangle.2.circlepath",
            isAutomated: true
        )
    }

    /// Trim and case-fold, and treat blank as absent. Does not attempt to make
    /// hostile input safe — that is the allowlist's job, not this function's.
    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
