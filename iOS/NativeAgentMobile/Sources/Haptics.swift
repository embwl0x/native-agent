import UIKit

// Haptics mark send and reply finalization, independently of Reduce Motion.
@MainActor
enum Haptics {
    /// Read the capture owner; never buzz a reply or another send into its mic.
    static var isRecording: @MainActor () -> Bool = { false }
    /// Light tap the instant the user fires a message.
    static func send() {
        guard !isRecording(), !TalkModeController.shared.isPresented else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Soft confirmation when receiveTerminalReply finalizes a reply, once per turn.
    static func replyFinalized() {
        guard !isRecording(), !TalkModeController.shared.isPresented else { return }
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
    }
}
