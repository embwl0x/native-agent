import Foundation

// Blueprint: | `MobileAppSettings.swift` | `MobileAppSetting`: settings control descriptor and current value for Mac projection and signed phone-local inspection; single-value update spellings |

/// A settings owner's current row. Mac-owned rows are projected to the phone;
/// phone-owned rows answer signed settings inspection requests. Each side
/// changes values through the same owners as its native controls.
public struct MobileAppSetting: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var page: String
    public var label: String
    /// `boolean`, `text`, `choice`, `number` or `list`.
    public var type: String
    public var choices: [String]
    public var writable: Bool
    /// The value as text: `true`/`false`, the number, the choice, or one list
    /// entry per line. A set sends the same spelling back. Unavailable rows
    /// carry no value, so a failed read never means off or empty.
    public var value: String?
    /// The failed row's read cause. Such rows are read-only; siblings still publish.
    public var unavailableReason: String?

    public init(id: String, page: String, label: String, type: String,
                choices: [String], writable: Bool, value: String?, unavailableReason: String? = nil) {
        self.id = id; self.page = page; self.label = label; self.type = type
        self.choices = choices; self.writable = writable; self.value = value
        self.unavailableReason = unavailableReason
    }
}
