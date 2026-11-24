import Foundation
import Observation
import Speech
import AVFoundation
import NativeAgentShared
// Blueprint: | `VoiceInputCapture.swift` | Consent-driven capture with terminal quality and audio attachments |

/// Only a final recognition result may be submitted; interrupted capture remains partial.
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
            "Voice input ended before a final transcript was available."
        case .failed(let message):
            message
        }
    }
}

/// Permission success admits a capture attempt; it does not prove the audio engine started.
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
            """
                Speech recognition permission was not resolved, so voice input did not start. Open System Settings → Privacy & Security → Speech \
                Recognition and try again.
                """
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

    // All stop callers join one terminal result; only the first finishes capture, preventing duplicate stops from treating partial text as final.
    private var stopWaiters: [UUID: ScopedWaiter] = [:]
    private var stopResults: [UUID: VoiceInputStopResult] = [:]
    private var stopInFlight = false
    public var isStopping: Bool { stopInFlight }
    // A queued UI stop reads the completed capture's terminal quality.
    private var latestStopResult: VoiceInputStopResult?
    private var recognitionGeneration: UInt64 = 0

    public init(
        recognitionContext: @escaping @MainActor () -> [String],
        requestSpeechAuthorization: @escaping @MainActor () async -> SFSpeechRecognizerAuthorizationStatus,
        failureMessage: @escaping @Sendable (Error, String) -> String
    ) {
        self.recognitionContext = recognitionContext
        self.requestSpeechAuthorization = requestSpeechAuthorization
        self.failureMessage = failureMessage
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

    /// Only final transcripts may submit; incomplete and failed capture stay available for visible recovery.
    public func stopListeningResult() async -> VoiceInputStopResult {
        guard isListening else { return latestStopResult ?? .final(transcript) }
        let id = UUID(), done = ScopedWaiter()
        let generation = recognitionGeneration
        stopWaiters[id] = done
        if !stopInFlight {
            stopInFlight = true
            finishRecognition()
        }
        await done.park()
        if Task.isCancelled {
            stopWaiters.removeValue(forKey: id)
            stopResults.removeValue(forKey: id)
            if recognitionGeneration == generation { discardListening() }
            return .partial("")
        }
        guard let result = stopResults.removeValue(forKey: id) else {
            return .failed("Voice recognition ended without its terminal capture result.")
        }
        return result
    }

    private func resolveStopWaiters(with result: VoiceInputStopResult) {
        latestStopResult = result
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        stopInFlight = false
        for (id, done) in waiters {
            stopResults[id] = result
            done.resume()
        }
    }

    private func cleanupRecognition(result: VoiceInputStopResult? = nil) {
        recognitionGeneration &+= 1
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
        resolveStopWaiters(with: result ?? .final(transcript))
    }

    /// Construct Speech and AVFoundation only on capture start so idle chat surfaces retain no unnecessary recognizer or service state.
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
        // Speech authorization is separate from microphone access on macOS.
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
        request.addsPunctuation = true
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
        attachment = nil
        utterance = nil
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
