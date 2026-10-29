import NativeAgentShared
import SwiftUI
import AppKit

// Blueprint: | `NativeAgentFeel.swift` | `NAInteractiveModifier` and `NAButtonStyle`: shared hover/press feedback vocabulary for interactive Mac surfaces |

// Clickable surfaces share one hover and press vocabulary.

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
                NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
                value: hovering
            )
            .onHover { hovering = $0 }
            // Recycled rows must not retain hover state.
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
    // Disabled buttons must not answer the cursor.
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovering && isEnabled ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .animation(
                NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .animation(
                NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
                value: hovering
            )
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == NAButtonStyle {
    /// `\.buttonStyle(.naFeel)` — the app-wide press/hover feel.
    static var naFeel: NAButtonStyle { NAButtonStyle() }
}
