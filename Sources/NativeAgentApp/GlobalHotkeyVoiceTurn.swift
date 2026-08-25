import Foundation

/// Owns one global-hotkey push-to-talk turn from authorization through the
/// same `AppModel.sendChat` boundary used by the visible composer. The Carbon
/// callbacks are intentionally thin: a second release, a release before TCC
/// resolves, or an unavailable capture can never manufacture a text turn.
@MainActor
final class GlobalHotkeyVoiceTurn {
    enum Outcome: Equatable {
        case listening
        case duplicateStartIgnored
        case permissionRefused(String)
        case releasedBeforeCapture
        case captureUnavailable(String)
        case noActiveCapture
        case discardedEmptyTranscript
        case submitted(AppModel.ChatTurnAcceptance)
        case submissionRejected(String)
    }

    private let requestPermission: () async -> Bool
    private let permissionFailureMessage: () -> String?
    private let isVoiceHoldCurrent: () -> Bool
    /// Returns a visible reason when the audio engine cannot actually begin.
    private let beginCapture: () -> String?
    private let stopCapture: () async -> String
    private let captureFailureMessage: () -> String?
    private let submitTurn: (String) async -> AppModel.ChatTurnAcceptance
    private let reportUnavailable: (String) -> Void
    private let reportRejectedTurn: (String) -> Void

    private var awaitingPermission = false
    private var captureActive = false
    private var captureFinishing = false

    init(
        requestPermission: @escaping () async -> Bool,
        permissionFailureMessage: @escaping () -> String?,
        isVoiceHoldCurrent: @escaping () -> Bool,
        beginCapture: @escaping () -> String?,
        stopCapture: @escaping () async -> String,
        captureFailureMessage: @escaping () -> String?,
        submitTurn: @escaping (String) async -> AppModel.ChatTurnAcceptance,
        reportUnavailable: @escaping (String) -> Void,
        reportRejectedTurn: @escaping (String) -> Void
    ) {
        self.requestPermission = requestPermission
        self.permissionFailureMessage = permissionFailureMessage
        self.isVoiceHoldCurrent = isVoiceHoldCurrent
        self.beginCapture = beginCapture
        self.stopCapture = stopCapture
        self.captureFailureMessage = captureFailureMessage
        self.submitTurn = submitTurn
        self.reportUnavailable = reportUnavailable
        self.reportRejectedTurn = reportRejectedTurn
    }

    /// Called only after the press state has crossed the hold threshold.
    func beginVoiceTurn() async -> Outcome {
        // `stopListening` waits for the recognizer's final result. A fresh
        // hold during that flush cannot reuse the previous audio engine as a
        // second capture.
        guard !awaitingPermission, !captureActive, !captureFinishing else {
            return .duplicateStartIgnored
        }

        awaitingPermission = true
        defer { awaitingPermission = false }

        guard await requestPermission() else {
            let message = permissionFailureMessage() ?? "Microphone or speech recognition permission was not granted."
            reportUnavailable(message)
            return .permissionRefused(message)
        }

        // A user may release while the TCC prompt is visible. Do not begin a
        // late recording that has no matching key-up event to finish it.
        guard isVoiceHoldCurrent() else {
            return .releasedBeforeCapture
        }

        if let message = beginCapture() {
            reportUnavailable(message)
            return .captureUnavailable(message)
        }

        captureActive = true
        return .listening
    }

    /// Finishes exactly one capture. A duplicate Carbon key-up is harmless;
    /// it cannot append an orphaned duplicate message to the conversation.
    func endVoiceTurn() async -> Outcome {
        guard captureActive else { return .noActiveCapture }
        captureActive = false
        captureFinishing = true
        defer { captureFinishing = false }

        let capturedTranscript = await stopCapture()
        let transcript = capturedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            if let message = captureFailureMessage(), !message.isEmpty {
                reportUnavailable(message)
                return .captureUnavailable(message)
            }
            return .discardedEmptyTranscript
        }

        let acceptance = await submitTurn(transcript)
        if case .rejected(let message) = acceptance {
            reportRejectedTurn(message)
            return .submissionRejected(message)
        }
        return .submitted(acceptance)
    }
}
