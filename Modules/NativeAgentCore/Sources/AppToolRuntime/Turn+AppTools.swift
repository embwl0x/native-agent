import Foundation
import NativeAgentCore
// Blueprint: | `Turn+AppTools.swift` | `Turn` parts app tools own: setting-write authority and the signed phone change |

private enum SettingFullMacPart: TurnPart { static let unset: Bool = false }
private enum SettingByOwnerPart: TurnPart { static let unset: Bool = false }
private enum RestoresPreviousSettingPart: TurnPart { static let unset: Bool = false }
private enum PhoneSettingChangePart: TurnPart { static let unset: PhoneSettingChange? = nil }

extension Turn {
    /// Full Mac authority for this setting act.
    public var settingFullMac: Bool {
        get { self[SettingFullMacPart.self] }
        set { self[SettingFullMacPart.self] = newValue }
    }
    /// The signed owner's setting-write authority.
    public var settingByOwner: Bool {
        get { self[SettingByOwnerPart.self] }
        set { self[SettingByOwnerPart.self] = newValue }
    }
    /// Authority to restore the last quoted switch value.
    public var restoresPreviousSetting: Bool {
        get { self[RestoresPreviousSettingPart.self] }
        set { self[RestoresPreviousSettingPart.self] = newValue }
    }
    /// The signed phone action and client this setting write answers.
    public var phoneSettingChange: PhoneSettingChange? {
        get { self[PhoneSettingChangePart.self] }
        set { self[PhoneSettingChangePart.self] = newValue }
    }
}
