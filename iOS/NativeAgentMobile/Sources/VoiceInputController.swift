// VoiceInputController.swift — voice input for NativeAgent iOS
// Uses SFSpeechRecognizer + AVAudioEngine, mirroring the Mac pattern but
// touch-driven rather than hotkey-driven.
import Foundation
import Observation
import UIKit
import Speech
import AVFoundation
import os
import NativeAgentShared

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
    var transcript = ""         // live partial transcript
    var lastFinalTranscript = "" // populated when user releases
    var lastAttachment: MultimodalAttachment?
    var error: String?
    var statusText: String?
    var hasReceivedAudio = false

    @ObservationIgnored private var audioToken: UUID?
    @ObservationIgnored private var hasRecognitionTask = false
    @ObservationIgnored private var desiredListening = false
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var waitingForFinalAfterStop = false
    @ObservationIgnored private var finalResultTimeout: Task<Void, Never>?
    @ObservationIgnored private var hasStartedAudioSession = false
    @ObservationIgnored private var utterance: SpeechUtterance?
    @ObservationIgnored private let requestSpeechAuthorization: () async -> SFSpeechRecognizerAuthorizationStatus
    @ObservationIgnored private let requestMicrophoneAuthorization: () async -> Bool

    init(
        requestSpeechAuthorization: @escaping () async -> SFSpeechRecognizerAuthorizationStatus = { await VoiceInputController.requestSpeechAuthorization() },
        requestMicrophoneAuthorization: @escaping () async -> Bool = { await VoiceInputController.requestMicrophonePermission() }
    ) {
        self.requestSpeechAuthorization = requestSpeechAuthorization
        self.requestMicrophoneAuthorization = requestMicrophoneAuthorization

        // Stop cleanly when the app backgrounds (e.g. home-button press mid-hold)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    // MARK: - Public API

    func start() async {
        guard !isStarting, !waitingForFinalAfterStop else { return }
        // If already listening, cancel the previous session first so we never
        // leak the audio engine across multiple rapid presses.
        finalResultTimeout?.cancel()
        finalResultTimeout = nil
        if hasRecognitionTask { teardownAudio(cancelTask: true) }
        startGeneration += 1
        let generation = startGeneration
        isStarting = true
        desiredListening = true
        waitingForFinalAfterStop = false
        hasStartedAudioSession = false
        error = nil
        statusText = "Requesting speech recognition permission..."
        transcript = ""
        lastFinalTranscript = ""
        lastAttachment = nil
        utterance = nil
        hasReceivedAudio = false
        defer {
            if generation == startGeneration, !isListening {
                isStarting = false
            }
        }

        // 1. Speech recognition auth
        let speechStatus = await requestSpeechAuthorization()
        guard desiredListening, generation == startGeneration else { return }
        guard speechStatus == .authorized else {
            desiredListening = false
            error = VoiceInputAuthorizationPresentation.speechFailureMessage(for: speechStatus)
            statusText = nil
            return
        }

        // 2. Microphone auth (required separately on iOS 17+)
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
            let preparationError = try await MobileAudioService.shared.prepareInput(token: token, onAudio: { [weak self] in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation
                        || (self.waitingForFinalAfterStop && self.startGeneration == generation + 1) else { return }
                    self.hasReceivedAudio = true
                    if self.transcript.isEmpty { self.statusText = "Hearing you..." }
                }
            }, onResult: { [weak self, generation] utterance in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation
                        || (self.waitingForFinalAfterStop && self.startGeneration == generation + 1) else { return }
                    self.utterance = utterance
                    self.transcript = utterance.text
                    if self.waitingForFinalAfterStop && utterance.isFinal { self.publishStoppedTranscript() }
                }
            }, onError: { [weak self, generation] detail in
                Task { @MainActor in
                    guard let self, self.startGeneration == generation
                        || (self.waitingForFinalAfterStop && self.startGeneration == generation + 1) else { return }
                    if let detail { self.error = detail }
                    if self.waitingForFinalAfterStop { self.publishStoppedTranscript() }
                    else if detail != nil { self.teardownAudio(cancelTask: true) }
                }
            })
            guard desiredListening, generation == startGeneration else {
                teardownAudio(cancelTask: true); return
            }
            if let preparationError {
                desiredListening = false
                teardownAudio(cancelTask: true)
                self.error = preparationError
                statusText = nil
                return
            }
        } catch {
            teardownAudio(cancelTask: true)
            self.error = "Microphone could not start: \(error.localizedDescription)"
            statusText = nil
            return
        }
        hasRecognitionTask = true

        // 6. Start engine after the recognition task is ready to consume buffers.
        do {
            try await MobileAudioService.shared.startInput(token: token)
            hasStartedAudioSession = true
        } catch {
            teardownAudio(cancelTask: true)
            self.error = "Audio engine failed to start: \(error.localizedDescription)"
            statusText = nil
            return
        }
        guard desiredListening, generation == startGeneration else {
            teardownAudio(cancelTask: true)
            return
        }

        isListening = true
        isStarting = false
        error = nil
        statusText = hasReceivedAudio && transcript.isEmpty ? "Hearing you..." : "Listening..."
    }

    /// End audio on touch-up, then allow recognition to finalize before publishing.
    func stop() {
        guard !waitingForFinalAfterStop else { return }
        let hadRecordingSession = isListening || hasStartedAudioSession
        desiredListening = false
        startGeneration += 1
        waitingForFinalAfterStop = hadRecordingSession
        teardownAudio(cancelTask: !hadRecordingSession)
        isListening = false
        isStarting = false
        statusText = nil
        guard hadRecordingSession else {
            waitingForFinalAfterStop = false
            return
        }
        let stopGeneration = startGeneration
        finalResultTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 900_000_000) }
            catch { return }
            guard let self, self.startGeneration == stopGeneration,
                  self.waitingForFinalAfterStop else { return }
            self.publishStoppedTranscript()
        }
    }

    private func publishStoppedTranscript() {
        guard waitingForFinalAfterStop else { return }
        finalResultTimeout?.cancel()
        finalResultTimeout = nil
        startGeneration += 1
        let generation = startGeneration
        guard let token = audioToken, let utterance, !utterance.text.isEmpty else {
            waitingForFinalAfterStop = false
            if error == nil {
                error = hasReceivedAudio
                    ? "No words were recognized. Try speaking a little longer."
                    : "No microphone audio detected. Check iOS microphone privacy and the selected audio route."
            }
            teardownAudio(cancelTask: true)
            return
        }
        Task {
            do {
                let attachment = try await MobileAudioService.shared.finishInput(token: token, utterance: utterance)
                guard startGeneration == generation else { return }
                lastAttachment = attachment
                lastFinalTranscript = utterance.text
            } catch {
                guard startGeneration == generation else { return }
                self.error = "Couldn't retain voice audio: \(error.localizedDescription)"
            }
            waitingForFinalAfterStop = false
            teardownAudio(cancelTask: true)
        }
    }

    // MARK: - Private

    private func teardownAudio(cancelTask: Bool) {
        if cancelTask { hasRecognitionTask = false }
        if let token = audioToken {
            Task {
                do { try await MobileAudioService.shared.stopInput(token: token, cancelTask: cancelTask) }
                catch { NSLog("[VoiceInputController] audio session deactivate failed: %@", error.localizedDescription) }
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

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

actor MobileAudioService {
    static let shared = MobileAudioService()
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputToken: UUID?
    private var routeToken: UUID?
    private var tapInstalled = false
    private var recording: SpeechUtterance.Recording?

    func prepareInput(token: UUID, onAudio: @escaping @Sendable () -> Void,
                      onResult: @escaping @Sendable (SpeechUtterance) -> Void,
                      onError: @escaping @Sendable (String?) -> Void) throws -> String? {
        if let inputToken { try stopInput(token: inputToken, cancelTask: true) }
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else { return "Speech recognition unavailable on this device or locale." }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request
        inputToken = token
        routeToken = token
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
        try? session.setPreferredSampleRate(16_000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "No usable microphone input route was found." }
        let recording = try SpeechUtterance.Recording(format: format)
        self.recording = recording
        let hasReceivedAudio = OSAllocatedUnfairLock(initialState: false)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do { try recording.append(buffer) }
            catch { onError(error.localizedDescription); return }
            request.append(buffer)
            let firstAudibleBuffer = hasReceivedAudio.withLockUnchecked { received in
                guard !received, let data = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return false }
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
                guard sqrt(sum / Float(buffer.frameLength)) > 0.002 else { return false }
                received = true
                return true
            }
            if firstAudibleBuffer { onAudio() }
        }
        tapInstalled = true
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result { onResult(SpeechUtterance(result)) }
            if let error {
                let failure = error as NSError
                let suppressed = failure.domain == "kAFAssistantErrorDomain"
                    && (failure.code == 216 || failure.code == 203 || failure.code == 1110)
                onError(suppressed ? nil : error.localizedDescription)
            }
        }
        return nil
    }

    func startInput(token: UUID) throws {
        guard inputToken == token, let engine else { throw CancellationError() }
        engine.prepare()
        try engine.start()
    }

    func stopInput(token: UUID, cancelTask: Bool) throws {
        guard inputToken == token else { return }
        request?.endAudio()
        if cancelTask { recognitionTask?.cancel(); recognitionTask = nil; inputToken = nil; recognizer = nil }
        else { recognitionTask?.finish() }
        request = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine?.stop()
        engine = nil
        if cancelTask { recording = nil }
        guard routeToken == token else { return }
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        routeToken = nil
    }

    func finishInput(token: UUID, utterance: SpeechUtterance) throws -> MultimodalAttachment {
        guard inputToken == token, let recording else { throw CancellationError() }
        try stopInput(token: token, cancelTask: false)
        return try recording.finish(utterance: utterance)
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
