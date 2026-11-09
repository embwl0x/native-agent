
import SwiftUI
import Foundation
import UIKit
import NativeAgentShared
// Blueprint: | `NativeAgentDesign.swift` | `NativeAgentAppearance` (the phone's color-scheme control), `AppFont` and `AppMotion` tokens |

// MARK: - Appearance

enum NativeAgentAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "NativeAgentMobile.appearance"

    @MainActor static var settingControl: PhoneLocalSetting {
        PhoneLocalSetting(id: "phone.appearance", label: "iPhone color scheme", type: "choice",
            choices: allCases.map(\.rawValue), read: {
                guard let saved = UserDefaults.standard.object(forKey: storageKey) else { return system.rawValue }
                guard let raw = saved as? String, Self(rawValue: raw) != nil else {
                    throw PhoneLocalSetting.failure("The saved iPhone appearance is invalid. Choose a color scheme in iPhone NativeAgent Settings.")
                }
                return raw
            }, write: { raw, authority in
                guard Self(rawValue: raw) != nil else { throw PhoneLocalSetting.failure("Choose a listed color scheme.") }
                try authority.check()
                UserDefaults.standard.set(raw, forKey: storageKey)
            })
    }

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolved(_ rawValue: String) -> NativeAgentAppearance {
        NativeAgentAppearance(rawValue: rawValue) ?? .system
    }
}

// MARK: - Typography tokens

enum AppFont {
    static let body    = Font.system(.body,       design: .rounded)
    static let label   = Font.system(.caption,    design: .rounded, weight: .semibold)
    static let tag     = Font.system(.caption2,   design: .rounded, weight: .bold)
}

// MARK: - Motion tokens

enum AppMotion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let pulse  = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    // Animate appended bubbles at the mutation seam; list animation must not animate snapshot replacement.
    static let entrance = Animation.easeOut(duration: 0.22)

    /// Mutation sites lack SwiftUI Environment; read the system Reduce Motion setting directly.
    @MainActor static var entranceSystem: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : entrance
    }

    static func respecting(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
