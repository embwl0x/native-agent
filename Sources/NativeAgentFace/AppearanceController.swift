import AppKit
import Observation
import SwiftUI

// Blueprint: | `AppearanceController.swift` | `AppearanceController`: one explicit light/dark answer applied consistently to SwiftUI and AppKit |

/// Apply explicit values to SwiftUI and AppKit so both layers agree while following live system appearance when dark mode is off.
@MainActor
@Observable
final class AppearanceController {
    static let shared = AppearanceController()

    static let preferenceKey = "nativeagent.darkMode"
    private static let systemKey = "AppleInterfaceStyle"
    private static let systemChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    private(set) var preferDark: Bool
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

    /// Apply both layers together so their appearances cannot diverge.
    func apply() {
        NSApp.appearance = appearance
        DetachedChatWindowController.shared.applyAppearanceToOpenPanels(appearance)
        ShotgunController.shared.applyAppearance(appearance)
    }

    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: systemKey)?.lowercased() == "dark"
    }
}
