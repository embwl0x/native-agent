import Foundation
// Blueprint: | `NotificationChannelPreference.swift` | Shared delivery-admission preferences. |

/// Suppress disabled destinations at claim admission; policy never selects another channel because one is off.
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
