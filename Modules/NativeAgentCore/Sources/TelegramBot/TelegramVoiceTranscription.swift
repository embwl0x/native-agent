@preconcurrency import Speech
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import NativeAgentShared
import Darwin
import os
// Blueprint: | `TelegramVoiceTranscription.swift` | Convert declared containers once; join recognition and temp cleanup on Stop and deadline |

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

private final class TelegramSpeechRecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<SpeechUtterance, Error>?
    // Completion and cancellation can both precede recognitionTask returning. Keep the winning result until the continuation has been registered.
    private var result: Result<SpeechUtterance, Error>?
    private var wasCancelled = false

    func set(_ task: SFSpeechRecognitionTask, continuation: CheckedContinuation<SpeechUtterance, Error>) {
        let (completed, cancelled) = lock.withLock {
            if result == nil {
                self.task = task
                self.continuation = continuation
            }
            return (result, wasCancelled)
        }
        if cancelled { task.cancel() }
        if let completed { continuation.resume(with: completed) }
    }

    func cancel() {
        let task = lock.withLock {
            wasCancelled = true
            return self.task
        }
        // The terminal recognition callback owns continuation settlement; cancellation requests exit without releasing the audio underneath it.
        task?.cancel()
    }

    func resume(with result: Result<SpeechUtterance, Error>) {
        let completed = lock.withLock { () -> (CheckedContinuation<SpeechUtterance, Error>?, SFSpeechRecognitionTask?)? in
            guard self.result == nil else { return nil }
            self.result = wasCancelled ? .failure(CancellationError()) : result
            let continuation = self.continuation
            let task = self.task
            self.continuation = nil
            self.task = nil
            return (continuation, task)
        }
        guard let (continuation, _) = completed else { return }
        let settled = lock.withLock { self.result }
        if let settled { continuation?.resume(with: settled) }
    }

    deinit {
        task?.cancel()
    }
}

struct TelegramPreparedVoiceAudio: Sendable {
    let url: URL
    let cleanupURLs: [URL]

    func cleanup() {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
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
        let output = tempRoot.appendingPathComponent("\(id).m4a")
        do {
            try bytes.write(to: input, options: .atomic)

            if speechReadableExtensions.contains(inputExt) {
                return TelegramPreparedVoiceAudio(url: input, cleanupURLs: [input])
            }

            guard ["ogg", "oga", "opus", "webm"].contains(inputExt) else {
                throw TelegramVoiceTranscriptionError.conversionFailed("Unsupported declared audio format: \(inputExt)")
            }
            try Task.checkCancellation()
            guard let ffmpeg = ffmpegURL() else {
                throw TelegramVoiceTranscriptionError.conversionFailed(
                    "Telegram \(inputExt) audio requires ffmpeg; install it before transcribing this format"
                )
            }
            try await transcodeWithFFmpeg(ffmpeg: ffmpeg, input: input, output: output)
            return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
        } catch {
            // Preparation failure bypasses caller cleanup; remove downloaded bytes here to prevent a private-data leak.
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
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

    private static func ffmpegURL() -> URL? {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func transcodeWithFFmpeg(ffmpeg: URL, input: URL, output: URL) async throws {
        let result: ProcessRunResult
        do {
            result = try await ProcessExecution().run(
                executable: ffmpeg.path,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", input.path, "-vn", "-acodec", "aac", "-b:a", "96k", output.path,
                ],
                currentDirectory: nil, environment: nil, standardInput: nil,
                timeoutSeconds: 30, outputByteLimit: 64 * 1024,
                launchFailure: { TelegramVoiceTranscriptionError.conversionFailed("ffmpeg failed to start: \($0.localizedDescription)") }
            )
        } catch {
            if error is CancellationError || error is ProcessRunCancellation { throw CancellationError() }
            throw error as? TelegramVoiceTranscriptionError
                ?? TelegramVoiceTranscriptionError.conversionFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        if result.timedOut {
            throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg timed out")
        }
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TelegramVoiceTranscriptionError.conversionFailed(
                "ffmpeg exited \(result.exitCode): \(message)"
            )
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg did not write output audio")
        }
    }
}

/// Convert Telegram containers to system audio: SFSpeechRecognizer requires file URLs in formats the system can read.
public final class SwiftAppleSpeechTranscriber: Sendable {
    public var hasSpeechPermission: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    private let localeIdentifier: String
    private let timeoutNanoseconds: UInt64
    private let contextualStrings: @Sendable () -> [String]

    public init(
        localeIdentifier: String = Locale.current.identifier,
        timeoutSeconds: TimeInterval = 45,
        contextualStrings: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.localeIdentifier = localeIdentifier
        self.timeoutNanoseconds = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
        self.contextualStrings = contextualStrings
    }

    public func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription {
        // Check permission before creating audio so headless failures remain immediate and never invoke a prompting API.
        try validateSpeechAuthorization()
        let started = Date()
        // Deadline and Stop cancel the owned body, then join its conversion, recognition and temporary-file cleanup before releasing the turn.
        let utterance = try await withThrowingTaskGroup(of: SpeechUtterance.self) { group in
            group.addTask { [self] in
                let prepared = try await TelegramVoiceAudioPreparer.prepareSpeechURL(attachment)
                defer { prepared.cleanup() }
                try Task.checkCancellation()
                return try await self.recognizeOnce(url: prepared.url)
            }
            group.addTask { [timeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw TelegramVoiceTranscriptionError.speechRecognitionFailed("timed out")
            }
            defer { group.cancelAll() }
            guard let utterance = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return utterance
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1000))
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
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TelegramVoiceTranscriptionError.speechUnavailable("locale \(localeIdentifier) is not supported")
        }
        guard recognizer.isAvailable else {
            throw TelegramVoiceTranscriptionError.speechUnavailable("recognizer is not currently available")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.contextualStrings = contextualStrings()
        request.addsPunctuation = true

        let taskBox = TelegramSpeechRecognitionTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        taskBox.resume(with: .success(SpeechUtterance(result)))
                        return
                    }
                    if let error {
                        taskBox.resume(
                            with: .failure(TelegramVoiceTranscriptionError.speechRecognitionFailed(error.localizedDescription))
                        )
                    }
                }
                taskBox.set(task, continuation: continuation)
            }
        } onCancel: {
            taskBox.cancel()
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
