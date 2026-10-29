import SwiftUI
import NativeAgentShared
import UIKit
// Blueprint: | `AliveCards.swift` | Card surfaces, sections, rows and row press presentation |

// MARK: - Cards

extension View {
    /// The one card surface: a fill, a top light and a rim. Content layer, so
    /// never glass; the haze behind is what makes it read as glass.
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

/// ONE card holding rows; put an `AliveDivider()` between them.
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
    /// A row inside an AliveCard: the card's inset, no chrome of its own.
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

/// Between rows of a card; a List draws its own separators.
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

/// The card for what waits on you: the kit's card, lit from the top with the
/// haze. Waiting on you is the haze colour's one job.
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

/// Section label: small caps in full secondary (the Mac's AliveEyebrow).
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

/// An eyebrow, what it labels (one card of rows by default), and an optional
/// quiet line under it.
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

/// A quiet line under a card.
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

/// The one row: a name, its detail in secondary text, and an optional
/// trailing control (an `AliveChevron` makes it a link row).
struct AliveRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var detailLines: Int?
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, detailLines: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.detailLines = detailLines
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AlivePalette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(detailLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .aliveRow()
        .contentShape(Rectangle())
    }
}

extension AliveRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, detailLines: Int? = nil) {
        self.init(title, detail: detail, detailLines: detailLines, trailing: { EmptyView() })
    }
}

/// A label on the left, its value in secondary text on the right.
struct AliveValueRow: View {
    let label: String
    let value: String
    var valueColor: Color = AlivePalette.secondary
    var emphasized = false

    var body: some View {
        MobileAdaptiveRow(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(AlivePalette.text)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(emphasized ? .medium : .regular)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .aliveRow()
        .accessibilityElement(children: .combine)
    }
}

/// A quiet sentence inside a card.
struct AliveNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AlivePalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .aliveRow()
    }
}

/// A row that does something: its words in the haze, the one tinted control.
struct AliveTapRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .aliveRow()
                .contentShape(Rectangle())
        }
        .aliveRowButtonStyle()
        .hazeTinted()
    }
}

struct AliveChevron: View {
    @Environment(\.aliveInList) private var inList

    var body: some View {
        if !inList { chevron }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AlivePalette.secondary)
            .accessibilityHidden(true)
    }
}

/// Rows carry no chrome; a press shows a soft inset wash.
extension View {
    /// A row's press: in a List the cell's own native highlight; elsewhere a
    /// soft inset wash.
    func aliveRowButtonStyle() -> some View { modifier(AliveRowPress()) }
}

private struct AliveRowPress: ViewModifier {
    @Environment(\.aliveInList) private var inList

    func body(content: Content) -> some View {
        if inList { content } else { content.buttonStyle(AliveRowButtonStyle()) }
    }
}

struct AliveRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AlivePalette.divider)
                        .padding(4)
                }
            }
    }
}
