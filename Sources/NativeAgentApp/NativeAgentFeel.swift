import SwiftUI
import AppKit

// Liquid Feel Pass W1 (2026-08-16, docs/build_plans/liquid-feel-pass.md).
// The ONE shared interaction vocabulary: every clickable surface answers the
// cursor the same way. No layout or IA changes ride in this file.

// MARK: - Hover-responsive rows/cards

/// Hover highlight + optional press scale for any interactive row or card.
/// Rows that are Buttons get press feedback from NAButtonStyle instead;
/// this modifier is for List/row/card surfaces with tap gestures or
/// NavigationLink-style selection.
private struct NAInteractiveModifier: ViewModifier {
    var radius: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0))  // 0.07->0.09: User wants the sessions-style roll to READ on busier pages
            )
            .animation(
                NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                value: hovering
            )
            .onHover { hovering = $0 }
            // Lazy containers recycle rows by identity — a row scrolled away
            // while hovered must not reappear pre-lit (gpt-5.5 MED).
            .onDisappear { hovering = false }
    }
}

extension View {
    /// Shared hover feel for interactive rows and cards.
    func naInteractive(radius: CGFloat = NativeAgentRadius.panel) -> some View {
        modifier(NAInteractiveModifier(radius: radius))
    }
}

// MARK: - Global button feel

/// Press scale + hover brightness for every button that opts in. Uses the
/// label as-is (no fills imposed) so existing per-button styling survives —
/// this style adds FEEL, not appearance.
struct NAButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Disabled buttons must not answer the cursor (gpt-5.5 LOW).
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovering && isEnabled ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .animation(
                NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .animation(
                NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                value: hovering
            )
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == NAButtonStyle {
    /// `\.buttonStyle(.naFeel)` — the app-wide press/hover feel.
    static var naFeel: NAButtonStyle { NAButtonStyle() }
}

// MARK: - Liquid Glass chrome

/// Glass treatment for CHROME surfaces (sidebar, composer, toolbars,
/// overlays). Content surfaces keep their existing materials.
/// Deployment floor is macOS 26 (User 2026-08-16), so no availability gates.
extension View {
    /// Regular Liquid Glass in a continuous rounded rect.
    func naGlassChrome(radius: CGFloat = NativeAgentRadius.panel) -> some View {
        glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }

    /// Interactive Liquid Glass (responds to pointer) — for the composer and
    /// floating controls.
    func naGlassInteractive(radius: CGFloat = NativeAgentRadius.panel) -> some View {
        glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }
}
