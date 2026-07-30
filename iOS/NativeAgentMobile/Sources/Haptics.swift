import UIKit

// chat-smoothness phase 6: tiny, subtle haptic feedback for the iOS chat
// surface. Haptics are independent of Reduce Motion (that setting governs
// on-screen animation, not the Taptic Engine), so these fire unconditionally —
// kept deliberately light (.light impact on send, .soft success when a reply
// finalizes). NOT wired to per-tick typewriter advances; only to the two
// discrete moments a user expects a tap: pressing send, and the answer landing.
@MainActor
enum Haptics {
    /// Light tap the instant the user fires a message.
    static func send() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Soft confirmation tap when a reply finalizes (finishPlaceholder site —
    /// once per turn, never per streaming/typewriter tick).
    static func replyFinalized() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
    }
}
