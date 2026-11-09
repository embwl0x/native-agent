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

/// Reserve the haze highlight for cards waiting on the user.
struct AliveWaitingCard<Content: View>: View {
    @ViewBuilder var content: Content
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let haze = HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .top) {
                LinearGradient(colors: [haze.opacity(colorScheme == .dark ? 0.22 : 0.14), haze.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
            }
            .clipShape(RoundedRectangle(cornerRadius: AliveMetrics.cardRadius, style: .continuous))
            .aliveCard()
    }
}

// MARK: - Sections and rows

struct AliveEyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(AlivePalette.secondary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AliveSection<Trailing: View, Content: View>: View {
    enum Surface { case card, waiting, none }
    let title: String?
    var footer: String?
    var surface: Surface
    let trailing: Trailing
    let content: Content

    init(_ title: String?, footer: String? = nil, surface: Surface = .card,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.surface = surface
        self.trailing = trailing()
        self.content = content()
    }

    @Environment(\.aliveInList) private var inList
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if inList { listSection } else { stack }
    }

    private var listSection: some View {
        let haze = HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false)
        return Section {
            if surface == .waiting {
                content.listRowBackground(
                    LinearGradient(colors: [haze.opacity(colorScheme == .dark ? 0.22 : 0.14), AlivePalette.fill],
                                   startPoint: .top, endPoint: .bottom))
            } else {
                content
            }
        } header: {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 8)
                    trailing.textCase(nil)
                }
            }
        } footer: {
            if let footer, !footer.isEmpty { Text(footer) }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    AliveEyebrow(title)
                    Spacer(minLength: 8)
                    trailing.padding(.trailing, 4)
                }
            }
            switch surface {
            case .card: AliveCard { content }
            case .waiting: AliveWaitingCard { content }
            case .none: content
            }
            if let footer, !footer.isEmpty { AliveFootnote(footer) }
        }
    }
}

extension AliveSection where Trailing == EmptyView {
    init(_ title: String?, footer: String? = nil, surface: Surface = .card, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, surface: surface, trailing: { EmptyView() }, content: content)
    }
}

struct AliveFootnote: View {
    let text: String
    var systemImage: String?
    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(AlivePalette.secondary)
        .padding(.horizontal, 4)
    }
}
