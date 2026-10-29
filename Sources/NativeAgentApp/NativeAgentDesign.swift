import NativeAgentShared
import SwiftUI
import AppKit
// Blueprint: | `NativeAgentDesign.swift` | `View`: `settingsCardSurface`; centered shell layout and shared surfaces |

/// An eyebrow over the kit's shared card surface.
struct NativePanel<Content: View>: View {
    var title: String?
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

/// A status word in the room's state colours.
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

extension View {
    func sheetCloseButton() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .foregroundStyle(Color(nsColor: .controlTextColor))
            .accessibilityLabel("Close")
    }

    /// The kit's card on a settings section; callers own content and padding.
    func settingsCardSurface() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .aliveCard()
            .accessibilityElement(children: .contain)
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

extension EnvironmentValues {
    @Entry var houseGlassEnclosed: Bool = false
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
    /// Every authored plate shares clear glass, tinted black in dark and white in light.
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

// Shared design primitives.

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

// MARK: - The shell

/// Appearance-aware palette: views name room, rail, list and text roles.
enum NativeAgentShell {
    // Charcoal-slate in dark, paper in light; cards remain lighter than the room.
    static let room       = dynamic(dark: 0x12161F, light: 0xF7F6F3)
    static let rail       = dynamic(dark: 0x121315, light: 0xF3F2EF)
    static let list       = dynamic(dark: 0x17181B, light: 0xF5F4F1)
    // Text uses native system label colours.
    static let text       = Color(nsColor: .labelColor)
    static let secondary  = Color(nsColor: .secondaryLabelColor)
    static let tertiary   = Color(nsColor: .tertiaryLabelColor)
    // Light felt-state colours must clear 4.5:1 against the room, rail and cards.
    /// Teal is reserved for approval borders and the pending-approval status dot.
    static let needsYou   = dynamic(dark: 0x06B6D4, light: 0x0B5F76)
    /// Trouble — a dropped connection, a turn that failed.
    static let trouble    = dynamic(dark: 0xFF9F0A, light: 0x864800)
    /// Calm — she is up and answering.
    static let calm       = dynamic(dark: 0x34C759, light: 0x136224)

    /// Selection and chip fill: 8% white on dark, 11% black on light.
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
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}

/// Always-active behind-window material lets the desktop bleed through the shell.
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

/// Every column shares one material and tint; hairlines separate columns.
/// Reduce Transparency makes the sheet opaque.
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

/// A soft, edgeless warm glow in dark; the tint coat owns text contrast.
struct ShellLamp: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.22),
                    Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.06),
                    .clear,
                ],
                // The glow stays high and left of the window's centre.
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

/// Fixed system-font roles; meaningful small text uses secondary ink over glass.
enum ShellType {
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
    /// Rounded display for onboarding and empty states.
    static let display = Font.system(size: displaySize, weight: .semibold, design: .rounded)
}

/// Shared shell geometry: a 740pt room holds a 708pt reply and two 16pt gutters.
enum NativeAgentShellLayout {
    // The rail accommodates full 14pt labels.
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
    /// Appearance-specific tint keeps the ground coherent while allowing desktop bleed.
    @MainActor static var roomGlassTint: Double {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? 0.74 : 0.66
    }
    /// Full-height glass runs behind the transparent title bar; content clears its traffic lights.
    static let titleBarInset: CGFloat = 28
    /// The two chat column headings share the slim header's top inset.
    static let columnHeaderTopInset: CGFloat = 6
    /// The list column, edge to edge.
    static let conversationsWidth: CGFloat = 288
    /// The list's inner gutter — the content inside `conversationsWidth`.
    static let conversationsInset: CGFloat = 12
    /// One list row, fixed. 46 + the 2pt gap between rows = a 48pt pitch,
    /// two 24pt units, the same pitch the rail already runs (44 + 4).
    static let listRowHeight: CGFloat = 46
    // The room grows to the text measure plus gutters; the composer spans the column.
    static let roomColumn: CGFloat = 740
    static let replyMaxWidth: CGFloat = 708
    /// The gutter inside the room column: header, transcript and working card
    /// wear it, and it is also the composer's own inner padding.
    static let roomGutter: CGFloat = 16
    static var roomLeadingInset: CGFloat { roomGutter }
    static var roomTrailingInset: CGFloat { roomGutter }
    static let roomAlignment: Alignment = .top
    static let userBubbleMaxWidth: CGFloat = 640
    static let composerRadius: CGFloat = 22
    /// The rail's floating plate.
    static let railPlateRadius: CGFloat = 18
    /// How far the plate floats in from the window's leading and bottom edges,
    /// and down from the title strip.
    static let railPlateInset: CGFloat = 10
    /// Extra leading between reply lines.
    static let replyLineSpacing: CGFloat = 8
    /// The 30pt action bar overlays the message's bottom edge without reserving layout space.
    static let hoverBarStrip: CGFloat = 30
    /// Overlap into the message's bottom edge; the rest stays in the gap, clear of text.
    static let hoverBarOverlap: CGFloat = 6
    /// One gap between all transcript items, in addition to each item's own padding.
    static let transcriptGap: CGFloat = 16
    /// Breathing room between the last line of the transcript and the top of
    /// the floating composer.
    static let composerClearanceMargin: CGFloat = 12
    static let userBubbleCorners = RectangleCornerRadii(
        topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14
    )
}

struct NativeEmptyState: View {
    var title: String
    var detail: String
    var actionTitle: String?
    var actionIsDisabled = false
    var action: (() -> Void)?

    /// The empty state's words and optional action, aligned to the page.
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
