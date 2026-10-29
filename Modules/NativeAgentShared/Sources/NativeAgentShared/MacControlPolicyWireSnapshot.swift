import Foundation

// Blueprint: | `MacControlPolicyWireSnapshot.swift` | `MacControlPolicyWireSnapshot`: shared Codable/Hashable policy snapshot, decoding/defaults; TrustCenter retains policy authority |

/// Shared policy fields and compatibility defaults; TrustCenter retains authority.
public struct MacControlPolicyWireSnapshot: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var applesScriptAllowed: Bool
    public var jxaAllowed: Bool
    public var shortcutsAllowed: Bool
    public var accessibilityAllowed: Bool
    public var systemControlAllowed: Bool
    public var fileOpsAllowed: Bool
    public var shellAllowed: Bool
    public var notificationsAllowed: Bool
    public var spotlightAllowed: Bool
    public var approvalRequiredFor: [String]
    public var remoteFromIosAllowed: Bool

    public static let defaults = Self(
        enabled: false, applesScriptAllowed: false, jxaAllowed: false,
        shortcutsAllowed: true, accessibilityAllowed: false, systemControlAllowed: false,
        fileOpsAllowed: false, shellAllowed: false, notificationsAllowed: true,
        spotlightAllowed: true,
        approvalRequiredFor: ["shell", "file_ops", "applescript", "jxa", "accessibility"],
        remoteFromIosAllowed: false)

    public init(
        enabled: Bool = MacControlPolicyWireSnapshot.defaults.enabled,
        applesScriptAllowed: Bool = MacControlPolicyWireSnapshot.defaults.applesScriptAllowed,
        jxaAllowed: Bool = MacControlPolicyWireSnapshot.defaults.jxaAllowed,
        shortcutsAllowed: Bool = MacControlPolicyWireSnapshot.defaults.shortcutsAllowed,
        accessibilityAllowed: Bool = MacControlPolicyWireSnapshot.defaults.accessibilityAllowed,
        systemControlAllowed: Bool = MacControlPolicyWireSnapshot.defaults.systemControlAllowed,
        fileOpsAllowed: Bool = MacControlPolicyWireSnapshot.defaults.fileOpsAllowed,
        shellAllowed: Bool = MacControlPolicyWireSnapshot.defaults.shellAllowed,
        notificationsAllowed: Bool = MacControlPolicyWireSnapshot.defaults.notificationsAllowed,
        spotlightAllowed: Bool = MacControlPolicyWireSnapshot.defaults.spotlightAllowed,
        approvalRequiredFor: [String] = MacControlPolicyWireSnapshot.defaults.approvalRequiredFor,
        remoteFromIosAllowed: Bool = MacControlPolicyWireSnapshot.defaults.remoteFromIosAllowed
    ) {
        self.enabled = enabled
        self.applesScriptAllowed = applesScriptAllowed
        self.jxaAllowed = jxaAllowed
        self.shortcutsAllowed = shortcutsAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.systemControlAllowed = systemControlAllowed
        self.fileOpsAllowed = fileOpsAllowed
        self.shellAllowed = shellAllowed
        self.notificationsAllowed = notificationsAllowed
        self.spotlightAllowed = spotlightAllowed
        self.approvalRequiredFor = approvalRequiredFor
        self.remoteFromIosAllowed = remoteFromIosAllowed
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case applesScriptAllowed = "applescript_allowed"
        case jxaAllowed = "jxa_allowed"
        case shortcutsAllowed = "shortcuts_allowed"
        case accessibilityAllowed = "accessibility_allowed"
        case systemControlAllowed = "system_control_allowed"
        case fileOpsAllowed = "file_ops_allowed"
        case shellAllowed = "shell_allowed"
        case notificationsAllowed = "notifications_allowed"
        case spotlightAllowed = "spotlight_allowed"
        case approvalRequiredFor = "approval_required_for"
        case remoteFromIosAllowed = "remote_from_ios_allowed"
    }

}

extension MacControlPolicyWireSnapshot {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.defaults.enabled
        applesScriptAllowed = try c.decodeIfPresent(Bool.self, forKey: .applesScriptAllowed) ?? Self.defaults.applesScriptAllowed
        jxaAllowed = try c.decodeIfPresent(Bool.self, forKey: .jxaAllowed) ?? Self.defaults.jxaAllowed
        shortcutsAllowed = try c.decodeIfPresent(Bool.self, forKey: .shortcutsAllowed) ?? Self.defaults.shortcutsAllowed
        accessibilityAllowed = try c.decodeIfPresent(Bool.self, forKey: .accessibilityAllowed) ?? Self.defaults.accessibilityAllowed
        systemControlAllowed = try c.decodeIfPresent(Bool.self, forKey: .systemControlAllowed) ?? Self.defaults.systemControlAllowed
        fileOpsAllowed = try c.decodeIfPresent(Bool.self, forKey: .fileOpsAllowed) ?? Self.defaults.fileOpsAllowed
        shellAllowed = try c.decodeIfPresent(Bool.self, forKey: .shellAllowed) ?? Self.defaults.shellAllowed
        notificationsAllowed = try c.decodeIfPresent(Bool.self, forKey: .notificationsAllowed) ?? Self.defaults.notificationsAllowed
        spotlightAllowed = try c.decodeIfPresent(Bool.self, forKey: .spotlightAllowed) ?? Self.defaults.spotlightAllowed
        approvalRequiredFor = try c.decodeIfPresent([String].self, forKey: .approvalRequiredFor) ?? Self.defaults.approvalRequiredFor
        remoteFromIosAllowed = try c.decodeIfPresent(Bool.self, forKey: .remoteFromIosAllowed) ?? Self.defaults.remoteFromIosAllowed
    }
}
