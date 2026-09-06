import Foundation

/// Persisted expansion state for the read-only Trust policy map. Keeping the
/// key and its read/write behavior beside the map projection lets the view and
/// an independent fresh owner agree on whether the explanatory disclosure is
/// open; it does not change or authorize any policy.
enum TrustPolicyMapDisclosurePresentation {
    static let preferenceKey = "trustShowPolicyMap"

    static func isExpanded(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    static func setExpanded(_ expanded: Bool, in defaults: UserDefaults) {
        defaults.set(expanded, forKey: preferenceKey)
    }
}

/// Capability claims shown by Trust Center must use the same mode templates as
/// the access-mode writer. Keeping this catalog at that boundary means a new
/// Mac-control flag cannot reach persisted policy without also changing the
/// map a person reads before selecting that mode.
enum TrustAccessModeCapabilityCatalog {
    static func normalizedMode(_ rawMode: String) -> String {
        let mode = rawMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return ["auto", "read_only", "workspace", "full"].contains(mode) ? mode : "auto"
    }

    static func macControlPolicy(
        for rawMode: String,
        remoteFromIosAllowed: Bool = false,
        developerMode: Bool = false
    ) -> TrustMacControlPolicy {
        switch normalizedMode(rawMode) {
        case "workspace":
            return TrustMacControlPolicy(
                enabled: true,
                shortcutsAllowed: true,
                fileOpsAllowed: true,
                notificationsAllowed: true,
                spotlightAllowed: true,
                remoteFromIosAllowed: remoteFromIosAllowed
            )
        case "full":
            return TrustMacControlPolicy(
                enabled: true,
                applesScriptAllowed: true,
                jxaAllowed: true,
                shortcutsAllowed: true,
                accessibilityAllowed: true,
                systemControlAllowed: developerMode,
                fileOpsAllowed: true,
                shellAllowed: developerMode,
                notificationsAllowed: true,
                spotlightAllowed: true,
                approvalRequiredFor: [],
                remoteFromIosAllowed: true
            )
        default:
            return TrustMacControlPolicy(
                enabled: false,
                applesScriptAllowed: false,
                jxaAllowed: false,
                shortcutsAllowed: false,
                accessibilityAllowed: false,
                systemControlAllowed: false,
                fileOpsAllowed: false,
                shellAllowed: false,
                notificationsAllowed: false,
                spotlightAllowed: false,
                remoteFromIosAllowed: false
            )
        }
    }

    static func macControlWireValue(
        for rawMode: String,
        remoteFromIosAllowed: Bool = false,
        developerMode: Bool = false
    ) -> [String: Any] {
        let policy = macControlPolicy(
            for: rawMode,
            remoteFromIosAllowed: remoteFromIosAllowed,
            developerMode: developerMode
        )
        let defaultRiskGate: [String: Any] = [
            "low": "auto",
            "medium": "approve_each",
            "high": "approve_each",
            "critical": "deny",
        ]
        let riskGate: [String: Any] = normalizedMode(rawMode) == "full"
            ? [
                "low": "auto",
                "medium": "auto",
                "high": "auto",
                "critical": developerMode ? "auto" : "deny",
            ]
            : defaultRiskGate
        return [
            "enabled": policy.enabled,
            "applescript_allowed": policy.applesScriptAllowed,
            "jxa_allowed": policy.jxaAllowed,
            "shortcuts_allowed": policy.shortcutsAllowed,
            "accessibility_allowed": policy.accessibilityAllowed,
            "system_control_allowed": policy.systemControlAllowed,
            "file_ops_allowed": policy.fileOpsAllowed,
            "shell_allowed": policy.shellAllowed,
            "notifications_allowed": policy.notificationsAllowed,
            "spotlight_allowed": policy.spotlightAllowed,
            "remote_from_ios_allowed": policy.remoteFromIosAllowed,
            "approval_required_for": policy.approvalRequiredFor,
            "riskGatePolicy": riskGate,
        ]
    }
}

struct TrustPolicyMapRow: Identifiable, Equatable {
    let mode: String
    let title: String
    let files: String
    let autonomy: String
    /// What SELECTING this mode would write — the mode's template.
    let macControlPolicy: TrustMacControlPolicy
    /// The policy actually on disk, carried only by the highlighted row.
    /// User, 2026-09-06: the highlighted row described the template rather than
    /// what is saved, so with Full Mac active it always claimed Mac control and
    /// iOS remote were on — but the Mac-control screen turns each of those off
    /// independently without leaving the mode. The row a person reads as "what
    /// is on right now" now reads the saved values.
    var savedPolicy: TrustMacControlPolicy?
    let isActive: Bool

    var id: String { mode }
    /// The template for every other row; the saved policy for the active one.
    private var describedPolicy: TrustMacControlPolicy {
        isActive ? (savedPolicy ?? macControlPolicy) : macControlPolicy
    }
    var shellAllowed: Bool { describedPolicy.enabled && describedPolicy.shellAllowed }
    var macControlAllowed: Bool { describedPolicy.enabled }
    var iosRemoteAllowed: Bool {
        describedPolicy.enabled && describedPolicy.remoteFromIosAllowed
    }
}

enum TrustPolicyMapPresentation: Equatable {
    case policyUnavailable
    case rows([TrustPolicyMapRow])

    static func resolve(policy: TrustPolicy?, activeMode: String) -> Self {
        guard let policy else { return .policyUnavailable }
        let remoteFromIosAllowed = policy.macControlPolicy?.remoteFromIosAllowed ?? false
        let developerMode = policy.developerMode
        let modes: [(mode: String, title: String, files: String, autonomy: String)] = [
            ("auto", "Auto", "read", "supervised"),
            ("read_only", "Read", "read", "supervised"),
            ("workspace", "Workspace", "workspace", "workspace"),
            ("full", "Full Mac", "all", "full"),
        ]
        let active = TrustAccessModeCapabilityCatalog.normalizedMode(activeMode)
        return .rows(modes.map { definition in
            TrustPolicyMapRow(
                mode: definition.mode,
                title: definition.title,
                files: definition.files,
                autonomy: definition.autonomy,
                macControlPolicy: TrustAccessModeCapabilityCatalog.macControlPolicy(
                    for: definition.mode,
                    remoteFromIosAllowed: remoteFromIosAllowed,
                    developerMode: developerMode
                ),
                savedPolicy: policy.macControlPolicy,
                isActive: definition.mode == active
            )
        })
    }
}
