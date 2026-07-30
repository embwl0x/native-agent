// VoiceInputController.swift — voice input for NativeAgent iOS
// Uses SFSpeechRecognizer + AVAudioEngine, mirroring the Mac pattern but
// touch-driven rather than hotkey-driven.
import Foundation
import UIKit
import Speech
import AVFoundation

@MainActor
final class VoiceInputController: ObservableObject {
    @Published var isListening = false
    @Published var isStarting = false
    @Published var transcript = ""         // live partial transcript
    @Published var lastFinalTranscript = "" // populated when user releases
    @Published var error: String?
    @Published var statusText: String?
    @Published var audioLevel: Double = 0
    @Published var hasReceivedAudio = false

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var desiredListening = false
    private var startGeneration = 0
    private var waitingForFinalAfterStop = false
    private var hasStartedAudioSession = false

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)

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
        guard !isStarting else { return }
        // If already listening, cancel the previous session first so we never
        // leak the audio engine across multiple rapid presses.
        if isListening { teardownAudio(cancelTask: true) }
        startGeneration += 1
        let generation = startGeneration
        isStarting = true
        desiredListening = true
        waitingForFinalAfterStop = false
        hasStartedAudioSession = false
        error = nil
        statusText = "Starting microphone..."
        transcript = ""
        lastFinalTranscript = ""
        audioLevel = 0
        hasReceivedAudio = false
        defer {
            if generation == startGeneration, !isListening {
                isStarting = false
            }
        }

        // 1. Speech recognition auth
        let speechStatus = await Self.requestSpeechAuthorization()
        guard desiredListening, generation == startGeneration else { return }
        guard speechStatus == .authorized else {
            error = "Speech recognition permission denied. Enable it in Settings."
            statusText = nil
            return
        }

        // 2. Microphone auth (required separately on iOS 17+)
        let micGranted = await Self.requestMicrophonePermission()
        guard desiredListening, generation == startGeneration else { return }
        guard micGranted else {
            error = "Microphone permission denied. Enable it in Settings."
            statusText = nil
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition unavailable on this device or locale."
            statusText = nil
            return
        }

        // 3. Configure AVAudioSession
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
            )
            try? session.setPreferredSampleRate(16_000)
            try? session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "Microphone could not start: \(error.localizedDescription)"
            statusText = nil
            return
        }
        guard desiredListening, generation == startGeneration else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        // 4. Build recognition request
        audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        request.taskHint = .dictation
        recognitionRequest = request

        // 5. Install tap on input node
        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            teardownAudio(cancelTask: true)
            self.error = "No usable microphone input route was found."
            statusText = nil
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, request] buffer, _ in
            request.append(buffer)
            guard let channelData = buffer.floatChannelData?.pointee else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            var sum: Float = 0
            for index in 0..<frameCount {
                let sample = channelData[index]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameCount))
            let normalized = min(1.0, max(0.0, Double(rms) * 35.0))
            Task { @MainActor [weak self] in
                guard let self, self.desiredListening || self.waitingForFinalAfterStop else { return }
                self.audioLevel = normalized
                if rms > 0.002 {
                    self.hasReceivedAudio = true
                    if self.transcript.isEmpty {
                        self.statusText = "Hearing you..."
                    }
                }
            }
        }
        tapInstalled = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self, generation] result, err in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    guard self.startGeneration == generation
                        || (self.waitingForFinalAfterStop && self.startGeneration == generation + 1)
                    else { return }
                    let text = result.bestTranscription.formattedString
                    self.transcript = text
                    if self.waitingForFinalAfterStop && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.lastFinalTranscript = text
                        self.waitingForFinalAfterStop = false
                        self.statusText = nil
                        self.error = nil
                    }
                }
            }
            if let err {
                let nsErr = err as NSError
                // Code 216 / 203 = cancelled/no-speech — suppress; they're normal on stop.
                let suppressed = nsErr.domain == "kAFAssistantErrorDomain"
                    && (nsErr.code == 216 || nsErr.code == 203 || nsErr.code == 1110)
                if !suppressed {
                    Task { @MainActor in
                        self.error = err.localizedDescription
                        self.teardownAudio(cancelTask: true)
                    }
                }
            }
        }

        // 6. Start engine after the recognition task is ready to consume buffers.
        audioEngine.prepare()
        do {
            try audioEngine.start()
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
        statusText = "Listening..."
    }

    /// Call on touch-up. Captures lastFinalTranscript from whatever partial we have,
    /// then tears everything down.
    func stop() {
        let hadRecordingSession = isListening || hasStartedAudioSession
        desiredListening = false
        startGeneration += 1
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        waitingForFinalAfterStop = hadRecordingSession && cleanTranscript.isEmpty
        if !cleanTranscript.isEmpty {
            lastFinalTranscript = cleanTranscript
        }
        teardownAudio(cancelTask: !hadRecordingSession)
        isListening = false
        isStarting = false
        statusText = nil
        guard hadRecordingSession else {
            waitingForFinalAfterStop = false
            return
        }
        if cleanTranscript.isEmpty, error == nil {
            let stopGeneration = startGeneration
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                if self.startGeneration == stopGeneration,
                   self.waitingForFinalAfterStop,
                   self.lastFinalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.waitingForFinalAfterStop = false
                    self.error = self.hasReceivedAudio
                        ? "No words were recognized. Try speaking a little longer."
                        : "No microphone audio detected. Check iOS microphone privacy and the selected audio route."
                }
            }
        }
    }

    // MARK: - Private

    private func teardownAudio(cancelTask: Bool) {
        recognitionRequest?.endAudio()
        if cancelTask {
            recognitionTask?.cancel()
        } else {
            recognitionTask?.finish()
        }
        recognitionTask = nil
        recognitionRequest = nil

        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
        isStarting = false
        hasStartedAudioSession = false
        statusText = nil
        audioLevel = 0
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
