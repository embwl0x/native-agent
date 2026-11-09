import AppKit
import NativeAgentShared
import SwiftUI
// Blueprint: | `NativeAgentDesign.swift` | AppKit transcript preparation tokens shared with the window's typography and geometry |

enum NativeAgentShell {
    static let room       = dynamic(dark: 0x12161F, light: 0xF7F6F3)
    static let rail       = dynamic(dark: 0x121315, light: 0xF3F2EF)
    static let list       = dynamic(dark: 0x17181B, light: 0xF5F4F1)
    static let text       = Color(nsColor: .labelColor)
    static let secondary  = Color(nsColor: .secondaryLabelColor)
    static let tertiary   = Color(nsColor: .tertiaryLabelColor)
    // Clear 4.5:1 on every shell surface; reserve teal for approvals.
    static let needsYou   = dynamic(dark: 0x06B6D4, light: 0x0B5F76)
    static let trouble    = dynamic(dark: 0xFF9F0A, light: 0x864800)
    static let calm       = dynamic(dark: 0x34C759, light: 0x136224)

    static let softFill   = primaryTint(dark: 0.08, light: 0.11)
    static let quietFill  = Color(nsColor: .quaternarySystemFill)
    static let hairline   = Color(nsColor: .separatorColor)

    /// Use appearance-specific primary alpha so fills and hairlines stay weighted in light mode.
    private static func primaryTint(dark: Double, light: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor.white.withAlphaComponent(dark) : NSColor.black.withAlphaComponent(light)
        })
    }

    private static func dynamic(dark: UInt, light: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

enum ShellType {
    static let captionSize: CGFloat = 11
    static let labelSize: CGFloat = 13
    static let bodySize: CGFloat = 16
    static let titleSize: CGFloat = 20
    static let displaySize: CGFloat = 25
    static let pageTitleSize: CGFloat = 44

    /// Reserve monospaced roles for codes, keys and paths so ordinary short labels keep the prose ramp.
    static let code = Font.system(size: labelSize, design: .monospaced)
    static let caption = Font.system(size: captionSize)
    static let captionMedium = Font.system(size: captionSize, weight: .medium)
    static let captionSemibold = Font.system(size: captionSize, weight: .semibold)
    static let captionCode = Font.system(size: captionSize, design: .monospaced)
    static let captionCodeSemibold = Font.system(size: captionSize, weight: .semibold, design: .monospaced)
    static let label = Font.system(size: labelSize)
    static let labelMedium = Font.system(size: labelSize, weight: .medium)
    static let railSize: CGFloat = 14
    static let rail = Font.system(size: railSize, weight: .medium)
    static let labelSemibold = Font.system(size: labelSize, weight: .semibold)
    static let rowTitle = Font.system(size: railSize, weight: .medium)
    static let rowDetail = label
    static let pageSentence = Font.system(size: railSize)
    static let pageTitle = Font.system(size: pageTitleSize, design: .serif)
    static let body = Font.system(size: bodySize)
    static let bodyMedium = Font.system(size: bodySize, weight: .medium)
    static let bodySemibold = Font.system(size: bodySize, weight: .semibold)
    static let columnTitle = bodySemibold
    static let title = Font.system(size: titleSize, weight: .semibold)
    static let display = Font.system(size: displaySize, weight: .semibold, design: .rounded)
}

/// A 740pt room fits the 708pt reply plus two 16pt gutters.
enum NativeAgentShellLayout {
    static let railWidth: CGFloat = 112
    static let railItemHeight: CGFloat = 44
    static let barInset: CGFloat = 4
    /// Bound composer room to five input lines, controls and attachments so a bad measurement cannot consume the transcript.
    static let composerClearanceMax: CGFloat = 320
    static let railWordInset: CGFloat = 14
    @MainActor static var roomGlassTint: Double {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? 0.74 : 0.66
    }
    static let titleBarInset: CGFloat = 28
    static let columnHeaderTopInset: CGFloat = 6
    static let conversationsWidth: CGFloat = 288
    static let conversationsInset: CGFloat = 12
    /// Use a 48pt row pitch (46 + 2 gap) to match the rail's two 24pt units.
    static let listRowHeight: CGFloat = 46
    static let roomColumn: CGFloat = 740
    static let replyMaxWidth: CGFloat = 708
    static let roomGutter: CGFloat = 16
    static var roomLeadingInset: CGFloat { roomGutter }
    static var roomTrailingInset: CGFloat { roomGutter }
    static let roomAlignment: Alignment = .top
    static let userBubbleMaxWidth: CGFloat = 640
    static let composerRadius: CGFloat = 22
    static let railPlateRadius: CGFloat = 18
    static let railPlateInset: CGFloat = 10
    static let replyLineSpacing: CGFloat = 8
    static let hoverBarStrip: CGFloat = 30
    static let transcriptGap: CGFloat = 16
    static let composerClearanceMargin: CGFloat = 12
    static let userBubbleCorners = RectangleCornerRadii(
        topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14
    )
}
