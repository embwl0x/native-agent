import SwiftUI
import UIKit

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Shared iOS vocabulary: native type and materials with the Mac's quiet hierarchy.
/// Content stays quiet; Liquid Glass belongs to floating controls and navigation.
enum NativeAgentMobileTheme {
    static var plateGlass: Glass { .clear.tint(.black.opacity(0.28)) }

    enum Colors {
        static let canvas = adaptive(dark: 0x211F1D, light: 0xF6F4F1)
        static let contentSurface = adaptive(dark: 0x292725, light: 0xFFFFFF)
        static let room = canvas
        static let rail = adaptive(dark: 0x121315, light: 0xECEBE7)
        static let list = adaptive(dark: 0x17181B, light: 0xF1F0EC)
        static let text = Color.primary
        static let secondary = Color.secondary
        /// Opaque secondary ink for reading plates; system secondary blends too faintly into glass.
        static let readingSecondary = adaptive(dark: 0xB8B7B5, light: 0x555451)
        static let tertiary = adaptive(dark: 0xA4AAB0, light: 0x4C5055)
        static let trouble = adaptive(dark: 0xFF9F0A, light: 0x864800)
        static let calm = adaptive(dark: 0x34C759, light: 0x136224)
        static let accentDecoration = Color(hex: 0x65CCD2)
        static let accentText = adaptive(dark: 0x65CCD2, light: 0x006B73)
        static let accentForeground = accentText
        static let navigationGlass = adaptive(dark: 0x292725, light: 0xFFFFFF)
        static let onAccent = adaptive(dark: 0x1C1B1A, light: 0xFFFFFF)
        static let accent = accentText
        /// Opaque ink for small metadata, including tags over quietFill.
        static let metadataText = tertiary
        static let accentDeep = Color(hex: 0x0E7490)
        static let accentCool = Color(hex: 0x38BDF8)
        static let softFill = ink(dark: 0.08, light: 0.11)
        static let quietFill = ink(dark: 0.05, light: 0.075)
        static let hairline = ink(dark: 0.10, light: 0.14)

        private static func adaptive(dark: UInt, light: UInt) -> Color {
            Color(uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: Double((hex >> 16) & 255) / 255,
                               green: Double((hex >> 8) & 255) / 255,
                               blue: Double(hex & 255) / 255, alpha: 1)
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

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let compact: CGFloat = 4
        static let control: CGFloat = 6
        static let panel: CGFloat = 8
        static let card: CGFloat = 8
        static let composer: CGFloat = 16
    }

    enum Layout {
        static let roomColumn: CGFloat = 740
        static let replyLineSpacing: CGFloat = 8
        static let controlHeight: CGFloat = 44
        static let hairline: CGFloat = 1
        static func roomGlassTint(dark: Bool) -> Double { dark ? 0.46 : 0.30 }
    }

    /// Native iOS base ramp; the modifier scales with Dynamic Type.
    enum Typography {
        case caption, label, body, title, display, code
        var size: CGFloat {
            switch self {
            case .caption: 12
            case .label: 16
            case .code: 13
            case .body: 17
            case .title: 22
            case .display: 28
            }
        }
        var relativeTo: Font.TextStyle {
            switch self {
            case .caption: .caption
            case .label: .callout
            case .code: .caption
            case .body: .body
            case .title: .title2
            case .display: .title
            }
        }
    }
}

extension View {
    func mobileTypography(_ style: NativeAgentMobileTheme.Typography, weight: Font.Weight = .regular) -> some View {
        modifier(MobileTypography(style: style, weight: weight))
    }

    /// Apply after sizing/padding. Do not nest glass inside another glass plate.
    func mobileGlassSurface(radius: CGFloat = NativeAgentMobileTheme.Radius.panel, interactive: Bool = false) -> some View {
        modifier(MobileGlassSurface(radius: radius, interactive: interactive))
    }

    func mobileCard() -> some View {
        padding(NativeAgentMobileTheme.Spacing.lg)
            .background(NativeAgentMobileTheme.Colors.contentSurface,
                        in: RoundedRectangle(cornerRadius: NativeAgentMobileTheme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: NativeAgentMobileTheme.Radius.card)
                    .strokeBorder(NativeAgentMobileTheme.Colors.hairline, lineWidth: NativeAgentMobileTheme.Layout.hairline)
            }
    }

    /// For custom floating navigation. Native TabView already supplies its own glass.
    func mobileRail() -> some View {
        mobileGlassSurface(radius: NativeAgentMobileTheme.Radius.composer)
    }

    func mobileDivider() -> some View {
        overlay(NativeAgentMobileTheme.Colors.hairline)
            .frame(height: NativeAgentMobileTheme.Layout.hairline)
            .accessibilityHidden(true)
    }

    func mobileSectionHeader() -> some View {
        mobileTypography(.label, weight: .semibold)
            .textCase(.uppercase)
            .foregroundStyle(NativeAgentMobileTheme.Colors.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

}

struct MobileGlassContainer<Content: View>: View {
    var spacing: CGFloat = NativeAgentMobileTheme.Spacing.md
    @ViewBuilder var content: () -> Content
    var body: some View {
        GlassEffectContainer(spacing: spacing, content: content)
    }
}

private struct MobileTypography: ViewModifier {
    let style: NativeAgentMobileTheme.Typography
    let weight: Font.Weight
    @ScaledMetric private var size: CGFloat
    init(style: NativeAgentMobileTheme.Typography, weight: Font.Weight) {
        self.style = style
        self.weight = weight
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }
    func body(content: Content) -> some View {
        content.font(.system(style.relativeTo, design: style == .code ? .monospaced : .default, weight: weight))
    }
}

private struct MobileGlassSurface: ViewModifier {
    let radius: CGFloat
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
        if reduceTransparency {
            content.background(NativeAgentMobileTheme.Colors.navigationGlass, in: shape)
                .overlay(shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : NativeAgentMobileTheme.Colors.hairline, lineWidth: 1))
        } else {
            content.glassEffect(interactive ? NativeAgentMobileTheme.plateGlass.interactive() : NativeAgentMobileTheme.plateGlass, in: shape)
        }
        }
    }
}
