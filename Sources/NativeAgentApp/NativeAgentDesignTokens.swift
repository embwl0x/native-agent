import SwiftUI
import AppKit

enum NativeAgentFont {
    static let title = Font.system(.title2, weight: .semibold)
    static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let section = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let label = Font.system(.caption, weight: .semibold)
    static let tag  = Font.system(.caption2, weight: .medium)
    static let mono = Font.system(.caption, design: .monospaced)
}

enum NativeAgentSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let pageInset: CGFloat = 20
    static let section: CGFloat = 28
    static let pageTop: CGFloat = 36
    // Content-specific exceptions to the general spacing steps.
    static let rowInsetV: CGFloat = 14
    static let eyebrowGap: CGFloat = 10
}

enum NativeAgentRadius {
    static let compact: CGFloat = 4
    static let control: CGFloat = 6
    static let panel: CGFloat = 8
    static let card: CGFloat = 8
}

enum NativeAgentLayout {
    static let cardPadding: CGFloat = NativeAgentSpacing.lg
}

enum NativeAgentTheme {
    static let ok = Color.green
    static let warn = Color.orange
    static let fail = Color.red
    static let info = Color.blue

    static func statusColor(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready", "scheduled": ok
        case "running", "info": info
        case "warn", "warning", "blocked", "needs_setup", "planned", "interrupted", "disabled": warn
        case "fail", "failed", "error", "timeout", "quarantined": fail
        default: .secondary
        }
    }
}

// MARK: - Color hex helper (mirrors the iOS NativeAgentTheme initializer so the
// Mac + iOS apps share one teal identity by hex value, not by eyeballed literals)
extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Brand palette — teal identity
//
// 2026-07-06: retheme from the old purple→pink chat accents to a blue-teal
// (cyan/sky, Agent's color). Centralized here so the chat surfaces stop
// carrying raw `Color.purple`/`Color.pink` literals — one source of truth for
// the Mac accent, matched hex-for-hex to the iOS `NativeAgentPalette`.
enum NativeAgentBrand {
    /// Vibrant cyan-500 — primary accent: icons, tints, borders, indicators.
    static let accent       = Color(hex: 0x06B6D4)
    /// Deep cyan-700 — gradient end for filled surfaces; keeps white text readable.
    static let accentDeep   = Color(hex: 0x0E7490)
    /// Sky-400 — cool blue counter-tone for multi-stop gradients + glows.
    static let accentCool    = Color(hex: 0x38BDF8)

}
