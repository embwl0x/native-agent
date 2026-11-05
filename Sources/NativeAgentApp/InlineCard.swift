import NativeAgentShared
import AppKit
import SwiftUI

// Blueprint: | `InlineCard.swift` | Inline card visual grammar: surfaces, controls, symbols and receipts; no store or work lifecycle ownership |

/// The interaction owner owns effects; views must keep failures live with their controls and reserve receipts for settled outcomes.

// MARK: - Tokens

enum InlineCardPalette {
    static let onNeedsYou = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x0B / 255, green: 0x10 / 255, blue: 0x13 / 255, alpha: 1)
            : .white
    })
}

enum InlineCardMetrics {
    static let symbolColumn: CGFloat = 24
    static let symbolGap: CGFloat = NativeAgentSpacing.sm
    static let padding: CGFloat = NativeAgentSpacing.lg
    static let controlHeight: CGFloat = 32
    static let touchTarget: CGFloat = 44
}

/// Quiet scrollback carries no fill so it does not compete with live cards.
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
        // Apply one local mood tint only inside the window's prose mask.
        .moodTintSurface(in: shape)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }
}

// MARK: - The display model

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

struct InlineCardSymbol: View {
    let name: String
    var tint: Color = NativeAgentShell.secondary
    // Scale the symbol column with Text size so its glyph cannot crowd the title.
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
                // Busy prevents duplicate submission but must leave the quiet way out active.
                InlineCardSecondaryButton(title: secondary, action: onSecondary)
            }
            if !consequence.isEmpty {
                Text(consequence)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

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

/// Align receipt marks with live-card symbols; wrap metadata separately so outcomes never truncate.
struct InlineCardReceipt<Details: View>: View {
    let mark: InlineCardMark
    let outcome: String
    var meta: String? = nil
    var detailsLabel: String? = nil
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

struct InlineCardSupersededLine: View {
    var text: String = "Asked earlier"
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
