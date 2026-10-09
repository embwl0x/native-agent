import SwiftUI
import AppKit

/// The panel every page still reaches for: an eyebrow over one card, the
/// kit's (`aliveCard`). `tint` and `systemImage` stay in the signature —
/// dozens of call sites pass them — but neither paints anything now
/// (advanced-page kit, 2026-09-03).
struct NativePanel<Content: View>: View {
    var title: String?
    var systemImage: String?
    var tint: Color? = nil
    var contentInsets = EdgeInsets(top: NativeAgentSpacing.lg, leading: NativeAgentSpacing.lg,
                                  bottom: NativeAgentSpacing.lg, trailing: NativeAgentSpacing.lg)
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            if let title {
                AliveEyebrow(title)
            }
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(contentInsets)
            .aliveCard()
        }
        // Keep each card's controls in a semantic group. Flattening a whole
        // settings page makes SwiftUI repeatedly order unrelated descendants
        // when accessibility clients inspect it during scrolling.
        .accessibilityElement(children: .contain)
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

extension View {
    /// The kit's card on a settings section; callers own content and padding.
    func settingsCardSurface() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .aliveCard()
            .accessibilityElement(children: .contain)
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

    func houseInset<S: Shape>(in shape: S) -> some View {
        modifier(HouseInset(shape: shape))
    }

    func houseSheet() -> some View {
        background {
            ShellSheet()
                .overlay { WindowHaze() }
                .houseSurface(in: ConcentricRectangle())
        }
        .presentationBackground(.clear)
        .environment(\.houseGlassEnclosed, true)
    }
}

private struct HouseGlassEnclosedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var houseGlassEnclosed: Bool {
        get { self[HouseGlassEnclosedKey.self] }
        set { self[HouseGlassEnclosedKey.self] = newValue }
    }
}

private struct HouseInset<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.houseGlassEnclosed) private var enclosed

    func body(content: Content) -> some View {
        if enclosed { content } else { content.houseSurface(in: shape) }
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

enum HouseGlass {
    /// User's clear glass, shared by every authored plate: a dark tint on the
    /// dark room. On the light room that same black tint read as a grey slab
    /// (User, 2026-10-09: "washed-out grey"), so light gets a white tint — a
    /// lifted frosted plate, not a shadow. One dynamic colour, every site.
    static let plate: Glass = .clear.tint(plateTint)
    private static let plateTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.28)
            : NSColor.white.withAlphaComponent(0.58)
    })
}

extension View {
    func houseSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(HouseSurface(shape: shape, interactive: interactive))
    }
}

private struct HouseSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let opaque = reduceTransparency || quietOffscreenRead
        content
            .background {
                if opaque { shape.fill(TodayPalette.cardFill) }
            }
            .glassEffect(opaque ? .identity : HouseGlass.plate.interactive(interactive), in: shape)
            .overlay {
                if opaque || contrast == .increased {
                    shape.stroke(opaque ? TodayPalette.cardStroke : Color(nsColor: .separatorColor), lineWidth: 1)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
            }
            .environment(\.houseGlassEnclosed, true)
    }
}

// PATCH-2026-05-07: ui-polish — Design system primitives (GlassCard, PulsingDot, Shimmer, GradientText)

/// House glass card with an optional accessibility state edge. Chrome
/// only: the chat turn card floating over the transcript and the detached
/// panels' classic composer. Content cards wear `aliveCard`.
struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    var body: some View {
        // A quiet screenshot draws the opaque fill too: tinted glass drawn
        // into a bitmap blanks the whole capture.
        let opaque = reduceTransparency || quietOffscreenRead
        let edgeColor = tint ?? Color.primary
        let edgeOpacity = tint != nil
            ? (colorSchemeContrast == .increased ? 0.72 : 0.34)
            : (colorSchemeContrast == .increased ? 0.28 : 0.10)

        if opaque {
            content()
                .padding(NativeAgentLayout.cardPadding)
                .background {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
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
                .houseSurface(in: RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous))
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
            withAnimation(NativeAgentMotion.pulse) {
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
                        withAnimation(NativeAgentMotion.pulse) {
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

// MARK: - The shell (ui-simplify 2026-09-02, Lane A)

/// The room's palette. Warm dark by default, warm light behind the same names,
/// so a view names a ROLE (room, rail, list, text) and never an appearance.
///
/// One rule the rest of the app must not break: `needsYou` (the brand teal) is
/// reserved for "she is waiting on you" — the approval card's border and the
/// status dot while an approval is pending. Nothing else may wear it.
enum NativeAgentShell {
    // Surfaces
    // User + Agent, 2026-09-12: the page ground, the cards and the waiting card
    // were three colours in one view — "too far off from our colors, stands
    // out, doesn't flow". The ground joins the cards' family: a charcoal-slate
    // one small step DARKER than `TodayPalette.cardFill`, so a card still reads
    // as a card by lightness (dark rooms elevate with light, not shadow) and
    // the room stops swinging from brown to green as the desktop moves under it.
    // 2026-10-09: the light room steps up toward paper (F4F3F0 read as grey
    // under the coat); rail and list sit one step either side of it, as in dark.
    static let room       = dynamic(dark: 0x12161F, light: 0xF7F6F3)
    static let rail       = dynamic(dark: 0x121315, light: 0xF3F2EF)
    static let list       = dynamic(dark: 0x17181B, light: 0xF5F4F1)
    // 2026-09-10, User: the two form panels were the only opaque cards in the app
    // and read as brown slabs against every other glass card. They use the
    // shared glass card again; the readable secondary text from the same pass stays.
    // Type
    // User 09-27: all Mac native — the system label colours.
    static let text       = Color(nsColor: .labelColor)
    // 2026-09-09: supporting text keeps its weight through the glass and
    // lamp compositing. Rendered before/after samples: mockups/simplicity/pass2.
    static let secondary  = Color(nsColor: .secondaryLabelColor)
    static let tertiary   = Color(nsColor: .tertiaryLabelColor)
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

    /// The one soft fill (rail selection, chips). Reads as 8%
    /// white on the warm dark and 8% ink on the warm light.
    // User, 2026-09-03: light reads flat on glass, so the fills and hairline
    // carry a step more contrast there than in dark.
    static let softFill   = primaryTint(dark: 0.08, light: 0.11)
    /// Quieter fill for the tool row and the search field.
    static let quietFill  = Color(nsColor: .quaternarySystemFill)
    /// The single hairline used by the composer and the quiet cards.
    static let hairline   = Color(nsColor: .separatorColor)

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
            // Agent, 2026-09-12: "keep a smaller, soft warm glow so we retain
            // the room's warmth." At 0.42 over 1200pt the lamp WAS the room's
            // colour; a third of the light over two thirds of the reach is a
            // lamp in the corner again, and the ground keeps its own family.
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.22),
                    Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.06),
                    .clear,
                ],
                // Where it sat when it was the room's own: a little left of
                // the room's centre, high. The room starts 348pt into the
                // window, so the same spot in window terms.
                center: UnitPoint(x: 0.38, y: 0.24),
                startRadius: 0,
                endRadius: 820
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
}

/// Shared page and shell roles: 11 metadata, 13 detail, 14 rows, 16 chat,
/// 20 detail headings and the approved 44 serif page door. Older display
/// and native control styles remain for surfaces outside the page kit.
/// Meaningful small text uses secondary ink over glass. The ramp uses
/// `Font.system` at the declared sizes; it has no text-size multiplier.
enum ShellType {
    // 10 measured 1.95:1 on the fold count in dark and 2.44 in light; 11 at
    // the secondary colour clears it (critique finding 5).
    static let captionSize: CGFloat = 11
    static let labelSize: CGFloat = 13
    static let bodySize: CGFloat = 16
    static let titleSize: CGFloat = 20
    static let displaySize: CGFloat = 25
    static let pageTitleSize: CGFloat = 44

    /// Codes and paths, and nothing else: keys, ids, file paths. Never for a
    /// label that happens to be short.
    static let code = Font.system(size: labelSize, design: .monospaced)
    static let caption = Font.system(size: captionSize)
    static let captionMedium = Font.system(size: captionSize, weight: .medium)
    static let captionSemibold = Font.system(size: captionSize, weight: .semibold)
    static let captionCode = Font.system(size: captionSize, design: .monospaced)
    static let captionCodeSemibold = Font.system(size: captionSize, weight: .semibold, design: .monospaced)
    /// 13 — list subtitle, rail words, tool rows, meta lines, buttons.
    static let label = Font.system(size: labelSize)
    static let labelMedium = Font.system(size: labelSize, weight: .medium)
    /// 14 — rail words and row titles, a step above their detail.
    static let railSize: CGFloat = 14
    static let rail = Font.system(size: railSize, weight: .medium)
    static let labelSemibold = Font.system(size: labelSize, weight: .semibold)
    /// The shared settings and content row: 14 medium over 13 regular.
    static let rowTitle = Font.system(size: railSize, weight: .medium)
    static let rowDetailSize = labelSize
    static let rowDetail = label
    static let pageSentence = Font.system(size: railSize)
    static let pageTitle = Font.system(size: pageTitleSize, design: .serif)
    /// 16 — body, list row title, card headline.
    static let body = Font.system(size: bodySize)
    static let bodyMedium = Font.system(size: bodySize, weight: .medium)
    static let bodySemibold = Font.system(size: bodySize, weight: .semibold)
    static let columnTitle = bodySemibold
    /// 20 — subordinate page and detail headings.
    static let title = Font.system(size: titleSize, weight: .semibold)
    /// Legacy rounded display for onboarding and older empty states.
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
        // 2026-09-12: the coat is what makes the ground one colour. At 0.46 more
        // than half the desktop came through unmodulated, so the same room
        // measured #3D3D44 under the lamp and #41432F over a green wallpaper —
        // an 18-point R-B swing across one page. Heavier, the room reads as the
        // room and the desktop is a movement in it, which is the bleed User
        // wanted without the colour cast he rejected.
        // 2026-10-09: light at 0.5 over the whitened material was a mid grey
        // that changed with the desktop; the heavier coat makes the light room
        // one colour too, and the bleed stays a movement in it.
        return dark ? 0.74 : 0.66
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
    /// The two chat column headings share the slim header's top inset.
    static let columnHeaderTopInset: CGFloat = 6
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
    // The one chat width.
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
    /// User, 2026-09-23 ("alive glass"): a generous round box, 16 -> 22.
    static let composerRadius: CGFloat = 22
    /// The rail's floating plate (2026-09-23).
    static let railPlateRadius: CGFloat = 18
    /// How far the plate floats in from the window's leading and bottom edges,
    /// and down from the title strip.
    static let railPlateInset: CGFloat = 10
    /// 16pt body at 1.6 line height → 9.6pt of extra leading.
    static let replyLineSpacing: CGFloat = 8
    /// The per-message action bar's height: 22pt buttons inside 4pt of
    /// vertical padding. Fluid glass A2: it is an overlay on the message's
    /// bottom edge and reserves nothing, so hover stays layout-neutral (the
    /// 2026-07-25 rule) without a 30pt strip under every bubble.
    static let hoverBarStrip: CGFloat = 30
    /// How far the hover bar reaches up over its own message's bottom edge;
    /// the rest hangs into the gap below, clear of the words (Agent,
    /// 2026-09-02: it must never land on text).
    static let hoverBarOverlap: CGFloat = 6
    /// Fluid glass A2: the one gap between transcript items — message and
    /// message, message and activity row, row and row. Every item carries a
    /// few points of its own vertical padding, so words sit ~24pt apart.
    static let transcriptGap: CGFloat = 16
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
