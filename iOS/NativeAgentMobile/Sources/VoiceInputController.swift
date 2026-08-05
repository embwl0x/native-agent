// VoiceInputController.swift — voice input for NativeAgent iOS
// Uses SFSpeechRecognizer + AVAudioEngine, mirroring the Mac pattern but
// touch-driven rather than hotkey-driven.
import Foundation
import Observation
import UIKit
import Speech
import AVFoundation

// PERF-2026-08-05: was `ObservableObject` with 8 `@Published` properties, injected
// at the app root via `.environmentObject` and subscribed by the 1454-line ChatView.
// `objectWillChange` is whole-object, so the ~45Hz `audioLevel` write from the
// installTap audio callback invalidated the ENTIRE chat screen while the mic was
// live — driven by a property no view reads. `@Observable` is field-granular: a
// view only re-renders for the exact properties its body touched. This matches the
// Mac controller (Sources/NativeAgentApp/VoiceInputController.swift), which has
// always been `@Observable`.
@MainActor
@Observable
final class VoiceInputController {
    var isListening = false
    var isStarting = false
    var transcript = ""         // live partial transcript
    var lastFinalTranscript = "" // populated when user releases
    var error: String?
    var statusText: String?
    /// Written ~45Hz from the audio tap. No view reads it today (no level meter /
    /// waveform exists on iOS). Left observation-tracked deliberately: under
    /// `@Observable` an unread property costs nothing, and if a meter is ever
    /// added only that leaf view will re-render. Do NOT read this from a
    /// container view — read it from the smallest possible leaf.
    var audioLevel: Double = 0
    var hasReceivedAudio = false

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var audioEngine = AVAudioEngine()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var desiredListening = false
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var waitingForFinalAfterStop = false
    @ObservationIgnored private var hasStartedAudioSession = false

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
                    // PERF-2026-08-05: `@Observable` setters fire a mutation
                    // unconditionally, including for same-value writes. These two
                    // used to be re-assigned every buffer (~45Hz); `statusText` IS
                    // read by ChatView, so the redundant writes would have kept a
                    // slice of the storm alive. Same final values, one write each.
                    if !self.hasReceivedAudio {
                        self.hasReceivedAudio = true
                    }
                    if self.transcript.isEmpty, self.statusText != "Hearing you..." {
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
