import EngineRuntime
import MacIntegration
import AppKit
import ChatTurnRuntime

// Blueprint: | `VoiceInputController.swift` | `VoiceInputCapture.forChat`: binds agent-name recognition context, person-visible macOS speech authorization and shared user-facing failures |

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
