import Testing
@testable import NativeAgentApp

@MainActor
private final class VoicePermissionRequestProbe {
    var calls = 0
    var result: VoiceInputPermissionResult

    init(result: VoiceInputPermissionResult) {
        self.result = result
    }

    func request() async -> VoiceInputPermissionResult {
        calls += 1
        return result
    }
}

/// Exercises the controller boundary used by ChatView.toggleVoice without
/// consulting this machine's TCC state or opening a real permission prompt.
@MainActor
@Suite("Chat voice input")
struct ChatVoiceInputEvalTests {
    // EVAL FENCE: app.chat / api.ChatView.voiceInput
    @Test("voice permission requests report granted, denied, and unresolved outcomes honestly")
    func voiceInputPermissionIsAnAttemptNotACaptureSuccessClaim() async {
        let grantedProbe = VoicePermissionRequestProbe(result: .granted)
        let granted = VoiceInputController(permissionRequest: { await grantedProbe.request() })

        #expect(await granted.requestPermission())
        #expect(grantedProbe.calls == 1)
        #expect(granted.permissionGranted)
        #expect(granted.errorMessage == nil)
        // `toggleVoice` calls startListening only after this point. A TCC
        // success alone must never appear as an active microphone session.
        #expect(!granted.isListening)

        let deniedProbe = VoicePermissionRequestProbe(result: .microphoneDenied)
        let denied = VoiceInputController(permissionRequest: { await deniedProbe.request() })
        #expect(!(await denied.requestPermission()))
        #expect(deniedProbe.calls == 1)
        #expect(!denied.permissionGranted)
        #expect(!denied.isListening)
        #expect(denied.errorMessage?.contains("Microphone access denied") == true)

        let unresolvedProbe = VoicePermissionRequestProbe(result: .speechNotDetermined)
        let unresolved = VoiceInputController(permissionRequest: { await unresolvedProbe.request() })
        #expect(!(await unresolved.requestPermission()))
        #expect(unresolvedProbe.calls == 1)
        #expect(!unresolved.permissionGranted)
        #expect(!unresolved.isListening)
        #expect(unresolved.errorMessage?.contains("not resolved") == true)
    }
}
