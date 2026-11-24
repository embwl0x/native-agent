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

    static let quickCurve = Animation.easeOut(duration: quickDuration)
    static let crossfade = Animation.easeOut(duration: standardDuration)
    static var standard: Animation? { respecting(crossfade, reduceMotion: reducesMotion) }
    static var quick: Animation? {
        respecting(quickCurve, reduceMotion: reducesMotion)
    }
    static var spring: Animation? {
        respecting(.spring(response: springDuration, dampingFraction: 0.88), reduceMotion: reducesMotion)
    }
    /// Reduce Motion disables layout motion without disabling fades.
    static var glide: Animation? {
        respecting(.smooth(duration: springDuration), reduceMotion: reducesMotion)
    }
    static let arrivalCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static let breatheDuration = standardDuration * 5
    /// Read the clock through TimelineView; repeatForever can crash during repeating motion.
    static func loopPhase(at date: Date, period: TimeInterval) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }

    static func respecting(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static var fade: AnyTransition { .opacity.animation(crossfade) }


    /// Remove the old page immediately so translucent text layers never overlap.
    static var fadeIn: AnyTransition { .asymmetric(insertion: fade, removal: .identity) }


    static func reveal(reduceMotion: Bool = reducesMotion, anchor: UnitPoint = .top) -> AnyTransition {
        reduceMotion ? fade : .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
            .animation(spring)
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
