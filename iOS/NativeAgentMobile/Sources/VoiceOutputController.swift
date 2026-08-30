// VoiceOutputController.swift — TTS for NativeAgent iOS via AVSpeechSynthesizer
import Foundation
import SwiftUI
import AVFoundation

enum VoiceOutputPlaybackState: Equatable {
    case idle
    case speaking

    var isSpeaking: Bool { self == .speaking }

    mutating func beginIfIdle() -> Bool {
        guard self == .idle else { return false }
        self = .speaking
        return true
    }

    mutating func finish() {
        self = .idle
    }
}

@MainActor
final class VoiceOutputController: NSObject, ObservableObject {
    @Published var isSpeaking = false
    @Published var error: String?
    @AppStorage("voiceOutputEnabled") var enabled = true

    // 2026-05-09 fix: lazy-init the synthesizer and audio session.  Eagerly
    // creating AVSpeechSynthesizer + setting AVAudioSession category at app
    // launch was contributing to startup main-thread pressure (alongside the
    // iCloudBridge.setup() block that triggered a kernel-watchdog panic).
    // The synthesizer is heavy enough on first construction that deferring it
    // to first speak() call shaves seconds off cold launch.
    private var _synthesizer: AVSpeechSynthesizer?
    private var audioSessionConfigured = false
    /// True between a successful `setActive(true)` and the deactivation that
    /// follows the last utterance.
    private(set) var audioSessionActive = false
    private let configureAudioSession: () throws -> Void
    private let activateAudioSession: () throws -> Void
    /// E5: leaving the session active after the last utterance keeps the audio
    /// route held and suppresses other apps' audio indefinitely. Deactivating
    /// with `.notifyOthersOnDeactivation` hands the route back.
    private let deactivateAudioSession: () throws -> Void
    private var playbackState: VoiceOutputPlaybackState = .idle
    private var interruptionObserver: NSObjectProtocol?

    init(
        configureAudioSession: @escaping () throws -> Void = {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers]
            )
        },
        activateAudioSession: @escaping () throws -> Void = {
            try AVAudioSession.sharedInstance().setActive(true)
        },
        deactivateAudioSession: @escaping () throws -> Void = {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    ) {
        self.configureAudioSession = configureAudioSession
        self.activateAudioSession = activateAudioSession
        self.deactivateAudioSession = deactivateAudioSession
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption()
            }
        }
        // Intentionally NO synth init or AVAudioSession setup here — see comment above.
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - Public API

    func speak(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        // A reply may arrive while the prior one is still audible. Keep that
        // state honest: do not queue a second utterance just because the UI
        // asked to speak again.
        guard playbackState == .idle else { return }
        let synth = ensureSynthesizer()
        guard ensureAudioSession() else { return }
        guard !synth.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        do {
            try activateAudioSession()
            audioSessionActive = true
        } catch {
            self.error = "Spoken reply could not start: \(error.localizedDescription)"
            finishPlayback()
            return
        }
        guard playbackState.beginIfIdle() else { return }
        synth.speak(utterance)
        error = nil
        isSpeaking = playbackState.isSpeaking
    }

    func stop() {
        _synthesizer?.stopSpeaking(at: .immediate)
        finishPlayback()
    }

    func handleAudioSessionInterruption() {
        _synthesizer?.stopSpeaking(at: .immediate)
        finishPlayback()
    }

    // MARK: - Lazy initializers

    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let s = _synthesizer { return s }
        let s = AVSpeechSynthesizer()
        s.delegate = self
        _synthesizer = s
        return s
    }

    private func ensureAudioSession() -> Bool {
        audioSessionConfigured = true
        // Configure playback category so TTS plays even when the phone is in
        // silent mode.  Apple's mute switch still applies at the hardware level
        // on physical devices — we intentionally do NOT override it.
        do {
            try configureAudioSession()
            return true
        } catch {
            self.error = "Spoken reply could not start: \(error.localizedDescription)"
            finishPlayback()
            return false
        }
    }

    private func finishPlayback() {
        playbackState.finish()
        isSpeaking = playbackState.isSpeaking
        releaseAudioSessionIfIdle()
    }

    /// E5: hand the audio route back once nothing is speaking. Only meaningful
    /// if we actually activated the session; a failure leaves the flag set so
    /// the next idle transition retries rather than silently keeping the route.
    private func releaseAudioSessionIfIdle() {
        guard audioSessionActive, playbackState == .idle else { return }
        do {
            try deactivateAudioSession()
            audioSessionActive = false
        } catch {
            NSLog("[VoiceOutputController] audio session deactivate failed: %@",
                  error.localizedDescription)
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceOutputController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishPlayback() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishPlayback() }
    }
}
