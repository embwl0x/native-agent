// VoiceOutputController.swift — TTS for NativeAgent iOS via AVSpeechSynthesizer
import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class VoiceOutputController: NSObject, ObservableObject {
    @Published var isSpeaking = false
    @Published var error: String?
    /// Spoken replies default to off; the person's saved choice takes precedence.
    @AppStorage("voiceOutputEnabled") var enabled = false

    // Create the synthesizer and prepare the audio session only when speech is requested.
    private var _synthesizer: AVSpeechSynthesizer?
    private var preparationTask: Task<Void, Never>?
    private var audioToken: UUID?
    /// True between a successful `setActive(true)` and the deactivation that
    /// follows the last utterance.
    private(set) var audioSessionActive = false
    private let configureAudioSession: @Sendable () throws -> Void
    private let activateAudioSession: @Sendable () throws -> Void
    /// Deactivate with `.notifyOthersOnDeactivation` to return the audio route to other apps.
    private let deactivateAudioSession: @Sendable () throws -> Void
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
    }

    @objc nonisolated private func audioSessionInterrupted(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleAudioSessionInterruption()
        }
    }

    // MARK: - Public API

    func speak(_ text: String) {
        guard enabled, !text.isEmpty, !isSpeaking, preparationTask == nil else { return }
        // Use the person's language preferences, as speech input does. A
        // missing installed voice is a failure, never an English substitution.
        guard let voice = Locale.preferredLanguages.lazy.compactMap({ AVSpeechSynthesisVoice(language: $0) }).first else {
            error = "No spoken-reply voice is available for your preferred languages."
            return
        }
        let token = UUID()
        audioToken = token
        preparationTask = Task {
            defer { preparationTask = nil }
            do {
                try await MobileDictation.shared.prepareOutput(token: token,
                    configure: configureAudioSession, activate: activateAudioSession)
                audioSessionActive = true
                guard !Task.isCancelled, audioToken == token, enabled else {
                    releaseAudioSessionIfIdle(); return
                }
                let synth = ensureSynthesizer()
                guard !synth.isSpeaking, !isSpeaking else { return }
                isSpeaking = true
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = voice
                utterance.rate = 0.50
                utterance.pitchMultiplier = 1.0
                utterance.volume = 1.0
                activeUtterance = utterance
                synth.speak(utterance)
                error = nil
            } catch {
                self.error = "Spoken reply could not start: \(error.localizedDescription)"
                finishPlayback()
            }
        }
    }

    /// Disabling spoken replies immediately stops current playback.
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
        isSpeaking = false
        releaseAudioSessionIfIdle()
    }

    private func finishPlayback(for utteranceID: ObjectIdentifier) {
        guard let activeUtterance, ObjectIdentifier(activeUtterance) == utteranceID else { return }
        finishPlayback()
    }

    /// Release an activated session while idle; a failed release remains owed at the next idle transition.
    private func releaseAudioSessionIfIdle() {
        guard audioSessionActive, !isSpeaking, let token = audioToken else { return }
        Task {
            do {
                try await MobileDictation.shared.releaseOutput(token: token, deactivate: deactivateAudioSession)
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
