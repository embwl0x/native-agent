import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore

extension SwiftNativeSecurityCenter {
    static func fullMacActive(policy: [String: JSONValue], now: Date = Date()) -> Bool {
        guard let trust = MacControlPolicy.fromTrustPolicyObject(policy).trustPolicy else {
            return false
        }
        return MacControlGate.fullMacActive(trust, now: now)
    }

    static func fullMacExpiresAt(policy: [String: JSONValue]) -> String? {
        if Self.bool(policy["fullMacNeverExpires"], default: false) {
            return "never"
        }
        guard let expiresAt = Self.string(policy["fullMacExpiresAt"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expiresAt.isEmpty else {
            return nil
        }
        return expiresAt
    }

    static func fullMacYoloAllowsAutonomy(
        tool: String,
        origin: SecurityOriginContext,
        originAssessment: OriginAssessment,
        profile: ToolProfile,
        fullMac: Bool
    ) -> Bool {
        let surface = origin.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let localYoloSurface = !originAssessment.isRemote
            && fullMacYoloLocalSurfaces.contains(surface)
        let trustedRemoteYoloSurface = originAssessment.isRemote
            && originAssessment.trusted
            && fullMacYoloTrustedRemoteSurfaces.contains(surface)
        guard fullMac,
              localYoloSurface || trustedRemoteYoloSurface else {
            return false
        }
        if fullMacYoloAutonomyExcludedToolNames.contains(tool) {
            return false
        }
        if profile.capabilities.contains("evolution_write")
            || profile.capabilities.contains("evolution_apply_trigger")
            || profile.capabilities.contains("money") {
            return false
        }
        if profile.capabilities.contains("external_send"),
           !profile.capabilities.contains("notification"),
           !profile.capabilities.contains("approval_stage") {
            return false
        }
        return true
    }

    /// P2-3: `workshop` is the canonical Workshop surface; `mission`/`missions`
    /// stay for turns that still arrive on the 0.3.x spelling. Dropping either
    /// makes full-mac yolo quietly stop elevating Workshop builder steps.
    ///
    /// Wave 5b: the Workshop spellings come from
    /// `WorkshopSurfaceVocabulary.gateSpellings` rather than being open-coded
    /// here, per this vocabulary's own rule (no caller may hand-write an
    /// `== "missions"` check). Same three strings, same membership.
    static let fullMacYoloLocalSurfaces: Set<String> = Set(
        ["chat", "codex-bridge", "claude-bridge"]
            + WorkshopSurfaceVocabulary.gateSpellings
    )

    static let fullMacYoloTrustedRemoteSurfaces: Set<String> = [
        "telegram",
        "slack",
        "ios",
        "icloud",
        "iphone",
        "ipad",
        "mobile",
        "watch",
        "remote",
    ]

    static let fullMacYoloAutonomyExcludedToolNames: Set<String> = [
        "self_install",
        "evolution_propose",
        "evolution_status",
        "gmail.send",
        "email.send",
        "agentmail.send",
        "slack.post_message",
        "x.post_tweet",
        "calendar.cancel_event",
    ]
}
