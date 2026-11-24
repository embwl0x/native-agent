import BodyRuntime
import MacNerves
import AppKit

// Blueprint: | `VoiceInputController.swift` | `VoiceInputCapture.forChat`: name context, macOS speech consent and shared failures |

extension VoiceInputCapture {
    @MainActor
    static func forChat() -> VoiceInputCapture {
        VoiceInputCapture(
            recognitionContext: { [AgentVoice.live.name] },
            requestSpeechAuthorization: {
                NSApp.activate()
                return await SystemPermissionPreflight.awaitSpeechAuthorization()
            },
            failureMessage: { UserFacingError.message($0, action: $1) }
        )
    }
}
