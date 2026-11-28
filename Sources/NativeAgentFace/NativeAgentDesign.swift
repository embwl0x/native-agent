import NativeAgentShared
import SwiftUI
import AppKit
// Blueprint: | `NativeAgentDesign.swift` | Centered shell layout and shared surfaces |

extension View {
    func sheetCloseButton() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .foregroundStyle(Color(nsColor: .controlTextColor))
            .accessibilityLabel("Close")
    }

    func houseInset<S: InsettableShape>(in shape: S, fill: Color = TodayPalette.cardFill) -> some View {
        modifier(HouseInset(shape: shape, fill: fill))
    }

    func houseSheet() -> some View {
        presentationBackground(TodayPalette.cardFill)
    }
}

private struct HouseInset<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? NativeAgentShell.hairline : TodayPalette.cardStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct HouseGlassContainer<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    var body: some View {
        if quietOffscreenRead {
            content()
        } else {
            GlassEffectContainer(spacing: spacing, content: content)
        }
    }
}

enum HouseGlass {
    static let plate: Glass = .clear.tint(plateTint)
    private static let plateTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.28)
            : NSColor.white.withAlphaComponent(0.58)
    })
}

extension View {
    func houseSurface<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        opaqueFill: Color? = TodayPalette.cardFill
    ) -> some View {
        modifier(HouseSurface(shape: shape, interactive: interactive, opaqueFill: opaqueFill))
    }
}

private struct HouseSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let opaqueFill: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        let opaque = reduceTransparency || quietOffscreenRead
        let showRim = (opaque && opaqueFill != nil) || contrast == .increased || activeState == .inactive
        content
            .background {
                if opaque, let opaqueFill { shape.fill(opaqueFill) }
            }
            .glassEffect(opaque ? .identity : HouseGlass.plate.interactive(interactive), in: shape)
            .overlay {
                if showRim {
                    shape.stroke(opaque && contrast != .increased ? TodayPalette.cardStroke : NativeAgentShell.hairline, lineWidth: 1)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
            }
    }
}


struct TurnCardSurface<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    var body: some View {
        let opaque = reduceTransparency || quietOffscreenRead
        let shape = RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
        let edgeColor = tint ?? Color.primary
        let edgeOpacity = tint != nil
            ? (colorSchemeContrast == .increased ? 0.72 : 0.34)
            : (colorSchemeContrast == .increased ? 0.28 : 0.10)

        content()
            .padding(NativeAgentLayout.cardPadding)
            .background(opaque ? Color(nsColor: .controlBackgroundColor) : TodayPalette.cardFill, in: shape)
            .overlay {
                shape.strokeBorder(edgeColor.opacity(edgeOpacity), lineWidth: colorSchemeContrast == .increased ? 1 : 0.75)
                    .allowsHitTesting(false)
            }
    }
}

/// Keep persistent status indicators static by default so idle lists cannot animate continuously.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    var animates: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shouldAnimate = animates && !reduceMotion

        ZStack {
            if shouldAnimate {
                // Draw from the clock to avoid repeatForever layout recursion.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let t = NativeAgentMotion.loopPhase(at: context.date, period: NativeAgentMotion.breatheDuration)
                    let eased = t * t * (3 - 2 * t)
                    Circle().fill(color.opacity(0.35))
                        .frame(width: size * 2.2, height: size * 2.2)
                        .scaleEffect(0.5 + 0.5 * eased)
                        .opacity(0.6 * (1 - eased))
                }
            }
            Circle().fill(color)
                .frame(width: size, height: size)
                .shadow(color: shouldAnimate ? color.opacity(0.45) : .clear, radius: shouldAnimate ? 2 : 0)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - The shell

enum NativeAgentShell {
    static let room       = Color.adaptive(dark: 0x12161F, light: 0xF7F6F3)
    static let rail       = Color.adaptive(dark: 0x121315, light: 0xF3F2EF)
    static let list       = Color.adaptive(dark: 0x17181B, light: 0xF5F4F1)
    static let text       = Color(nsColor: .labelColor)
    static let secondary  = Color(nsColor: .secondaryLabelColor)
    static let tertiary   = Color(nsColor: .tertiaryLabelColor)
    // Clear 4.5:1 on every shell surface; reserve teal for approvals.
    static let needsYou   = Color.adaptive(dark: 0x06B6D4, light: 0x0B5F76)
    static let trouble    = Color.adaptive(dark: 0xFF9F0A, light: 0x864800)
    static let calm       = Color.adaptive(dark: 0x34C759, light: 0x136224)

    static let softFill   = primaryTint(dark: 0.08, light: 0.11)
    static let quietFill  = Color(nsColor: .quaternarySystemFill)
    static let hairline   = Color(nsColor: .separatorColor)

    /// Use appearance-specific primary alpha so fills and hairlines stay weighted in light mode.
    private static func primaryTint(dark: Double, light: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor.white.withAlphaComponent(dark) : NSColor.black.withAlphaComponent(light)
        })
    }
}

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

struct ShellSheet: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if reduceTransparency || quietOffscreenRead {
                NativeAgentShell.room
            } else {
                ShellGlass(material: .underWindowBackground)
                NativeAgentShell.room.opacity(colorScheme == .dark ? 0.74 : 0.66)
            }
        }
        .ignoresSafeArea()
    }
}

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

enum ShellType {
    static let captionSize: CGFloat = 11
    static let labelSize: CGFloat = 13
    static let railSize: CGFloat = 14
    static let bodySize: CGFloat = 16
    static let titleSize: CGFloat = 20
    static let displaySize: CGFloat = 25
    static let pageTitleSize: CGFloat = 44

    static func scaled(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        Font.system(.body, design: design, weight: weight).scaled(by: size / labelSize)
    }

    static let caption = scaled(captionSize)
    static let captionMedium = scaled(captionSize, weight: .medium)
    static let captionSemibold = scaled(captionSize, weight: .semibold)
    static let label = scaled(labelSize)
    static let labelMedium = scaled(labelSize, weight: .medium)
    static let rail = scaled(railSize, weight: .medium)
    static let labelSemibold = scaled(labelSize, weight: .semibold)
    static let pageSentence = scaled(railSize)
    static let pageTitle = scaled(pageTitleSize, design: .serif)
    static let body = scaled(bodySize)
    static let bodyMedium = scaled(bodySize, weight: .medium)
    static let bodySemibold = scaled(bodySize, weight: .semibold)
    static let columnTitle = bodySemibold
    static let title = scaled(titleSize, weight: .semibold)
    static let display = scaled(displaySize, weight: .semibold, design: .rounded)
}

/// A 740pt room fits the 708pt reply plus two 16pt gutters.
enum NativeAgentShellLayout {
    static let railWidth: CGFloat = 112
    static let railItemHeight: CGFloat = 44
    static let barInset: CGFloat = 4
    /// Bound composer room to five input lines, controls and attachments so a bad measurement cannot consume the transcript.
    static let composerClearanceMax: CGFloat = 320
    static let railWordInset: CGFloat = 14
    static let titleBarInset: CGFloat = 28
    static let columnHeaderTopInset: CGFloat = 6
    static let columnHeaderMinHeight: CGFloat = 28
    static let conversationsWidth: CGFloat = 288
    static let conversationsInset: CGFloat = 12
    /// Use a 48pt row pitch (46 + 2 gap) to match the rail's two 24pt units.
    static let listRowHeight: CGFloat = 46
    static let roomColumn: CGFloat = NativeAgentSpacing.chatRoomWidth
    static let replyMaxWidth: CGFloat = 708
    static let roomGutter: CGFloat = 16
    static var roomLeadingInset: CGFloat { roomGutter }
    static var roomTrailingInset: CGFloat { roomGutter }
    static let roomAlignment: Alignment = .top
    static let composerRadius: CGFloat = 22
    static let railPlateRadius: CGFloat = 18
    static let railPlateInset: CGFloat = 10
    static let replyLineSpacing: CGFloat = 8
    static let hoverBarStrip: CGFloat = 30
    static let composerClearanceMargin: CGFloat = 12
    static let userBubbleCorners = RectangleCornerRadii(
        topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14
    )
}

struct NativeEmptyState: View {
    var title: String
    var detail: String

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
        }
        .padding(NativeAgentSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
