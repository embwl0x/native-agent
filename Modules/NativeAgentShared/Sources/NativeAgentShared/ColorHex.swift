// ColorHex.swift — Color(hex: String) extension shared between Mac and iOS
// Moved from Mac Sources/NativeAgentApp/PanelRenderer.swift and
// iOS iOS/NativeAgentMobile/Sources/PanelRenderer.swift — implementations
// were byte-identical.
// Note: NativeAgentTheme.swift defines a separate Color(hex: UInt) integer overload
// which does NOT conflict with this String overload.
import SwiftUI

public extension Color {
    /// Initialize from a 6- or 8-digit hex string, e.g. "FF3300" or "FFFF3300".
    /// Returns nil for invalid input.
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        guard h.count == 6 || h.count == 8 else { return nil }
        if h.count == 6 { h = "FF" + h }
        var int: UInt64 = 0
        let scanner = Scanner(string: h)
        guard scanner.scanHexInt64(&int), scanner.isAtEnd else { return nil }
        let a = Double((int >> 24) & 0xFF) / 255
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
