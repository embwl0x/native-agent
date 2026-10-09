import AppKit
import SwiftUI

/// Shared timing and transitions. Layout changes stop under Reduce Motion;
/// opacity transitions keep their own animation so content still crossfades.
enum NativeAgentMotion {
    static let quickDuration = 0.12
    static let standardDuration = 0.28
    static let springDuration = 0.35

    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static let crossfade = Animation.easeOut(duration: standardDuration)
    static var standard: Animation? { respecting(crossfade, reduceMotion: reducesMotion) }
    static var quick: Animation? {
        respecting(.easeOut(duration: quickDuration), reduceMotion: reducesMotion)
    }
    static var spring: Animation? {
        respecting(.spring(response: springDuration, dampingFraction: 0.88), reduceMotion: reducesMotion)
    }
    /// Fluid glass A2: a smooth spring, bounce 0 — for chrome that grows and
    /// shrinks in place (the composer tray). Off under Reduce Motion.
    static var glide: Animation? {
        respecting(.smooth(duration: springDuration), reduceMotion: reducesMotion)
    }
    /// A message landing in the transcript (wave 3, after Grok): 180ms
    /// ease-out-quint, which lands sooner and stops cleaner than `standard`.
    static let arrivalCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static var arrive: Animation? {
        respecting(arrivalCurve, reduceMotion: reducesMotion)
    }
    /// Opacity stays animated when Reduce Motion removes layout interpolation.
    static var arrivalFade: AnyTransition { .opacity.animation(arrivalCurve) }
    /// The reply's live, settled and folded phases share its arrival rhythm.
    static var replyDissolve: AnyTransition { arrivalFade }
    static let breathe = Animation.easeInOut(duration: standardDuration * 5)
    static var pulse: Animation? {
        respecting(breathe.repeatForever(autoreverses: false), reduceMotion: reducesMotion)
    }

    static func respecting(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static var fade: AnyTransition { .opacity.animation(crossfade) }

    /// Content swapped in place (fluid glass A1): the new fades in ease-out
    /// over the old, which fades out ease-in, so text the two share never
    /// dims (a plain crossfade dips it to 75% mid-way).
    static var dissolve: AnyTransition {
        .asymmetric(insertion: fade, removal: .opacity.animation(.easeIn(duration: standardDuration)))
    }

    /// A page or transcript swapped in place: the old goes in the same frame
    /// and only the new fades in, so two translucent layers of text never
    /// draw over each other.
    static var fadeIn: AnyTransition { .asymmetric(insertion: fade, removal: .identity) }

    /// A small row swapped in place: the old leaves first, then the new comes
    /// in, so two one-line rows never draw over each other.
    static var fadeThrough: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: quickDuration).delay(quickDuration)),
            removal: .opacity.animation(.easeOut(duration: quickDuration)))
    }

    static func reveal(reduceMotion: Bool = reducesMotion, anchor: UnitPoint = .top) -> AnyTransition {
        reduceMotion ? fade : .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
            .animation(spring)
    }

    static var arrival: AnyTransition {
        reducesMotion ? arrivalFade : .opacity.combined(with: .offset(y: 6))
    }
}

private struct MotionArrival: ViewModifier {
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .opacity(settled ? 1 : 0)
            .task {
                guard !settled else { return }
                withAnimation(NativeAgentMotion.crossfade) { settled = true }
            }
    }
}

extension View {
    /// A newly mounted onboarding step fades in once.
    func motionArrival() -> some View {
        modifier(MotionArrival())
    }
}
