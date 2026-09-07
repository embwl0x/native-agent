import SwiftUI
import AppKit

// PATCH-2026-05-09: chat-ux-polish — Motion tokens, tag font
enum NativeAgentMotion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.72)
    static let gentle = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let pulse  = Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: true)
    // chat-smoothness phase 6: subtle entrance for newly-inserted chat bubbles.
    // Triggered ONLY by withAnimation at the append seam (appendChatMessage) —
    // never by a list-level .animation key. gpt-5.5 r1 blocker: an id-list key
    // also animates the end-of-turn optimistic→daemon id swap (wholesale
    // replace), turning a known row-identity hitch into a visible re-settle.
    // 2026-09-03 motion pass: a bubble arriving is the app's most-seen state
    // change, and easeOut(0.22) landed it flat. `.smooth` is Apple's own
    // no-bounce spring; 0.35 s is Material 3's "medium 3" token, borrowed —
    // Apple publishes no durations. It fires ONLY at the append seam, and the
    // list drops the transition entirely when the reader has scrolled away.
    static let entrance = Animation.smooth(duration: 0.35)

    /// Reduce-motion-aware entrance for MODEL-layer mutation sites
    /// (withAnimation in NativeClient has no SwiftUI Environment) — reads the
    /// system setting directly.
    static var entranceSystem: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : entrance
    }

    /// chat-smoothness phase 6: reduce-motion gate. Returns nil (no animated
    /// transition — SwiftUI applies the change instantly, no movement) when the
    /// system Reduce Motion accessibility setting is on; otherwise the given
    /// animation. Wire this into any animation ADDED in this phase plus the
    /// phase-4 floating thinking-row fade.
    static func respecting(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

enum NativeAgentFont {
    static let title = Font.system(.title2, weight: .semibold)
    static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let section = Font.system(.headline, weight: .semibold)
    static let body = Font.system(.body)
    static let label = Font.system(.caption, weight: .semibold)
    static let tag  = Font.system(.caption2, weight: .medium)
    static let mono = Font.system(.caption, design: .monospaced)
}

enum NativeAgentSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum NativeAgentRadius {
    static let compact: CGFloat = 4
    static let control: CGFloat = 6
    static let panel: CGFloat = 8
    static let card: CGFloat = 8
}

enum NativeAgentLayout {
    static let cardPadding: CGFloat = NativeAgentSpacing.lg
    static let maxReadableChatWidth: CGFloat = 760
}

enum NativeAgentTheme {
    static let ok = Color.green
    static let warn = Color.orange
    static let fail = Color.red
    static let info = Color.blue

    static func statusColor(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready", "scheduled": ok
        case "running", "info": info
        case "warn", "warning", "blocked", "needs_setup", "planned", "interrupted", "disabled": warn
        case "fail", "failed", "error", "timeout", "quarantined": fail
        default: .secondary
        }
    }
}

// MARK: - Color hex helper (mirrors the iOS NativeAgentTheme initializer so the
// Mac + iOS apps share one teal identity by hex value, not by eyeballed literals)
extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Brand palette — teal identity
//
// 2026-07-06: retheme from the old purple→pink chat accents to a blue-teal
// (cyan/sky, Agent's color). Centralized here so the chat surfaces stop
// carrying raw `Color.purple`/`Color.pink` literals — one source of truth for
// the Mac accent, matched hex-for-hex to the iOS `NativeAgentPalette`.
enum NativeAgentBrand {
    /// Vibrant cyan-500 — primary accent: icons, tints, borders, indicators.
    static let accent       = Color(hex: 0x06B6D4)
    /// Deep cyan-700 — gradient end for filled surfaces; keeps white text readable.
    static let accentDeep   = Color(hex: 0x0E7490)
    /// Sky-400 — cool blue counter-tone for multi-stop gradients + glows.
    static let accentCool    = Color(hex: 0x38BDF8)

}

/// The panel every page still reaches for: an eyebrow over one card. The
/// material slab and the tinted accent border it used to draw were the second
/// plate on a page that already sits on the sheet, so both are gone. `tint` and
/// `systemImage` stay in the signature — dozens of call sites pass them — but
/// neither paints anything now (advanced-page kit, 2026-09-03).
struct NativePanel<Content: View>: View {
    var title: String?
    var systemImage: String?
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            if let title {
                Text(title.uppercased())
                    .font(ShellType.labelSemibold)
                    .tracking(0.6)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NativeAgentSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(TodayPalette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
            )
        }
    }
}

/// A status said in a word, in the room's state colours. The tinted capsule it
/// used to wear was a plate around one word; the word carries the state on its
/// own. API unchanged — the eval suite pins the call shape.
struct StatusBadge: View {
    var text: String
    var status: String?

    var body: some View {
        Text(AdvancedStatusWords.label(text))
            .font(ShellType.caption)
            .foregroundStyle(AdvancedStatusWords.color(status ?? text))
            .lineLimit(1)
    }
}

/// A fact beside a row. Was a filled capsule; now it is just the fact.
struct InfoPill: View {
    var text: String
    var systemImage: String

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
            .lineLimit(1)
    }
}

/// A settings eyebrow and its rows on one card.
struct SettingsCardSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .settingsCardSurface()
        }
    }
}

extension View {
    /// The shared settings card surface; callers own content and padding.
    func settingsCardSurface() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(TodayPalette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
            )
    }

    /// Shared capsule-tag chrome: semibold caption2 text, tight padding, a
    /// 16%-tint capsule fill, and matching tinted foreground. Each call site
    /// keeps its own (label, color) mapping — this owns only the visual chrome
    /// so the pills can't drift byte-by-byte. Distinct from `StatusBadge` /
    /// `InfoPill` (different padding/opacity by design).
    func capsuleTag(_ color: Color) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

struct InlineStatusDot: View {
    var status: String?

    var body: some View {
        Circle()
            .fill(NativeAgentTheme.statusColor(status))
            .frame(width: 8, height: 8)
    }
}

// PATCH-2026-05-07: ui-polish — Design system primitives (GlassCard, PulsingDot, Shimmer, GradientText, AuroraBackground)

/// Neutral material card with an optional semantic or identity edge.
struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    /// Rows inside scrolling Lists render material instead of live glass —
    /// per-row glassEffect is a scroll-perf hazard (gpt-5.5 MED, InboxView).
    var scrollRow: Bool = false
    /// Clear-glass variant for cards that FLOAT OVER live content (the chat
    /// turn card): regular glass reads near-opaque over a dark transcript and
    /// buries the text beneath (User, 2026-08-20). Reduce-transparency still
    /// gets the fully opaque fallback — that setting is a request for MORE
    /// opacity, never less.
    var lightweight: Bool = false
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let edgeColor = tint ?? Color.primary
        let edgeOpacity = tint != nil
            ? (colorSchemeContrast == .increased ? 0.72 : 0.34)
            : (colorSchemeContrast == .increased ? 0.28 : 0.10)

        // Liquid Feel W2 (2026-08-16): GlassCard renders REAL Liquid Glass on
        // the macOS 26 floor — every card in the app upgrades through this one
        // seam. Reduce-transparency keeps the opaque fallback.
        if reduceTransparency || scrollRow {
            content()
                .padding(NativeAgentLayout.cardPadding)
                .background {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                        .fill(reduceTransparency
                            ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                            : AnyShapeStyle(.thinMaterial))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                        .strokeBorder(
                            edgeColor.opacity(edgeOpacity),
                            lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                        )
                }
        } else {
            content()
                .padding(NativeAgentLayout.cardPadding)
                .glassEffect(
                    {
                        let base: Glass = lightweight ? .clear : .regular
                        return tint.map { base.tint($0.opacity(0.12)) } ?? base
                    }(),
                    in: RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                        .strokeBorder(
                            edgeColor.opacity(edgeOpacity * 0.6),
                            lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                        )
                }
        }
    }
}

/// Status indicator. Static by default so persistent lists/cards do not keep
/// SwiftUI's display list animating while the app is idle.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    var animates: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let shouldAnimate = animates && !reduceMotion

        ZStack {
            if shouldAnimate {
                Circle().fill(color.opacity(0.35))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(pulse ? 1 : 0.5)
                    .opacity(pulse ? 0 : 0.6)
            }
            Circle().fill(color)
                .frame(width: size, height: size)
                .shadow(color: shouldAnimate ? color.opacity(0.45) : .clear, radius: shouldAnimate ? 2 : 0)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard shouldAnimate else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Shimmer sweep modifier — use `.appShimmer()` on placeholder content
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { geo in
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(0.28), location: 0.5),
                        .init(color: .white.opacity(0), location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: geo.size.width * 1.6)
                    .offset(x: geo.size.width * phase)
                    .blendMode(.plusLighter)
                    .onAppear {
                        withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                            phase = 1.4
                        }
                    }
                }
                .mask(content)
            }
        }
    }
}
extension View {
    func appShimmer() -> some View { modifier(Shimmer()) }
}

/// Identity text that keeps the historical color-list API while rendering solid.
struct GradientText: View {
    let text: String
    let colors: [Color]
    let font: Font

    var body: some View {
        Text(text).font(font)
            .foregroundStyle(colors.first ?? NativeAgentBrand.accentDeep)
    }
}

/// Static neutral background with a restrained identity tint.
struct AuroraBackground: View {
    let colors: [Color]
    var animates: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let identityTint = colors.first ?? NativeAgentBrand.accent
        let tintOpacity = colorSchemeContrast == .increased
            ? 0.02
            : (colorScheme == .dark ? 0.05 : 0.035)

        ZStack {
            Color(nsColor: .windowBackgroundColor)
            identityTint.opacity(tintOpacity)
        }
    }
}

// MARK: - The shell (ui-simplify 2026-09-02, Lane A)

/// Kill switch for the 2026-09-02 shell. When this preference is ON the app
/// renders the PREVIOUS sidebar/list shell, unchanged. Default OFF: the new
/// shell is the shell. One key, read everywhere, so a rollback is one toggle.
enum NativeAgentShellPreference {
    static let classicShellKey = "uiClassicShell"

    static func isClassic(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: classicShellKey)
    }

    /// User, 2026-09-04: "developer surfaces always left on, we have room, let
    /// people see." The new shell shows everything; the stored switch only
    /// still gates the classic sidebar.
    static func developerSurfacesShown(_ stored: Bool, defaults: UserDefaults = .standard) -> Bool {
        isClassic(defaults) ? stored : true
    }
}

/// The room's palette. Warm dark by default, warm light behind the same names,
/// so a view names a ROLE (room, rail, list, text) and never an appearance.
///
/// One rule the rest of the app must not break: `needsYou` (the brand teal) is
/// reserved for "she is waiting on you" — the approval card's border and the
/// status dot while an approval is pending. Nothing else may wear it.
enum NativeAgentShell {
    // Surfaces
    static let room       = dynamic(dark: 0x151618, light: 0xF6F5F2)
    static let rail       = dynamic(dark: 0x121315, light: 0xECEBE7)
    static let list       = dynamic(dark: 0x17181B, light: 0xF1F0EC)
    // Type
    static let text       = dynamic(dark: 0xF6F3EE, light: 0x0B0B0C)
    // User, 2026-09-02: the pages sit on behind-window glass, which eats
    // contrast. Secondary and tertiary are lifted a step in both appearances.
    // User, 2026-09-03, "light mode needs tons of work": with the light coat
    // at 0.3 the desktop smears through, and measured on the glass at a
    // smear (#B4B4B4) the old light greys fell to 3.7 / 2.7 and the teal to
    // 2.6. These clear 4.9 / 3.9 / 3.5 at that smear and 8.2 / 6.5 / 5.8 on
    // the plain room; the bleed stays, the words keep their ground.
    // so a quiet line still reads through the blur.
    static let secondary  = dynamic(dark: 0xA4AAB0, light: 0x3E4146)
    static let tertiary   = dynamic(dark: 0x858B91, light: 0x4C5055)
    // Felt state
    // User, 2026-09-03: the felt-state colours were dark-only hexes and failed
    // their contrast floors on the light room (teal 2.23:1, calm 2.04, trouble
    // 1.89). Dark keeps the exact hex it had; light gets a darker variant that
    // clears 4.5:1 on the room (0xF6F5F2) and the rail (0xECEBE7).
    /// "Needs you" — approval borders and the waiting status dot. Nothing else.
    static let needsYou   = dynamic(dark: 0x06B6D4, light: 0x0B5F76)
    /// Trouble — a dropped connection, a turn that failed.
    static let trouble    = dynamic(dark: 0xFF9F0A, light: 0x864800)
    /// Calm — she is up and answering.
    // Light calm/trouble measured on the Advanced cards (#DCDCDC), not the
    // room: 3.95 / 3.97 there; these clear 5.5 / 5.2 on the card and 6.0 / 5.7
    // on the room (2026-09-03).
    static let calm       = dynamic(dark: 0x34C759, light: 0x136224)

    /// The one soft fill (user bubbles, rail selection, chips). Reads as 8%
    /// white on the warm dark and 8% ink on the warm light.
    // User, 2026-09-03: light reads flat on glass, so the fills and hairline
    // carry a step more contrast there than in dark.
    static let softFill   = primaryTint(dark: 0.08, light: 0.11)
    /// Quieter fill for the tool row and the search field.
    static let quietFill  = primaryTint(dark: 0.05, light: 0.075)
    /// The single hairline used by the composer and the quiet cards.
    static let hairline   = primaryTint(dark: 0.10, light: 0.14)

    /// The primary colour at an appearance-specific alpha: white on dark,
    /// black on light, so a fill or hairline can carry more weight in light.
    private static func primaryTint(dark: Double, light: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor.white.withAlphaComponent(dark) : NSColor.black.withAlphaComponent(light)
        })
    }

    private static func dynamic(dark: UInt, light: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(shellHex: isDark ? dark : light)
        })
    }
}

/// Glass, the Mac way: the desktop bleeds through the rail and the list, the
/// way Finder's sidebar does it. In-window blur over our own dark is a tint
/// pretending (Agent, 2026-09-02), so this is behind-window material, always
/// active, with the shell colour laid over it at a fraction so the palette
/// still reads in both appearances.
struct ShellGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The room's backdrop: glass, the coat, and in dark one warm lamp top-left.
/// Agent, 2026-09-02, on User's "gloomy": a lamp is a familiar light, a room
/// somebody is in at night. It sits in the room, radial, no edge, and it is
/// ours: it survives any desktop because it is drawn over the coat.
/// User, 2026-09-03: "it should all look like one." The window is a single
/// sheet of glass: the rail, the sessions list and the room all sit on the
/// same behind-window material under the same coat, so the desktop bleeds
/// through every column alike. Columns are told apart by a hairline, not by a
/// change of material. Reduce transparency takes the sheet opaque.
struct ShellSheet: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                NativeAgentShell.room
            } else {
                ShellGlass(material: .underWindowBackground)
                NativeAgentShell.room.opacity(NativeAgentShellLayout.roomGlassTint)
            }
        }
        .ignoresSafeArea()
    }
}

/// The room's ground: the shared sheet. The lamp used to be drawn here, per
/// room column; Agent, 2026-09-03: it stopped dead at the list/room hairline,
/// one thing on the wrong layer. It lives on the window now (`ShellLamp`, in
/// `ShellFrame`), one source over all three columns, so its bloom crosses the
/// hairlines like weather.
struct ShellRoomBackdrop: View {
    var body: some View {
        // Agent, 2026-09-03: nothing. The sheet is drawn once on the window
        // (ShellFrame); a page that drew its own was one more plate.
        Color.clear
    }
}

/// The one warm light in the window, dark only, drawn over the whole sheet.
/// Radial with no edge, low and wide enough that the middle of the room has
/// light. Warmth for a room; not a fix for contrast, that is the coat's job.
struct ShellLamp: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.42),
                    Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.10),
                    .clear,
                ],
                // Where it sat when it was the room's own: a little left of
                // the room's centre, high. The room starts 348pt into the
                // window, so the same spot in window terms.
                center: UnitPoint(x: 0.38, y: 0.24),
                startRadius: 0,
                endRadius: 1200
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
}

/// The shell's type ramp. One modular scale, major third (1.25) from a 16pt
/// body — methods-grids-and-type §11: 16 ÷ 1.25 = 12.8 → 13, ÷ 1.25 = 10.24 →
/// 10; 16 × 1.25 = 20, × 1.25 = 25. Five steps and nothing between them, so
/// the 11 / 12 / 14 / 15 / 17 / 28 / 30 the shell had collected have one place
/// each to land.
///
/// Rules: body is regular, titles are semibold, no Light/Thin/Ultralight, and
/// no manual `.tracking` — the system applies its own per-size tracking and an
/// override fights it. 10 is the HIG floor and is for timestamps and counters
/// only; it must still clear 4.5:1, which means the `tertiary` token, never
/// SwiftUI's hierarchical `.tertiary` over glass.
enum ShellType {
    // 10 measured 1.95:1 on the fold count in dark and 2.44 in light; 11 at
    // the secondary colour clears it (critique finding 5).
    static let captionSize: CGFloat = 11
    static let labelSize: CGFloat = 13
    static let bodySize: CGFloat = 16
    static let titleSize: CGFloat = 20
    static let displaySize: CGFloat = 25

    /// 10 — timestamps, counters. The floor.
    /// Codes and paths, and nothing else: keys, ids, file paths. Never for a
    /// label that happens to be short.
    static let code = Font.system(size: labelSize, design: .monospaced)
    static let caption = Font.system(size: captionSize)
    static let captionMedium = Font.system(size: captionSize, weight: .medium)
    static let captionSemibold = Font.system(size: captionSize, weight: .semibold)
    /// 13 — list subtitle, rail words, tool rows, meta lines, buttons.
    static let label = Font.system(size: labelSize)
    static let labelMedium = Font.system(size: labelSize, weight: .medium)
    /// The rail's word. User, 2026-09-04: a half step above label so twelve
    /// words read at a glance; the rail is the one place off the ramp.
    static let railSize: CGFloat = 14
    static let rail = Font.system(size: railSize, weight: .medium)
    static let labelSemibold = Font.system(size: labelSize, weight: .semibold)
    /// 16 — body, list row title, card headline.
    static let body = Font.system(size: bodySize)
    static let bodyMedium = Font.system(size: bodySize, weight: .medium)
    static let bodySemibold = Font.system(size: bodySize, weight: .semibold)
    /// 20 — every column header: "Chat" is a word not a title, but "Agent"
    /// and "Conversations" are the same rank and now wear the same face.
    static let title = Font.system(size: titleSize, weight: .semibold)
    /// 25 — page titles: Today, Desk, Memories, Setup, the empty room.
    static let display = Font.system(size: displaySize, weight: .semibold, design: .rounded)
}

/// Where the room's one column sits inside the room pane.
enum RoomAnchor {
    /// Pinned a fixed gutter right of the list/room seam, with the surplus
    /// collected on the right as ONE gutter. At 2560 the centred column left
    /// 614pt of dead air on each side and 819pt to the right of the last word;
    /// against the seam the transcript sits by the list the way a page sits by
    /// a sidebar, and the right-hand surplus becomes somewhere to put things.
    case seam
    /// The 2026-09-02 behaviour: the column centred in the pane.
    case center
}

/// Measurements the shell is drawn to. The room is a 720pt column; her replies
/// stay inside 600 so a long answer never runs the full width of a big display.
enum NativeAgentShellLayout {
    // User, 2026-09-04: 84 truncated "Notifications" once the Advanced pages
    // came out onto the rail; 112 holds the longest word at the rail's 14pt.
    static let railWidth: CGFloat = 112
    static let railItemHeight: CGFloat = 44
    /// The bar's inset from the column's edge, one rule for rail and list.
    static let barInset: CGFloat = 4
    /// The most composer the transcript will ever clear: five lines of input,
    /// the control row and an attachment strip. Anything larger is a bad
    /// measurement, not a tall composer.
    static let composerClearanceMax: CGFloat = 320
    /// Where the rail's words start, one left edge top to bottom.
    static let railWordInset: CGFloat = 14
    /// User, 2026-09-02: "make it all glass." The room and every page sit on
    /// the same material, under a heavier coat so the words keep their ground.
    @MainActor static var roomGlassTint: Double {
        // Light material already whitens what is behind it; a lighter coat
        // there lets the desktop read, a heavier one in dark keeps the words.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // The bleed is the point (User): the coat stays light; crispness
        // comes from the type, not the ground. User, 2026-09-03: "light mode
        // needs tons of work" — the light material already whitens what is
        // behind it, and a 0.5 coat on top of that left the desktop invisible;
        // the coat comes down so light bleeds like dark does.
        return dark ? 0.46 : 0.3
    }
    /// Agent, 2026-09-02: the title bar was a painted strip sitting on top of
    /// three glass columns, so the top-left read as two objects — system
    /// chrome bolted onto our room. The window now uses a transparent title
    /// bar over a full-size content view, so each column's material runs from
    /// the top edge to the bottom edge and the traffic lights float on the
    /// rail's glass. Content keeps its old position: this is the strip the
    /// title bar used to occupy, given back as a safe-area inset so the header
    /// row and the rail's first item do not move up under the lights.
    static let titleBarInset: CGFloat = 28
    /// The list column, edge to edge. The source used to say 264 while the
    /// view rendered 288 (the 264 was the content inside a 12pt pad); source
    /// and pixels now agree on the measured number.
    static let conversationsWidth: CGFloat = 288
    /// The list's inner gutter — the content inside `conversationsWidth`.
    static let conversationsInset: CGFloat = 12
    /// One list row, fixed. 46 + the 2pt gap between rows = a 48pt pitch,
    /// two 24pt units, the same pitch the rail already runs (44 + 4).
    static let listRowHeight: CGFloat = 46
    static let listRowGap: CGFloat = 2
    // User, 2026-09-03: the room grows with the window like the Claude app,
    // up to a cap; the composer spans the whole column.
    // User/Agent, 2026-09-03: the measure decides the column, not the window.
    // 708 at 16pt is ~66 characters — Bringhurst's ideal, and the number
    // Notion runs at the same body size. The column is that measure plus the
    // room's own gutter on each side, so the composer's inner edges and the
    // last word of a reply share one right edge.
    static let roomColumn: CGFloat = 740
    static let replyMaxWidth: CGFloat = 708
    /// The gutter inside the room column: header, transcript and working card
    /// wear it, and it is also the composer's own inner padding.
    static let roomGutter: CGFloat = 16
    /// How far the column sits from the list/room seam when anchored there.
    static let roomSeamGutter: CGFloat = 96
    /// Default `.seam`. Flip to `.center` to get the old centred column back.
    // Round A comps (2026-09-03): A (seam) leaves a 1384pt void at 2560 until
    // something lives on the right; B (centre) reads as a page. Centre now;
    // seam the day a side track ships. One token.
    static let roomAnchor: RoomAnchor = .center
    static var roomLeadingInset: CGFloat {
        roomAnchor == .seam ? roomSeamGutter : roomGutter
    }
    static var roomTrailingInset: CGFloat { roomGutter }
    static var roomAlignment: Alignment {
        roomAnchor == .seam ? .topLeading : .top
    }
    static let userBubbleMaxWidth: CGFloat = 640
    static let composerRadius: CGFloat = 16
    /// 16pt body at 1.6 line height → 9.6pt of extra leading.
    static let replyLineSpacing: CGFloat = 8
    /// Agent, 2026-09-02: the per-message action bar used to float over the
    /// top of the bubble and land on the first line of the message above it.
    /// It now sits in its own strip UNDER the message. The strip is reserved
    /// whether or not the pointer is there, so hover stays layout-neutral
    /// (the 2026-07-25 "scrolls up when I move to the composer" rule). The
    /// height is the bar's own: 22pt buttons inside 4pt of vertical padding.
    static let hoverBarStrip: CGFloat = 30
    /// Breathing room between the last line of the transcript and the top of
    /// the floating composer.
    static let composerClearanceMargin: CGFloat = 12
    static let userBubbleCorners = RectangleCornerRadii(
        topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14
    )
}

private extension NSColor {
    convenience init(shellHex hex: UInt) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8) & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha:   1
        )
    }
}

struct NativeEmptyState: View {
    var title: String
    var detail: String
    var systemImage: String
    var actionTitle: String?
    var actionImage: String?
    var actionIsDisabled = false
    var action: (() -> Void)?

    /// Words, left-aligned, where the thing would be. The big tinted glyph and
    /// the prominent button were the loudest thing on a page that had nothing
    /// in it; an empty state says what would fill it and offers one plain way
    /// to start (advanced-page kit, 2026-09-03). `systemImage` and
    /// `actionImage` stay in the signature and no longer draw.
    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                Text(title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                if !detail.isEmpty {
                    Text(detail)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .disabled(actionIsDisabled)
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
