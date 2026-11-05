import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `AlivePalette.swift` | Phone haze colours, contrast tokens and page metrics |

// MARK: - The colour setting

extension HazeColor {
    var swatch: Color { Color(hex: shades[0]) }

    /// Deep haze clears 5:1 for white labels; darken it 30% in light mode so tinted words also clear 5:1 over the brightest haze.
    func control(dark: Bool, labelled: Bool) -> Color {
        guard !dark else { return Color(hex: labelled ? shades[1] : shades[0]) }
        let deep = UIColor(Color(hex: shades[1]))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        deep.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(uiColor: UIColor(red: r * 0.7, green: g * 0.7, blue: b * 0.7, alpha: 1))
    }
}

// MARK: - Tokens

enum AliveMetrics {
    static let cardRadius: CGFloat = 22
    static let rowInsetH: CGFloat = 18
    static let rowInsetV: CGFloat = 14
    static let pageInset: CGFloat = 16
    static let rootTop: CGFloat = 8
    /// Hold 44pt for the trailing control so the title row cannot grow.
    static let titleRow: CGFloat = 44
    static let lineRow: CGFloat = 22
}

/// Text must clear 4.5:1 over card fill and overlapping haze; secondary clears about 6.5:1, whereas tertiary does not.
enum AlivePalette {
    static let room = adaptive(dark: 0x12161F, light: 0xF2EDE4)
    static let text = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    /// User chat text needs about 6:1 contrast; 60% secondary reaches only 3.1:1 over light haze.
    static let ownLine = text.opacity(0.64)
    /// Translucent cream in light mode and 6% white in dark keep the haze visible through cards.
    static let fill = tint(dark: UIColor.white.withAlphaComponent(0.06),
                           light: UIColor(red: 1, green: 0.985, blue: 0.955, alpha: 0.36))
    static let highlight = tint(dark: UIColor.white.withAlphaComponent(0.14), light: UIColor.white.withAlphaComponent(0.85))
    static let rim = tint(dark: UIColor.white.withAlphaComponent(0.05),
                          light: UIColor(red: 0.36, green: 0.26, blue: 0.16, alpha: 0.12))
    static let divider = Color(uiColor: .separator)

    private static func adaptive(dark: UInt, light: UInt) -> Color {
        Color(uiColor: UIColor { UIColor(Color(hex: $0.userInterfaceStyle == .dark ? dark : light)) })
    }

    private static func tint(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
