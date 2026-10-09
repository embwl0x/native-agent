import NativeAgentShared

public enum TrustPolicyPreset: CaseIterable, Equatable, Sendable {
    case safe
    case work
    case builder
    case fullMac

    public var title: String {
        switch self {
        case .safe: "Safe"
        case .work: "Work mode"
        case .builder: "Builder"
        case .fullMac: "Full Mac"
        }
    }

    /// What this posture actually permits, in one line. The Trust page and the
    /// composer's Trust card read the same string, so a posture can never mean
    /// one thing on one surface and another somewhere else.
    public var summary: String {
        switch self {
        case .safe: MobileTrustAction.Preset.safe.summary
        case .work: MobileTrustAction.Preset.workMode.summary
        case .builder: MobileTrustAction.Preset.builder.summary
        case .fullMac: MobileTrustAction.Preset.fullMac.summary
        }
    }

    /// The name quiet self-administration uses for this preset.
    public var quietID: String {
        switch self {
        case .safe: "safe"
        case .work: "work_mode"
        case .builder: "builder"
        case .fullMac: "full_mac"
        }
    }

    /// The presets the agent may apply to itself while this Mac is in Full Mac.
    /// Full Mac is deliberately absent: lowering the fence is allowed, raising
    /// it to Full Mac is the person's alone.
    public static var quietWritable: [TrustPolicyPreset] { [.safe, .work, .builder] }

    public var plan: TrustPolicyPresetPlan {
        switch self {
        case .safe:
            TrustPolicyPresetPlan(
                agentAccessMode: "read_only", permissionLevel: "strict",
                autonomyDefault: "supervised", requireBackups: true,
                outsideDefault: "deny", developerMode: false,
                commit: .accessModeOnly, requiresFullMacConfirmation: false,
                enablesAutonomy: false
            )
        case .work:
            TrustPolicyPresetPlan(
                agentAccessMode: "workspace", permissionLevel: "balanced",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "deny", developerMode: false,
                commit: .accessModeOnly, requiresFullMacConfirmation: false
            )
        case .builder:
            TrustPolicyPresetPlan(
                agentAccessMode: "workspace", permissionLevel: "balanced",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "ask", developerMode: false,
                commit: .accessModeThenTrustPolicy, requiresFullMacConfirmation: false
            )
        case .fullMac:
            TrustPolicyPresetPlan(
                agentAccessMode: "full", permissionLevel: "full_mac_os",
                autonomyDefault: "workspace_autonomous", requireBackups: true,
                outsideDefault: "allow", developerMode: true,
                commit: .accessModeOnly, requiresFullMacConfirmation: true,
                enablesAutonomy: true
            )
        }
    }
}

public struct TrustPolicyPresetPlan: Equatable, Sendable {
    public enum Commit: Equatable, Sendable {
        case accessModeOnly
        case accessModeThenTrustPolicy
    }

    public let agentAccessMode: String
    public let permissionLevel: String
    public let autonomyDefault: String
    public let requireBackups: Bool
    public let outsideDefault: String
    public let developerMode: Bool
    public let commit: Commit
    public let requiresFullMacConfirmation: Bool
    /// What this preset does to unattended work. Full Mac means unattended work
    /// too (User, 2026-09-13), so it writes the switch on; Safe means the
    /// opposite and writes it OFF — leaving it alone meant Full Mac → Safe kept
    /// running unattended under a card that says it cannot change anything.
    /// Work mode and Builder are silent (nil) and leave the person's choice.
    public var enablesAutonomy: Bool? = nil
}
