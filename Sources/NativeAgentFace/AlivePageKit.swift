import NativeAgentShared

// Blueprint: | `AlivePageKit.swift` | Shared page style, native header and accessibility-aware card surface |
// Cards share a fill over one haze; tertiary ink lacks sufficient contrast.

import AppKit
import SwiftUI

enum AliveMetrics {
    static let cardRadius: CGFloat = 18
    static let rowInsetH = NativeAgentSpacing.pageInset
    static let sectionSpacing = NativeAgentSpacing.section
}

enum AlivePalette {
    /// White is the only highlight that reads as light on a pale card.
    static let highlight = adaptive(dark: NSColor.white.withAlphaComponent(0.12),
                                    light: NSColor.white.withAlphaComponent(0.7))

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Header and labels

/// Hold the header sentence's line while data loads so content below does not jump.
struct AlivePageHeader: View {
    let title: String
    var line: String? = nil
    var lineID: String? = nil
    var wrapsLine = false

    var body: some View {
        let shown = line.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            Text(title)
                .font(ShellType.pageTitle)
                .foregroundStyle(NativeAgentShell.text)
                .accessibilityAddTraits(.isHeader)
            Text(shown ?? " ")
                .font(ShellType.pageSentence)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(wrapsLine ? nil : 1)
                .fixedSize(horizontal: false, vertical: wrapsLine)
                .truncationMode(.tail)
                .opacity(shown == nil ? 0 : 1)
                .accessibilityHidden(shown == nil)
                .accessibilityIdentifier(lineID ?? "alive.page.line")
        }
    }
}

// MARK: - Cards

extension View {
    func macContentCard() -> some View {
        houseInset(in: RoundedRectangle(cornerRadius: AliveMetrics.cardRadius, style: .continuous))
    }
}

extension FaceStyle {
    static let mac = FaceStyle(
        insets: EdgeInsets(top: 6, leading: AliveMetrics.rowInsetH, bottom: 6, trailing: AliveMetrics.rowInsetH),
        minimumHeight: 30, title: .body.weight(.medium), detail: .callout, value: .callout.monospacedDigit(),
        elevation: AlivePalette.highlight, actionSurface: TodayPalette.cardFill, answer: NativeAgentBrand.accentDeep,
        card: { AnyView($0.macContentCard()) })
}

extension View {
    func macFaceStyle() -> some View { environment(\.faceStyle, .mac) }
}
