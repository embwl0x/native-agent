import EngineRuntime
import MacIntegration
import AppKit
import ChatOrchestration

extension VoiceInputCapture {
    @MainActor
    static func forChat() -> VoiceInputCapture {
        VoiceInputCapture(
            recognitionContext: { [AgentVoice.live.name] },
            requestSpeechAuthorization: {
                NSApp.activate(ignoringOtherApps: true)
                return await SystemPermissionPreflight.awaitSpeechAuthorization()
            },
            failureMessage: { UserFacingError.message($0, action: $1) }
        )
    }
}
