import Foundation
import Observation
import UIKit
import Speech
import AVFoundation
import os
import NativeAgentShared
// Blueprint: | `VoiceInputController.swift` | Session-bound capture; recognition completion or cancellation settles the draft |

enum VoiceInputAuthorizationPresentation {
    static func speechFailureMessage(
        for status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined:
            return "Speech recognition permission was not resolved. The iOS permission prompt may not be available right now; open Settings and try again."
        case .restricted:
            return "Speech recognition is restricted on this device. Check Screen Time restrictions and Settings."
        case .denied:
            return VoicePresentation.deniedSpeechMessage()
        case .authorized:
            return "Speech recognition permission is required. Open Settings and try again."
        @unknown default:
            return "Speech recognition permission could not be confirmed. Open Settings and try again."
        }
    }
}

@MainActor
@Observable
final class VoiceInputController {
    var isListening = false
    var isStarting = false
    var transcript = ""
    var lastFinalTranscript = ""
    var error: String?
    var statusText: String?
    var hasReceivedAudio = false
    var isFinalizing: Bool { waitingForFinalAfterStop }
    var isVoiceNote = false
    var isLocked = false
    var startedAt: Date?
    var levels: [Float] = []

    @ObservationIgnored private var audioToken: UUID?
    @ObservationIgnored private var hasRecognitionTask = false
    @ObservationIgnored private var desiredListening = false
    @ObservationIgnored private var startGeneration = UUID()
    @ObservationIgnored private var finalizingGeneration: UUID?
    private var waitingForFinalAfterStop = false
    @ObservationIgnored private var hasStartedAudioSession = false
    @ObservationIgnored private var utterance: SpeechUtterance?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private let requestSpeechAuthorization: () async -> SFSpeechRecognizerAuthorizationStatus
    @ObservationIgnored private let requestMicrophoneAuthorization: () async -> Bool

    init(
        requestSpeechAuthorization: @escaping () async -> SFSpeechRecognizerAuthorizationStatus = { await VoiceInputController.requestSpeechAuthorization() },
        requestMicrophoneAuthorization: @escaping () async -> Bool = { await VoiceInputController.requestMicrophonePermission() }
    ) {
        self.requestSpeechAuthorization = requestSpeechAuthorization
        self.requestMicrophoneAuthorization = requestMicrophoneAuthorization
        Haptics.isRecording = { [weak self] in self?.isListening == true }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    // MARK: - Public API

    func begin(voiceNote: Bool, names: [String]) {
        startTask?.cancel()
        startTask = Task { await start(voiceNote: voiceNote, names: names) }
    }

    func start(voiceNote: Bool = false, names: [String] = []) async {
        guard !TalkModeController.shared.isPresented else { return }
        guard !Task.isCancelled, !isStarting, !waitingForFinalAfterStop else { return }
        // Cancel prior capture before starting so rapid presses cannot leak audio engines.
        if hasRecognitionTask { teardownAudio(cancelTask: true) }
        startGeneration = UUID()
        finalizingGeneration = nil
        let generation = startGeneration
        isStarting = true
        isVoiceNote = voiceNote
        isLocked = false
        startedAt = nil
        levels = []
        desiredListening = true
        waitingForFinalAfterStop = false
        hasStartedAudioSession = false
        error = nil
        statusText = "Requesting speech recognition permission..."
        transcript = ""
        lastFinalTranscript = ""
        utterance = nil
        hasReceivedAudio = false
        defer {
            if generation == startGeneration, !isListening {
                isStarting = false
            }
        }

        let speechStatus = await requestSpeechAuthorization()
        guard desiredListening, generation == startGeneration else { return }
        guard speechStatus == .authorized else {
            desiredListening = false
            error = VoiceInputAuthorizationPresentation.speechFailureMessage(for: speechStatus)
            statusText = nil
            return
        }

        // Microphone and speech recognition require independent authorization.
        statusText = "Requesting microphone permission..."
        let micGranted = await requestMicrophoneAuthorization()
        guard desiredListening, generation == startGeneration else { return }
        guard micGranted else {
            desiredListening = false
            error = VoicePresentation.deniedMicrophoneMessage()
            statusText = nil
            return
        }

        let token = UUID()
        audioToken = token
        do {
            let preparationError = try await MobileDictation.shared.prepareInput(token: token, names: names, onAudio: { [weak self] in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation
                        || (self.waitingForFinalAfterStop && self.finalizingGeneration == generation) else { return }
                    self.hasReceivedAudio = true
                    if self.transcript.isEmpty { self.statusText = "Hearing you..." }
                }
            }, onLevel: { [weak self, generation] rms in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation, self.isListening else { return }
                    self.pushLevel(rms)
                }
            }, onResult: { [weak self, generation] utterance in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation
                        || (self.waitingForFinalAfterStop && self.finalizingGeneration == generation) else { return }
                    self.utterance = utterance
                    self.transcript = utterance.text
                    if self.waitingForFinalAfterStop && utterance.isFinal { self.publishStoppedTranscript() }
                }
            }, onError: { [weak self, generation] detail in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation
                        || (self.waitingForFinalAfterStop && self.finalizingGeneration == generation) else { return }
                    guard let detail else { return }
                    self.error = detail
                    self.waitingForFinalAfterStop = false
                    self.desiredListening = false
                    self.teardownAudio(cancelTask: true)
                }
            })
            guard desiredListening, generation == startGeneration else {
                do { try await MobileDictation.shared.stopInput(token: token, cancelTask: true) }
                catch { self.error = "Cancelled voice input could not release audio: \(error.localizedDescription)" }
                return
            }
            if let preparationError {
                desiredListening = false
                teardownAudio(cancelTask: true)
                self.error = preparationError
                statusText = nil
                return
            }
        } catch {
            guard desiredListening, generation == startGeneration else { return }
            teardownAudio(cancelTask: true)
            self.error = "Microphone could not start: \(error.localizedDescription)"
            statusText = nil
            return
        }
        hasRecognitionTask = true

        // Start capture only after recognition is ready to consume its buffers.
        do {
            try await MobileDictation.shared.startInput(token: token)
            hasStartedAudioSession = true
        } catch {
            guard desiredListening, generation == startGeneration else { return }
            teardownAudio(cancelTask: true)
            self.error = "Audio engine failed to start: \(error.localizedDescription)"
            statusText = nil
            return
        }
        guard desiredListening, generation == startGeneration else {
            do { try await MobileDictation.shared.stopInput(token: token, cancelTask: true) }
            catch { self.error = "Cancelled voice input could not release audio: \(error.localizedDescription)" }
            return
        }

        isListening = true
        isStarting = false
        startedAt = Date()
        if isVoiceNote { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        error = nil
        statusText = hasReceivedAudio && transcript.isEmpty ? "Hearing you..." : "Listening..."
    }

    /// Map roughly -50 through -10 dBFS to 0...1 because that span covers speech levels.
    private func pushLevel(_ rms: Float) {
        let decibels = 20 * log10(max(rms, 0.000_01))
        levels.append(min(1, max(0, (decibels + 50) / 40)))
        if levels.count > 96 { levels.removeFirst(levels.count - 96) }
    }

    /// End capture on touch-up; only recognition completion publishes the final words.
    func stop() {
        guard !waitingForFinalAfterStop else { return }
        let hadRecordingSession = isListening || hasStartedAudioSession
        if !hadRecordingSession { startTask?.cancel() }
        desiredListening = false
        finalizingGeneration = hadRecordingSession ? startGeneration : nil
        startGeneration = UUID()
        waitingForFinalAfterStop = hadRecordingSession
        teardownAudio(cancelTask: !hadRecordingSession)
        isListening = false
        isStarting = false
        statusText = hadRecordingSession ? "Waiting for final recognition · Cancel to discard" : nil
        guard hadRecordingSession else {
            waitingForFinalAfterStop = false
            return
        }
    }

    func lock() {
        guard isVoiceNote, isListening, !isLocked else { return }
        isLocked = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cancel() {
        desiredListening = false
        startGeneration = UUID()
        finalizingGeneration = nil
        startTask?.cancel()
        waitingForFinalAfterStop = false
        isLocked = false
        lastFinalTranscript = ""; transcript = ""
        teardownAudio(cancelTask: true)
    }

    private func publishStoppedTranscript() {
        guard waitingForFinalAfterStop else { return }
        startGeneration = UUID()
        finalizingGeneration = nil
        guard let utterance, !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            waitingForFinalAfterStop = false
            if error == nil {
                error = hasReceivedAudio
                    ? "No words were recognized. Try speaking a little longer."
                    : "No microphone audio detected. Check iOS microphone privacy and the selected audio route."
            }
            teardownAudio(cancelTask: true)
            return
        }
        // Only recognized words travel; never export or upload the captured audio.
        lastFinalTranscript = utterance.text
        waitingForFinalAfterStop = false
        teardownAudio(cancelTask: true)
    }

    // MARK: - Private

    private func teardownAudio(cancelTask: Bool) {
        if cancelTask { hasRecognitionTask = false }
        if let token = audioToken {
            let generation = startGeneration
            Task {
                do { try await MobileDictation.shared.stopInput(token: token, cancelTask: cancelTask) }
                catch {
                    guard self.startGeneration == generation else { return }
                    self.error = "Voice input could not finish: \(error.localizedDescription)"
                    self.waitingForFinalAfterStop = false
                }
            }
            if cancelTask { audioToken = nil }
        }
        isListening = false
        isStarting = false
        hasStartedAudioSession = false
        statusText = nil
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// iOS calls back on its own queue; defining this callback inside MainActor would trigger an isolation trap.
    nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
actor MobileDictation {
    static let shared = MobileDictation()
    private var engine: AVAudioEngine?
    private var inputToken: UUID?
    private var routeToken: UUID?
    private var tapInstalled = false
    private var modern: MobileSpeechAnalyzer?

    /// Release ordinary audio ownership before Talk prepares so pending cleanup cannot close the new call session.
    func prepareForTalk() async throws {
        if let inputToken { try await stopInput(token: inputToken, cancelTask: true) }
        if routeToken != nil {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            routeToken = nil
        }
    }

    func prepareInput(token: UUID, names: [String], onAudio: @escaping @Sendable () -> Void,
                      onLevel: @escaping @Sendable (Float) -> Void,
                      onResult: @escaping @Sendable (SpeechUtterance) -> Void,
                      onError: @escaping @Sendable (String?) -> Void) async throws -> String? {
        if let inputToken { try await stopInput(token: inputToken, cancelTask: true) }
        try Task.checkCancellation()
        inputToken = token
        routeToken = token
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "No usable microphone input route was found." }
        let locale = await MobileSpeechAnalyzer.supportedLocale()
        guard inputToken == token, !Task.isCancelled else { throw CancellationError() }
        guard let locale else {
            return """
                On-device speech recognition does not support this device or language. Choose a supported iPhone language in Settings before trying voice \
                input again.
                """
        }
        let modern = try await MobileSpeechAnalyzer(locale: locale, sourceFormat: format, names: names)
        guard inputToken == token, !Task.isCancelled else { await modern.cancel(); throw CancellationError() }
        self.modern = modern
        modern.start(onResult: onResult, onError: onError)
        let hasReceivedAudio = OSAllocatedUnfairLock(initialState: false)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do { try modern.append(buffer) }
            catch { onError(error.localizedDescription); return }
            var rms: Float = 0
            if let data = buffer.floatChannelData?.pointee, buffer.frameLength > 0 {
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
                rms = sqrt(sum / Float(buffer.frameLength))
            }
            onLevel(rms)
            let firstAudibleBuffer = hasReceivedAudio.withLockUnchecked { received in
                guard !received, rms > 0.002 else { return false }
                received = true
                return true
            }
            if firstAudibleBuffer { onAudio() }
        }
        tapInstalled = true
        return nil
    }

    func startInput(token: UUID) throws {
        guard inputToken == token, let engine else { throw CancellationError() }
        engine.prepare()
        try engine.start()
    }

    func stopInput(token: UUID, cancelTask: Bool) async throws {
        guard inputToken == token else { return }
        if cancelTask { inputToken = nil }
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine?.stop()
        engine = nil
        var routeError: Error?
        if routeToken == token {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { routeError = error }
            routeToken = nil
        }
        let analyzer = modern
        if cancelTask { modern = nil; await analyzer?.cancel() }
        else { try await analyzer?.finish() }
        if let routeError { throw routeError }
    }


    func prepareOutput(token: UUID, configure: @Sendable () throws -> Void,
                       activate: @Sendable () throws -> Void) throws {
        try configure()
        try activate()
        routeToken = token
    }

    func releaseOutput(token: UUID, deactivate: @Sendable () throws -> Void) throws {
        guard routeToken == token else { return }
        try deactivate()
        routeToken = nil
    }
}
