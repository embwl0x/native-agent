#if DEBUG
import AppKit
import SwiftUI

/// Composer round, 2026-09-15. MOCKUPS ONLY — mounted nowhere in the app.
///
/// User's brief: make the chat composer as sleek as Claude Code's. The rail
/// keeps every tab it has (Personality, Providers, the feature toggles) —
/// more controls than Claude Code, on purpose. The target is the chat column
/// and the composer alone:
///
///   "Nothing on screen until you reach for it; every setting lives behind
///    the word that names it."
///
/// So the composer is one quiet field over one bottom row. Left: attach and
/// mic. Right: "<Model> · <Effort>" as one label whose two halves are two
/// hit targets, the Trust posture as one word, and Fast as a small chip that
/// exists only when Fast is on. Each word opens its own small anchored card:
///
///   model word  → providers as section headers, models under them, the Fast
///                 chip on the row it modifies, number shortcuts, "More models ›"
///   effort word → a Faster↔Smarter slider, the level spelled as a word
///   trust word  → the four real Trust presets, each with its real one-line meaning
///
/// What leaves the popover entirely: the "Applies to your next message" line
/// (implied — the composer IS the next message) and the screen-on pill (a
/// 5pt dot on the mic, or nothing).
///
/// Provider choice survives: catalogs are data, providers are the section
/// headers, and nothing here branches on a provider name.
///
/// The only entry point is gated:
///
///   SIMPLICITY_MOCKUPS_COMPOSER=1 SIMPLICITY_SNAPSHOT_DIR=<dir> \
///     swift test --filter BotsShelfTests
enum ComposerMockups {

    // MARK: - Entry point

    @MainActor static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 980, height: 760)
        for (name, card) in [("rest", OpenCard.none), ("model-card", .model),
                             ("effort-card", .effort), ("trust-card", .trust)] {
            try BotsShelfSnapshots.write(Room(open: card), name: name,
                                         size: size, scheme: .dark,
                                         directory: directory, scale: 2)
        }
    }

    // MARK: - The values the sheets are drawn from
    //
    // Real strings only. The Trust meanings are the ones TrustCenterView
    // already shows on its four preset cards, word for word.

    enum OpenCard { case none, model, effort, trust }

    private struct ModelRow {
        let name: String
        let shortcut: Int
        var isDefault = false
        var isSelected = false
    }

    private struct ProviderGroup {
        let provider: String
        let models: [ModelRow]
    }

    private static let catalog: [ProviderGroup] = [
        ProviderGroup(provider: "OpenAI", models: [
            ModelRow(name: "GPT-6-Astra", shortcut: 1, isDefault: true, isSelected: true),
            ModelRow(name: "GPT-5.6-Sol", shortcut: 2),
            ModelRow(name: "GPT-5.5", shortcut: 3),
        ]),
        ProviderGroup(provider: "Anthropic", models: [
            ModelRow(name: "Opus 5", shortcut: 4),
            ModelRow(name: "Fable 5.1", shortcut: 5),
        ]),
        ProviderGroup(provider: "On this Mac", models: [
            ModelRow(name: "Qwen3-4B", shortcut: 6),
        ]),
    ]

    private static let effortLevels = ["Low", "Medium", "High", "Ultra"]
    private static let effortIndex = 1

    private struct TrustRow {
        let name: String
        let meaning: String
        let shortcut: Int
        var isSelected = false
    }

    private static let trustRows: [TrustRow] = [
        TrustRow(name: "Safe", meaning: "Read files; no changes or Mac control", shortcut: 1),
        TrustRow(name: "Work mode", meaning: "Edit approved workspaces; no outside writes or shell", shortcut: 2),
        TrustRow(name: "Builder", meaning: "Edit workspaces; ask to write outside; no shell", shortcut: 3),
        TrustRow(name: "Full Mac", meaning: "Files anywhere, shell, system control, move or trash", shortcut: 4, isSelected: true),
    ]

    private static let modelWord = "GPT-6-Astra"
    private static let trustWord = "Full Mac"
    private static let fastIsOn = true
    private static let screenIsOn = true

    // MARK: - The room

    /// The chat column as it really is: the shared sheet, the one lamp, the
    /// 740pt room, replies at 708. Only the composer is new.
    private struct Room: View {
        let open: OpenCard

        var body: some View {
            ZStack {
                ShellSheet()
                ShellLamp()
                VStack(alignment: .leading, spacing: 0) {
                    Header()
                    Spacer(minLength: 0)
                    Transcript()
                        .padding(.bottom, 32)
                    ComposerStack(open: open)
                }
                .frame(width: NativeAgentShellLayout.roomColumn)
                .padding(.top, NativeAgentShellLayout.titleBarInset)
                .padding(.bottom, NativeAgentSpacing.xl)
            }
        }
    }

    private struct Header: View {
        var body: some View {
            HStack(spacing: NativeAgentSpacing.sm) {
                Text("Agent")
                    .font(ShellType.title)
                    .foregroundStyle(NativeAgentShell.text)
                Circle()
                    .fill(NativeAgentShell.calm)
                    .frame(width: 6, height: 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
            .padding(.bottom, NativeAgentSpacing.lg)
        }
    }

    /// Two real turns so the composer is judged in the column it lives in,
    /// at the reply's own measure and line spacing.
    private struct Transcript: View {
        var body: some View {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xl) {
                HStack {
                    Spacer(minLength: 0)
                    Text("What did the composer round actually change?")
                        .font(ShellType.body)
                        .foregroundStyle(NativeAgentShell.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(NativeAgentShell.softFill,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text("""
                     Everything that was a control became a word. The model, the effort, \
                     the Trust posture and Fast were four separate objects sitting on the \
                     row at all times; now they are three quiet labels and a chip that \
                     only exists when Fast is on. Nothing was removed — each word opens \
                     the card that names it, and the card is the only place the choices live.
                     """)
                    .font(ShellType.body)
                    .lineSpacing(8)
                    .foregroundStyle(NativeAgentShell.text)
                    .frame(width: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        }
    }

    // MARK: - The composer, and the card above it

    /// The card floats above the composer with a gap: two neighbouring glass
    /// surfaces, never glass drawn on glass. Each card's right edge is where
    /// a real popover would clamp — at the room's gutter, or at the word it
    /// belongs to when there is room for it.
    private struct ComposerStack: View {
        let open: OpenCard

        var body: some View {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                if open != .none {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        card
                            .padding(.trailing, cardTrailingInset)
                    }
                    .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                }
                Composer(open: open)
            }
        }

        @ViewBuilder private var card: some View {
            switch open {
            case .model: ModelCard()
            case .effort: EffortCard()
            case .trust: TrustCard()
            case .none: EmptyView()
            }
        }

        /// Measured back from the room's inner right edge, so each card's left
        /// edge lands on the left edge of the word that opened it. The trust
        /// card is wider than the space to its right, so it clamps to the
        /// gutter the way a real popover clamps to the window.
        private var cardTrailingInset: CGFloat {
            switch open {
            case .model: 74
            case .effort: 10
            case .trust, .none: 0
            }
        }
    }

    private struct Composer: View {
        let open: OpenCard

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(ChatShellCopy.composerPlaceholder)
                    .font(ShellType.body)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .frame(height: 24, alignment: .leading)

                HStack(spacing: 0) {
                    Glyph(symbol: "plus")
                    Glyph(symbol: "mic", showsDot: screenIsOn)

                    Spacer(minLength: 0)

                    // "<Model> · <Effort>" reads as one label and is two hit
                    // targets. The dot is punctuation, not a control.
                    Word(text: modelWord, isOpen: open == .model)
                    Text("·")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .padding(.horizontal, 6)
                    Word(text: effortLevels[effortIndex], isOpen: open == .effort)

                    if fastIsOn {
                        FastChip().padding(.leading, 12)
                    }

                    Word(text: trustWord, isOpen: open == .trust)
                        .padding(.leading, 14)

                    SendButton().padding(.leading, 12)
                }
            }
            // The room's gutter, inside the glass: the field's first character
            // lands on the first character of her replies, and the box's inner
            // right edge on their last (708 + 2 x 16 = the 740 column).
            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
            .padding(.top, 12)
            .padding(.bottom, 11)
            // ImageRenderer cannot rasterize Liquid Glass offscreen, so the
            // shipped rail's trick carries the still: a tone hint of the room
            // UNDER the real glass call. On screen this is glass; here it is
            // the ground glass would have lensed.
            .background {
                RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius,
                                 style: .continuous)
                    .fill(NativeAgentShell.room.opacity(0.80))
            }
            .glassEffect(.regular.interactive(),
                         in: RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius,
                                              style: .continuous))
        }
    }

    /// Attach and mic keep their glyphs: they are verbs, not settings, and
    /// words for them would be two more things to read on every turn.
    private struct Glyph: View {
        let symbol: String
        var showsDot = false

        var body: some View {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(ShellType.bodyMedium)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .frame(width: 32, height: 32)
                if showsDot {
                    // The screen-on pill, reduced to the smallest thing that
                    // can still say it: a 5pt dot on the control it concerns.
                    Circle()
                        .fill(NativeAgentShell.calm)
                        .frame(width: 5, height: 5)
                        .offset(x: -5, y: 6)
                }
            }
        }
    }

    /// A setting rendered as the word that names it. Quiet at rest; when its
    /// card is open the word takes the room's own fill, so the open card and
    /// the word it came from are visibly one object.
    private struct Word: View {
        let text: String
        var isOpen = false

        var body: some View {
            Text(text)
                .font(ShellType.labelMedium)
                .foregroundStyle(isOpen ? NativeAgentShell.text : NativeAgentShell.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background {
                    if isOpen {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(NativeAgentShell.softFill)
                    }
                }
        }
    }

    /// Fast is the one state that is worth a chip, because it is the one a
    /// person turns on for a while and forgets. Off, it is not on screen.
    private struct FastChip: View {
        var body: some View {
            Text("Fast")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(NativeAgentShell.softFill, in: Capsule())
        }
    }

    private struct SendButton: View {
        var body: some View {
            Image(systemName: "arrow.right")
                .font(ShellType.body)
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(NativeAgentShell.text)
        }
    }

    // MARK: - The three cards

    /// One shape for all three: regular glass over a tone hint, the room's
    /// own fill, at a radius concentric with the composer's 16.
    private struct CardShell<Content: View>: View {
        let width: CGFloat
        @ViewBuilder let content: Content

        var body: some View {
            content
                .padding(NativeAgentSpacing.md)
                .frame(width: width, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(NativeAgentShell.room.opacity(0.82))
                }
                .glassEffect(.regular,
                             in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// The provider is a section header, never a row you pick and never a
    /// branch in the code: the catalog is data and the headers come from it.
    private struct ModelCard: View {
        var body: some View {
            CardShell(width: 300) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(catalog.enumerated()), id: \.offset) { index, group in
                        Text(group.provider)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, index == 0 ? 0 : 10)
                            .padding(.bottom, 4)
                        ForEach(Array(group.models.enumerated()), id: \.offset) { _, model in
                            ModelRowView(model: model)
                        }
                    }
                    Rectangle()
                        .fill(NativeAgentShell.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 8)
                    HStack(spacing: 4) {
                        Text("More models")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    private struct ModelRowView: View {
        let model: ModelRow

        var body: some View {
            HStack(spacing: 6) {
                Text(model.name)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.text)
                if model.isDefault {
                    Tag(text: "Default")
                }
                Spacer(minLength: 4)
                // Fast modifies THIS model, so it lives on this row and
                // nowhere else — the composer chip is the same switch.
                if model.isSelected, fastIsOn {
                    Tag(text: "Fast", isOn: true)
                }
                Text("\(model.shortcut)")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .frame(width: 12, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if model.isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(NativeAgentShell.quietFill)
                }
            }
        }
    }

    private struct Tag: View {
        let text: String
        var isOn = false

        var body: some View {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? NativeAgentShell.text : NativeAgentShell.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isOn ? NativeAgentShell.softFill : NativeAgentShell.quietFill,
                            in: Capsule())
        }
    }

    /// The segmented Low/Medium/High/Ultra control becomes what it always
    /// meant: one axis, with the level spelled out. Faster and Smarter are
    /// the ends, because those are the two things a person is trading.
    private struct EffortCard: View {
        var body: some View {
            CardShell(width: 238) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Faster")
                        Spacer(minLength: 0)
                        Text("Smarter")
                    }
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)

                    GeometryReader { geo in
                        let fraction = Double(effortIndex) / Double(effortLevels.count - 1)
                        let x = geo.size.width * fraction
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(NativeAgentShell.quietFill)
                                .frame(height: 4)
                            Capsule()
                                .fill(NativeAgentShell.secondary)
                                .frame(width: max(x, 4), height: 4)
                            Circle()
                                .fill(NativeAgentShell.text)
                                .frame(width: 14, height: 14)
                                .offset(x: x - 7)
                        }
                        .frame(height: 14)
                    }
                    .frame(height: 14)

                    Text(effortLevels[effortIndex])
                        .font(ShellType.bodyMedium)
                        .foregroundStyle(NativeAgentShell.text)
                }
            }
        }
    }

    /// The four presets Trust already ships, with the meanings Trust already
    /// writes. The composer does not invent a fifth posture or a shorthand.
    private struct TrustCard: View {
        var body: some View {
            CardShell(width: 404) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(trustRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(ShellType.labelMedium)
                                    .foregroundStyle(NativeAgentShell.text)
                                Text(row.meaning)
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Text("\(row.shortcut)")
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .frame(width: 12, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background {
                            if row.isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(NativeAgentShell.quietFill)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
