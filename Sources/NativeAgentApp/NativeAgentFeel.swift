import NativeAgentShared
import SwiftUI
import AppKit

// Blueprint: | `NativeAgentFeel.swift` | `NAInteractiveModifier` and `NAButtonStyle`: shared hover/press feedback vocabulary for interactive Mac surfaces |


// MARK: - Hover-responsive rows/cards

/// Use this modifier for gesture rows; buttons already receive press feedback from NAButtonStyle.
private struct NAInteractiveModifier: ViewModifier {
    var radius: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0))  // Stronger hover contrast keeps busy rows readable.
            )
            .animation(
                NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
                value: hovering
            )
            .onHover { hovering = $0 }
            // Clear hover when recycling rows so reused content cannot inherit another row's state.
            .onDisappear { hovering = false }
    }
}

extension View {
    func naInteractive(radius: CGFloat = NativeAgentRadius.panel) -> some View {
        modifier(NAInteractiveModifier(radius: radius))
    }
}

// MARK: - Global button feel

/// Leave label fills intact so shared press/hover feedback cannot replace per-button styling.
struct NAButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Disabled buttons must not respond to the cursor.
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
    static var naFeel: NAButtonStyle { NAButtonStyle() }
}
