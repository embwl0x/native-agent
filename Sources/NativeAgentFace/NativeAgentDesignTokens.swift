import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `NativeAgentDesignTokens.swift` | Mac fonts, layout, status colours and brand palette; geometry lives in Shared |

enum NativeAgentFont {
    static let section = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let label = Font.system(.caption, weight: .semibold)
    static let tag  = Font.system(.caption2, weight: .medium)
}

enum NativeAgentLayout {
    static let cardPadding: CGFloat = NativeAgentSpacing.lg
}

enum NativeAgentTheme {
    static let ok = Color.green
    static let warn = Color.orange
    static let fail = Color.red
    static let info = Color.blue

}

// MARK: - Brand palette — teal identity
enum NativeAgentBrand {
    static let accent       = Color(hex: 0x06B6D4)
    /// Deep cyan-700 keeps white text readable at the filled gradient's end.
    static let accentDeep   = Color(hex: 0x0E7490)
}
