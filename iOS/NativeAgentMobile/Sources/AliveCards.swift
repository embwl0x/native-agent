import SwiftUI
import NativeAgentShared
import UIKit
// Blueprint: | `AliveCards.swift` | Native card surfaces, sections, pairing-row insets and footnotes |

// MARK: - Cards

extension View {
    /// Content cards use fill, never glass; the room haze supplies their translucency.
    func aliveCard(radius: CGFloat = AliveMetrics.cardRadius) -> some View {
        modifier(AliveCardSurface(radius: radius))
    }
}

private struct AliveCardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(\.aliveInList) private var inList

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if inList { content } else { card(content, shape) }
    }

    private func card(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(reduceTransparency
                        ? AnyShapeStyle(NativeAgentMobileTheme.Colors.contentSurface)
                        : AnyShapeStyle(AlivePalette.fill), in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(stops: [.init(color: AlivePalette.highlight, location: 0),
                                           .init(color: AlivePalette.rim, location: 0.25)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
    }
}

struct AliveCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.aliveInList) private var inList

    var body: some View {
        if inList {
            Section { content }
        } else {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .aliveCard()
        }
    }
}

extension View {
    /// Rows inherit the card's inset and must not add chrome.
    func aliveRow() -> some View { modifier(AliveRowInset()) }
}

private struct AliveRowInset: ViewModifier {
    @Environment(\.aliveInList) private var inList

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inList ? 0 : AliveMetrics.rowInsetH)
            .padding(.vertical, inList ? 2 : AliveMetrics.rowInsetV)
    }
}

/// Lists own separators; add AliveDivider only between standalone card rows.
struct AliveDivider: View {
    @Environment(\.aliveInList) private var inList

    var body: some View {
        if !inList {
            Rectangle().fill(AlivePalette.divider).frame(height: 1)
                .padding(.leading, AliveMetrics.rowInsetH)
                .accessibilityHidden(true)
        }
    }
}

struct AliveFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(AlivePalette.secondary)
        .padding(.horizontal, 4)
    }
}
