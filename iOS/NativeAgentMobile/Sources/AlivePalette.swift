import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `AlivePalette.swift` | Phone haze colours, contrast tokens and page metrics |

// MARK: - The colour setting

extension HazeColor {
    var swatch: Color { Color(hex: shades[0]) }

    /// A switch's "on" track takes the base shade in dark; anything carrying a
    /// white label on the colour (a primary button) takes the deep shade,
    /// where the label clears 5:1. In light the deep shade goes 30% darker, so
    /// tinted words clear 5:1 even where the haze is brightest behind them.
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
    /// Cards sit this far from the screen edge; headers, eyebrows and
    /// footnotes sit 4pt further in.
    static let pageInset: CGFloat = 16
    /// A tab root's door sits this far under the status bar, on every tab.
    static let rootTop: CGFloat = 8
    /// The title row holds a 44pt trailing control without growing.
    static let titleRow: CGFloat = 44
    static let lineRow: CGFloat = 22
}

/// Every text colour here clears 4.5:1 on the card fill and on the room where
/// all three haze discs overlap (light, at its 0.7 weight: secondary ≈ 6.5:1).
/// Tertiary grey does not; nothing here uses it.
enum AlivePalette {
    /// Dark: the Mac's night room. Light: warm paper, not a grey list.
    static let room = adaptive(dark: 0x12161F, light: 0xF2EDE4)
    // Use native system label colours.
    static let text = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    /// User's own lines in chat: the label colour, lighter. `secondary` (a grey
    /// at 60%) measured 3.1:1 on the light haze; this is about 6:1 in both
    /// appearances and still reads quieter than her words.
    static let ownLine = text.opacity(0.64)
    /// The card fill: 6% white in dark; in light a translucent warm cream, so
    /// the haze reads through instead of a stark white slab.
    static let fill = tint(dark: UIColor.white.withAlphaComponent(0.06),
                           light: UIColor(red: 1, green: 0.985, blue: 0.955, alpha: 0.36))
    /// Inner top light on a card.
    static let highlight = tint(dark: UIColor.white.withAlphaComponent(0.14), light: UIColor.white.withAlphaComponent(0.85))
    /// The card's rim: a warm umber hairline in light.
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
