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
    static let entrance = Animation.easeOut(duration: 0.22)

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
    static let identityTitle = Font.system(.title2, design: .rounded, weight: .semibold)
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
    static let panelPadding: CGFloat = NativeAgentSpacing.lg
    static let cardPadding: CGFloat = NativeAgentSpacing.lg
    static let maxReadableChatWidth: CGFloat = 760
    static let maxReadableContentWidth: CGFloat = 900
    static let maxEmptyStateTextWidth: CGFloat = 360
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
    /// Bright cyan-400 — light stop for hero/title gradients.
    static let accentBright  = Color(hex: 0x22D3EE)
    /// Sky-400 — cool blue counter-tone for multi-stop gradients + glows.
    static let accentCool    = Color(hex: 0x38BDF8)

    /// Primary fill gradient (user bubble, send button): cyan-500 → deep cyan-700.
    static var fillGradient: [Color] { [accent, accentDeep] }
}

// PATCH-2026-05-07: ui-polish NativePanel — added tint parameter for accent border
struct NativePanel<Content: View>: View {
    var title: String?
    var systemImage: String?
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let edgeColor = tint ?? Color.primary
        let edgeOpacity = tint != nil
            ? (colorSchemeContrast == .increased ? 0.72 : 0.34)
            : (colorSchemeContrast == .increased ? 0.28 : 0.10)

        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            if let title {
                HStack(spacing: NativeAgentSpacing.sm) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(tint ?? .secondary)
                    }
                    Text(title)
                        .font(NativeAgentFont.section)
                    Spacer()
                }
            }
            content()
        }
        .padding(NativeAgentLayout.panelPadding)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                    .fill(.thinMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(
                    edgeColor.opacity(edgeOpacity),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                )
        }
    }
}

// PATCH-2026-05-07: ui-polish StatusBadge — vibrant colors + subtle glow
struct StatusBadge: View {
    var text: String
    var status: String?

    var body: some View {
        let color = NativeAgentTheme.statusColor(status)
        Text(text)
            .font(NativeAgentFont.label)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct InfoPill: View {
    var text: String
    var systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}

extension View {
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
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let edgeColor = tint ?? Color.primary
        let edgeOpacity = tint != nil
            ? (colorSchemeContrast == .increased ? 0.72 : 0.34)
            : (colorSchemeContrast == .increased ? 0.28 : 0.10)

        content()
            .padding(NativeAgentLayout.cardPadding)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                        .fill(.thinMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                    .strokeBorder(
                        edgeColor.opacity(edgeOpacity),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
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

struct NativeEmptyState: View {
    var title: String
    var detail: String
    var systemImage: String
    var actionTitle: String?
    var actionImage: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: NativeAgentSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(NativeAgentBrand.accentDeep)
                .frame(width: 36, height: 36)

            VStack(spacing: NativeAgentSpacing.xs) {
                Text(title)
                    .font(NativeAgentFont.section)
                if !detail.isEmpty {
                    Text(detail)
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: NativeAgentLayout.maxEmptyStateTextWidth)
                }
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionImage ?? "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
