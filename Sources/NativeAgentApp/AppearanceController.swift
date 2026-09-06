import AppKit
import Observation
import SwiftUI

/// The one answer to "is the window dark?".
///
/// User, 2026-09-02: turning the dark window OFF used to hand SwiftUI a nil
/// colour scheme and AppKit a nil appearance. Neither reliably undoes an
/// explicit dark: the title bar and rail stayed dark while the page repainted
/// white with white labels. So the window is never told "nil". It is told
/// dark or light, explicitly, on both layers, and "off" means whatever the
/// system is doing right now, tracked live.
@MainActor
@Observable
final class AppearanceController {
    static let shared = AppearanceController()

    static let preferenceKey = "nativeagent.darkMode"
    private static let systemKey = "AppleInterfaceStyle"
    private static let systemChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    /// Settings ▸ Appearance ▸ "Prefer the dark window, whatever the system is doing."
    private(set) var preferDark: Bool
    /// The system's own setting, live.
    private(set) var systemIsDark: Bool

    var isDark: Bool { preferDark || systemIsDark }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    private init() {
        // User, 2026-09-06: dark is the default. An unset preference means
        // dark; only an explicit false means follow the system.
        preferDark = (UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool) ?? true
        systemIsDark = Self.readSystemIsDark()
        DistributedNotificationCenter.default().addObserver(
            forName: Self.systemChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemIsDark = Self.readSystemIsDark(); self?.apply() }
        }
        apply()
    }

    func setPreferDark(_ dark: Bool) {
        guard preferDark != dark else { return }
        preferDark = dark
        apply()
    }

    /// Both layers, explicitly, every time.
    func apply() {
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: systemKey)?.lowercased() == "dark"
    }
}
