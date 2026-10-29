import UIKit

// Haptics mark send and reply finalization, independently of Reduce Motion.
@MainActor
enum Haptics {
    /// Light tap the instant the user fires a message.
    static func send() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Soft confirmation when receiveTerminalReply finalizes a reply, once per turn.
    static func replyFinalized() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
    }
}
