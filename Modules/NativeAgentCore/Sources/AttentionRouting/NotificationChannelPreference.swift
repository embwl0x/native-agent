import Foundation

/// Which ways out the app is allowed to use when it reaches for a person.
///
/// The routing DECISION still belongs entirely to `AttentionRouter.delivery` —
/// importance and last-active surface, unchanged. This is the narrower
/// question layered over it: of the channels that decision can name, which
/// ones has the person left switched on. A channel that is off is not
/// re-routed to a louder one; it is simply not used, and if nothing is left
/// the delivery is `.none` and the card in the app remains the record.
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
