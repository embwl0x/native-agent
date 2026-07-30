// PATCH-2026-05-06: multimodal-ui Sprint 3.1 — voice input via SFSpeechRecognizer + AVAudioEngine
import Foundation
import Speech
import AVFoundation
import Observation

private func makeSpeechAudioTap(
    request: SFSpeechAudioBufferRecognitionRequest
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        request.append(buffer)
    }
}

private func makeSpeechRecognitionHandler(
    controller: VoiceInputController
) -> (SFSpeechRecognitionResult?, Error?) -> Void {
    { [weak controller] result, error in
        if let result {
            let transcript = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor [weak controller] in
                controller?.transcript = transcript
                if isFinal {
                    controller?.cleanupRecognition()
                }
            }
        }
        if let error {
            let nsError = error as NSError
            let ignoredCodes: Set<Int> = [203, 216]
            if nsError.domain != "kAFAssistantErrorDomain" || !ignoredCodes.contains(nsError.code) {
                let message = error.localizedDescription
                Task { @MainActor [weak controller] in
                    controller?.errorMessage = message
                    controller?.cleanupRecognition()
                    controller?.isListening = false
                }
            }
        }
    }
}

@Observable
@MainActor
final class VoiceInputController {
    var transcript: String = ""
    var isListening: Bool = false
    var permissionGranted: Bool = false
    var errorMessage: String? = nil

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    // Held across an in-flight stopListening() while the recognizer flushes its
    // final result asynchronously. Resumed exactly once: either from
    // cleanupRecognition() when isFinal arrives (or an error tears the session
    // down), or from a 2-second timeout fallback inside stopListening().
    private var stopContinuation: CheckedContinuation<String, Never>?
    // The 2s fallback timer armed by stopListening(). Cancelled when the
    // continuation resolves early (cleanupRecognition) — otherwise a previous
    // stop's stale timer could resume a LATER stop's continuation with a
    // truncated transcript.
    private var stopTimeoutTask: Task<Void, Never>?

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        audioEngine = AVAudioEngine()
    }

    func requestPermission() async -> Bool {
        // Speech-to-text authorization (separate from microphone access on macOS).
        let speechStatus = await Self.requestSpeechAuthorization()
        let speechOK = (speechStatus == .authorized)

        // Microphone hardware access — REQUIRED for AVAudioEngine to actually
        // capture audio.  Without this, startListening "succeeds" but the
        // input tap receives silent buffers and the recognizer produces nothing,
        // which is exactly what looks like a broken button.
        let micOK = await Self.requestMicrophoneAuthorization()

        if !speechOK {
            errorMessage = "Speech recognition permission denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        } else if !micOK {
            errorMessage = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        }

        permissionGranted = speechOK && micOK
        return permissionGranted
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            // If already authorized, this resumes immediately without prompting.
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                cont.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            case .denied, .restricted:
                cont.resume(returning: false)
            @unknown default:
                cont.resume(returning: false)
            }
        }
    }

    func startListening() {
        guard !isListening else { return }
        errorMessage = nil
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer not available on this device."
            return
        }
        guard let audioEngine else {
            errorMessage = "Audio input is not available."
            return
        }

        cleanupRecognition()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            errorMessage = "No usable microphone input route was found."
            recognitionRequest = nil
            return
        }

        let tap = makeSpeechAudioTap(request: request)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat, block: tap)
        inputTapInstalled = true

        transcript = ""
        let recognitionHandler = makeSpeechRecognitionHandler(controller: self)
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: recognitionHandler)

        do {
            try audioEngine.start()
        } catch {
            cleanupRecognition()
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }

        isListening = true
    }

    /// Stops recording and returns the FINAL transcript. SFSpeechRecognizer's
    /// `finish()` flushes asynchronously — the recognitionHandler may deliver
    /// a final result after several hundred ms. We hold a continuation until
    /// either `isFinal` arrives (resolved from cleanupRecognition) or a 2s
    /// timeout fires, so callers never send a partial/empty transcript.
    func stopListening() async -> String {
        guard isListening else { return transcript }
        // A concurrent stop is already awaiting the same flush — don't queue
        // another finish(), just return what we currently have.
        if stopContinuation != nil { return transcript }

        recognitionRequest?.endAudio()
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioEngine?.stop()

        return await withCheckedContinuation { cont in
            stopContinuation = cont
            recognitionTask?.finish()

            stopTimeoutTask?.cancel()
            stopTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.stopTimeoutTask = nil
                if let waiting = self.stopContinuation {
                    self.stopContinuation = nil
                    self.recognitionTask?.cancel()
                    self.recognitionTask = nil
                    self.recognitionRequest = nil
                    self.isListening = false
                    waiting.resume(returning: self.transcript)
                }
            }
        }
    }

    fileprivate func cleanupRecognition() {
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        if let cont = stopContinuation {
            stopContinuation = nil
            cont.resume(returning: transcript)
        }
    }
}
