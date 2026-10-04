@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - Telegram voice transcription

public struct TelegramVoiceTranscription: Sendable, Codable, Equatable {
    public let text: String
    public let backend: String
    public let model: String
    public let latencyMilliseconds: Int?

    public init(text: String, backend: String, model: String, latencyMilliseconds: Int? = nil) {
        self.text = text
        self.backend = backend
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public protocol TelegramVoiceTranscribing: Sendable {
    var hasSpeechPermission: Bool { get }
    func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription
}

public enum TelegramVoiceTranscriptionBackends {
    public static let appleSpeech = "apple_speech"
    public static let appleSpeechModel = "apple-speech"

    /// Apple Speech is the only backend; any stored value reads as it.
    public static func canonical(_ raw: String) -> String { appleSpeech }
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

private final class TelegramAVExportSessionBox: @unchecked Sendable {
    let export: AVAssetExportSession

    init(_ export: AVAssetExportSession) {
        self.export = export
    }
}

private final class TelegramFFmpegCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TelegramFFmpeg.stderr")
    private let reader: FileHandle
    private let source: DispatchSourceRead
    private var bytes = Data()
    private var ended = false

    init(_ reader: FileHandle) throws {
        self.reader = reader
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg stderr could not be opened")
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? reader.close() }
        source.resume()
    }

    private func drain() {
        guard !ended else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(reader.fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                let room = max(0, 64 * 1024 - bytes.count)
                bytes.append(contentsOf: chunk.prefix(min(count, room)))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    ended = true
                    source.cancel()
                }
                break
            }
        }
    }

    func finish() -> Data {
        queue.sync {
            drain()
            source.cancel()
            return bytes
        }
    }
}

private final class TelegramFFmpegCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let wake = DispatchSemaphore(value: 0)

    func cancel() {
        lock.withLock { cancelled = true }
        wake.signal()
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

private final class TelegramSpeechRecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    // Completion and cancellation can both precede recognitionTask returning.
    // Keep the winning result until the continuation has been registered.
    private var result: Result<String, Error>?
    private var wasCancelled = false

    func set(_ task: SFSpeechRecognitionTask, continuation: CheckedContinuation<String, Error>) {
        let completed = lock.withLock { () -> (Result<String, Error>, Bool)? in
            if let result { return (result, wasCancelled) }
            self.task = task
            self.continuation = continuation
            return nil
        }
        guard let (result, cancelled) = completed else { return }
        if cancelled { task.cancel() }
        continuation.resume(with: result)
    }

    func cancel() {
        finish(with: .failure(CancellationError()), cancelling: true)
    }

    func resume(with result: Result<String, Error>) {
        finish(with: result, cancelling: false)
    }

    private func finish(with result: Result<String, Error>, cancelling: Bool) {
        let completed = lock.withLock { () -> (CheckedContinuation<String, Error>?, SFSpeechRecognitionTask?)? in
            guard self.result == nil else { return nil }
            self.result = result
            wasCancelled = cancelling
            let continuation = self.continuation
            let task = self.task
            self.continuation = nil
            self.task = nil
            return (continuation, task)
        }
        guard let (continuation, task) = completed else { return }
        // Speech may invoke its callback during cancel; never call it locked.
        if cancelling { task?.cancel() }
        continuation?.resume(with: result)
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

enum TelegramVoiceAudioPreparer {
    static let speechReadableExtensions: Set<String> = ["aif", "aiff", "caf", "m4a", "mp3", "mp4", "wav"]

    /// The production transcode path. The optional seams keep its failure
    /// contract testable without consulting a host's AVFoundation/ffmpeg
    /// installation; production always supplies the real converters.
    static func prepareSpeechURL(
        _ attachment: TelegramMediaAttachment,
        temporaryDirectory: URL? = nil,
        avFoundationTranscoder: (@Sendable (URL, URL) async throws -> Void)? = nil,
        ffmpegLocator: (@Sendable () -> URL?)? = nil,
        ffmpegTranscoder: (@Sendable (URL, URL, URL) async throws -> Void)? = nil
    ) async throws -> TelegramPreparedVoiceAudio {
        try await prepareURL(
            attachment,
            readableExtensions: speechReadableExtensions,
            missingConverterMessage: "Telegram OGG/Opus audio is not readable by AVFoundation on this Mac, and no ffmpeg binary was found",
            temporaryDirectory: temporaryDirectory,
            avFoundationTranscoder: avFoundationTranscoder,
            ffmpegLocator: ffmpegLocator,
            ffmpegTranscoder: ffmpegTranscoder
        )
    }

    private static func prepareURL(
        _ attachment: TelegramMediaAttachment,
        readableExtensions: Set<String>,
        missingConverterMessage: String,
        temporaryDirectory: URL? = nil,
        avFoundationTranscoder: (@Sendable (URL, URL) async throws -> Void)? = nil,
        ffmpegLocator: (@Sendable () -> URL?)? = nil,
        ffmpegTranscoder: (@Sendable (URL, URL, URL) async throws -> Void)? = nil
    ) async throws -> TelegramPreparedVoiceAudio {
        guard let bytes = attachment.bytes, !bytes.isEmpty else {
            throw TelegramVoiceTranscriptionError.missingAudioBytes
        }
        let tempRoot = temporaryDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(InstallPaths.current.name("nativeagent-telegram-voice"), isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let inputExt = fileExtension(for: attachment.captureFilename) ?? fileExtension(forMIMEType: attachment.mimeType) ?? "oga"
        let input = tempRoot.appendingPathComponent("\(id).\(inputExt)")
        let output = tempRoot.appendingPathComponent("\(id).m4a")
        do {
            try bytes.write(to: input, options: .atomic)

            if readableExtensions.contains(inputExt) {
                return TelegramPreparedVoiceAudio(url: input, cleanupURLs: [input])
            }

            let avTranscode = avFoundationTranscoder ?? { input, output in
                try await transcodeWithAVFoundation(input: input, output: output)
            }
            do {
                try await avTranscode(input, output)
                return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
            } catch {
                try? FileManager.default.removeItem(at: output)
            }

            let locateFFmpeg = ffmpegLocator ?? { ffmpegURL() }
            guard let ffmpeg = locateFFmpeg() else {
                throw TelegramVoiceTranscriptionError.conversionFailed(
                    missingConverterMessage
                )
            }
            let ffmpegTranscode = ffmpegTranscoder ?? { ffmpeg, input, output in
                try await transcodeWithFFmpeg(ffmpeg: ffmpeg, input: input, output: output)
            }
            try await ffmpegTranscode(ffmpeg, input, output)
            return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
        } catch {
            // A failed preparation never reaches the caller's deferred
            // cleanup. Leaving the downloaded voice bytes behind turns a
            // missing converter into an unbounded private-data leak.
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

    private static func transcodeWithAVFoundation(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TelegramVoiceTranscriptionError.conversionFailed("AVAssetExportSession unavailable")
        }
        export.outputURL = output
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = true
        let exportBox = TelegramAVExportSessionBox(export)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                let export = exportBox.export
                switch export.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: TelegramVoiceTranscriptionError.conversionFailed(
                        export.error?.localizedDescription ?? "export failed"
                    ))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: TelegramVoiceTranscriptionError.conversionFailed(
                        "unexpected export status \(export.status.rawValue)"
                    ))
                }
            }
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
        try Task.checkCancellation()
        let cancellation = TelegramFFmpegCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Thread {
                    do {
                        try transcodeWithFFmpegBlocking(ffmpeg: ffmpeg, input: input, output: output, cancellation: cancellation)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
    }

    private static func transcodeWithFFmpegBlocking(
        ffmpeg: URL, input: URL, output: URL, cancellation: TelegramFFmpegCancellation
    ) throws {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", input.path,
            "-vn",
            "-acodec", "aac",
            "-b:a", "96k",
            output.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let capture = try TelegramFFmpegCapture(errorPipe.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.signal()
            cancellation.wake.signal()
        }
        do {
            try process.run()
            try? errorPipe.fileHandleForWriting.close()
        } catch {
            try? errorPipe.fileHandleForWriting.close()
            _ = capture.finish()
            throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg failed to start: \(error.localizedDescription)")
        }
        let pid = process.processIdentifier
        ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(pid)
        let timedOut = cancellation.wake.wait(timeout: .now() + .seconds(30)) == .timedOut
        if process.isRunning {
            let tree = ProcessTreeReaper.snapshot(rootPID: pid)
            ProcessTreeReaper.signal(tree, signal: SIGTERM)
            let graceExpired = exited.wait(timeout: .now() + .milliseconds(200)) == .timedOut
            let remaining = ProcessTreeReaper.snapshot(rootPID: pid, retaining: tree)
            if graceExpired || ProcessTreeReaper.hasLiveDescendant(in: remaining) {
                ProcessTreeReaper.quiesceAndKill(remaining)
            }
        }
        process.waitUntilExit()
        let errorData = capture.finish()
        if cancellation.isCancelled { throw CancellationError() }
        if timedOut {
            throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg timed out")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TelegramVoiceTranscriptionError.conversionFailed(
                "ffmpeg exited \(process.terminationStatus)\(message.map { ": \($0)" } ?? "")"
            )
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg did not write output audio")
        }
    }
}

/// Swift-native, no-API-key Telegram voice-note transcriber backed by Apple's
/// Speech framework. Telegram OGG/Opus files are converted to M4A before
/// recognition because SFSpeechRecognizer consumes file URLs in system audio
/// formats, not raw Telegram voice-note containers.
public final class SwiftAppleSpeechTranscriber: TelegramVoiceTranscribing {
    public var hasSpeechPermission: Bool { speechAuthorizationStatus() == .authorized }
    private let localeIdentifier: String
    private let preferOnDevice: Bool
    private let timeoutNanoseconds: UInt64
    /// Read-only authorization seam. Production uses the system status reader;
    /// the injectable form lets the headless denial boundary be exercised
    /// without changing a machine's TCC state.
    private let speechAuthorizationStatus: @Sendable () -> SFSpeechRecognizerAuthorizationStatus
    /// Words the recognizer should expect, read per note (the agent's name).
    private let contextualStrings: @Sendable () -> [String]

    public init(
        localeIdentifier: String = Locale.current.identifier,
        preferOnDevice: Bool = false,
        timeoutSeconds: TimeInterval = 45,
        speechAuthorizationStatus: @escaping @Sendable () -> SFSpeechRecognizerAuthorizationStatus = {
            SFSpeechRecognizer.authorizationStatus()
        },
        contextualStrings: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.localeIdentifier = localeIdentifier
        self.preferOnDevice = preferOnDevice
        self.timeoutNanoseconds = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
        self.speechAuthorizationStatus = speechAuthorizationStatus
        self.contextualStrings = contextualStrings
    }

    public func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription {
        // Check the non-prompting grant before materializing the remote audio.
        // A denied or fresh TCC state can never produce a transcript, and
        // returning here makes the Telegram failure/card path immediate while
        // ensuring this headless surface never reaches a prompting API.
        try validateSpeechAuthorization()
        let prepared = try await TelegramVoiceAudioPreparer.prepareSpeechURL(attachment)
        defer { prepared.cleanup() }

        let started = Date()
        let text = try await recognize(url: prepared.url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1000))
        return TelegramVoiceTranscription(
            text: text,
            backend: TelegramVoiceTranscriptionBackends.appleSpeech,
            model: TelegramVoiceTranscriptionBackends.appleSpeechModel,
            latencyMilliseconds: elapsed
        )
    }

    private func recognize(url: URL) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.recognizeWithoutTimeout(url: url)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                throw TelegramVoiceTranscriptionError.speechRecognitionFailed("timed out")
            }
            guard let text = try await group.next() else {
                throw TelegramVoiceTranscriptionError.speechRecognitionFailed("no recognition result")
            }
            group.cancelAll()
            return text
        }
    }

    private func recognizeWithoutTimeout(url: URL) async throws -> String {
        if preferOnDevice {
            do {
                return try await recognizeOnce(url: url, forceOnDevice: true)
            } catch {
                if Self.shouldRetryWithoutOnDevice(error) {
                    return try await recognizeOnce(url: url, forceOnDevice: false)
                }
                throw error
            }
        }
        return try await recognizeOnce(url: url, forceOnDevice: false)
    }

    private func recognizeOnce(url: URL, forceOnDevice: Bool) async throws -> String {
        // Read authorization only: headless Telegram work cannot present the
        // macOS prompt safely. Permission requests belong to MainActor's
        // SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined().
        // A denial here lets the caller raise a health card.
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
        if forceOnDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let taskBox = TelegramSpeechRecognitionTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        taskBox.resume(with: .success(result.bestTranscription.formattedString))
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

    private static func shouldRetryWithoutOnDevice(_ error: Error) -> Bool {
        let description = [
            (error as? LocalizedError)?.errorDescription,
            String(describing: error)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        return description.contains("siri and dictation")
            || description.contains("dictation")
            || description.contains("local speech recognition")
    }

    private func validateSpeechAuthorization() throws {
        let status = speechAuthorizationStatus()
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
