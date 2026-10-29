import Foundation
import Observation
import Speech
import AVFoundation
import NativeAgentShared
// Blueprint: | `VoiceInputCapture.swift` | consent-driven native microphone lifecycle; shared SpeechUtterance recognition and original audio travel through existing chat attachments |

/// The terminal quality of a stopped voice capture.  A recognizer timeout is
/// deliberately distinct from a completed transcription: callers can retain
/// the partial text for visible recovery without ever submitting it as though
/// it were a finished user utterance.
public enum VoiceInputStopResult: Equatable, Sendable {
    case final(String)
    case partial(String)
    case failed(String)

    public var transcriptForSubmission: String {
        guard case .final(let transcript) = self else { return "" }
        return transcript
    }

    public var userFacingFailureMessage: String? {
        switch self {
        case .final:
            nil
        case .partial:
            "Voice input timed out before a final transcript was available. Try again."
        case .failed(let message):
            message
        }
    }
}

/// The terminal result of one user-initiated voice permission request.  This
/// stays separate from `isListening`: an authorization success only permits a
/// capture attempt; it does not claim that audio capture actually started.
public enum VoiceInputPermissionResult: Equatable, Sendable {
    case granted
    case speechNotDetermined
    case speechDenied
    case speechRestricted
    case microphoneNotDetermined
    case microphoneDenied
    case microphoneRestricted

    public var errorMessage: String? {
        switch self {
        case .granted:
            nil
        case .speechNotDetermined:
            "Speech recognition permission was not resolved, so voice input did not start. Open System Settings → Privacy & Security → Speech Recognition and try again."
        case .speechDenied:
            "Speech recognition permission denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .speechRestricted:
            "Speech recognition is restricted on this Mac, so voice input cannot start."
        case .microphoneNotDetermined:
            "Microphone permission was not resolved, so voice input did not start. Open System Settings → Privacy & Security → Microphone and try again."
        case .microphoneDenied:
            "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .microphoneRestricted:
            "Microphone access is restricted on this Mac, so voice input cannot start."
        }
    }
}

private func makeSpeechAudioTap(
    request: SFSpeechAudioBufferRecognitionRequest,
    recording: SpeechUtterance.Recording,
    onError: @escaping @Sendable (String) -> Void
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        do { try recording.append(buffer) }
        catch { onError(error.localizedDescription); return }
        request.append(buffer)
    }
}

private func makeSpeechRecognitionHandler(
    controller: VoiceInputCapture,
    generation: UInt64,
    failureMessage: @escaping @Sendable (Error, String) -> String
) -> (SFSpeechRecognitionResult?, Error?) -> Void {
    { [weak controller] result, error in
        if let result {
            let utterance = SpeechUtterance(result)
            Task { @MainActor [weak controller] in
                controller?.receiveNativeRecognition(
                    utterance: utterance,
                    generation: generation
                )
            }
        }
        if let error {
            let nsError = error as NSError
            let ignoredCodes: Set<Int> = [203, 216]
            if nsError.domain != "kAFAssistantErrorDomain" || !ignoredCodes.contains(nsError.code) {
                let message = failureMessage(error, "hear that")
                Task { @MainActor [weak controller] in
                    controller?.receiveNativeRecognitionFailure(
                        message: message,
                        generation: generation
                    )
                }
            }
        }
    }
}

@Observable
@MainActor
public final class VoiceInputCapture {
    public var transcript = ""
    public var isListening = false
    public var errorMessage: String?
    public private(set) var attachment: MultimodalAttachment?

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    private var recording: SpeechUtterance.Recording?
    private var utterance: SpeechUtterance?
    private let recognitionContext: @MainActor () -> [String]
    private let requestSpeechAuthorization: @MainActor () async -> SFSpeechRecognizerAuthorizationStatus
    private let failureMessage: @Sendable (Error, String) -> String

    // Every concurrent stop caller waits for the same terminal capture result.
    // The first caller owns finish(); later callers only join this list. Each
    // continuation is drained exactly once by a final result, failure, or
    // timeout, so a duplicate UI/hotkey stop cannot observe a transient
    // partial transcript as a completed phrase.
    private var stopWaiters: [CheckedContinuation<VoiceInputStopResult, Never>] = []
    private var stopInFlight = false
    // A mounted composer can observe `isListening` and queue its stop task in
    // the same run-loop turn that the timeout wins. Preserve that terminal
    // quality until the next capture starts, rather than reclassifying the
    // retained partial text as a new final result.
    private var latestStopResult: VoiceInputStopResult?
    // The stop timeout armed by stopListeningResult(). Cancelled when the
    // continuation resolves early (cleanupRecognition) — otherwise a previous
    // stop's stale timer could resume a LATER stop's continuation with a
    // truncated transcript.
    private var stopTimeoutTask: Task<Void, Never>?
    // A canceled Task can already be scheduled on the main actor. Bind its
    // completion to this stop generation so it can never resolve a later
    // session's continuation.
    private var stopGeneration: UInt64 = 0
    private var recognitionGeneration: UInt64 = 0

    private let stopTimeoutNanoseconds: UInt64

    public init(
        recognitionContext: @escaping @MainActor () -> [String],
        requestSpeechAuthorization: @escaping @MainActor () async -> SFSpeechRecognizerAuthorizationStatus,
        failureMessage: @escaping @Sendable (Error, String) -> String,
        stopTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.recognitionContext = recognitionContext
        self.requestSpeechAuthorization = requestSpeechAuthorization
        self.failureMessage = failureMessage
        self.stopTimeoutNanoseconds = stopTimeoutNanoseconds
    }

    private func prepareForCapture() {
        latestStopResult = nil
        attachment = nil
        utterance = nil
    }

    private func beginCapture() -> UInt64 {
        transcript = ""
        recognitionGeneration &+= 1
        isListening = true
        return recognitionGeneration
    }

    /// Exposes whether a stop was final, incomplete, or failed. Composers
    /// submit only the final transcript; recovery can describe partial capture.
    public func stopListeningResult() async -> VoiceInputStopResult {
        guard isListening else { return latestStopResult ?? .final(transcript) }
        return await withCheckedContinuation { cont in
            stopWaiters.append(cont)
            guard !stopInFlight else { return }
            stopInFlight = true
            let generation = nextStopGeneration()
            armStopTimeout(for: generation)
            finishRecognition()
        }
    }

    private func nextStopGeneration() -> UInt64 {
        stopGeneration &+= 1
        return stopGeneration
    }

    private func armStopTimeout(for generation: UInt64) {
        stopTimeoutTask?.cancel()
        let timeout = stopTimeoutNanoseconds
        stopTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled,
                  let self,
                  self.stopGeneration == generation else { return }
            self.stopTimeoutTask = nil
            self.errorMessage = "Voice input timed out before a final transcript was available. Try again."
            self.cleanupRecognition(result: .partial(self.transcript))
        }
    }

    private func resolveStopWaiters(with result: VoiceInputStopResult) {
        latestStopResult = result
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        stopInFlight = false
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func cleanupRecognition(result: VoiceInputStopResult? = nil) {
        recognitionGeneration &+= 1
        stopGeneration &+= 1
        cancelRecognition()
        var result = result
        if case .final? = result, let utterance, let recording {
            do { attachment = try recording.finish(utterance: utterance) }
            catch {
                let message = "Couldn't retain voice audio: \(error.localizedDescription)"
                errorMessage = message
                result = .failed(message)
            }
        }
        recording = nil
        isListening = false
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        resolveStopWaiters(with: result ?? .final(transcript))
    }

    /// Chat, detached chat, and the global voice shortcut each own a
    /// controller. Keep Speech and AVFoundation cold until one of those
    /// surfaces actually starts native voice input; constructing them during
    /// ordinary app/view initialization needlessly loads service state and the
    /// Speech framework retains per-recognizer internals on macOS.
    private func prepareNativeResourcesIfNeeded() {
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale.current)
        }
        if audioEngine == nil {
            audioEngine = AVAudioEngine()
        }
    }

    public func requestPermission() async -> VoiceInputPermissionResult {
        let result = await requestSystemPermission()
        errorMessage = result.errorMessage
        return result
    }

    private func requestSystemPermission() async -> VoiceInputPermissionResult {
        // Speech-to-text authorization (separate from microphone access on macOS).
        let current = SFSpeechRecognizer.authorizationStatus()
        let speechStatus = current == .notDetermined ? await requestSpeechAuthorization() : current
        switch speechStatus {
        case .authorized:
            return await Self.requestMicrophoneAuthorization()
        case .notDetermined:
            // TCC should resolve the status after the user-initiated prompt.
            // If it does not, state that explicitly instead of presenting a
            // generic denial that invites a silent retry loop.
            return .speechNotDetermined
        case .denied:
            return .speechDenied
        case .restricted:
            return .speechRestricted
        @unknown default:
            return .speechRestricted
        }
    }

    nonisolated private static func requestMicrophoneAuthorization() async -> VoiceInputPermissionResult {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .microphoneNotDetermined
        case .denied:
            return .microphoneDenied
        case .restricted:
            return .microphoneRestricted
        @unknown default:
            return .microphoneRestricted
        }
    }

    public func startListening() {
        guard !isListening else { return }
        errorMessage = nil
        prepareNativeResourcesIfNeeded()
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer not available on this device."
            return
        }
        guard let audioEngine else {
            errorMessage = "Audio input is not available."
            return
        }

        cleanupRecognition()
        prepareForCapture()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = recognitionContext()
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

        let recording: SpeechUtterance.Recording
        do { recording = try SpeechUtterance.Recording(format: recordingFormat) }
        catch {
            errorMessage = "Couldn't retain voice audio: \(error.localizedDescription)"
            recognitionRequest = nil
            return
        }
        self.recording = recording
        let generation = beginCapture()
        let tap = makeSpeechAudioTap(request: request, recording: recording) { [weak self] message in
            Task { @MainActor [weak self] in
                self?.receiveNativeRecognitionFailure(message: message, generation: generation)
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat, block: tap)
        inputTapInstalled = true

        // A recognition callback can arrive while the engine begins. Install
        // the active state before registering it so a synchronous final stays
        // terminal rather than being overwritten after cleanup.
        let recognitionHandler = makeSpeechRecognitionHandler(controller: self, generation: generation, failureMessage: failureMessage)
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: recognitionHandler)

        do {
            try audioEngine.start()
        } catch {
            cleanupRecognition()
            errorMessage = failureMessage(error, "start the microphone")
            return
        }

    }

    fileprivate func receiveNativeRecognition(
        utterance: SpeechUtterance,
        generation: UInt64
    ) {
        guard recognitionGeneration == generation else { return }
        self.utterance = utterance
        transcript = utterance.text
        if utterance.isFinal {
            cleanupRecognition(result: .final(utterance.text))
        }
    }

    fileprivate func receiveNativeRecognitionFailure(message: String, generation: UInt64) {
        guard recognitionGeneration == generation else { return }
        errorMessage = message
        cleanupRecognition(result: .failed(message))
    }

    public func discardListening() {
        cleanupRecognition(result: .partial(""))
        transcript = ""
    }

    private func finishRecognition() {
        recognitionRequest?.endAudio()
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioEngine?.stop()
        recognitionTask?.finish()
    }

    private func cancelRecognition() {
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }
}
