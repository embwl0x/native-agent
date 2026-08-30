// PATCH-2026-05-06: multimodal-ui Sprint 3.1 — voice input via SFSpeechRecognizer + AVAudioEngine
import Foundation
import Speech
import AVFoundation
import Observation

/// The terminal result of one user-initiated voice permission request.  This
/// stays separate from `isListening`: an authorization success only permits a
/// capture attempt; it does not claim that audio capture actually started.
enum VoiceInputPermissionResult: Equatable, Sendable {
    case granted
    case speechNotDetermined
    case speechDenied
    case speechRestricted
    case microphoneNotDetermined
    case microphoneDenied
    case microphoneRestricted

    var errorMessage: String? {
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
    request: SFSpeechAudioBufferRecognitionRequest
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        request.append(buffer)
    }
}

private func makeSpeechRecognitionHandler(
    controller: VoiceInputController,
    generation: UInt64
) -> (SFSpeechRecognitionResult?, Error?) -> Void {
    { [weak controller] result, error in
        if let result {
            let transcript = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor [weak controller] in
                controller?.receiveNativeRecognition(
                    transcript: transcript,
                    isFinal: isFinal,
                    generation: generation
                )
            }
        }
        if let error {
            let nsError = error as NSError
            let ignoredCodes: Set<Int> = [203, 216]
            if nsError.domain != "kAFAssistantErrorDomain" || !ignoredCodes.contains(nsError.code) {
                let message = error.localizedDescription
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

/// The small recognition lifecycle the controller needs to own. Production
/// uses SFSpeechRecognizer directly; this seam lets the same stop/final race
/// be driven without a microphone, TCC grant, or speech service.
enum VoiceInputRecognitionEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
    case failed(String)
}

/// The terminal quality of a stopped voice capture.  A recognizer timeout is
/// deliberately distinct from a completed transcription: callers can retain
/// the partial text for visible recovery without ever submitting it as though
/// it were a finished user utterance.
enum VoiceInputStopResult: Equatable, Sendable {
    case final(String)
    case partial(String)
    case failed(String)

    var transcriptForSubmission: String {
        guard case .final(let transcript) = self else { return "" }
        return transcript
    }

    var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }

    var userFacingFailureMessage: String? {
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

@MainActor
protocol VoiceInputRecognitionDriving: AnyObject {
    func start(handler: @escaping @MainActor (VoiceInputRecognitionEvent) -> Void) throws
    func finish()
    func cancel()
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
    // The 2s fallback timer armed by stopListening(). Cancelled when the
    // continuation resolves early (cleanupRecognition) — otherwise a previous
    // stop's stale timer could resume a LATER stop's continuation with a
    // truncated transcript.
    private var stopTimeoutTask: Task<Void, Never>?
    // A canceled Task can already be scheduled on the main actor. Bind its
    // completion to this stop generation so it can never resolve a later
    // session's continuation.
    private var stopGeneration: UInt64 = 0
    private var recognitionGeneration: UInt64 = 0

    /// The real requester prompts through Speech/TCC.  Injection exists only
    /// at that operating-system boundary so the controller's visible consent
    /// semantics remain executable without reading a test machine's grants.
    private let permissionRequest: () async -> VoiceInputPermissionResult
    private let recognitionDriver: (any VoiceInputRecognitionDriving)?
    private let stopTimeoutNanoseconds: UInt64

    init(
        permissionRequest: @escaping () async -> VoiceInputPermissionResult = VoiceInputController.requestSystemPermission,
        recognitionDriver: (any VoiceInputRecognitionDriving)? = nil,
        stopTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.permissionRequest = permissionRequest
        self.recognitionDriver = recognitionDriver
        self.stopTimeoutNanoseconds = stopTimeoutNanoseconds
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

    var _nativeResourcesPreparedForTesting: Bool {
        recognizer != nil || audioEngine != nil
    }

    func requestPermission() async -> Bool {
        let result = await permissionRequest()
        permissionGranted = result == .granted
        errorMessage = result.errorMessage
        return permissionGranted
    }

    nonisolated private static func requestSystemPermission() async -> VoiceInputPermissionResult {
        // Speech-to-text authorization (separate from microphone access on macOS).
        let speechStatus = await requestSpeechAuthorization()
        switch speechStatus {
        case .authorized:
            return await requestMicrophoneAuthorization()
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

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophoneAuthorization() async -> VoiceInputPermissionResult {
        return await withCheckedContinuation { cont in
            // If already authorized, this resumes immediately without prompting.
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                cont.resume(returning: .granted)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized:
                        cont.resume(returning: .granted)
                    case .notDetermined:
                        cont.resume(returning: .microphoneNotDetermined)
                    case .denied:
                        cont.resume(returning: .microphoneDenied)
                    case .restricted:
                        cont.resume(returning: .microphoneRestricted)
                    @unknown default:
                        cont.resume(returning: .microphoneRestricted)
                    }
                }
            case .denied:
                cont.resume(returning: .microphoneDenied)
            case .restricted:
                cont.resume(returning: .microphoneRestricted)
            @unknown default:
                cont.resume(returning: .microphoneRestricted)
            }
        }
    }

    func startListening() {
        guard !isListening else { return }
        errorMessage = nil
        if let recognitionDriver {
            startListening(using: recognitionDriver)
            return
        }
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
        latestStopResult = nil

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
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        // A recognition callback can arrive while the engine begins. Install
        // the active state before registering it so a synchronous final stays
        // terminal rather than being overwritten after cleanup.
        isListening = true
        let recognitionHandler = makeSpeechRecognitionHandler(controller: self, generation: generation)
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: recognitionHandler)

        do {
            try audioEngine.start()
        } catch {
            cleanupRecognition()
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }

    }

    private func startListening(using driver: any VoiceInputRecognitionDriving) {
        cleanupRecognition()
        latestStopResult = nil
        transcript = ""
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        // The driver is allowed to deliver a final result synchronously from
        // start(). Mark the session active first so that final cleanup remains
        // the terminal state instead of being overwritten below.
        isListening = true
        do {
            try driver.start { [weak self] event in
                guard let self, self.recognitionGeneration == generation else { return }
                self.handleRecognitionEvent(event)
            }
        } catch {
            errorMessage = "Speech recognizer failed to start: \(error.localizedDescription)"
            cleanupRecognition()
        }
    }

    private func handleRecognitionEvent(_ event: VoiceInputRecognitionEvent) {
        switch event {
        case .partial(let text):
            transcript = text
        case .final(let text):
            transcript = text
            cleanupRecognition(result: .final(text))
        case .failed(let detail):
            errorMessage = detail
            cleanupRecognition(result: .failed(detail))
        }
    }

    fileprivate func receiveNativeRecognition(
        transcript: String,
        isFinal: Bool,
        generation: UInt64
    ) {
        guard recognitionGeneration == generation else { return }
        self.transcript = transcript
        if isFinal {
            cleanupRecognition(result: .final(transcript))
        }
    }

    fileprivate func receiveNativeRecognitionFailure(message: String, generation: UInt64) {
        guard recognitionGeneration == generation else { return }
        errorMessage = message
        cleanupRecognition(result: .failed(message))
    }

    /// Stops recording and returns the FINAL transcript. SFSpeechRecognizer's
    /// `finish()` flushes asynchronously — the recognitionHandler may deliver
    /// a final result after several hundred ms. We hold a continuation until
    /// either `isFinal` arrives (resolved from cleanupRecognition) or a 2s
    /// timeout fires. The compatibility string result is empty for every
    /// non-final outcome, so composers restore their pre-voice draft rather
    /// than sending a partial transcript as a completed utterance.
    func stopListening() async -> String {
        await stopListeningResult().transcriptForSubmission
    }

    /// Exposes whether a stop was final, incomplete, or failed. The visible
    /// composers intentionally use `stopListening()` above, which refuses to
    /// submit anything except `.final`; recovery surfaces can inspect this
    /// result to describe an incomplete capture accurately.
    func stopListeningResult() async -> VoiceInputStopResult {
        guard isListening else { return latestStopResult ?? .final(transcript) }
        return await withCheckedContinuation { cont in
            stopWaiters.append(cont)
            guard !stopInFlight else { return }
            stopInFlight = true
            let generation = nextStopGeneration()
            armStopTimeout(for: generation)
            if let recognitionDriver {
                recognitionDriver.finish()
                return
            }
            recognitionRequest?.endAudio()
            if inputTapInstalled {
                audioEngine?.inputNode.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            audioEngine?.stop()
            recognitionTask?.finish()
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

    fileprivate func cleanupRecognition(result: VoiceInputStopResult? = nil) {
        recognitionGeneration &+= 1
        stopGeneration &+= 1
        if inputTapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognitionDriver?.cancel()
        isListening = false
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        resolveStopWaiters(with: result ?? .final(transcript))
    }
}
