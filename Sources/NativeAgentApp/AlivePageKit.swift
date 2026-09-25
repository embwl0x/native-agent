// AlivePageKit.swift
// "Alive glass", the pages — User approved the mockup 2026-09-23. The shared
// pieces Today and Desk are built from in the Advanced shell. Content layer:
// every surface here is a FILL, never glassEffect; the haze behind the window
// (WindowHaze.swift) is what makes it read as glass.
//
// Contrast: every text colour here is a shell token that clears 4.5:1 on the
// card fill and on the room where all three haze discs overlap (peak 0.44).
// Tertiary grey does not (≈2.6:1 at the haze peak), so nothing here uses it.

import AppKit
import SwiftUI

enum AliveMetrics {
    static let cardRadius: CGFloat = 18
    static let rowInsetH: CGFloat = 20
    static let rowInsetV: CGFloat = 14
    static let sectionSpacing: CGFloat = 28
    static let eyebrowGap: CGFloat = 10
}

enum AlivePalette {
    /// Inner top light on a card: 12% white in dark; in light, white is the
    /// only thing that reads as light on a pale card.
    static let highlight = adaptive(dark: NSColor.white.withAlphaComponent(0.12),
                                    light: NSColor.white.withAlphaComponent(0.7))
    /// The card's rim: 5% white in dark, a faint ink line in light.
    static let rim = adaptive(dark: NSColor.white.withAlphaComponent(0.05),
                              light: NSColor.black.withAlphaComponent(0.06))
    /// Row dividers inside a group card.
    static let divider = adaptive(dark: NSColor.white.withAlphaComponent(0.06),
                                  light: NSColor.black.withAlphaComponent(0.07))

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Header and labels

/// The page's door: a serif word and one sentence under it. The sentence is
/// said only once the page has read its data, but its line is always held,
/// so nothing below jumps when it arrives.
struct AlivePageHeader: View {
    let title: String
    var line: String? = nil
    var lineID: String? = nil

    var body: some View {
        let shown = line.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 44, design: .serif))
                .foregroundStyle(NativeAgentShell.text)
                .accessibilityAddTraits(.isHeader)
            Text(shown ?? " ")
                .font(.system(size: 15))
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(shown == nil ? 0 : 1)
                .accessibilityHidden(shown == nil)
                .accessibilityIdentifier(lineID ?? "alive.page.line")
        }
    }
}

/// A framed page's header sentence, handed up from the page's content to the
/// frame that draws the header (`ShellPageFrame(alive: true)`). Nil text is
/// "not loaded yet": the line is held, not said.
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

/// Section label. Full secondary, not the mockup's 50%: at half strength it
/// measured 3.4:1 on the bare dark room and ≈2.5:1 at the haze peak.
struct AliveEyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(NativeAgentShell.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Cards

extension View {
    /// The one card surface: fill, top light and rim, and the soft teal glow
    /// when the card holds something waiting on him.
    func aliveCard(waiting: Bool = false, radius: CGFloat = AliveMetrics.cardRadius) -> some View {
        modifier(AliveCardSurface(waiting: waiting, radius: radius))
    }
}

private struct AliveCardSurface: ViewModifier {
    let waiting: Bool
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack(alignment: .top) {
                    // Reduce Transparency asks for MORE opacity: the opaque
                    // card the page wore before.
                    shape.fill(reduceTransparency ? TodayPalette.cardFill : NativeAgentShell.quietFill)
                    if waiting {
                        LinearGradient(
                            colors: [NativeAgentShell.needsYou.opacity(0.10), .clear],
                            startPoint: .top, endPoint: .bottom)
                            .frame(height: 60)
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(
                    reduceTransparency
                        ? AnyShapeStyle(TodayPalette.cardStroke)
                        : AnyShapeStyle(LinearGradient(
                            stops: [.init(color: AlivePalette.highlight, location: 0),
                                    .init(color: AlivePalette.rim, location: 0.22)],
                            startPoint: .top, endPoint: .bottom)),
                    lineWidth: 1)
            }
    }
}

/// ONE card holding several rows, hairlines between them. Each row gets the
/// card's inset; the rows themselves carry no chrome.
struct AliveGroupCard<Content: View>: View {
    var waiting: Bool
    let content: Content

    init(waiting: Bool = false, @ViewBuilder content: () -> Content) {
        self.waiting = waiting
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard(waiting: waiting)
    }
}

// MARK: - Progress

/// The haze's deep and base shades, for progress fills.
private struct HazeShades {
    let deep: Color
    let base: Color
    init(_ raw: String) {
        let haze = HazeColor(stored: raw)
        deep = Color(nsColor: HazeColor.nsColor(haze.shades[1]))
        base = haze.base
    }
}

/// A thin bar and "3 of 8" beside it.
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
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) done")
    }
}

/// A 42pt ring. `nil` is "no progress recorded": the track, no arc.
struct AliveProgressRing: View {
    let fraction: Double?
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue

    var body: some View {
        let shades = HazeShades(colorRaw)
        let value = min(max(fraction ?? 0, 0), 1)
        ZStack {
            Circle().stroke(NativeAgentShell.softFill, lineWidth: 4)
            if fraction != nil, value > 0 {
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(
                        AngularGradient(colors: [shades.deep, shades.base], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * value)),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(fraction == nil ? "–" : "\(Int((value * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(NativeAgentShell.text)
        }
        .frame(width: 42, height: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fraction == nil ? "No progress recorded" : "\(Int((value * 100).rounded())) percent done")
    }
}

// MARK: - Small marks

/// Teal means "waiting on you" and nothing else.
struct AliveWaitingDot: View {
    var body: some View {
        Circle()
            .fill(NativeAgentShell.needsYou)
            .frame(width: 8, height: 8)
            .shadow(color: NativeAgentShell.needsYou.opacity(0.55), radius: 4)
            .accessibilityHidden(true)
    }
}

/// A capsule chip on the card fill.
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
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(reduceTransparency ? TodayPalette.cardFill : NativeAgentShell.quietFill))
        .overlay(Capsule().strokeBorder(reduceTransparency ? TodayPalette.cardStroke : AlivePalette.rim, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Older pieces inside an alive page

extension EnvironmentValues {
    /// Set by a page rebuilt in the kit whose tabs still draw with the older
    /// shared pieces (`NativePanel`, `SettingsCardSection`,
    /// `settingsCardSurface`, `HealthPill`): inside it they wear the kit's
    /// eyebrow and card. Off everywhere else, so no other page moves.
    @Entry var aliveCards: Bool = false
}

/// Left-aligned wrapping flow, for pills and the Desk's count line.
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
