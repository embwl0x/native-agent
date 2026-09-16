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
enum NotificationChannelPreference {
    static let pushKey = "nativeagent.notify.channel.push"
    static let telegramKey = "nativeagent.notify.channel.telegram"
    static let inAppKey = "nativeagent.notify.channel.inApp"

    private static func on(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func push(in defaults: UserDefaults = .standard) -> Bool { on(pushKey, in: defaults) }
    static func telegram(in defaults: UserDefaults = .standard) -> Bool { on(telegramKey, in: defaults) }
    static func inApp(in defaults: UserDefaults = .standard) -> Bool { on(inAppKey, in: defaults) }
}

/// Read-aloud's voice and the one switch that guarantees silence.
///
/// `quiet` is deliberately enforced at `VoiceOutputController.speak`, the
/// single door both routes go through, rather than at each caller: a promise
/// of "no audio out" that depends on every future call site remembering to ask
/// is not a promise. The tool that renders speech to a FILE is unaffected, and
/// correctly so — it never opens an output device.
///
/// `name` is empty by default, which means the Mac's chosen system voice
/// locally and the route's default voice in the cloud — what shipped.
enum VoicePreference {
    static let quietKey = "nativeagent.voice.quiet"
    static let nameKey = "nativeagent.voice.name"

    /// The cloud voice used before this preference existed. Kept as the
    /// fallback so an unset name renders exactly as it always has.
    static let cloudDefaultName = "alloy"

    static func quiet(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: quietKey)
    }

    static func name(in defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: nameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cloudVoice(in defaults: UserDefaults = .standard) -> String {
        let chosen = name(in: defaults)
        return chosen.isEmpty ? cloudDefaultName : chosen
    }
}
