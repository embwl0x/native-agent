@preconcurrency import Speech
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import NativeAgentShared
import Darwin
import AudioToolbox
// Blueprint: | `TelegramVoiceTranscription.swift` | Speech final/error and cancellation own recognition; the Mac's own audio reader owns conversion |

// MARK: - Telegram voice transcription

public struct TelegramVoiceTranscription: Sendable, Codable, Equatable {
    public let utterance: SpeechUtterance
    public var text: String { utterance.text }
    public let backend: String
    public let model: String
    public let latencyMilliseconds: Int?

    public init(utterance: SpeechUtterance, backend: String, model: String, latencyMilliseconds: Int? = nil) {
        self.utterance = utterance
        self.backend = backend
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public enum TelegramVoiceTranscriptionBackends {
    public static let appleSpeech = "apple_speech"
    public static let appleSpeechModel = "apple-speech"
}

public enum TelegramVoiceTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case missingAudioBytes
    case malformedResponse
    case conversionFailed(String)
    case speechPermissionDenied(String)
    case speechUnavailable(String)
    case speechRecognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAudioBytes:
            return "voice transcription: missing audio bytes"
        case .malformedResponse:
            return "voice transcription: malformed response"
        case .conversionFailed(let message):
            return "voice transcription: audio conversion failed: \(message)"
        case .speechPermissionDenied(let message):
            return "voice transcription: speech recognition permission denied: \(message)"
        case .speechUnavailable(let message):
            return "voice transcription: Apple Speech unavailable: \(message)"
        case .speechRecognitionFailed(let message):
            return "voice transcription: Apple Speech recognition failed: \(message)"
        }
    }
}

private actor TelegramSpeechRecognition {
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var continuation: CheckedContinuation<SpeechUtterance, Error>?
    private var wasCancelled = false

    func recognize(url: URL, localeIdentifier: String, contextualStrings: [String]) async throws -> SpeechUtterance {
        guard !wasCancelled else { throw CancellationError() }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw TelegramVoiceTranscriptionError.speechUnavailable("locale \(localeIdentifier) is not supported")
        }
        guard recognizer.isAvailable else {
            throw TelegramVoiceTranscriptionError.speechUnavailable("recognizer is not currently available")
        }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.contextualStrings = contextualStrings
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task = Self.start(recognizer: recognizer, request: request) { result in
                Task { await self.complete(result) }
            }
        }
    }

    func cancel() {
        wasCancelled = true
        // The recognition callback settles before its audio can be released.
        task?.cancel()
    }

    private func complete(_ result: Result<SpeechUtterance, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task = nil
        recognizer = nil
        continuation.resume(with: wasCancelled ? .failure(CancellationError()) : result)
    }

    private nonisolated static func start(
        recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest,
        completion: @escaping @Sendable (Result<SpeechUtterance, Error>) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal { completion(.success(SpeechUtterance(result))) }
            else if let error {
                completion(.failure(TelegramVoiceTranscriptionError.speechRecognitionFailed(error.localizedDescription)))
            }
        }
    }
}

struct TelegramPreparedVoiceAudio: Sendable {
    let url: URL
    let cleanupURLs: [URL]

    func cleanup() {
        for url in cleanupURLs {
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile { continue }
            catch { nativeLog("Telegram voice cleanup failed at %@: %@", url.path, error.localizedDescription) }
        }
    }
}

/// Owns system-temp audio outside the data root; cleaned after use, never backed up, exported or synced. PrivacyMap's telegram tree does not count it.
enum TelegramVoiceAudioPreparer {
    static let speechReadableExtensions: Set<String> = ["aif", "aiff", "caf", "m4a", "mp3", "mp4", "wav"]

    static func prepareSpeechURL(
        _ attachment: TelegramMediaAttachment
    ) async throws -> TelegramPreparedVoiceAudio {
        try Task.checkCancellation()
        guard let bytes = attachment.bytes, !bytes.isEmpty else {
            throw TelegramVoiceTranscriptionError.missingAudioBytes
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(InstallPaths.current.name("nativeagent-telegram-voice"), isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let id = UUID().uuidString
        guard let inputExt = fileExtension(for: attachment.captureFilename) ?? fileExtension(forMIMEType: attachment.mimeType) else {
            throw TelegramVoiceTranscriptionError.conversionFailed("Audio has no declared filename format or supported MIME type")
        }
        let input = tempRoot.appendingPathComponent("\(id).\(inputExt)")
        let output = tempRoot.appendingPathComponent("\(id).wav")
        do {
            try bytes.write(to: input, options: .atomic)

            if speechReadableExtensions.contains(inputExt) {
                return TelegramPreparedVoiceAudio(url: input, cleanupURLs: [input])
            }

            // The Mac reads the note itself: Core Audio opens Ogg Opus (what Telegram records) with nothing installed. Speech gets plain PCM.
            try Task.checkCancellation()
            try decodeWithSystemAudio(input: input, output: output, format: inputExt)
            return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
        } catch {
            // Preparation failure bypasses caller cleanup; remove downloaded bytes here to prevent a private-data leak.
            TelegramPreparedVoiceAudio(url: input, cleanupURLs: [input, output]).cleanup()
            throw error
        }
    }

    static func fileExtension(for filename: String?) -> String? {
        guard let filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let ext = URL(fileURLWithPath: filename).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ext.isEmpty ? nil : ext
    }

    private static func fileExtension(forMIMEType mimeType: String?) -> String? {
        let normalized = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "audio/ogg", "audio/oga", "audio/opus":
            return "oga"
        case "audio/mp4", "audio/x-m4a":
            return "m4a"
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/webm":
            return "webm"
        default:
            return nil
        }
    }

    /// One reader for every container Core Audio knows; what it cannot open is refused by name. Writes 16 kHz mono 16-bit PCM.
    private static func decodeWithSystemAudio(input: URL, output: URL, format: String) throws {
        func unreadable(_ step: String, _ status: OSStatus) -> TelegramVoiceTranscriptionError {
            .conversionFailed("This Mac cannot read \(format) audio (\(step), status \(status)).")
        }
        var source: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(input as CFURL, &source)
        guard status == noErr, let source else { throw unreadable("opening it", status) }
        defer { ExtAudioFileDispose(source) }
        var pcm = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            source, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm
        )
        guard status == noErr else { throw unreadable("decoding it", status) }
        var destination: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(output as CFURL, kAudioFileWAVEType, &pcm, nil, AudioFileFlags.eraseFile.rawValue, &destination)
        guard status == noErr, let destination else { throw unreadable("writing the decoded audio", status) }
        defer { ExtAudioFileDispose(destination) }
        let capacity: UInt32 = 8_192
        let samples = UnsafeMutableRawPointer.allocate(byteCount: Int(capacity) * 2, alignment: 2)
        defer { samples.deallocate() }
        var written = 0
        while true {
            try Task.checkCancellation()
            var buffers = AudioBufferList(
                mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: capacity * 2, mData: samples)
            )
            var frames = capacity
            status = ExtAudioFileRead(source, &frames, &buffers)
            guard status == noErr else { throw unreadable("decoding it", status) }
            if frames == 0 { break }
            buffers.mBuffers.mDataByteSize = frames * 2
            status = ExtAudioFileWrite(destination, frames, &buffers)
            guard status == noErr else { throw unreadable("writing the decoded audio", status) }
            written += Int(frames)
        }
        guard written > 0 else { throw TelegramVoiceTranscriptionError.conversionFailed("This \(format) audio holds no sound.") }
    }
}

/// Convert Telegram containers to system audio: SFSpeechRecognizer requires file URLs in formats the system can read.
public final class SwiftAppleSpeechTranscriber: Sendable {
    public var hasSpeechPermission: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    private let localeIdentifier: String
    private let contextualStrings: @Sendable () -> [String]

    public init(
        localeIdentifier: String = Locale.current.identifier,
        contextualStrings: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.localeIdentifier = localeIdentifier
        self.contextualStrings = contextualStrings
    }

    public func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription {
        // Check permission before creating audio so headless failures remain immediate and never invoke a prompting API.
        try validateSpeechAuthorization()
        let started = Date()
        let prepared = try await TelegramVoiceAudioPreparer.prepareSpeechURL(attachment)
        defer { prepared.cleanup() }
        try Task.checkCancellation()
        let utterance = try await recognizeOnce(url: prepared.url)
        try Task.checkCancellation()
        let elapsed = Int(exactly: max(0, Date().timeIntervalSince(started) * 1000).rounded(.towardZero))
        return TelegramVoiceTranscription(
            utterance: utterance,
            backend: TelegramVoiceTranscriptionBackends.appleSpeech,
            model: TelegramVoiceTranscriptionBackends.appleSpeechModel,
            latencyMilliseconds: elapsed
        )
    }

    private func recognizeOnce(url: URL) async throws -> SpeechUtterance {
        try Task.checkCancellation()
        // Headless work cannot safely prompt: read authorization here; MainActor permission preflight owns requests.
        try validateSpeechAuthorization()
        let recognition = TelegramSpeechRecognition()
        return try await withTaskCancellationHandler {
            try await recognition.recognize(url: url, localeIdentifier: localeIdentifier, contextualStrings: contextualStrings())
        } onCancel: {
            Task { await recognition.cancel() }
        }
    }

    private func validateSpeechAuthorization() throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw TelegramVoiceTranscriptionError.speechPermissionDenied(Self.authorizationLabel(status))
        }
    }

    /// Human-readable label for the non-prompting authorization gate.
    private static func authorizationLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}
