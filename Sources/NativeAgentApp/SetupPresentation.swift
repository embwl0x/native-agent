// Lane B (2026-09-02, ui-simplify): the value owners behind the Setup page.
// Pure mapping + a single settings key owner, kept out of the view so the
// switch wording and the storage it writes can be read in one place.

import Foundation

/// MOMENTS THE AGENT KEEPS — the one owner of the moments-lane switch key.
///
/// `AdaptiveMemoryPromoter` lives in a module that must never read
/// UserDefaults, so it receives this as an injected closure at launch
/// (AppDelegate+Launch). Default ON: the lane shipped on, and an install that
/// never opens Setup keeps the behavior it already had.
enum MomentsLaneSetting {
    static let defaultsKey = "momentsLaneEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

/// HOW MUCH THE AGENT MAY DO ALONE — the three postures Setup exposes, mapped
/// onto the Trust Center presets that already own the policy write.
///
/// ── THE MAPPING ─────────────────────────────────────────────────────────────
///   Ask      → `TrustPolicyPreset.safe`     (access `read_only`, strict)
///   Balanced → `TrustPolicyPreset.work`     (access `workspace`, outside deny)
///   Trusted  → `TrustPolicyPreset.builder`  (access `workspace`, outside ask)
///
/// Full Mac YOLO and Developer Mode are deliberately NOT reachable from here.
/// They are a security-domain escalation with their own confirmation alert and
/// stay in Advanced ▸ Trust. A policy already sitting at Full Mac is therefore
/// not representable by these three segments: `resolve` returns nil for it and
/// the Setup row renders a read-only line pointing at Trust rather than
/// silently downgrading a grant the user made deliberately.
enum SetupPosture: String, CaseIterable, Identifiable, Sendable {
    case ask
    case balanced
    case trusted
    /// Full run of the Mac. A fourth word, because the picker must never
    /// light a segment for a state it is not in.
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .balanced: "Balanced"
        case .trusted: "Trusted"
        case .everything: "Everything"
        }
    }

    /// One plain sentence that changes with the choice, spoken in the agent's
    /// name. User, 2026-09-02: "Everything" has to read as what it is — full
    /// run, no asking, nothing held back.
    func sentence(_ voice: AgentVoice) -> String {
        switch self {
        case .ask:
            "Asks before anything that changes something, and reads only what you point \(voice.object) at."
        case .balanced:
            "Asks before anything that changes something outside this app."
        case .trusted:
            "Works alone in your folders, and still asks before touching anything outside them."
        case .everything:
            "Full run of this Mac. \(voice.Subject) can change anything within reach."
        }
    }

    var preset: TrustPolicyPreset {
        switch self {
        case .ask: .safe
        case .balanced: .work
        case .trusted: .builder
        case .everything: .fullMac
        }
    }

    /// The live posture, or nil when the saved policy is outside these three
    /// (Full Mac). `accessMode` is the already-resolved mode string the Trust
    /// surface computes from the same policy.
    static func resolve(accessMode: String, outsideWorkspaceDefault: String?) -> SetupPosture? {
        switch accessMode {
        case "full":
            return .everything
        case "read_only":
            return .ask
        default:
            // workspace / auto. The outside-workspace default is what separates
            // Balanced from Trusted, and it is the only field the Builder
            // preset moves relative to Work Mode.
            return (outsideWorkspaceDefault == "ask" || outsideWorkspaceDefault == "allow")
                ? .trusted
                : .balanced
        }
    }
}
