import Foundation
import Testing
@testable import NativeAgentApp

/// The setting is owned by the durable Trust Center policy, not UserDefaults.
/// Fixture policy bytes are decoded through the production model before the
/// shared selector used by both auto-read and per-message read-aloud runs.
@MainActor
@Suite("OpenAI voice setting")
struct VoiceUseOpenAISettingEvalTests {
    // EVAL FENCE: app.chat / setting.voiceUseOpenAI
    @Test("loaded Trust policy is the only OpenAI voice mode source")
    func voiceModeFollowsTheLoadedTrustPolicyWithoutPreferenceDrift() throws {
        func loadedPolicy(ttsOpenAI: Bool) throws -> TrustPolicy {
            let data = Data("""
            {"permissionLevel":"balanced","multimodalPolicy":{"tts_openai":\(ttsOpenAI)}}
            """.utf8)
            return try JSONDecoder().decode(TrustPolicy.self, from: data)
        }

        let enabled = try loadedPolicy(ttsOpenAI: true)
        let disabled = try loadedPolicy(ttsOpenAI: false)

        #expect(enabled.multimodalPolicy?.tts_openai == true)
        #expect(VoiceOutputModeSelection.mode(for: enabled) == .openai)
        #expect(VoiceOutputModeSelection.resolve(for: enabled) == .openAI)

        #expect(disabled.multimodalPolicy?.tts_openai == false)
        #expect(VoiceOutputModeSelection.mode(for: disabled) == .local)
        #expect(VoiceOutputModeSelection.resolve(for: disabled) == .localConfigured)

        // An unavailable policy cannot inherit an old preference and claim
        // OpenAI playback; the shared selector fails closed to the Mac voice.
        #expect(VoiceOutputModeSelection.mode(for: nil) == .local)
        let unavailable = VoiceOutputModeSelection.resolve(for: nil)
        #expect(unavailable == .localPolicyUnavailable)
        #expect(unavailable.notice?.contains("unavailable") == true)
    }
}
