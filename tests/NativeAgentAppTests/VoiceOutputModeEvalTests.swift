import Foundation
import MultimodalTTS
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / voice.output.mode
@Suite("Voice output mode runtime boundary")
struct VoiceOutputModeEvalTests {
    @Test("the decoded Trust policy selects the only remote output route")
    func configuredOpenAIAndLocalModesRemainDistinct() throws {
        let openAI = try policy(ttsOpenAI: true)
        let local = try policy(ttsOpenAI: false)

        #expect(VoiceOutputModeSelection.resolve(for: openAI) == .openAI)
        #expect(VoiceOutputModeSelection.resolve(for: openAI).mode == .openai)
        #expect(VoiceOutputModeSelection.resolve(for: local) == .localConfigured)
        #expect(VoiceOutputModeSelection.resolve(for: local).mode == .local)
        #expect(VoiceOutputModeSelection.resolve(for: local).notice == nil)
    }

    @Test("missing policy fails closed to local output with observable provenance")
    func unavailablePolicyCannotImpersonateConfiguredLocalMode() {
        let resolution = VoiceOutputModeSelection.resolve(for: nil)

        #expect(resolution == .localPolicyUnavailable)
        #expect(resolution.mode == .local)
        #expect(resolution.notice?.contains("Voice policy is unavailable") == true)
    }

    @MainActor
    @Test("a selected remote mode falls back only for an honest preflight refusal")
    func preflightFailureKeepsPlaybackLocalAndReportsWhy() async {
        let output = VoiceOutputController(openAISynthesis: { _ in
            throw MultimodalTTSError.notConfigured
        })

        await output.speak(text: "Voice preflight evaluation", resolution: .openAI)

        #expect(output.isSpeaking)
        #expect(output.errorMessage?.contains("API key") == true)
        output.stop()
    }

    private func policy(ttsOpenAI: Bool) throws -> TrustPolicy {
        try JSONDecoder().decode(TrustPolicy.self, from: Data("""
        {"permissionLevel":"balanced","multimodalPolicy":{"tts_openai":\(ttsOpenAI)}}
        """.utf8))
    }
}
