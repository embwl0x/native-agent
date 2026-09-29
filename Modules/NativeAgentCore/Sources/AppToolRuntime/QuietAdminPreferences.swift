import PersistenceCore
import Foundation

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
public enum VoicePreference {
    public static let quietKey = "nativeagent.voice.quiet"
    public static let nameKey = "nativeagent.voice.name"

    /// The cloud voice used before this preference existed. Kept as the
    /// fallback so an unset name renders exactly as it always has.
    public static let cloudDefaultName = "alloy"

    public static func quiet(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: quietKey)
    }

    public static func name(in defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: nameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func cloudVoice(in defaults: UserDefaults = .standard) -> String {
        let chosen = name(in: defaults)
        return chosen.isEmpty ? cloudDefaultName : chosen
    }
}

/// The revert seam. On for a fresh install (User: fresh installs turn every
/// feature on; users switch off what they want), off in one flip, and the same
/// key the agent reads and writes through `app_settings_list` /
/// `app_setting_set`.
public enum MoodTintPreference {
    public static let key = "uiMoodTint"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}

/// Defaults-backed design experiment.
public enum BotsShelfPreference {
    public static let key = "uiBotsShelfPreview"
    /// On unless the person switched it off (User: fresh installs turn everything on).
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}

/// "simple", "advanced" or "agent", in `nativeagent.viewMode` (the agent can
/// switch it: `settings.view_mode` in QuietSelfAdminSettings). Agent is User's
/// window into hers (AgentScreenView.swift) and never the unset default.
public enum SimpleViewMode {
    public static let key = "nativeagent.viewMode"
    public static let simple = "simple"
    public static let advanced = "advanced"
    public static let agent = "agent"
    public static let choices = [simple, advanced, agent]

    /// With the key unset: Simple on a fresh install, Advanced where chats
    /// already exist, so nobody who knows the full app loses it on update.
    /// Read once per launch.
    public static let unsetDefault: String = hasExistingChats(PersistenceCore.defaultDataRoot()) ? advanced : simple

    public static func resolved(_ raw: String) -> String { choices.contains(raw) ? raw : unsetDefault }

    /// What the window shows now: Simple has no pages to send anyone to.
    public static var isShowing: Bool {
        let defaults = UserDefaults.standard
        return resolved(defaults.string(forKey: key) ?? "") == simple
    }
    public static let noPagesNote = "No pages in Simple view; raise request_interaction for setup."

    /// Write the first-launch answer down, so the chats a new install goes on
    /// to make never flip it to Advanced later.
    public static func settle(_ defaults: UserDefaults = .standard) {
        if defaults.string(forKey: key) == nil { defaults.set(unsetDefault, forKey: key) }
    }

    private static func hasExistingChats(_ root: URL) -> Bool {
        let messages = root.appendingPathComponent("chat/messages", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: messages.path)) ?? []
        return names.contains { $0.hasSuffix(".jsonl") }
    }
}

/// One hue, three shades. The whole palette — the agent may pick any of these
/// by chat and nothing else (`settings.haze_color`).
public enum HazeColor: String, CaseIterable, Identifiable, Sendable {
    case teal, blue, violet, rose, amber, forest, graphite

    public static let key = "nativeagent.hazeColor"
    public static let storageKey = key
    public static let defaultValue: HazeColor = .teal

    public init(stored raw: String) { self = HazeColor(rawValue: raw) ?? .teal }

    public var id: String { rawValue }

    /// The accessibility name, and the word the Settings swatch speaks.
    public var name: String {
        switch self {
        case .forest: return "Forest green"
        default: return rawValue.capitalized
        }
    }

    public var shades: [UInt] {
        switch self {
        case .teal:     return [0x17A597, 0x0F7C78, 0x1CB8A6]
        case .blue:     return [0x2F6FD6, 0x1F4FA8, 0x3C86E8]
        case .violet:   return [0x7A52D6, 0x5A3AA8, 0x8D66EA]
        case .rose:     return [0xC9486E, 0x9C3456, 0xDC5F84]
        case .amber:    return [0xC9852C, 0x9C6220, 0xDC9A3D]
        case .forest:   return [0x3F9A52, 0x2C753C, 0x4FB064]
        case .graphite: return [0x6B7280, 0x4B5260, 0x7D8595]
        }
    }

}
