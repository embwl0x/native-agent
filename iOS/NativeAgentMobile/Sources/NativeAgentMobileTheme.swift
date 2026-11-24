import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |

/// Keep content quiet; reserve Liquid Glass for floating controls and navigation.
enum NativeAgentMobileTheme {
    private static let plateTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.28)
            : UIColor.white.withAlphaComponent(0.58)
    })

    static var plateGlass: Glass { .clear.tint(plateTint) }

    enum Colors {
        static let canvas = Color.adaptive(dark: 0x211F1D, light: 0xF6F4F1)
        static let contentSurface = Color.adaptive(dark: 0x292725, light: 0xFFFFFF)
        static let secondary = Color.secondary
        static let trouble = Color.adaptive(dark: 0xFF9F0A, light: 0x864800)
        static let accentText = Color.adaptive(dark: 0x65CCD2, light: 0x006B73)
        static let navigationGlass = Color.adaptive(dark: 0x292725, light: 0xFFFFFF)
        static let accent = accentText
        static let softFill = ink(dark: 0.08, light: 0.11)
        static let quietFill = ink(dark: 0.05, light: 0.075)
        static let hairline = ink(dark: 0.10, light: 0.14)

        private static func ink(dark: Double, light: Double) -> Color {
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(dark)
                    : UIColor.black.withAlphaComponent(light)
            })
        }
    }

    typealias Spacing = NativeAgentSpacing
    typealias Radius = NativeAgentRadius

    enum Layout {
        static let roomColumn: CGFloat = 740
        static let controlHeight: CGFloat = 44
        static let hairline: CGFloat = 1
    }
}

extension NativeAgentRadius {
    static let composer: CGFloat = 16
}

extension View {
    func mobileCard() -> some View {
        padding(NativeAgentMobileTheme.Spacing.lg)
            .background(NativeAgentMobileTheme.Colors.contentSurface,
                        in: RoundedRectangle(cornerRadius: NativeAgentMobileTheme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: NativeAgentMobileTheme.Radius.card)
                    .strokeBorder(NativeAgentMobileTheme.Colors.hairline, lineWidth: NativeAgentMobileTheme.Layout.hairline)
            }
    }
}
