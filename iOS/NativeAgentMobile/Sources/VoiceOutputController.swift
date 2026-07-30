// VoiceOutputController.swift — TTS for NativeAgent iOS via AVSpeechSynthesizer
import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class VoiceOutputController: NSObject, ObservableObject {
    @Published var isSpeaking = false
    @AppStorage("voiceOutputEnabled") var enabled = true

    // 2026-05-09 fix: lazy-init the synthesizer and audio session.  Eagerly
    // creating AVSpeechSynthesizer + setting AVAudioSession category at app
    // launch was contributing to startup main-thread pressure (alongside the
    // iCloudBridge.setup() block that triggered a kernel-watchdog panic).
    // The synthesizer is heavy enough on first construction that deferring it
    // to first speak() call shaves seconds off cold launch.
    private var _synthesizer: AVSpeechSynthesizer?
    private var audioSessionConfigured = false

    override init() {
        super.init()
        // Intentionally NO synth init or AVAudioSession setup here — see comment above.
    }

    // MARK: - Public API

    func speak(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        let synth = ensureSynthesizer()
        ensureAudioSession()
        // Cancel any in-flight speech so the new reply takes priority
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        try? AVAudioSession.sharedInstance().setActive(true)
        synth.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        _synthesizer?.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Lazy initializers

    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let s = _synthesizer { return s }
        let s = AVSpeechSynthesizer()
        s.delegate = self
        _synthesizer = s
        return s
    }

    private func ensureAudioSession() {
        audioSessionConfigured = true
        // Configure playback category so TTS plays even when the phone is in
        // silent mode.  Apple's mute switch still applies at the hardware level
        // on physical devices — we intentionally do NOT override it.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers]
        )
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceOutputController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
