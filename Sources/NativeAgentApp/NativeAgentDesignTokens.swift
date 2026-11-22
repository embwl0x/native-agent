import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `NativeAgentDesignTokens.swift` | Mac fonts and brand palette; geometry lives in Shared |

enum NativeAgentFont {
    static let section = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let label = Font.system(.caption, weight: .semibold)
    static let tag  = Font.system(.caption2, weight: .medium)
}

// MARK: - Brand palette — teal identity
enum NativeAgentBrand {
    /// Deep cyan-700 keeps white text readable at the filled gradient's end.
    static let accentDeep   = Color(hex: 0x0E7490)
}
