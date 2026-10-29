import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `NativeAgentMobileTheme.swift` | `NativeAgentMobileTheme` enum |

/// Shared iOS vocabulary: native type and materials with the Mac's quiet hierarchy.
/// Content stays quiet; Liquid Glass belongs to floating controls and navigation.
enum NativeAgentMobileTheme {
    static var plateGlass: Glass { .clear.tint(.black.opacity(0.28)) }

    enum Colors {
        static let canvas = adaptive(dark: 0x211F1D, light: 0xF6F4F1)
        static let contentSurface = adaptive(dark: 0x292725, light: 0xFFFFFF)
        static let secondary = Color.secondary
        /// Opaque secondary ink for reading plates; system secondary blends too faintly into glass.
        static let readingSecondary = adaptive(dark: 0xB8B7B5, light: 0x555451)
        static let trouble = adaptive(dark: 0xFF9F0A, light: 0x864800)
        static let accentText = adaptive(dark: 0x65CCD2, light: 0x006B73)
        static let navigationGlass = adaptive(dark: 0x292725, light: 0xFFFFFF)
        static let accent = accentText
        static let softFill = ink(dark: 0.08, light: 0.11)
        static let quietFill = ink(dark: 0.05, light: 0.075)
        static let hairline = ink(dark: 0.10, light: 0.14)

        private static func adaptive(dark: UInt, light: UInt) -> Color {
            Color(uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(Color(hex: hex))
            })
        }

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
