import AppKit
import SwiftUI

// Blueprint: | `NativeAgentMotion.swift` | `NativeAgentMotion`: shared transitions; Reduce Motion stops layout, retains fades |

/// Reduce Motion stops layout interpolation while opacity keeps content transitions legible.
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
    /// Reduce Motion disables layout motion without disabling fades.
    static var glide: Animation? {
        respecting(.smooth(duration: springDuration), reduceMotion: reducesMotion)
    }
    static let arrivalCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static var arrive: Animation? {
        respecting(arrivalCurve, reduceMotion: reducesMotion)
    }
    /// Opacity stays animated when Reduce Motion removes layout interpolation.
    static var arrivalFade: AnyTransition { .opacity.animation(arrivalCurve) }
    /// Reply phases share the arrival rhythm so transitions stay coherent.
    static var replyDissolve: AnyTransition { arrivalFade }
    static let breatheDuration = standardDuration * 5
    static let breathe = Animation.easeInOut(duration: breatheDuration)
    /// Read the clock through TimelineView; repeatForever can crash during repeating motion.
    static func loopPhase(at date: Date, period: TimeInterval) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }

    static func respecting(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static var fade: AnyTransition { .opacity.animation(crossfade) }

    /// New content fades in ease-out over the old fading out ease-in, keeping shared text bright.
    static var dissolve: AnyTransition {
        .asymmetric(insertion: fade, removal: .opacity.animation(.easeIn(duration: standardDuration)))
    }

    /// Remove the old page immediately so translucent text layers never overlap.
    static var fadeIn: AnyTransition { .asymmetric(insertion: fade, removal: .identity) }

    /// Remove the old row before inserting the new one so their text never overlaps.
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
    func motionArrival() -> some View {
        modifier(MotionArrival())
    }
}
