import UIKit

// Send/finalization haptics are independent of Reduce Motion.
@MainActor
enum Haptics {
    /// Read capture ownership so reply/send haptics cannot buzz into an active microphone.
    static var isRecording: @MainActor () -> Bool = { false }
    static func send() {
        guard !isRecording(), !TalkModeController.shared.isPresented else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    static func replyFinalized() {
        guard !isRecording(), !TalkModeController.shared.isPresented else { return }
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
    }
}
