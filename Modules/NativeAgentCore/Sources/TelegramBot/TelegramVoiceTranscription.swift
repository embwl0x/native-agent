@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
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
    func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription
}

public enum TelegramVoiceTranscriptionBackends {
    public static let appleSpeech = "apple_speech"
    public static let appleSpeechModel = "apple-speech"
    public static let openAI = "openai"
    public static let openAIModel = "gpt-4o-mini-transcribe"

    public static func canonical(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "", "apple", "apple_speech", "speech", "sfspeech", "sfspeechrecognizer", "native", "local":
            return appleSpeech
        case "openai", "openai_whisper", "whisper", "whisper_api":
            return openAI
        default:
            return normalized
        }
    }

    public static func defaultModel(for backend: String) -> String {
        isOpenAI(backend) ? openAIModel : appleSpeechModel
    }

    public static func isAppleSpeech(_ backend: String) -> Bool {
        canonical(backend) == appleSpeech
    }

    public static func isOpenAI(_ backend: String) -> Bool {
        canonical(backend) == openAI
    }

    public static func isSupported(_ backend: String) -> Bool {
        isAppleSpeech(backend) || isOpenAI(backend)
    }

    public static func requiresAPIKey(_ backend: String) -> Bool {
        isOpenAI(backend)
    }
}

public enum TelegramVoiceTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case missingAudioBytes
    case notConfigured
    case authRejected
    case apiError(status: Int, message: String?)
    case malformedResponse
    case conversionFailed(String)
    case speechPermissionDenied(String)
    case speechUnavailable(String)
    case speechRecognitionFailed(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAudioBytes:
            return "voice transcription: missing audio bytes"
        case .notConfigured:
            return "voice transcription: no OpenAI platform key configured"
        case .authRejected:
            return "voice transcription: OpenAI token rejected"
        case .apiError(let status, let message):
            if let message, !message.isEmpty {
                return "voice transcription: HTTP \(status): \(message)"
            }
            return "voice transcription: HTTP \(status)"
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
        case .transport(let message):
            return "voice transcription: \(message)"
        }
    }
}

private final class TelegramAVExportSessionBox: @unchecked Sendable {
    let export: AVAssetExportSession

    init(_ export: AVAssetExportSession) {
        self.export = export
    }
}

private final class TelegramSpeechRecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var didResume = false

    func set(_ task: SFSpeechRecognitionTask, continuation: CheckedContinuation<String, Error>) {
        lock.withLock {
            self.task = task
            self.continuation = continuation
        }
    }

    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard !didResume else { return nil }
            didResume = true
            let continuation = self.continuation
            self.continuation = nil
            task?.cancel()
            task = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func resume(with result: Result<String, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard !didResume else { return nil }
            didResume = true
            let continuation = self.continuation
            self.continuation = nil
            task = nil
            return continuation
        }
        guard let continuation else { return }
        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    deinit {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }
}

private struct TelegramPreparedVoiceAudio: Sendable {
    let url: URL
    let cleanupURLs: [URL]

    func cleanup() {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private enum TelegramVoiceAudioPreparer {
    static let speechReadableExtensions: Set<String> = ["aif", "aiff", "caf", "m4a", "mp3", "mp4", "wav"]

    static func prepareSpeechURL(_ attachment: TelegramMediaAttachment) async throws -> TelegramPreparedVoiceAudio {
        guard let bytes = attachment.bytes, !bytes.isEmpty else {
            throw TelegramVoiceTranscriptionError.missingAudioBytes
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-telegram-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let inputExt = fileExtension(for: attachment.captureFilename) ?? fileExtension(forMIMEType: attachment.mimeType) ?? "oga"
        let input = tempRoot.appendingPathComponent("\(id).\(inputExt)")
        try bytes.write(to: input, options: .atomic)

        if speechReadableExtensions.contains(inputExt) {
            return TelegramPreparedVoiceAudio(url: input, cleanupURLs: [input])
        }

        let output = tempRoot.appendingPathComponent("\(id).m4a")
        do {
            try await transcodeWithAVFoundation(input: input, output: output)
            return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
        } catch {
            try? FileManager.default.removeItem(at: output)
        }

        if let ffmpeg = ffmpegURL() {
            try await transcodeWithFFmpeg(ffmpeg: ffmpeg, input: input, output: output)
            return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
        }

        throw TelegramVoiceTranscriptionError.conversionFailed(
            "Telegram OGG/Opus audio is not readable by AVFoundation on this Mac, and no ffmpeg binary was found"
        )
    }

    static func transcodeToM4AAttachment(_ attachment: TelegramMediaAttachment) async throws -> TelegramMediaAttachment {
        let prepared = try await prepareM4AURL(attachment)
        defer { prepared.cleanup() }
        let converted = try Data(contentsOf: prepared.url)
        return TelegramMediaAttachment(
            kind: attachment.kind,
            fileId: attachment.fileId,
            mimeType: "audio/mp4",
            sizeBytes: converted.count,
            bytes: converted,
            captureFilename: "telegram_voice_\(UUID().uuidString).m4a"
        )
    }

    private static func prepareM4AURL(_ attachment: TelegramMediaAttachment) async throws -> TelegramPreparedVoiceAudio {
        guard let bytes = attachment.bytes, !bytes.isEmpty else {
            throw TelegramVoiceTranscriptionError.missingAudioBytes
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-telegram-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let inputExt = fileExtension(for: attachment.captureFilename) ?? fileExtension(forMIMEType: attachment.mimeType) ?? "oga"
        let input = tempRoot.appendingPathComponent("\(id).\(inputExt)")
        let output = tempRoot.appendingPathComponent("\(id).m4a")
        try bytes.write(to: input, options: .atomic)

        if inputExt == "m4a" {
            return TelegramPreparedVoiceAudio(url: input, cleanupURLs: [input])
        }

        do {
            try await transcodeWithAVFoundation(input: input, output: output)
            return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
        } catch {
            try? FileManager.default.removeItem(at: output)
        }

        if let ffmpeg = ffmpegURL() {
            try await transcodeWithFFmpeg(ffmpeg: ffmpeg, input: input, output: output)
            return TelegramPreparedVoiceAudio(url: output, cleanupURLs: [input, output])
        }

        throw TelegramVoiceTranscriptionError.conversionFailed(
            "audio is not readable by AVFoundation on this Mac, and no ffmpeg binary was found"
        )
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

    static func mimeType(for filename: String?) -> String {
        switch fileExtension(for: filename) {
        case "mp3": return "audio/mpeg"
        case "mp4", "m4a": return "audio/mp4"
        case "mpeg", "mpga": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "webm": return "audio/webm"
        case "oga", "ogg", "opus": return "audio/ogg"
        default: return "application/octet-stream"
        }
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
        try await Task.detached(priority: .utility) {
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
            do {
                try process.run()
            } catch {
                throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg failed to start: \(error.localizedDescription)")
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                if process.isRunning {
                    process.terminate()
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw TelegramVoiceTranscriptionError.conversionFailed(
                    "ffmpeg exited \(process.terminationStatus)\(message.map { ": \($0)" } ?? "")"
                )
            }
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw TelegramVoiceTranscriptionError.conversionFailed("ffmpeg did not write output audio")
            }
        }.value
    }
}

/// Swift-native, no-API-key Telegram voice-note transcriber backed by Apple's
/// Speech framework. Telegram OGG/Opus files are converted to M4A before
/// recognition because SFSpeechRecognizer consumes file URLs in system audio
/// formats, not raw Telegram voice-note containers.
public final class SwiftAppleSpeechTranscriber: TelegramVoiceTranscribing {
    private let localeIdentifier: String
    private let preferOnDevice: Bool
    private let timeoutNanoseconds: UInt64

    public init(
        localeIdentifier: String = Locale.current.identifier,
        preferOnDevice: Bool = false,
        timeoutSeconds: TimeInterval = 45
    ) {
        self.localeIdentifier = localeIdentifier
        self.preferOnDevice = preferOnDevice
        self.timeoutNanoseconds = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
    }

    public func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription {
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
        // PATCH-2026-08-18: READ, never REQUEST.
        //
        // This method runs HEADLESS — off an inbound Telegram update, with no
        // active app and no window. Calling SFSpeechRecognizer.requestAuthorization
        // here (as this code did until 2026-08-18) does NOT defer the prompt: macOS
        // cannot render it, so it resolves the request .denied immediately, without
        // recording a real user decision. TCC then considers the grant RESOLVED and
        // will never ask again — so a single inbound voice note on a fresh install
        // permanently bricked Speech Recognition for the whole app, including the
        // in-app mic button. That is the root cause of the 130dc377 regression.
        //
        // The prompting sibling now lives in exactly one place:
        // SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined(),
        // which is @MainActor and only fires at launch/at a user's click. Here we
        // only ever READ, and fail loudly so the caller can raise a health card.
        let status = Self.currentSpeechAuthorization()
        guard status == .authorized else {
            throw TelegramVoiceTranscriptionError.speechPermissionDenied(Self.authorizationLabel(status))
        }
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TelegramVoiceTranscriptionError.speechUnavailable("locale \(localeIdentifier) is not supported")
        }
        guard recognizer.isAvailable else {
            throw TelegramVoiceTranscriptionError.speechUnavailable("recognizer is not currently available")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
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

    /// Non-prompting class-level READ of the current grant.
    ///
    /// Deliberately NOT `requestAuthorization`. See recognizeOnce(url:forceOnDevice:)
    /// for why a request fired from this headless context is destructive rather
    /// than merely useless. If this ever needs to become a request again, it does
    /// not — route the user to SystemPermissionPreflight instead.
    private static func currentSpeechAuthorization() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

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

/// Swift-native Telegram voice-note transcriber. It calls OpenAI's
/// `/v1/audio/transcriptions` endpoint directly, with no external runtime and no
/// local Whisper CLI. The default model favors speed for short Telegram notes;
/// set `voice_transcription_model` to `whisper-1` for literal Whisper.
public final class SwiftOpenAIWhisperTranscriber: TelegramVoiceTranscribing {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let userAgent = "NativeAgent/0.2.0"
    public static let supportedExtensions: Set<String> = ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"]

    private let session: URLSession
    private let endpoint: URL
    private let model: String
    private let apiKeyOverride: String?
    private let dataRoot: URL

    public init(
        session: URLSession = .shared,
        endpoint: URL = SwiftOpenAIWhisperTranscriber.endpoint,
        model: String = TelegramVoiceTranscriptionBackends.openAIModel,
        apiKeyOverride: String? = nil,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.session = session
        self.endpoint = endpoint
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TelegramVoiceTranscriptionBackends.openAIModel
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKeyOverride = apiKeyOverride
        self.dataRoot = dataRoot
    }

    public func transcribe(_ attachment: TelegramMediaAttachment) async throws -> TelegramVoiceTranscription {
        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: "OPENAI_API_KEY",
                    providerConfigFile: "openai.json",
                    dataRoot: dataRoot
                ),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TelegramVoiceTranscriptionError.notConfigured
        }
        guard let originalBytes = attachment.bytes, !originalBytes.isEmpty else {
            throw TelegramVoiceTranscriptionError.missingAudioBytes
        }

        let prepared = try await prepareForOpenAI(attachment)
        guard let audioBytes = prepared.bytes, !audioBytes.isEmpty else {
            throw TelegramVoiceTranscriptionError.missingAudioBytes
        }

        let started = Date()
        let body = Self.multipartBody(
            fileField: "file",
            filename: prepared.captureFilename ?? "telegram_voice.m4a",
            mimeType: prepared.mimeType ?? TelegramVoiceAudioPreparer.mimeType(for: prepared.captureFilename),
            fileBytes: audioBytes,
            fields: [
                "model": model,
                "response_format": "json",
            ]
        )
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if error is CancellationError { throw CancellationError() }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw TelegramVoiceTranscriptionError.transport(ns.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TelegramVoiceTranscriptionError.transport("non-HTTP response")
        }
        if http.statusCode == 401 {
            throw TelegramVoiceTranscriptionError.authRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TelegramVoiceTranscriptionError.apiError(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw TelegramVoiceTranscriptionError.malformedResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1000))
        return TelegramVoiceTranscription(
            text: trimmed,
            backend: "openai",
            model: model,
            latencyMilliseconds: elapsed
        )
    }

    private func prepareForOpenAI(_ attachment: TelegramMediaAttachment) async throws -> TelegramMediaAttachment {
        let ext = TelegramVoiceAudioPreparer.fileExtension(for: attachment.captureFilename)
        if let ext, Self.supportedExtensions.contains(ext) {
            return attachment
        }
        do {
            return try await TelegramVoiceAudioPreparer.transcodeToM4AAttachment(attachment)
        } catch {
            // Some providers accept more than the public format list. If native
            // conversion cannot read the source, fall back to the original file
            // instead of throwing before the transcription service gets a chance.
            return attachment
        }
    }

    private static func multipartBody(
        fileField: String,
        filename: String,
        mimeType: String,
        fileBytes: Data,
        fields: [String: String]
    ) -> (boundary: String, data: Data) {
        let boundary = "NativeAgentBoundary-\(UUID().uuidString)"
        var data = Data()
        func append(_ string: String) {
            data.append(Data(string.utf8))
        }
        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileBytes)
        append("\r\n--\(boundary)--\r\n")
        return (boundary, data)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = obj["message"] as? String { return message }
        if let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }
}
