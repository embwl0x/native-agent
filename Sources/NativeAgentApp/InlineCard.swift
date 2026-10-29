import NativeAgentShared
import AppKit
import SwiftUI

// Blueprint: | `InlineCard.swift` | Inline card visual grammar: surfaces, controls, symbols and receipts; no store or work lifecycle ownership |

/// Cards render supplied values and actions; the interaction owner decides effects.
/// Live cards use fill and hairline; receipts use hairline with the same symbol inset.
/// The consequence alone uses “→”; links remain plain.
/// Receipt marks are green ✓ done, white ✕ declined and yellow ? unknown.
/// Failures keep the live card, explanation and safe retry under the yellow mark.
/// Declining consequences and permission durations are explicit.
/// Titles wrap at narrow widths; metadata moves to a gray second line.

// MARK: - Tokens

enum InlineCardPalette {
    /// Primary buttons use dark ink on dark-mode teal, white on light-mode teal.
    static let onNeedsYou = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x0B / 255, green: 0x10 / 255, blue: 0x13 / 255, alpha: 1)
            : .white
    })
}

enum InlineCardMetrics {
    /// The symbol column and its gap: body and controls align with the title.
    static let symbolColumn: CGFloat = 24
    static let symbolGap: CGFloat = NativeAgentSpacing.sm
    static let padding: CGFloat = NativeAgentSpacing.lg
    static let controlHeight: CGFloat = 32
    /// The pointer target a control must fill, whatever its drawn height.
    static let touchTarget: CGFloat = 44
}

/// Live cards wear the kit's house glass; receipts carry the hairline alone; a quiet line
/// (superseded, declined) carries neither — it is scrollback, not an object.
enum InlineCardSurface {
    case live
    case settled
    case quiet
}

extension View {
    func inlineCardSurface(_ surface: InlineCardSurface) -> some View {
        let shape = RoundedRectangle(cornerRadius: AliveMetrics.cardRadius, style: .continuous)
        let framed = self.frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            switch surface {
            case .live: framed.aliveCard()
            case .settled: framed.overlay { shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1) }
            case .quiet: framed
            }
        }
        // Cards inside the window's prose mask receive one local mood tint.
        .moodTintSurface(in: shape)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }
}

// MARK: - The display model

/// The three receipt marks. Three colours, three meanings, no fourth.
enum InlineCardMark {
    case done
    case declined
    case unknown

    var symbol: String {
        switch self {
        case .done: return "checkmark"
        case .declined: return "xmark"
        case .unknown: return "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .done: return NativeAgentShell.calm
        case .declined: return NativeAgentShell.text
        case .unknown: return NativeAgentShell.trouble
        }
    }
}

// MARK: - Parts

/// The symbol column: 24 pt wide, 8 pt gap, everything else aligned to the title.
struct InlineCardSymbol: View {
    let name: String
    var tint: Color = NativeAgentShell.secondary
    // The ramp scales with the system's Text size, so the column the title
    // aligns to has to scale with it or the glyph crowds the words.
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = InlineCardMetrics.symbolColumn
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 15

    var body: some View {
        Image(systemName: name)
            .font(.system(size: glyph, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: column, height: column - 4, alignment: .center)
            .accessibilityHidden(true)
    }
}

struct InlineCardPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    var busy: Bool = false
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = InlineCardMetrics.controlHeight
    @ScaledMetric(relativeTo: .body) private var target: CGFloat = InlineCardMetrics.touchTarget

    var body: some View {
        Button(action: action) {
            HStack(spacing: NativeAgentSpacing.sm) {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                }
                Text(title).font(ShellType.labelSemibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(enabled ? InlineCardPalette.onNeedsYou : NativeAgentShell.tertiary)
            .padding(.horizontal, 16)
            .frame(minHeight: height)
            .background(
                enabled ? NativeAgentShell.needsYou.opacity(busy ? 0.7 : 1) : NativeAgentShell.quietFill,
                in: RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous)
            )
            .frame(minHeight: target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityIdentifier("inline-card.primary")
        .disabled(!enabled || busy)
    }
}

struct InlineCardSecondaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = InlineCardMetrics.controlHeight
    @ScaledMetric(relativeTo: .body) private var target: CGFloat = InlineCardMetrics.touchTarget

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ShellType.labelSemibold)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(enabled ? NativeAgentShell.secondary : NativeAgentShell.tertiary)
                .padding(.horizontal, 16)
                .frame(minHeight: height)
                .overlay(
                    RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous)
                        .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                )
                .frame(minHeight: target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .accessibilityIdentifier("inline-card.secondary")
        .disabled(!enabled)
    }
}

/// One primary, one quiet secondary and its consequence; “→” belongs only here.
struct InlineCardActions: View {
    let primary: String
    var primaryEnabled: Bool = true
    var busy: Bool = false
    let secondary: String
    let consequence: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            HStack(spacing: NativeAgentSpacing.sm) {
                InlineCardPrimaryButton(title: primary, enabled: primaryEnabled,
                                        busy: busy, action: onPrimary)
                // Busy disables a SECOND submission, never the way out: the
                // quiet command stays live while the card is working.
                InlineCardSecondaryButton(title: secondary, action: onSecondary)
            }
            if !consequence.isEmpty {
                // The cost of declining uses subtitle weight with contrast above captions.
                Text(consequence)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// In-place disclosure — the payload, the exact scope, the historical receipt.
/// Never a sheet and never a navigation.
struct InlineCardDetails<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            content.transition(NativeAgentMotion.arrivalFade)
        } label: {
            Text(label)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.tertiary)
                .togglesDisclosure($open)
                .accessibilityIdentifier("inline-card.details")
        }
    }
}

/// A scope line: what the permission actually covers, wrapped, never a caption.
struct InlineCardScopeLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .font(ShellType.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(NativeAgentShell.secondary)
    }
}

/// Busy is still: one small indicator, no shimmer, no gradient, no percentage
/// the app cannot prove.
struct InlineCardBusyLine: View {
    let text: String

    var body: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            Text(text).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary).textSelection(.enabled)
        }
    }
}

// MARK: - The shell

/// Symbol column, title, one-sentence reason, whatever the card needs in the
/// middle, and an optional disclosure. Everything below the title aligns with
/// the title's leading edge.
struct InlineCard<Content: View>: View {
    let symbol: String
    var symbolTint: Color = NativeAgentShell.secondary
    let title: String
    var reason: String = ""
    var surface: InlineCardSurface = .live
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: InlineCardMetrics.symbolGap) {
            InlineCardSymbol(name: symbol, tint: symbolTint)
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    // The title never truncates, at any width.
                    Text(title)
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !reason.isEmpty {
                        Text(reason)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(InlineCardMetrics.padding)
        .inlineCardSurface(surface)
        .accessibilityElement(children: .contain)
    }
}

/// The settled receipt: hairline only, ONE line — symbol + outcome — at the
/// live card's horizontal inset, so the mark lands in the icon column. When the
/// width cannot hold outcome and metadata together, the metadata drops to a
/// gray second line; the outcome itself is never truncated.
struct InlineCardReceipt<Details: View>: View {
    let mark: InlineCardMark
    let outcome: String
    var meta: String? = nil
    var detailsLabel: String? = nil
    /// Quiet declines use one gray line without a box.
    var quiet: Bool = false
    @ViewBuilder var details: Details

    private var ink: Color { quiet ? NativeAgentShell.secondary : NativeAgentShell.text }

    private var outcomeText: some View {
        Text(outcome)
            .font(ShellType.label)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metaText: some View {
        Text(meta ?? "")
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        HStack(alignment: .top, spacing: InlineCardMetrics.symbolGap) {
            InlineCardSymbol(name: mark.symbol,
                             tint: quiet ? NativeAgentShell.secondary : mark.tint)
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                if meta == nil {
                    HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                        outcomeText
                        Spacer(minLength: 0)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                            Text(outcome).font(ShellType.label)
                                .foregroundStyle(ink).lineLimit(1)
                            Text(meta ?? "").font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.tertiary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            outcomeText
                            metaText
                        }
                    }
                }
                if let detailsLabel {
                    InlineCardDetails(label: detailsLabel) { details }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, InlineCardMetrics.padding)
        .padding(.vertical, NativeAgentSpacing.md)
        .inlineCardSurface(quiet ? .quiet : .settled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([outcome, meta].compactMap { $0 }.joined(separator: ", "))
    }
}

extension InlineCardReceipt where Details == EmptyView {
    init(mark: InlineCardMark, outcome: String, meta: String? = nil, quiet: Bool = false) {
        self.init(mark: mark, outcome: outcome, meta: meta,
                  detailsLabel: nil, quiet: quiet) { EmptyView() }
    }
}

/// The one line an ask leaves behind when a newer, identical ask replaced it.
/// No mark, no box, no controls: the question is still open, but it is open on
/// the card further down, and this line says where it went.
struct InlineCardSupersededLine: View {
    var text: String = "Asked earlier"
    // Stays aligned with the symbol column beside it, at any text size.
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = InlineCardMetrics.symbolColumn

    var body: some View {
        HStack(alignment: .top, spacing: InlineCardMetrics.symbolGap) {
            Color.clear.frame(width: column, height: 1)
            Text(text)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InlineCardMetrics.padding)
        .padding(.vertical, NativeAgentSpacing.xs)
        .inlineCardSurface(.quiet)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
