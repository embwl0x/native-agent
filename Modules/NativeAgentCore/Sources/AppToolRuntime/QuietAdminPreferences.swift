import Foundation
// Blueprint: | `QuietAdminPreferences.swift` | `ShotgunPreference`, `MoodTintPreference`, `SimpleViewMode`; Shared checked view and appearance preferences |

/// Driving in the visible chat moves the window aside into a floating chat; fresh installs enable this preference.
/// Composer, panel and agent settings share one key so the user's choice remains consistent.
public enum ShotgunPreference {
    public static let enabledKey = "NativeAgent.shotgun.enabled"
}

public enum MoodTintPreference {
    public static let key = "uiMoodTint"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}

/// The shared view-mode key selects Simple, Advanced or Agent; Agent exposes the agent's window and is never the unset default.
public enum SimpleViewMode {
    public static let key = "nativeagent.viewMode"
    public static let simple = "simple"
    public static let advanced = "advanced"
    public static let agent = "agent"
    public static let choices = [simple, advanced, agent]

    public static func checkedCurrent(_ defaults: UserDefaults = .standard) throws -> String {
        if let value = defaults.object(forKey: key) {
            guard let saved = value as? String, choices.contains(saved) else { throw QuietSettingError.unavailable(
                "The saved view is not a current view. Choose simple, advanced or agent explicitly.") }
            return saved
        }
        return simple
    }

    public static func resolved(_ raw: String) -> String {
        // The AppStorage argument makes SwiftUI observe changes; the checked preference owner decides the value, including invalid stored types.
        current
    }

    public static var readFailure: String? {
        do { _ = try checkedCurrent(); return nil }
        catch { return error.localizedDescription }
    }

    /// Resolve the live view before choosing its layout profile.
    public static var current: String {
        do { return try checkedCurrent() }
        catch { return "unavailable" }
    }

    /// Simple has no sidebar pages to navigate to.
    public static var isShowing: Bool { current == simple }
    public static let noPagesNote = """
        Simple view is on screen and has no pages: this switches it to Advanced, so use it only when asked to see a page; otherwise say where it is.
        """

    /// Persist the first-launch default only while no preference exists.
    public static func settle(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(simple, forKey: key)
    }
}
