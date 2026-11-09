import NativeAgentShared
import SwiftUI
import AppKit
// Blueprint: | `NativeAgentDesign.swift` | `View`: `settingsCardSurface`; centered shell layout and shared surfaces |

extension View {
    func sheetCloseButton() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .foregroundStyle(Color(nsColor: .controlTextColor))
            .accessibilityLabel("Close")
    }

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

enum HouseGlass {
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


/// Use glass only for floating chat chrome; content cards use aliveCard.
struct GlassCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    var body: some View {
        // Use opaque fill for quiet screenshots because bitmap rendering blanks tinted glass.
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
    static let room       = dynamic(dark: 0x12161F, light: 0xF7F6F3)
    static let rail       = dynamic(dark: 0x121315, light: 0xF3F2EF)
    static let list       = dynamic(dark: 0x17181B, light: 0xF5F4F1)
    static let text       = Color(nsColor: .labelColor)
    static let secondary  = Color(nsColor: .secondaryLabelColor)
    static let tertiary   = Color(nsColor: .tertiaryLabelColor)
    // Clear 4.5:1 on every shell surface; reserve teal for approvals.
    static let needsYou   = dynamic(dark: 0x06B6D4, light: 0x0B5F76)
    static let trouble    = dynamic(dark: 0xFF9F0A, light: 0x864800)
    static let calm       = dynamic(dark: 0x34C759, light: 0x136224)

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

    private static func dynamic(dark: UInt, light: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
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
    static let bodySize: CGFloat = 16
    static let titleSize: CGFloat = 20
    static let displaySize: CGFloat = 25
    static let pageTitleSize: CGFloat = 44

    /// Reserve monospaced roles for codes, keys and paths so ordinary short labels keep the prose ramp.
    static let code = Font.system(size: labelSize, design: .monospaced)
    static let caption = Font.system(size: captionSize)
    static let captionMedium = Font.system(size: captionSize, weight: .medium)
    static let captionSemibold = Font.system(size: captionSize, weight: .semibold)
    static let captionCode = Font.system(size: captionSize, design: .monospaced)
    static let captionCodeSemibold = Font.system(size: captionSize, weight: .semibold, design: .monospaced)
    static let label = Font.system(size: labelSize)
    static let labelMedium = Font.system(size: labelSize, weight: .medium)
    static let railSize: CGFloat = 14
    static let rail = Font.system(size: railSize, weight: .medium)
    static let labelSemibold = Font.system(size: labelSize, weight: .semibold)
    static let rowTitle = Font.system(size: railSize, weight: .medium)
    static let rowDetail = label
    static let pageSentence = Font.system(size: railSize)
    static let pageTitle = Font.system(size: pageTitleSize, design: .serif)
    static let body = Font.system(size: bodySize)
    static let bodyMedium = Font.system(size: bodySize, weight: .medium)
    static let bodySemibold = Font.system(size: bodySize, weight: .semibold)
    static let columnTitle = bodySemibold
    static let title = Font.system(size: titleSize, weight: .semibold)
    static let display = Font.system(size: displaySize, weight: .semibold, design: .rounded)
}

/// A 740pt room fits the 708pt reply plus two 16pt gutters.
enum NativeAgentShellLayout {
    static let railWidth: CGFloat = 112
    static let railItemHeight: CGFloat = 44
    static let barInset: CGFloat = 4
    /// Bound composer room to five input lines, controls and attachments so a bad measurement cannot consume the transcript.
    static let composerClearanceMax: CGFloat = 320
    static let railWordInset: CGFloat = 14
    @MainActor static var roomGlassTint: Double {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? 0.74 : 0.66
    }
    static let titleBarInset: CGFloat = 28
    static let columnHeaderTopInset: CGFloat = 6
    static let conversationsWidth: CGFloat = 288
    static let conversationsInset: CGFloat = 12
    /// Use a 48pt row pitch (46 + 2 gap) to match the rail's two 24pt units.
    static let listRowHeight: CGFloat = 46
    static let roomColumn: CGFloat = 740
    static let replyMaxWidth: CGFloat = 708
    static let roomGutter: CGFloat = 16
    static var roomLeadingInset: CGFloat { roomGutter }
    static var roomTrailingInset: CGFloat { roomGutter }
    static let roomAlignment: Alignment = .top
    static let userBubbleMaxWidth: CGFloat = 640
    static let composerRadius: CGFloat = 22
    static let railPlateRadius: CGFloat = 18
    static let railPlateInset: CGFloat = 10
    static let replyLineSpacing: CGFloat = 8
    static let hoverBarStrip: CGFloat = 30
    static let transcriptGap: CGFloat = 16
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
