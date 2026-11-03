import Foundation
// Blueprint: | `NotificationChannelPreference.swift` | Shared phone, Telegram and native banner preferences read by delivery claim admission; Settings writes the same keys |

/// Which ways out the app is allowed to use when it reaches for a person.
///
/// AttentionRouter.policy selects the destination. Its ledger settles an off
/// channel as suppressed; it never selects another channel because one is off.
/// Native banner admission reads inApp at that same claim boundary.
///
/// Every channel ships ON, so an install that never touches these behaves
/// exactly as it did before they existed.
public enum NotificationChannelPreference {
    public static let pushKey = "nativeagent.notify.channel.push"
    public static let telegramKey = "nativeagent.notify.channel.telegram"
    public static let inAppKey = "nativeagent.notify.channel.inApp"

    private static func on(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    public static func push(in defaults: UserDefaults = .standard) -> Bool { on(pushKey, in: defaults) }
    public static func telegram(in defaults: UserDefaults = .standard) -> Bool { on(telegramKey, in: defaults) }
    public static func inApp(in defaults: UserDefaults = .standard) -> Bool { on(inAppKey, in: defaults) }
}
