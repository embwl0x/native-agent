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
    static let breathe = Animation.easeInOut(duration: standardDuration * 5)
    static var pulse: Animation? {
        respecting(breathe.repeatForever(autoreverses: false), reduceMotion: reducesMotion)
    }

    static func respecting(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static var fade: AnyTransition { .opacity.animation(crossfade) }

    static func reveal(reduceMotion: Bool = reducesMotion, anchor: UnitPoint = .top) -> AnyTransition {
        reduceMotion ? fade : .opacity.combined(with: .scale(scale: 0.97, anchor: anchor))
            .animation(spring)
    }

    static var arrival: AnyTransition {
        reducesMotion ? fade : .opacity.combined(with: .offset(y: 6))
    }
}

private struct MotionArrival: ViewModifier {
    let ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .opacity(!ready || settled ? 1 : 0)
            .offset(y: !ready || settled || reduceMotion ? 0 : 6)
            .task(id: ready) {
                guard ready, !settled else { return }
                withAnimation(NativeAgentMotion.crossfade) { settled = true }
            }
    }
}

extension View {
    /// One entrance after the first read, retaining loading UI and local state.
    /// Later refreshes do not replay the whole page's entrance.
    func motionArrival(when ready: Bool = true) -> some View {
        modifier(MotionArrival(ready: ready))
    }
}
