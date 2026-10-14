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
    /// Quiet by default (2026-09-13). A fresh phone install used to speak
    /// every reply aloud before the person had asked for a voice at all; the
    /// speaker button is right there when they want one. An existing explicit
    /// choice is untouched — @AppStorage only uses this default when no value
    /// has been written, and `setEnabled` writes one on every toggle.
    @AppStorage("voiceOutputEnabled") var enabled = false

    // 2026-05-09 fix: lazy-init the synthesizer and audio session.  Eagerly
    // creating AVSpeechSynthesizer + setting AVAudioSession category at app
    // launch was contributing to startup main-thread pressure (alongside the
    // iCloudBridge.setup() block that triggered a kernel-watchdog panic).
    // The synthesizer is heavy enough on first construction that deferring it
    // to first speak() call shaves seconds off cold launch.
    private var _synthesizer: AVSpeechSynthesizer?
    private var preparationTask: Task<Void, Never>?
    private var audioToken: UUID?
    /// True between a successful `setActive(true)` and the deactivation that
    /// follows the last utterance.
    private(set) var audioSessionActive = false
    private let configureAudioSession: @Sendable () throws -> Void
    private let activateAudioSession: @Sendable () throws -> Void
    /// E5: leaving the session active after the last utterance keeps the audio
    /// route held and suppresses other apps' audio indefinitely. Deactivating
    /// with `.notifyOthersOnDeactivation` hands the route back.
    private let deactivateAudioSession: @Sendable () throws -> Void
    private var playbackState: VoiceOutputPlaybackState = .idle
    private var activeUtterance: AVSpeechUtterance?

    init(
        configureAudioSession: @escaping @Sendable () throws -> Void = {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers]
            )
        },
        activateAudioSession: @escaping @Sendable () throws -> Void = {
            try AVAudioSession.sharedInstance().setActive(true)
        },
        deactivateAudioSession: @escaping @Sendable () throws -> Void = {
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        // Intentionally NO synth init or AVAudioSession setup here — see comment above.
    }

    @objc nonisolated private func audioSessionInterrupted(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleAudioSessionInterruption()
        }
    }

    // MARK: - Public API

    func speak(_ text: String) {
        guard enabled, !text.isEmpty, playbackState == .idle, preparationTask == nil else { return }
        let token = UUID()
        audioToken = token
        preparationTask = Task {
            defer { preparationTask = nil }
            do {
                try await MobileAudioService.shared.prepareOutput(token: token,
                    configure: configureAudioSession, activate: activateAudioSession)
                audioSessionActive = true
                guard !Task.isCancelled, audioToken == token, enabled else {
                    releaseAudioSessionIfIdle(); return
                }
                let synth = ensureSynthesizer()
                guard !synth.isSpeaking, playbackState.beginIfIdle() else { return }
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                utterance.rate = 0.50
                utterance.pitchMultiplier = 1.0
                utterance.volume = 1.0
                activeUtterance = utterance
                synth.speak(utterance)
                error = nil
                isSpeaking = playbackState.isSpeaking
            } catch {
                self.error = "Spoken reply could not start: \(error.localizedDescription)"
                finishPlayback()
            }
        }
    }

    /// 2026-09-06: `enabled` was only consulted when an utterance STARTS, so
    /// tapping the speaker off mid-reply left the agent talking to the end.
    /// Turning it off silences what is already playing.
    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { stop() }
    }

    func stop() {
        preparationTask?.cancel()
        _synthesizer?.stopSpeaking(at: .immediate)
        finishPlayback()
    }

    func handleAudioSessionInterruption() {
        preparationTask?.cancel()
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

    private func finishPlayback() {
        activeUtterance = nil
        playbackState.finish()
        isSpeaking = playbackState.isSpeaking
        releaseAudioSessionIfIdle()
    }

    private func finishPlayback(for utteranceID: ObjectIdentifier) {
        guard let activeUtterance, ObjectIdentifier(activeUtterance) == utteranceID else { return }
        finishPlayback()
    }

    /// E5: hand the audio route back once nothing is speaking. Only meaningful
    /// if we actually activated the session; a failure leaves the flag set so
    /// the next idle transition retries rather than silently keeping the route.
    private func releaseAudioSessionIfIdle() {
        guard audioSessionActive, playbackState == .idle, let token = audioToken else { return }
        Task {
            do {
                try await MobileAudioService.shared.releaseOutput(token: token, deactivate: deactivateAudioSession)
                if audioToken == token { audioSessionActive = false }
            } catch {
                NSLog("[VoiceOutputController] audio session deactivate failed: %@", error.localizedDescription)
            }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceOutputController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in self.finishPlayback(for: utteranceID) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in self.finishPlayback(for: utteranceID) }
    }
}
