import NativeAgentShared
import AppToolRuntime

// Blueprint: | `AlivePageKit.swift` | Alive page components: shared glass metrics/palette, headers, cards, pills, progress and flow layout for Today/Desk |
// Cards share glass over one haze; tertiary ink lacks sufficient contrast.

import AppKit
import SwiftUI

enum AliveMetrics {
    static let cardRadius: CGFloat = 18
    static let rowInsetH = NativeAgentSpacing.pageInset
    static let rowInsetV = NativeAgentSpacing.rowInsetV
    static let sectionSpacing = NativeAgentSpacing.section
    static let eyebrowGap = NativeAgentSpacing.eyebrowGap
}

enum AlivePalette {
    /// White is the only highlight that reads as light on a pale card.
    static let highlight = adaptive(dark: NSColor.white.withAlphaComponent(0.12),
                                    light: NSColor.white.withAlphaComponent(0.7))
    static let rim = adaptive(dark: NSColor.white.withAlphaComponent(0.05),
                              light: NSColor.black.withAlphaComponent(0.06))
    static let divider = Color(nsColor: .separatorColor)

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
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(shown == nil ? 0 : 1)
                .accessibilityHidden(shown == nil)
                .accessibilityIdentifier(lineID ?? "alive.page.line")
        }
    }
}

/// Nil means not loaded: reserve the header line without inventing a sentence.
struct AlivePageLine: Equatable {
    var text: String?
    var id: String?
}

struct AlivePageLineKey: PreferenceKey {
    static let defaultValue: AlivePageLine? = nil
    static func reduce(value: inout AlivePageLine?, nextValue: () -> AlivePageLine?) {
        value = value ?? nextValue()
    }
}

extension View {
    func alivePageLine(_ text: String?, id: String? = nil) -> some View {
        preference(key: AlivePageLineKey.self, value: AlivePageLine(text: text, id: id))
    }
}

/// Use full secondary ink: half strength measures 3.4:1 in the dark room and about 2.5:1 at the haze peak.
struct AliveEyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(ShellType.captionSemibold)
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(NativeAgentShell.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Cards

extension View {
    func aliveCard(waiting: Bool = false, radius: CGFloat = AliveMetrics.cardRadius) -> some View {
        modifier(AliveCardSurface(waiting: waiting, radius: radius))
    }
}

private struct AliveCardSurface: ViewModifier {
    let waiting: Bool
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack(alignment: .top) {
                    // Reduce Transparency requires an opaque card.
                    if reduceTransparency || quietOffscreenRead { shape.fill(TodayPalette.cardFill) }
                    if waiting {
                        // Cap the edge at 60pt and half the card height so short and tall cards share the same treatment.
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [NativeAgentShell.needsYou.opacity(0.10), .clear],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: min(60, proxy.size.height / 2))
                        }
                    }
                }
                .clipShape(shape)
            }
            .glassEffect(reduceTransparency || quietOffscreenRead ? .identity : HouseGlass.plate, in: shape)
            .overlay {
                if reduceTransparency || quietOffscreenRead {
                    shape.strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
                }
            }
            .environment(\.houseGlassEnclosed, true)
    }
}

/// Rows share one card so they do not stack chrome.
struct AliveGroupCard<Content: View>: View {
    var waiting: Bool
    var lazy: Bool
    let content: Content

    init(waiting: Bool = false, lazy: Bool = false, @ViewBuilder content: () -> Content) {
        self.waiting = waiting
        self.lazy = lazy
        self.content = content()
    }

    var body: some View {
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) { rows }
            } else {
                VStack(alignment: .leading, spacing: 0) { rows }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard(waiting: waiting)
    }

    private var rows: some View {
        Group(subviews: content) { subviews in
            ForEach(Array(subviews.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(AlivePalette.divider)
                        .frame(height: 1)
                        .padding(.horizontal, AliveMetrics.rowInsetH)
                }
                row
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AliveMetrics.rowInsetH)
                    .padding(.vertical, AliveMetrics.rowInsetV)
            }
        }
    }
}

// MARK: - Progress

private struct HazeShades {
    let deep: Color
    let base: Color
    init(_ raw: String) {
        let haze = HazeColor(stored: raw)
        deep = Color(hex: haze.shades[1])
        base = haze.base
    }
}

struct AliveProgressBar: View {
    let done: Int
    let total: Int
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue

    private var fraction: CGFloat {
        total > 0 ? CGFloat(min(max(done, 0), total)) / CGFloat(total) : 0
    }

    var body: some View {
        let shades = HazeShades(colorRaw)
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                Capsule().fill(NativeAgentShell.softFill)
                Capsule()
                    .fill(LinearGradient(colors: [shades.deep, shades.base],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 96 * fraction)
            }
            .frame(width: 96, height: 4)
            Text("\(done) of \(total)")
                .font(ShellType.rowDetail)
                .monospacedDigit()
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) done")
    }
}

// MARK: - Small marks

/// Teal means waiting on the user.
struct AliveWaitingDot: View {
    var body: some View {
        Circle()
            .fill(NativeAgentShell.needsYou)
            .frame(width: 8, height: 8)
            .shadow(color: NativeAgentShell.needsYou.opacity(0.55), radius: 4)
            .accessibilityHidden(true)
    }
}

struct AlivePill: View {
    let text: String
    var leading: String? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(_ text: String, leading: String? = nil) {
        self.text = text
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 6) {
            if let leading, !leading.isEmpty {
                Text(leading).foregroundStyle(NativeAgentShell.secondary)
            }
            Text(text).foregroundStyle(NativeAgentShell.text)
        }
        .font(ShellType.label)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(reduceTransparency ? TodayPalette.cardFill : NativeAgentShell.quietFill))
        .overlay(Capsule().strokeBorder(reduceTransparency ? TodayPalette.cardStroke : AlivePalette.rim, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct AliveFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
