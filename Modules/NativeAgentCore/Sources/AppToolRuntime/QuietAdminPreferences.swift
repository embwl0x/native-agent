import PersistenceCore
import Foundation
// Blueprint: | `QuietAdminPreferences.swift` | `ShotgunPreference`, `MoodTintPreference`, `SimpleViewMode`; shared appearance and view preferences |

/// The revert seam. On for a fresh install (User: fresh installs turn every
/// feature on; users switch off what they want), off in one flip, and the same
/// key the agent reads and writes through `app_settings_list` /
/// `app_setting_set`.
/// Shotgun (User, 10-04): when she starts driving the Mac in the chat on
/// screen, the main window steps aside into a small floating chat. One key,
/// read by the composer's switch, the panel and her own settings page.
public enum ShotgunPreference {
    public static let enabledKey = "NativeAgent.shotgun.enabled"
}

public enum MoodTintPreference {
    public static let key = "uiMoodTint"

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

    /// The view the window shows now, and so the layout profile it draws with.
    public static var current: String { resolved(UserDefaults.standard.string(forKey: key) ?? "") }

    /// What the window shows now: Simple has no pages to send anyone to.
    public static var isShowing: Bool { current == simple }
    public static let noPagesNote = "Simple view is on screen and has no pages: this switches it to Advanced, so use it only when asked to see a page; otherwise say where it is."

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
