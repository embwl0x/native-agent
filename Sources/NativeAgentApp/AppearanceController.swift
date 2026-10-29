import AppKit
import Observation
import SwiftUI

// Blueprint: | `AppearanceController.swift` | `AppearanceController`: one explicit light/dark answer applied consistently to SwiftUI and AppKit |

/// SwiftUI and AppKit receive explicit light/dark values; dark mode off follows the live system appearance.
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
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    private init() {
        // An unset preference means dark; only explicit false follows the system.
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
        NSApp.appearance = appearance
        DetachedChatWindowController.shared.applyAppearanceToOpenPanels(appearance)
        ShotgunController.shared.applyAppearance(appearance)
    }

    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: systemKey)?.lowercased() == "dark"
    }
}
