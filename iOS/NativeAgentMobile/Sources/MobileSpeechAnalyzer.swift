import Foundation
import Speech
import AVFoundation
import CoreMedia
import NativeAgentShared
// Blueprint: | `MobileSpeechAnalyzer.swift` | On-device timed recognition, name context and PCM conversion; detector events retain capture |

/// Admit only supported device/locale pairs; report admitted failures without switching recognition engines.
@available(iOS 26.0, *)
final class MobileSpeechAnalyzer: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let input: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let conversionLock = NSLock()
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private let detector: SpeechDetector?
    private var detectionTask: Task<Void, Never>?

    static func supportedLocale() async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: .current)
    }

    init(locale: Locale, sourceFormat: AVAudioFormat, names: [String], conversation: Bool = false) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        self.transcriber = transcriber
        let detector = conversation ? SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true) : nil
        self.detector = detector
        var modules: [any SpeechModule] = [transcriber]
        if let detector { modules.append(detector) }
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: sourceFormat),
              let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw NSError(domain: "VoiceNote", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone format cannot be used for on-device speech."])
        }
        self.format = format
        self.converter = converter
        let stream = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = stream.stream
        continuation = stream.continuation
        let context = AnalysisContext()
        context.contextualStrings[.general] = names
        analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
    }

    /// Timed segments bound call growth; draft and final results share their audio start, and turn finalization must not close capture.
    func startConversation(onResult: @escaping @Sendable (SpeechUtterance, Double) -> Void,
                           onSpeech: @escaping @Sendable (Bool, Double) -> Void,
                           onError: @escaping @Sendable (String) -> Void) {
        resultTask = Task { [transcriber] in
            do {
                for try await result in transcriber.results {
                    onResult(Self.utterance([result], final: result.isFinal), result.range.start.seconds)
                }
                if !Task.isCancelled { onError("On-device speech recognition ended. End talk and start again.") }
            } catch { if !Task.isCancelled { Self.log("results", error); onError(error.localizedDescription) } }
        }
        detectionTask = Task { [detector] in
            guard let detector else { return }
            do {
                for try await result in detector.results { onSpeech(result.speechDetected, result.range.end.seconds) }
            } catch { if !Task.isCancelled { Self.log("detector", error); onError(error.localizedDescription) } }
        }
        analysisTask = Task { [analyzer, input] in
            do { try await analyzer.start(inputSequence: input) }
            catch { if !Task.isCancelled { Self.log("analyzer", error); onError(error.localizedDescription) } }
        }
    }


    func start(onResult: @escaping @Sendable (SpeechUtterance) -> Void,
               onError: @escaping @Sendable (String?) -> Void) {
        resultTask = Task { [transcriber] in
            var finals: [SpeechTranscriber.Result] = []
            do {
                for try await result in transcriber.results {
                    if result.isFinal { finals.append(result) }
                    let visible = result.isFinal ? finals : finals + [result]
                    onResult(Self.utterance(visible, final: false))
                }
                onResult(Self.utterance(finals, final: true))
            } catch { if !Task.isCancelled { onError(error.localizedDescription) } }
        }
        analysisTask = Task { [analyzer, input] in
            do { try await analyzer.start(inputSequence: input) }
            catch { if !Task.isCancelled { onError(error.localizedDescription) } }
        }
    }

    func append(_ source: AVAudioPCMBuffer) throws {
        try conversionLock.withLock {
            let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw CocoaError(.coderInvalidValue) }
            var supplied = false
            var failure: NSError?
            let status = converter.convert(to: converted, error: &failure) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return source
            }
            if let failure { throw failure }
            guard status != .error else { throw CocoaError(.coderInvalidValue) }
            // The converted buffer owns its storage; the tap's buffer is reused.
            if converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    func finish() async throws {
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async {
        continuation.finish()
        resultTask?.cancel(); analysisTask?.cancel()
        detectionTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private static func log(_ stage: String, _ error: Error) {
        let failure = error as NSError
        NSLog("[Talk] speech %@ stopped: %@ %ld %@", stage, failure.domain, failure.code, String(describing: failure.userInfo))
    }

    private static func utterance(_ results: [SpeechTranscriber.Result], final: Bool) -> SpeechUtterance {
        let text = results.map { String($0.text.characters) }.joined()
        let segments: [SpeechUtterance.Hypothesis.Segment] = results.flatMap { result in
            result.text.runs.map { run in
                let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? result.range
                return .init(text: String(result.text[run.range].characters), timestamp: range.start.seconds,
                    duration: range.duration.seconds,
                    confidence: Float(run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] ?? 0),
                    alternatives: result.alternatives.map { String($0.characters) })
            }
        }
        return SpeechUtterance(text: text, isFinal: final, hypotheses: [.init(text: text, segments: segments)])
    }
}
