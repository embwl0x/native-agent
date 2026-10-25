import Foundation

// Blueprint: | `MacControlPolicyWireSnapshot.swift` | `MacControlPolicyWireSnapshot`: shared policy snapshot decoding/defaults; TrustCenter retains policy authority |

/// Decoding compatibility for Mac Control snapshots; TrustCenter retains policy authority.
/// Shared immutable defaults keep phone decoding and TrustCenter's schema equal.
public struct MacControlPolicyWireSnapshot: Decodable, Sendable {
    public let enabled: Bool
    public let applesScriptAllowed: Bool
    public let jxaAllowed: Bool
    public let shortcutsAllowed: Bool
    public let accessibilityAllowed: Bool
    public let systemControlAllowed: Bool
    public let fileOpsAllowed: Bool
    public let shellAllowed: Bool
    public let notificationsAllowed: Bool
    public let spotlightAllowed: Bool
    public let approvalRequiredFor: [String]
    public let remoteFromIosAllowed: Bool

    public static let defaults = Self(
        enabled: false, applesScriptAllowed: false, jxaAllowed: false,
        shortcutsAllowed: true, accessibilityAllowed: false, systemControlAllowed: false,
        fileOpsAllowed: false, shellAllowed: false, notificationsAllowed: true,
        spotlightAllowed: true,
        approvalRequiredFor: ["shell", "file_ops", "applescript", "jxa", "accessibility"],
        remoteFromIosAllowed: false)

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
