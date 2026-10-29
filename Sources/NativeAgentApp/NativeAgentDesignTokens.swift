import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `NativeAgentDesignTokens.swift` | Mac fonts, layout, status colours and brand palette; geometry lives in Shared |

enum NativeAgentFont {
    static let title = Font.system(.title2, weight: .semibold)
    static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let section = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let label = Font.system(.caption, weight: .semibold)
    static let tag  = Font.system(.caption2, weight: .medium)
    static let mono = Font.system(.caption, design: .monospaced)
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
        case "running", "info", "unmeasured": info
        case "warn", "warning", "blocked", "needs_setup", "planned", "interrupted", "disabled": warn
        case "fail", "failed", "error", "timeout", "quarantined": fail
        default: .secondary
        }
    }
}

// MARK: - Brand palette — teal identity
enum NativeAgentBrand {
    /// Vibrant cyan-500 — primary accent: icons, tints, borders, indicators.
    static let accent       = Color(hex: 0x06B6D4)
    /// Deep cyan-700 — gradient end for filled surfaces; keeps white text readable.
    static let accentDeep   = Color(hex: 0x0E7490)
    /// Sky-400 — cool blue counter-tone for multi-stop gradients + glows.
    static let accentCool    = Color(hex: 0x38BDF8)

}
