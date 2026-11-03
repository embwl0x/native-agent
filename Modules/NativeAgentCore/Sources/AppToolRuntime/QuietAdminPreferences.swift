import Foundation
// Blueprint: | `QuietAdminPreferences.swift` | `ShotgunPreference`, `MoodTintPreference`, `SimpleViewMode`; shared appearance preferences and checked saved view; an absent preference starts in Simple |

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

    public static func checkedCurrent(_ defaults: UserDefaults = .standard) throws -> String {
        if let value = defaults.object(forKey: key) {
            guard let saved = value as? String, choices.contains(saved) else { throw QuietSettingError.unavailable("The saved view is not a current view. Choose simple, advanced or agent explicitly.") }
            return saved
        }
        return simple
    }

    public static func resolved(_ raw: String) -> String {
        // The AppStorage argument makes SwiftUI observe changes; the checked
        // preference owner decides the value, including invalid stored types.
        current
    }

    public static var readFailure: String? {
        do { _ = try checkedCurrent(); return nil }
        catch { return error.localizedDescription }
    }

    /// The view the window shows now, and so the layout profile it draws with.
    public static var current: String {
        do { return try checkedCurrent() }
        catch { return "unavailable" }
    }

    /// What the window shows now: Simple has no pages to send anyone to.
    public static var isShowing: Bool { current == simple }
    public static let noPagesNote = "Simple view is on screen and has no pages: this switches it to Advanced, so use it only when asked to see a page; otherwise say where it is."

    /// Persist the one first-launch default, without replacing an existing value.
    public static func settle(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(simple, forKey: key)
    }
}
