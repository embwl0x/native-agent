import SwiftUI

/// The inline card family — one grammar for every moment where Agent needs the
/// person before she can carry on: a connection, a permission, a model choice,
/// an API key, a capability, a plain decision, an approval, and the receipt a
/// finished run leaves behind.
///
/// This file is the VIEW half. It owns no approval store, no routing store and
/// no work lifecycle: a card is handed a value and an action closure, and the
/// owner of the interaction decides what a click means. The value below is the
/// display model the mechanism's shared interaction projects into
/// (`kind` / `target` / `title` / `why` / labels / `consequence` / `state` /
/// persistence note / optional field and choices) — nothing else crosses.
///
/// Agent's design call, binding:
///   * A LIVE card is the silver fill plus its hairline. A SETTLED receipt is
///     the hairline only — one line, symbol + outcome — at the same horizontal
///     inset, so the receipt's symbol sits in the live card's icon column.
///   * One glyph, one meaning. "→" appears only on the consequence line;
///     links are plain links.
///   * Three symbols, three colours, no fourth: green ✓ done, white ✕ declined
///     (declined is not failure), yellow ? unknown. A failure is not a receipt —
///     it keeps the live card, its explanation and its retry, under the yellow
///     mark, because "this did not work" is the same family of news as "I do
///     not know whether it worked".
///   * Every card states the consequence of declining, and every permission
///     card says how long the permission lasts.
///   * At narrow widths the title never truncates; metadata drops to a gray
///     second line instead.

// MARK: - Tokens

/// The card's surface, promoted from `settingsCardSurface()` unchanged so the
/// inline cards and the settings cards stay one family.
enum InlineCardPalette {
    static var fill: Color { TodayPalette.cardFill }
    static var stroke: Color { TodayPalette.cardStroke }
    static var radius: CGFloat { TodayMetrics.cardRadius }

    /// The shared foreground for the primary button: dark ink on the bright
    /// dark-mode teal, white on the darker light-mode teal. The old approval
    /// card paired fixed dark ink with a dynamic teal and lost its contrast in
    /// light; this is the pairing that holds in both.
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

/// Live cards carry the fill; receipts carry the hairline alone; a quiet line
/// (superseded, declined) carries neither — it is scrollback, not an object.
enum InlineCardSurface {
    case live
    case settled
    case quiet
}

extension View {
    func inlineCardSurface(_ surface: InlineCardSurface) -> some View {
        let shape = RoundedRectangle(cornerRadius: InlineCardPalette.radius, style: .continuous)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                switch surface {
                case .live: shape.fill(InlineCardPalette.fill)
                case .settled, .quiet: shape.fill(Color.clear)
                }
            }
            .overlay {
                switch surface {
                case .live: shape.strokeBorder(InlineCardPalette.stroke, lineWidth: 1)
                case .settled: shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                case .quiet: shape.strokeBorder(Color.clear, lineWidth: 0)
                }
            }
            // Mood in the tint, 2026-09-14: a card sits inside the transcript's
            // prose guard, where the window pass is punched out, and its own
            // fill is clear — so what should warm is the room showing through
            // it. It takes the warmth here instead. One tint, never two.
            .moodTintSurface(in: shape)
            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }
}

// MARK: - The display model

/// What the card is for. Selects the symbol and which content appears —
/// never a separate visual style.
enum InlineCardKind: String, Sendable, Equatable, CaseIterable {
    case needsConnector
    case needsPermission
    case needsModelChoice
    case needsAPIKey
    case needsCapability
    case choose
    case confirm
    /// Work the app is doing on its own behalf: the working card and its receipt.
    case work

    var symbol: String {
        switch self {
        case .needsConnector: return "link"
        case .needsPermission: return "lock.open"
        case .needsModelChoice: return "sparkles"
        case .needsAPIKey: return "key"
        case .needsCapability: return "switch.2"
        case .choose: return "questionmark.circle"
        case .confirm: return "paperplane"
        case .work: return "gearshape"
        }
    }
}

/// Where an interaction stands. Presentation only — derived from whatever owns
/// the real lifecycle, never stored here.
enum InlineCardState: String, Sendable, Equatable, CaseIterable {
    case pending
    case running
    case settled
    case declined
    case failed
    /// Terminal and honest about not knowing: neither done nor declined.
    case unknown
    /// A newer, identical ask replaced this one before anybody answered it.
    /// One quiet line, "Asked earlier" — Agent's one-live-card-per-ask rule.
    case superseded

    var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .settled, .declined, .failed, .unknown, .superseded: return true
        }
    }
}

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

struct InlineCardChoice: Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    /// The consequence that belongs to this row — "billed separately",
    /// "needs an API key" — not a footnote at the bottom of the card.
    var note: String?
    /// What the PRIMARY says once this row is picked: "Use GPT-5.6 Sol".
    /// Agent, 2026-09-13 — the button names the outcome, and with a list on
    /// the card the outcome is the row the person chose. nil keeps the card's
    /// own label, which is what the one row that is not a model needs.
    var actionLabel: String?

    init(id: String, title: String, note: String? = nil, actionLabel: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.actionLabel = actionLabel
    }
}

/// One value the card collects. Secrets never become transcript content.
struct InlineCardField: Sendable, Equatable {
    var label: String
    var placeholder: String
    var helper: String?
    var isSecret: Bool
    /// The key the value travels under when a card collects several.
    var id: String
    /// An optional field never holds the primary back.
    var isOptional: Bool

    init(label: String, placeholder: String, helper: String? = nil, isSecret: Bool = true,
         id: String = "value", isOptional: Bool = false) {
        self.label = label
        self.placeholder = placeholder
        self.helper = helper
        self.isSecret = isSecret
        self.id = id
        self.isOptional = isOptional
    }
}

/// The display value. Every field the seven uses need, and nothing about how
/// the interaction resolves.
struct InlineCardModel: Identifiable, Sendable, Equatable {
    /// Bound to the originating request, not to the last message: a second
    /// observation of the same blocked request updates this card.
    let id: String
    var kind: InlineCardKind
    /// What the interaction is about: "GitHub", "Desktop", "Work".
    var target: String
    var title: String
    /// One sentence. A writing constraint, not a line limit — it wraps.
    var why: String
    var primaryLabel: String
    var secondaryLabel: String
    /// Required on every card: what taking the quiet option costs.
    var consequence: String
    var state: InlineCardState
    /// "Stays on until you turn it off in Trust." — required on permissions.
    var persistenceNote: String?
    /// What the card collects, in order. Values never become transcript content.
    var fields: [InlineCardField]
    var field: InlineCardField? { fields.first }
    /// "Sign in with ChatGPT": what the primary does while every field is
    /// empty. Typing into a field turns the primary back into the paste.
    var signInLabel: String?
    /// A quiet link to the full setup sheet, for what the card can't express.
    var fullSetupLabel: String?
    var choices: [InlineCardChoice]
    /// Scope, paths, recipients — the consequential detail, on the face of the
    /// card rather than behind the fold.
    var scopeLines: [String]
    /// A monospaced identifier the card is about: a path, an address, a key id.
    var identifier: String?
    var detailsLabel: String?
    var detailsBody: String?
    /// What the primary button says while the work is in flight.
    var busyLabel: String?
    /// The honest note beside the spinner: "12 pages", "Usually about 20 seconds".
    var busyNote: String?
    /// The settled/declined/failed one-liner and its metadata.
    var outcome: String?
    var outcomeMeta: String?
    /// Whether the running state still offers Stop.
    var canStop: Bool
    /// Whether a failure is safe to retry.
    var canRetry: Bool

    init(
        id: String,
        kind: InlineCardKind,
        target: String = "",
        title: String,
        why: String,
        primaryLabel: String,
        secondaryLabel: String = "Not now",
        consequence: String,
        state: InlineCardState = .pending,
        persistenceNote: String? = nil,
        field: InlineCardField? = nil,
        fields: [InlineCardField] = [],
        signInLabel: String? = nil,
        fullSetupLabel: String? = nil,
        choices: [InlineCardChoice] = [],
        scopeLines: [String] = [],
        identifier: String? = nil,
        detailsLabel: String? = nil,
        detailsBody: String? = nil,
        busyLabel: String? = nil,
        busyNote: String? = nil,
        outcome: String? = nil,
        outcomeMeta: String? = nil,
        canStop: Bool = false,
        canRetry: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.why = why
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.consequence = consequence
        self.state = state
        self.persistenceNote = persistenceNote
        self.fields = fields.isEmpty ? (field.map { [$0] } ?? []) : fields
        self.signInLabel = signInLabel
        self.fullSetupLabel = fullSetupLabel
        self.choices = choices
        self.scopeLines = scopeLines
        self.identifier = identifier
        self.detailsLabel = detailsLabel
        self.detailsBody = detailsBody
        self.busyLabel = busyLabel
        self.busyNote = busyNote
        self.outcome = outcome
        self.outcomeMeta = outcomeMeta
        self.canStop = canStop
        self.canRetry = canRetry
    }

    /// Which mark a terminal card wears. A failure is not a receipt, so it
    /// never reaches here as one — see `InlineCardView`.
    var mark: InlineCardMark {
        switch state {
        case .settled: return .done
        case .declined: return .declined
        case .failed, .unknown: return .unknown
        case .pending, .running, .superseded: return .done
        }
    }
}

/// What the person did. Resolution belongs to the mechanism; the view only
/// says which command was taken and with what.
enum InlineCardAction: Sendable, Equatable {
    /// The primary command, carrying whatever the card collected: `value` is
    /// the first field, `values` every field by id.
    case primary(value: String?, choice: String?, values: [String: String] = [:])
    /// The quiet "Open full setup" link.
    case fullSetup
    /// The quiet secondary: "Not now", "Don't send", "Decide later".
    case secondary
    /// Retry after a safe failure.
    case retry
    /// Stop the work this card is showing.
    case stop
}

typealias InlineCardActionHandler = @MainActor (InlineCardAction) -> Void

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

/// One primary command, one quiet secondary, and the consequence of taking the
/// quiet one. The secondary never stands alone (Agent): "→" is used here and
/// nowhere else.
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
                // Agent, 2026-09-13: this is the most important line on the
                // card — what saying no costs. It reads at the subtitle's own
                // weight and one contrast step up from a caption.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    NativeAgentMotion.standard, reduceMotion: reduceMotion
                )) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(label).font(ShellType.label)
                }
                .foregroundStyle(NativeAgentShell.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            // VoiceOver has no other way to know a disclosure moved: the
            // chevron's rotation is the only visual state.
            .accessibilityLabel(label)
            .accessibilityIdentifier("inline-card.details")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint(open ? "Hides these details." : "Shows these details.")
            if open {
                content.transition(NativeAgentMotion.reveal(reduceMotion: reduceMotion))
            }
        }
    }
}

/// Radio rows. Selecting a row never executes the choice — the primary does.
struct InlineCardChoiceList: View {
    let choices: [InlineCardChoice]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(choices) { choice in
                Button {
                    selection = choice.id
                } label: {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        Image(systemName: selection == choice.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(selection == choice.id
                                             ? NativeAgentShell.needsYou : NativeAgentShell.tertiary)
                        Text(choice.title)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: NativeAgentSpacing.sm)
                        if let note = choice.note {
                            Text(note)
                                .font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .background(selection == choice.id ? NativeAgentShell.softFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityIdentifier("inline-card.choice.\(choice.id)")
                .accessibilityAddTraits(selection == choice.id ? [.isSelected] : [])
            }
        }
    }
}

/// A labelled field. A secret is typed into a `SecureField` and goes to the
/// action closure, never into transcript content.
struct InlineCardSecretField: View {
    let field: InlineCardField
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            Text(field.label)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
            Group {
                if field.isSecret {
                    SecureField(field.placeholder, text: $value)
                } else {
                    TextField(field.placeholder, text: $value)
                }
            }
            .textFieldStyle(.plain)
            .accessibilityLabel(field.label)
            .accessibilityIdentifier("inline-card.field")
            .font(ShellType.code)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(NativeAgentShell.quietFill,
                        in: RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous)
                .strokeBorder(NativeAgentShell.hairline, lineWidth: 1))
            if let helper = field.helper {
                Text(helper)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Text(text).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
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
    /// A decline is not an object in scrollback: no hairline box, gray ink,
    /// one line (Agent, 2026-09-13).
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

// MARK: - The model-driven card

/// One card for one interaction, through every state it passes: ready, in
/// flight, settled, declined, failed. It appears in place and settles in
/// place — no bounce, no shimmer, and no modal anywhere.
struct InlineCardView: View {
    let model: InlineCardModel
    let action: InlineCardActionHandler

    @State private var fieldValues: [String: String] = [:]
    @State private var selection: String?

    /// A card that collects something keeps its controls while it submits: the
    /// primary takes the spinner and the busy label ("Connecting…"), the quiet
    /// secondary stays live, and the dimensions do not move. A card that is
    /// merely showing work in flight has nothing to submit, so it gets the busy
    /// line and its Stop instead.
    private var collectsInput: Bool {
        !model.fields.isEmpty || !model.choices.isEmpty
    }

    private func typed(_ field: InlineCardField) -> String {
        (fieldValues[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing typed and a sign-in offered: the primary signs in.
    private var signsIn: Bool {
        model.signInLabel != nil && model.fields.allSatisfy { typed($0).isEmpty }
    }

    private var primaryEnabled: Bool {
        if !model.choices.isEmpty && selection == nil { return false }
        if signsIn { return true }
        // The fields are there from the start (User, 2026-09-23: no reveal
        // click), and the primary stays disabled until the required ones are
        // filled: it must never submit an empty key.
        return model.fields.allSatisfy { $0.isOptional || !typed($0).isEmpty }
    }

    private func fieldBinding(_ id: String) -> Binding<String> {
        Binding(get: { fieldValues[id] ?? "" }, set: { fieldValues[id] = $0 })
    }

    /// Every field the card shows, before its buttons in the key-view order.
    private var fieldRows: some View {
        ForEach(model.fields, id: \.id) { field in
            InlineCardSecretField(field: field, value: fieldBinding(field.id))
        }
    }

    /// Values travel in the action, never in the transcript.
    private func submit() {
        var values: [String: String] = [:]
        for field in model.fields where !typed(field).isEmpty { values[field.id] = typed(field) }
        action(.primary(value: model.field.flatMap { values[$0.id] },
                        choice: selection, values: values))
    }

    @ViewBuilder
    private var fullSetupLink: some View {
        if let label = model.fullSetupLabel {
            // Secondary text, underlined: a link without system blue, which
            // would be a second accent on the card.
            Button { action(.fullSetup) } label: {
                Text(label).underline().foregroundStyle(NativeAgentShell.secondary)
            }
            .buttonStyle(.plain)
            .font(ShellType.label)
            .accessibilityIdentifier("inline-card.full-setup")
        }
    }

    /// The outcome the primary buys. With a list on the card that is the row
    /// the person picked — "Use GPT-5.6 Sol" — and otherwise the card's own.
    private var primaryLabel: String {
        if signsIn, let signIn = model.signInLabel { return signIn }
        if let picked = selection,
           let choice = model.choices.first(where: { $0.id == picked }),
           let label = choice.actionLabel, !label.isEmpty {
            return label
        }
        return model.primaryLabel
    }

    var body: some View {
        // 2026-09-25: a card becomes its receipt in place, no crossfade — the
        // two share a spot and drew over each other for a frame.
        switch model.state {
        case .pending, .running:
            liveCard.transition(.identity)
        case .failed:
            failedCard.transition(.identity)
        case .settled, .declined, .unknown:
            receipt.transition(.identity)
        case .superseded:
            InlineCardSupersededLine()
                .accessibilityIdentifier("inline-card.\(model.kind.rawValue).superseded")
                .transition(.identity)
        }
    }

    // A live card: the fill, the ask, the control, and what declining costs.
    private var liveCard: some View {
        InlineCard(symbol: model.kind.symbol,
                   symbolTint: NativeAgentShell.needsYou,
                   title: model.state == .running && !collectsInput
                       ? (model.busyLabel ?? model.title) : model.title,
                   reason: model.why) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                scope
                fieldRows.disabled(model.state == .running)
                if !model.choices.isEmpty {
                    InlineCardChoiceList(choices: model.choices, selection: $selection)
                        .disabled(model.state == .running)
                }
                if model.state == .running && !collectsInput {
                    runningRow
                } else {
                    InlineCardActions(
                        primary: model.state == .running
                            ? (model.busyLabel ?? primaryLabel) : primaryLabel,
                        primaryEnabled: model.state == .running || primaryEnabled,
                        busy: model.state == .running,
                        secondary: model.secondaryLabel,
                        consequence: model.consequence,
                        onPrimary: submit,
                        onSecondary: { action(.secondary) }
                    )
                    fullSetupLink
                }
                details
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue)")
    }

    // Still, not shimmering: one indicator, the honest note beside it, and Stop
    // wherever the owning operation supports it.
    private var runningRow: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            InlineCardBusyLine(text: model.busyNote ?? (model.busyLabel ?? "Working…"))
            Spacer(minLength: NativeAgentSpacing.sm)
            if model.canStop {
                InlineCardSecondaryButton(title: "Stop") { action(.stop) }
            }
        }
    }

    // A failure keeps the card — the entered values, the explanation, and a
    // retry only when retrying is safe.
    private var failedCard: some View {
        InlineCard(symbol: model.kind.symbol,
                   symbolTint: NativeAgentShell.trouble,
                   title: model.outcome ?? model.title,
                   reason: model.outcomeMeta ?? model.why) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                fieldRows
                // A failure keeps what the card COLLECTS, not just what was
                // typed into it: a remount has no selection, so a failed
                // choice card with no list has nothing to answer with and
                // "Try again" submits nil for ever.
                if !model.choices.isEmpty {
                    InlineCardChoiceList(choices: model.choices, selection: $selection)
                }
                if model.canRetry {
                    InlineCardActions(
                        primary: "Try again",
                        primaryEnabled: primaryEnabled,
                        secondary: model.secondaryLabel,
                        consequence: model.consequence,
                        // A failure keeps what was typed, so the retry carries
                        // it: a key the provider rejected is corrected in place
                        // rather than re-entered from nothing.
                        onPrimary: {
                            if collectsInput {
                                submit()
                            } else {
                                action(.retry)
                            }
                        },
                        onSecondary: { action(.secondary) }
                    )
                }
                fullSetupLink
                details
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue).failed")
    }

    private var receipt: some View {
        InlineCardReceipt(mark: model.mark,
                          outcome: model.outcome ?? model.title,
                          meta: model.outcomeMeta,
                          detailsLabel: model.detailsBody == nil ? nil : (model.detailsLabel ?? "Details"),
                          // A decline is the quietest thing in the transcript.
                          quiet: model.state == .declined) {
            if let body = model.detailsBody {
                Text(body)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue).\(model.state.rawValue)")
    }

    @ViewBuilder
    private var scope: some View {
        if !model.scopeLines.isEmpty || model.identifier != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.scopeLines.enumerated()), id: \.offset) { _, line in
                    InlineCardScopeLine(text: line)
                }
                if let identifier = model.identifier {
                    Text(identifier)
                        .font(ShellType.code)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "What happens", and — Agent, 2026-09-13 — how long it lasts. The
    /// persistence note is true and it is not what the person is deciding in
    /// the second before they press the button, so it sits with the rest of
    /// the mechanics rather than taking a row above the controls.
    @ViewBuilder
    private var details: some View {
        let note = model.persistenceNote
        if model.detailsBody != nil || note != nil {
            InlineCardDetails(label: model.detailsLabel ?? "What happens") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    if let body = model.detailsBody {
                        Text(body)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note {
                        Text(note)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - The transcript host

/// Anchors a card to the turn it belongs to, inside the transcript, at the tool
/// row where the interaction lives. It appears in place and settles in place:
/// the entrance animation fires once, on insertion, and Reduce Motion turns it
/// off. Nothing here scrolls the reader anywhere.
struct ChatInlineCardHost: View {
    let cards: [InlineCardModel]
    let action: @MainActor (InlineCardModel, InlineCardAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(cards) { card in
                    InlineCardView(model: card) { taken in action(card, taken) }
                        // Identity is the request, so a re-observation of the
                        // same blocked request updates this card instead of
                        // stacking a second one.
                        .id(card.id)
                        .transition(NativeAgentMotion.fade)
                }
            }
            .animation(NativeAgentMotion.respecting(NativeAgentMotion.standard,
                                                    reduceMotion: reduceMotion),
                       value: cards.map(\.id))
        }
    }
}

/// Where the transcript asks for the cards belonging to one tool row. The
/// mechanism supplies them; with nothing injected the transcript renders
/// exactly as it does today.
struct InlineCardSourceKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor (String) -> [InlineCardModel] = { _ in [] }
}

/// Where a card's action goes. Default: nowhere.
struct InlineCardActionKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor (InlineCardModel, InlineCardAction) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var inlineCardSource: @Sendable @MainActor (String) -> [InlineCardModel] {
        get { self[InlineCardSourceKey.self] }
        set { self[InlineCardSourceKey.self] = newValue }
    }

    var inlineCardAction: @Sendable @MainActor (InlineCardModel, InlineCardAction) -> Void {
        get { self[InlineCardActionKey.self] }
        set { self[InlineCardActionKey.self] = newValue }
    }
}

/// Mounts whatever cards belong to one transcript row, directly under it.
struct InlineCardsForRow: View {
    let rowID: String
    @Environment(\.inlineCardSource) private var source
    @Environment(\.inlineCardAction) private var action

    var body: some View {
        ChatInlineCardHost(cards: source(rowID)) { model, taken in action(model, taken) }
    }
}
