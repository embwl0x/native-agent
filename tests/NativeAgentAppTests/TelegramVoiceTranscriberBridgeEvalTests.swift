import Foundation
import Testing
import TelegramBot
@testable import NativeAgentApp

/// Executable app-assembly proof for coverage row
/// `app.bridges / telegram.voiceTranscriber`.
///
/// The silent failure class is a Telegram config that appears to enable voice
/// but yields no transcriber, or selects an implementation that can make a
/// headless permission request. This drives the real assembly factory with its
/// saved-config value object; it never reads a live token, TCC grant, or data
/// root.
@Suite("app.bridges · Telegram voice transcriber")
struct TelegramVoiceTranscriberBridgeEvalTests {
    private func config(
        enabled: Bool = true,
        backend: String = TelegramVoiceTranscriptionBackends.appleSpeech,
        model: String = TelegramVoiceTranscriptionBackends.appleSpeechModel
    ) -> TelegramBot.TelegramConfig {
        TelegramBot.TelegramConfig(
            botToken: "test-token",
            allowedChatIds: [42],
            enabled: true,
            voiceTranscriptionEnabled: enabled,
            voiceTranscriptionBackend: backend,
            voiceTranscriptionModel: model
        )
    }

    @Test func assemblySelectsExactlyTheConfiguredSupportedBackend() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-voice-bridge-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(BackgroundLoopsAssembly.makeTelegramVoiceTranscriber(
            cfg: config(enabled: false), dataRoot: root
        ) == nil)

        let apple = BackgroundLoopsAssembly.makeTelegramVoiceTranscriber(
            cfg: config(backend: "local"), dataRoot: root
        )
        #expect(apple is SwiftAppleSpeechTranscriber,
                "Apple aliases must resolve to the non-prompting Apple Speech transcriber")

        #expect(BackgroundLoopsAssembly.makeTelegramVoiceTranscriber(
            cfg: config(backend: "unsupported-backend"), dataRoot: root
        ) is SwiftAppleSpeechTranscriber,
                "Apple Speech is the only backend; an unknown value falls back to it")
    }
}
