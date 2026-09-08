import Foundation

/// Decoding compatibility for Mac Control snapshots; TrustCenter retains policy authority.
/// Platform models own their direct-construction defaults and encoding surfaces.
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        applesScriptAllowed = try c.decodeIfPresent(Bool.self, forKey: .applesScriptAllowed) ?? false
        jxaAllowed = try c.decodeIfPresent(Bool.self, forKey: .jxaAllowed) ?? false
        shortcutsAllowed = try c.decodeIfPresent(Bool.self, forKey: .shortcutsAllowed) ?? true
        accessibilityAllowed = try c.decodeIfPresent(Bool.self, forKey: .accessibilityAllowed) ?? false
        systemControlAllowed = try c.decodeIfPresent(Bool.self, forKey: .systemControlAllowed) ?? false
        fileOpsAllowed = try c.decodeIfPresent(Bool.self, forKey: .fileOpsAllowed) ?? false
        shellAllowed = try c.decodeIfPresent(Bool.self, forKey: .shellAllowed) ?? false
        notificationsAllowed = try c.decodeIfPresent(Bool.self, forKey: .notificationsAllowed) ?? true
        spotlightAllowed = try c.decodeIfPresent(Bool.self, forKey: .spotlightAllowed) ?? true
        approvalRequiredFor = try c.decodeIfPresent([String].self, forKey: .approvalRequiredFor) ?? ["shell", "file_ops", "applescript", "jxa", "accessibility"]
        remoteFromIosAllowed = try c.decodeIfPresent(Bool.self, forKey: .remoteFromIosAllowed) ?? false
    }
}
