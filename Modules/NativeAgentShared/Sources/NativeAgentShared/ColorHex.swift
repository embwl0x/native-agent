import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// Blueprint: | `ColorHex.swift` | `NativeAgentSpacing`, `NativeAgentRadius`, `HazeColor`, `HazeMood` and `Color.init(hex:)`: shared geometry and appearance values |

public enum NativeAgentSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let pageInset: CGFloat = 20
    public static let section: CGFloat = 28
    public static let pageTop: CGFloat = 36
    // Content-specific exceptions to the general spacing steps.
    public static let rowInsetV: CGFloat = 14
    public static let eyebrowGap: CGFloat = 10
}

public enum NativeAgentRadius {
    public static let compact: CGFloat = 4
    public static let control: CGFloat = 6
    public static let panel: CGFloat = 8
    public static let card: CGFloat = 8
}

public extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// Initialize from a 6- or 8-digit hex string, e.g. "FF3300" or "FFFF3300".
    /// Returns nil for invalid input.
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        guard h.count == 6 || h.count == 8 else { return nil }
        if h.count == 6 { h = "FF" + h }
        var int: UInt64 = 0
        let scanner = Scanner(string: h)
        guard scanner.scanHexInt64(&int), scanner.isAtEnd else { return nil }
        let a = Double((int >> 24) & 0xFF) / 255
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
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

public enum HazeMood: Equatable, Sendable {
    case idle, busy, replying

    /// Dark-appearance container opacity; each platform applies its light weight.
    public var opacity: Float {
        switch self {
        case .idle: return 0.52
        case .busy: return 0.62
        case .replying: return 0.56
        }
    }

    /// Multiplier on the idle animation loops.
    public var speed: Float {
        switch self {
        case .idle: return 1
        case .busy: return 3.3
        case .replying: return 2
        }
    }
}
