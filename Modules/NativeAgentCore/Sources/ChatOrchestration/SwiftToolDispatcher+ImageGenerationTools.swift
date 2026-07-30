import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// MARK: - OpenAI image generation tool

enum ImageGenerationToolError: Error, Equatable, Sendable, LocalizedError {
    case trustDenied
    case missingPrompt
    case unsupportedProvider(String)
    case codexUnavailable
    case codexFailed(exitCode: Int32, message: String)
    case noCodexImagesFound
    case notConfigured
    case authRejected
    case apiError(status: Int, message: String?)
    case transport(message: String)
    case invalidResponse(String)
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .trustDenied:
            return "[trust_denied] Capability 'image_generation_openai' is disabled in Trust Center. To enable: set multimodalPolicy.image_generation_openai=true"
        case .missingPrompt:
            return "prompt is required"
        case .unsupportedProvider(let provider):
            return "[image_generation_unsupported_provider] Use provider='codex', provider='codex_cli', or provider='openai_api', not '\(provider)'."
        case .codexUnavailable:
            return "[image_generation_codex_unavailable] Codex OAuth is not available or not signed in. Open Codex or run `codex login`."
        case .codexFailed(let exitCode, let message):
            return "[image_generation_codex_failed] codex exec exited \(exitCode): \(message)"
        case .noCodexImagesFound:
            return "[image_generation_no_artifact] Codex completed but no new image files were found under CODEX_HOME/generated_images. This Codex build may not expose the built-in image_gen tool to codex exec child sessions."
        case .notConfigured:
            return "[image_generation_openai_api_unavailable] Set OPENAI_API_KEY or configure data/providers/openai.json for provider='openai_api'."
        case .authRejected:
            return "[image_generation_auth_error] OpenAI rejected the API key."
        case .apiError(let status, let message):
            if let message, !message.isEmpty {
                return "[image_generation_api_error] HTTP \(status): \(message)"
            }
            return "[image_generation_api_error] HTTP \(status)"
        case .transport(let message):
            return "[image_generation_error] \(message)"
        case .invalidResponse(let message):
            return "[image_generation_invalid_response] \(message)"
        case .invalidImageData:
            return "[image_generation_invalid_image_data] Response did not include decodable base64 image data."
        }
    }
}

struct CodexImageGenerationRequest: Sendable, Equatable {
    var prompt: String
    var size: String?
    var quality: String?
    var outputFormat: String
    var count: Int
    var timeoutSeconds: Int
}

struct CodexImageGenerationInvocation: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var cwd: URL
    var timeoutSeconds: Int
    var startedAt: Date
    var codexGeneratedImagesDir: URL
    var lastMessagePath: URL
}

struct CodexImageGenerationProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var lastMessage: String
    var timedOut: Bool
    var durationMs: Int
}

struct CodexImageGenerationResult: Sendable, Equatable {
    var runId: String
    var model: String
    var sourceImages: [URL]
    var reply: String
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var timedOut: Bool
    var durationMs: Int
}

typealias CodexImageGenerationRunner = @Sendable (CodexImageGenerationInvocation) async throws -> CodexImageGenerationProcessResult

final class SwiftCodexImageGenerationClient: @unchecked Sendable {
    static let modelLabel = "codex-imagegen"
    static let maxPromptScalars = 16_000
    static let maxImageCount = 4
    static let defaultTimeoutSeconds = 600

    private let executable: String
    private let runner: CodexImageGenerationRunner
    private let codexHome: URL
    private let dataRoot: URL
    private let cwd: URL
    private let persistence: any PersistenceCoreProtocol

    init(
        executable: String = "/usr/bin/env",
        runner: @escaping CodexImageGenerationRunner = SwiftCodexImageGenerationClient.defaultRunner,
        codexHome: URL? = nil,
        dataRoot: URL? = nil,
        cwd: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.executable = executable
        self.runner = runner
        self.codexHome = codexHome ?? Self.defaultCodexHome()
        self.dataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        self.cwd = cwd ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("NativeAgent", isDirectory: true)
        self.persistence = persistence
    }

    func generate(_ request: CodexImageGenerationRequest) async throws -> CodexImageGenerationResult {
        guard await imageGenerationAllowed() else { throw ImageGenerationToolError.trustDenied }

        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw ImageGenerationToolError.missingPrompt }

        let runId = UUID().uuidString.lowercased()
        let started = Date()
        let codexImagesDir = codexHome.appendingPathComponent("generated_images", isDirectory: true)
        let knownImages = Set(Self.imageFiles(in: codexImagesDir).map(\.standardizedFileURL.path))
        let auditDir = dataRoot
            .appendingPathComponent("generated_images", isDirectory: true)
            .appendingPathComponent("codex_runs", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        let lastMessagePath = auditDir.appendingPathComponent("\(runId)-last-message.txt", isDirectory: false)

        let prompt = Self.codexPrompt(for: request, prompt: trimmedPrompt)
        let invocation = CodexImageGenerationInvocation(
            executable: executable,
            arguments: Self.codexExecArguments(
                cwd: cwd.path,
                lastMessagePath: lastMessagePath.path,
                prompt: prompt
            ),
            cwd: cwd,
            timeoutSeconds: max(30, min(1800, request.timeoutSeconds)),
            startedAt: started,
            codexGeneratedImagesDir: codexImagesDir,
            lastMessagePath: lastMessagePath
        )

        let processResult: CodexImageGenerationProcessResult
        do {
            processResult = try await runner(invocation)
        } catch {
            if error is CancellationError { throw CancellationError() }
            throw ImageGenerationToolError.transport(message: String(describing: error))
        }

        if processResult.exitCode == 127 {
            throw ImageGenerationToolError.codexUnavailable
        }
        guard processResult.exitCode == 0 else {
            let detail = [processResult.lastMessage, processResult.stderr, processResult.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "no stderr"
            throw ImageGenerationToolError.codexFailed(exitCode: processResult.exitCode, message: detail)
        }

        let newImages = Self.imageFiles(in: codexImagesDir)
            .filter { !knownImages.contains($0.standardizedFileURL.path) }
            .filter { Self.modifiedAtOrAfter($0, started.addingTimeInterval(-5)) }
            .sorted { Self.modificationDate($0) < Self.modificationDate($1) }
            .prefix(max(1, min(Self.maxImageCount, request.count)))

        guard !newImages.isEmpty else {
            throw ImageGenerationToolError.noCodexImagesFound
        }

        return CodexImageGenerationResult(
            runId: runId,
            model: Self.modelLabel,
            sourceImages: Array(newImages),
            reply: processResult.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            stdout: processResult.stdout,
            stderr: processResult.stderr,
            exitCode: processResult.exitCode,
            timedOut: processResult.timedOut,
            durationMs: processResult.durationMs
        )
    }

    private func imageGenerationAllowed() async -> Bool {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let policy = await persistence.readJSON(path, defaultValue: .object([:]))
        guard case let .object(root) = policy,
              case let .object(mm)? = root["multimodalPolicy"],
              case let .bool(allowed)? = mm["image_generation_openai"] else {
            return false
        }
        return allowed
    }

    static func defaultCodexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment["CODEX_HOME"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func codexExecArguments(cwd: String, lastMessagePath: String, prompt: String) -> [String] {
        [
            "codex", "exec",
            "--enable", "image_generation",
            "--sandbox", "workspace-write",
            "-C", cwd,
            "--color", "never",
            "-o", lastMessagePath,
            prompt,
        ]
    }

    static func codexPrompt(for request: CodexImageGenerationRequest, prompt: String) -> String {
        let count = max(1, min(maxImageCount, request.count))
        var lines: [String] = [
            "You are Codex running as an image-generation worker for the configured NativeAgent identity.",
            "Use the imagegen skill's default built-in image_gen tool. Do not use OPENAI_API_KEY, the OpenAI platform API, or the imagegen fallback CLI.",
            "Generate \(count) raster image\(count == 1 ? "" : "s") from the prompt below.",
            "Leave generated files in Codex's default generated_images location; NativeAgent will collect them after this turn.",
            "Before your final answer, verify that at least one new image file exists under CODEX_HOME/generated_images. If no actual image_gen tool is available or no image artifact exists, reply exactly IMAGE_GEN_UNAVAILABLE and do not claim success.",
        ]
        if let size = request.size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
            lines.append("Requested size/aspect: \(size).")
        }
        if let quality = request.quality?.trimmingCharacters(in: .whitespacesAndNewlines), !quality.isEmpty {
            lines.append("Requested quality/style control: \(quality).")
        }
        lines.append("Requested output format preference: \(request.outputFormat).")
        lines.append("Return only a concise final note with what was generated.")
        lines.append("")
        lines.append("Prompt:")
        lines.append(truncatedPrompt(prompt))
        return lines.joined(separator: "\n")
    }

    static func defaultRunner(_ invocation: CodexImageGenerationInvocation) async throws -> CodexImageGenerationProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.cwd

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutBuffer = SwiftToolDispatcher.BoundedBuffer(cap: 512 * 1024)
        let stderrBuffer = SwiftToolDispatcher.BoundedBuffer(cap: 256 * 1024)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }

        let timedOutFlag = SwiftToolDispatcher.AtomicFlag()
        let started = Date()
        return await withCheckedContinuation { (cont: CheckedContinuation<CodexImageGenerationProcessResult, Never>) in
            let resumed = SwiftToolDispatcher.ResumeGuard()
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                SwiftToolDispatcher.drainPipeNonBlocking(stdout.fileHandleForReading, into: stdoutBuffer)
                SwiftToolDispatcher.drainPipeNonBlocking(stderr.fileHandleForReading, into: stderrBuffer)

                var stdoutText = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
                var stderrText = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
                if stdoutBuffer.truncated { stdoutText += "\n[stdout truncated]" }
                if stderrBuffer.truncated { stderrText += "\n[stderr truncated]" }
                let lastMessage = (try? String(contentsOf: invocation.lastMessagePath, encoding: .utf8)) ?? ""
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let didTimeOut = timedOutFlag.isSet && proc.terminationStatus != 0

                guard resumed.tryResume() else { return }
                cont.resume(returning: CodexImageGenerationProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutText,
                    stderr: stderrText,
                    lastMessage: lastMessage,
                    timedOut: didTimeOut,
                    durationMs: durationMs
                ))
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guard resumed.tryResume() else { return }
                cont.resume(returning: CodexImageGenerationProcessResult(
                    exitCode: 127,
                    stdout: "",
                    stderr: String(describing: error),
                    lastMessage: "",
                    timedOut: false,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000)
                ))
                return
            }

            SwiftToolDispatcher.armSubprocessTimeout(
                process: process,
                timeoutSeconds: invocation.timeoutSeconds
            ) {
                timedOutFlag.set()
            }
        }
    }

    private static func imageFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let allowed = Set(["png", "jpg", "jpeg", "webp"])
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  allowed.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private static func modifiedAtOrAfter(_ url: URL, _ date: Date) -> Bool {
        modificationDate(url) >= date
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private static func truncatedPrompt(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars
        guard scalars.count > maxPromptScalars else { return prompt }
        return String(String.UnicodeScalarView(scalars.prefix(maxPromptScalars)))
    }
}

final class SwiftCodexOAuthImageGenerationClient: @unchecked Sendable {
    static let codexEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let imageModel = "gpt-image-2"
    static let maxPromptScalars = 16_000
    static let maxImageCount = 4
    static let defaultTimeoutSeconds = 600

    private static let instructions = "You are an assistant that must fulfill image generation requests by using the image_generation tool when provided."

    private let session: URLSession
    private let endpoint: URL
    private let authAdapter: OpenAIOAuthDirectAdapter
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol

    init(
        session: URLSession = OpenAIOAuthDirectAdapter.productionSession,
        endpoint: URL = SwiftCodexOAuthImageGenerationClient.codexEndpoint,
        authPathOverride: URL? = nil,
        dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.session = session
        self.endpoint = endpoint
        self.dataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        self.persistence = persistence
        self.authAdapter = OpenAIOAuthDirectAdapter(
            session: session,
            endpoint: endpoint,
            authPathOverride: authPathOverride,
            telemetryDataRootOverride: dataRoot
        )
    }

    func generate(_ request: CodexImageGenerationRequest) async throws -> CodexImageGenerationResult {
        guard await imageGenerationAllowed() else { throw ImageGenerationToolError.trustDenied }

        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw ImageGenerationToolError.missingPrompt }

        let runId = UUID().uuidString.lowercased()
        let count = max(1, min(Self.maxImageCount, request.count))
        let size = Self.normalizedSize(request.size)
        let quality = Self.normalizedQuality(request.quality)
        let timeoutSeconds = max(30, min(1800, request.timeoutSeconds))
        let started = DispatchTime.now().uptimeNanoseconds
        let outputDir = dataRoot
            .appendingPathComponent("generated_images", isDirectory: true)
            .appendingPathComponent("codex_oauth_runs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var sources: [URL] = []
        var replyParts: [String] = []
        for idx in 0..<count {
            let image = try await collectImage(
                prompt: Self.truncatedPrompt(trimmedPrompt),
                size: size,
                quality: quality,
                timeoutSeconds: timeoutSeconds
            )
            let path = outputDir.appendingPathComponent("\(runId)-\(idx + 1).png", isDirectory: false)
            try image.data.write(to: path, options: .atomic)
            _ = chmod(path.path, 0o600)
            sources.append(path)
            let reply = image.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { replyParts.append(reply) }
        }

        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        return CodexImageGenerationResult(
            runId: runId,
            model: "\(Self.imageModel)-\(quality)",
            sourceImages: sources,
            reply: replyParts.joined(separator: "\n"),
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false,
            durationMs: durationMs
        )
    }

    private func imageGenerationAllowed() async -> Bool {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let policy = await persistence.readJSON(path, defaultValue: .object([:]))
        guard case let .object(root) = policy,
              case let .object(mm)? = root["multimodalPolicy"],
              case let .bool(allowed)? = mm["image_generation_openai"] else {
            return false
        }
        return allowed
    }

    private struct CollectedImage: Sendable, Equatable {
        var data: Data
        var reply: String
    }

    private func collectImage(prompt: String, size: String, quality: String, timeoutSeconds: Int) async throws -> CollectedImage {
        let body = Self.codexResponsesPayload(prompt: prompt, size: size, quality: quality)
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ImageGenerationToolError.invalidResponse("encode Codex image request: \(error.localizedDescription)")
        }

        for attempt in 0...1 {
            let context: CodexOAuthAccessContext
            do {
                context = try await authAdapter.codexAccessContext(forceRefresh: attempt == 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ImageGenerationToolError.codexUnavailable
            }

            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = TimeInterval(timeoutSeconds)
            urlRequest.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue(context.accountID, forHTTPHeaderField: "chatgpt-account-id")
            urlRequest.setValue(
                OpenAIOAuthDirectAdapter.codexBackendOriginator,
                forHTTPHeaderField: "originator"
            )
            urlRequest.setValue(
                OpenAIOAuthDirectAdapter.codexBackendUserAgent,
                forHTTPHeaderField: "User-Agent"
            )
            urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = bodyData

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch {
                if error is CancellationError { throw CancellationError() }
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    throw CancellationError()
                }
                throw ImageGenerationToolError.transport(message: nsError.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ImageGenerationToolError.transport(message: "non-HTTP response")
            }
            if http.statusCode == 401 {
                if attempt == 0 { continue }
                throw ImageGenerationToolError.authRejected
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ImageGenerationToolError.apiError(
                    status: http.statusCode,
                    message: Self.boundedBodyString(data)
                )
            }

            let parsed = Self.parseCodexImageSSE(data)
            if let error = parsed.error {
                throw ImageGenerationToolError.invalidResponse(error)
            }
            guard let b64 = parsed.imageBase64,
                  let imageData = Data(base64Encoded: b64) else {
                throw ImageGenerationToolError.invalidImageData
            }
            return CollectedImage(data: imageData, reply: parsed.reply)
        }
        throw ImageGenerationToolError.codexUnavailable
    }

    static func codexResponsesPayload(prompt: String, size: String, quality: String) -> [String: Any] {
        [
            "model": nativeAgentPrimaryModel,
            "store": false,
            "instructions": instructions,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": truncatedPrompt(prompt),
                        ],
                    ],
                ],
            ],
            "tools": [
                [
                    "type": "image_generation",
                    "model": imageModel,
                    "size": size,
                    "quality": quality,
                    "output_format": "png",
                    "background": "opaque",
                    "partial_images": 1,
                ],
            ],
            "tool_choice": [
                "type": "allowed_tools",
                "mode": "required",
                "tools": [
                    ["type": "image_generation"],
                ],
            ],
            "stream": true,
        ]
    }

    private struct ParsedCodexImageSSE: Sendable, Equatable {
        var imageBase64: String?
        var reply: String
        var error: String?
    }

    private static func parseCodexImageSSE(_ data: Data) -> ParsedCodexImageSSE {
        var imageBase64: String?
        var textDeltas: [String] = []
        var errorMessage: String?

        for event in SSEEventParser.parse(data: data) {
            let raw = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw == "[DONE]" { continue }
            guard let payloadData = raw.data(using: .utf8),
                  var payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }
            if let eventName = event.event, payload["type"] == nil {
                payload["type"] = eventName
            }
            let type = payload["type"] as? String ?? ""
            if type == "response.output_text.delta",
               let delta = payload["delta"] as? String,
               !delta.isEmpty {
                textDeltas.append(delta)
            } else if type == "response.failed" {
                let error = ((payload["response"] as? [String: Any])?["error"] as? [String: Any]) ?? [:]
                errorMessage = (error["message"] as? String) ?? "Codex image generation failed"
            } else if type == "error" {
                let error = payload["error"] as? [String: Any]
                let message = (error?["message"] as? String)
                    ?? (payload["message"] as? String)
                    ?? "Codex image generation error"
                if let code = (error?["code"] as? String) ?? (error?["type"] as? String),
                   !code.isEmpty {
                    errorMessage = "\(message) [code=\(code)]"
                } else {
                    errorMessage = message
                }
            }
            if let found = extractImageBase64(from: payload) {
                imageBase64 = found
            }
        }

        return ParsedCodexImageSSE(
            imageBase64: imageBase64,
            reply: textDeltas.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            error: errorMessage
        )
    }

    private static func extractImageBase64(from value: Any) -> String? {
        var found: String?
        if let object = value as? [String: Any] {
            if object["type"] as? String == "image_generation_call",
               let result = object["result"] as? String,
               !result.isEmpty {
                found = result
            }
            if let partial = object["partial_image_b64"] as? String, !partial.isEmpty {
                found = partial
            }
            for child in object.values {
                if let nested = extractImageBase64(from: child) {
                    found = nested
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let nested = extractImageBase64(from: child) {
                    found = nested
                }
            }
        }
        return found
    }

    private static func normalizedSize(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1536x1024", "landscape", "wide", "16:9", "3:2":
            return "1536x1024"
        case "1024x1536", "portrait", "vertical", "2:3", "9:16":
            return "1024x1536"
        case "1024x1024", "square", "1:1":
            return "1024x1024"
        default:
            return "1024x1024"
        }
    }

    private static func normalizedQuality(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low", "gpt-image-2-low":
            return "low"
        case "high", "gpt-image-2-high":
            return "high"
        default:
            return "medium"
        }
    }

    private static func truncatedPrompt(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars
        guard scalars.count > maxPromptScalars else { return prompt }
        return String(String.UnicodeScalarView(scalars.prefix(maxPromptScalars)))
    }

    private static func boundedBodyString(_ data: Data, maxBytes: Int = 4_096) -> String {
        guard !data.isEmpty else { return "empty error body" }
        let prefix = data.prefix(maxBytes)
        let text = String(decoding: prefix, as: UTF8.self)
        if data.count > maxBytes {
            return text + "\n...(truncated \(data.count - maxBytes) bytes)"
        }
        return text
    }
}

struct OpenAIImageGenerationRequest: Sendable, Equatable {
    var prompt: String
    var model: String
    var size: String?
    var quality: String?
    var outputFormat: String
    var count: Int
}

struct OpenAIImageGenerationResult: Sendable, Equatable {
    struct Image: Sendable, Equatable {
        var index: Int
        var data: Data
        var revisedPrompt: String?
    }

    var model: String
    var images: [Image]
    var usage: JSONValue?
}

final class SwiftOpenAIImageGenerationClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!
    static let defaultModel = "gpt-image-2"
    static let userAgent = "NativeAgent/0.2.0"
    static let timeoutSeconds: TimeInterval = 180
    static let maxPromptScalars = 16_000
    static let maxImageCount = 4

    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol

    init(
        session: URLSession = .shared,
        endpoint: URL = SwiftOpenAIImageGenerationClient.endpoint,
        apiKeyOverride: String? = nil,
        dataRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKeyOverride = apiKeyOverride
        self.dataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
        self.persistence = persistence
    }

    private func imageGenerationAllowed() async -> Bool {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let policy = await persistence.readJSON(path, defaultValue: .object([:]))
        guard case let .object(root) = policy,
              case let .object(mm)? = root["multimodalPolicy"],
              case let .bool(allowed)? = mm["image_generation_openai"] else {
            return false
        }
        return allowed
    }

    func generate(_ request: OpenAIImageGenerationRequest) async throws -> OpenAIImageGenerationResult {
        guard await imageGenerationAllowed() else { throw ImageGenerationToolError.trustDenied }

        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw ImageGenerationToolError.missingPrompt }

        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: "OPENAI_API_KEY",
                    providerConfigFile: "openai.json",
                    dataRoot: dataRoot),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageGenerationToolError.notConfigured
        }

        var body: [String: Any] = [
            "model": request.model,
            "prompt": Self.truncatedPrompt(trimmedPrompt),
            "n": max(1, min(Self.maxImageCount, request.count)),
            "output_format": request.outputFormat,
        ]
        if let size = request.size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
            body["size"] = size
        }
        if let quality = request.quality?.trimmingCharacters(in: .whitespacesAndNewlines), !quality.isEmpty {
            body["quality"] = quality
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.timeoutSeconds
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            if error is CancellationError { throw CancellationError() }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw ImageGenerationToolError.transport(message: nsError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ImageGenerationToolError.transport(message: "non-HTTP response")
        }
        if http.statusCode == 401 { throw ImageGenerationToolError.authRejected }
        guard (200..<300).contains(http.statusCode) else {
            throw ImageGenerationToolError.apiError(
                status: http.statusCode,
                message: Self.apiErrorMessage(from: data)
            )
        }

        let parsed = try JSONValue.parse(data)
        guard case let .object(root) = parsed,
              case let .array(rows)? = root["data"] else {
            throw ImageGenerationToolError.invalidResponse("missing data array")
        }

        var images: [OpenAIImageGenerationResult.Image] = []
        for (idx, row) in rows.enumerated() {
            guard case let .object(obj) = row,
                  case let .string(b64)? = obj["b64_json"],
                  let bytes = Data(base64Encoded: b64) else {
                throw ImageGenerationToolError.invalidImageData
            }
            let revised: String? = {
                if case let .string(value)? = obj["revised_prompt"] { return value }
                return nil
            }()
            images.append(.init(index: idx, data: bytes, revisedPrompt: revised))
        }
        guard !images.isEmpty else { throw ImageGenerationToolError.invalidImageData }

        return OpenAIImageGenerationResult(
            model: request.model,
            images: images,
            usage: root["usage"]
        )
    }

    private static func truncatedPrompt(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars
        guard scalars.count > maxPromptScalars else { return prompt }
        return String(String.UnicodeScalarView(scalars.prefix(maxPromptScalars)))
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let parsed = try? JSONValue.parse(data),
              case let .object(root) = parsed,
              case let .object(error)? = root["error"] else {
            return nil
        }
        if case let .string(message)? = error["message"] { return message }
        return nil
    }
}

extension SwiftToolDispatcher {
    func impl_image_generate(input: [String: JSONValue]) async -> JSONValue {
        let prompt = jsonString(input["prompt"]) ?? jsonString(input["description"]) ?? ""
        let provider = normalizedImageProvider(jsonString(input["provider"] ?? input["backend"]))
        let model = normalizedImageModel(jsonString(input["model"]))
        let outputFormat = normalizedImageOutputFormat(jsonString(input["output_format"] ?? input["format"]))
        do {
            switch provider {
            case "codex":
                let request = CodexImageGenerationRequest(
                    prompt: prompt,
                    size: jsonString(input["size"]),
                    quality: jsonString(input["quality"]) ?? jsonString(input["model"]),
                    outputFormat: "png",
                    count: jsonInt(input["n"] ?? input["count"]) ?? 1,
                    timeoutSeconds: jsonInt(input["timeout_seconds"]) ?? SwiftCodexOAuthImageGenerationClient.defaultTimeoutSeconds
                )
                let client = SwiftCodexOAuthImageGenerationClient(dataRoot: dataRoot)
                let result = try await client.generate(request)
                return try await persistCodexImageGenerationResult(
                    result,
                    request: request,
                    prompt: prompt,
                    provider: "codex"
                )
            case "codex_cli":
                let request = CodexImageGenerationRequest(
                    prompt: prompt,
                    size: jsonString(input["size"]),
                    quality: jsonString(input["quality"]),
                    outputFormat: outputFormat,
                    count: jsonInt(input["n"] ?? input["count"]) ?? 1,
                    timeoutSeconds: jsonInt(input["timeout_seconds"]) ?? SwiftCodexImageGenerationClient.defaultTimeoutSeconds
                )
                let client = SwiftCodexImageGenerationClient(dataRoot: dataRoot)
                let result = try await client.generate(request)
                return try await persistCodexImageGenerationResult(
                    result,
                    request: request,
                    prompt: prompt,
                    provider: "codex_cli"
                )
            case "openai_api":
                let request = OpenAIImageGenerationRequest(
                    prompt: prompt,
                    model: model,
                    size: jsonString(input["size"]),
                    quality: jsonString(input["quality"]),
                    outputFormat: outputFormat,
                    count: jsonInt(input["n"] ?? input["count"]) ?? 1
                )
                let client = SwiftOpenAIImageGenerationClient(dataRoot: dataRoot)
                let result = try await client.generate(request)
                return try await persistOpenAIImageGenerationResult(
                    result,
                    request: request,
                    prompt: prompt
                )
            default:
                throw ImageGenerationToolError.unsupportedProvider(provider)
            }
        } catch {
            return imageGenerationErrorEnvelope(error)
        }
    }

    private func persistOpenAIImageGenerationResult(
        _ result: OpenAIImageGenerationResult,
        request: OpenAIImageGenerationRequest,
        prompt: String
    ) async throws -> JSONValue {
        let runId = UUID().uuidString.lowercased()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let baseDir = dataRoot
            .appendingPathComponent("generated_images", isDirectory: true)
        let receiptsDir = baseDir.appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)

        var imageRows: [JSONValue] = []
        for image in result.images {
            let filename = result.images.count == 1
                ? "\(runId).\(request.outputFormat)"
                : "\(runId)-\(image.index + 1).\(request.outputFormat)"
            let path = baseDir.appendingPathComponent(filename, isDirectory: false)
            try image.data.write(to: path, options: .atomic)
            _ = chmod(path.path, 0o600)
            var row: [String: JSONValue] = [
                "index": .int(Int64(image.index)),
                "path": .string(path.path),
                "filename": .string(filename),
                "byteSize": .int(Int64(image.data.count)),
            ]
            if let revised = image.revisedPrompt, !revised.isEmpty {
                row["revisedPrompt"] = .string(ChatSecretRedactor.redactText(String(revised.prefix(1_000))))
            }
            imageRows.append(.object(row))
        }

        var receipt: [String: JSONValue] = [
            "id": .string(runId),
            "tool": .string("image_generate"),
            "provider": .string("openai_api"),
            "model": .string(result.model),
            "createdAt": .string(createdAt),
            "promptPreview": .string(ChatSecretRedactor.redactText(String(prompt.prefix(1_000)))),
            "size": request.size.map { .string($0) } ?? .null,
            "quality": request.quality.map { .string($0) } ?? .null,
            "outputFormat": .string(request.outputFormat),
            "count": .int(Int64(result.images.count)),
            "images": .array(imageRows),
        ]
        if let usage = result.usage {
            receipt["usage"] = usage
        }

        let receiptPath = receiptsDir.appendingPathComponent("\(runId).json", isDirectory: false)
        try await SwiftNativePersistenceCore().writeJSON(.object(receipt), to: receiptPath)

        var response = receipt
        response["status"] = .string("ok")
        response["receiptPath"] = .string(receiptPath.path)
        response["message"] = .string("Generated \(result.images.count) image\(result.images.count == 1 ? "" : "s") with \(result.model).")
        return .object(response)
    }

    private func persistCodexImageGenerationResult(
        _ result: CodexImageGenerationResult,
        request: CodexImageGenerationRequest,
        prompt: String,
        provider: String = "codex"
    ) async throws -> JSONValue {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let baseDir = dataRoot
            .appendingPathComponent("generated_images", isDirectory: true)
        let receiptsDir = baseDir.appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)

        var imageRows: [JSONValue] = []
        for (idx, source) in result.sourceImages.enumerated() {
            let ext = normalizedImageOutputFormat(source.pathExtension)
            let filename = result.sourceImages.count == 1
                ? "\(result.runId).\(ext)"
                : "\(result.runId)-\(idx + 1).\(ext)"
            let destination = baseDir.appendingPathComponent(filename, isDirectory: false)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            _ = chmod(destination.path, 0o600)
            let byteSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            imageRows.append(.object([
                "index": .int(Int64(idx)),
                "path": .string(destination.path),
                "filename": .string(filename),
                "byteSize": .int(Int64(byteSize)),
                "codexSourcePath": .string(source.path),
            ]))
        }

        var receipt: [String: JSONValue] = [
            "id": .string(result.runId),
            "tool": .string("image_generate"),
            "provider": .string(provider),
            "model": .string(result.model),
            "createdAt": .string(createdAt),
            "promptPreview": .string(ChatSecretRedactor.redactText(String(prompt.prefix(1_000)))),
            "size": request.size.map { .string($0) } ?? .null,
            "quality": request.quality.map { .string($0) } ?? .null,
            "outputFormat": .string(request.outputFormat),
            "count": .int(Int64(imageRows.count)),
            "durationMs": .int(Int64(result.durationMs)),
            "exitCode": .int(Int64(result.exitCode)),
            "images": .array(imageRows),
        ]
        if !result.reply.isEmpty {
            receipt["codexReply"] = .string(ChatSecretRedactor.redactText(String(result.reply.prefix(2_000))))
        }
        if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receipt["codexStderrPreview"] = .string(ChatSecretRedactor.redactText(String(result.stderr.prefix(2_000))))
        }

        let receiptPath = receiptsDir.appendingPathComponent("\(result.runId).json", isDirectory: false)
        try await SwiftNativePersistenceCore().writeJSON(.object(receipt), to: receiptPath)

        var response = receipt
        response["status"] = .string("ok")
        response["receiptPath"] = .string(receiptPath.path)
        response["message"] = .string("Generated \(imageRows.count) image\(imageRows.count == 1 ? "" : "s") through \(provider == "codex_cli" ? "Codex CLI" : "Codex OAuth").")
        return .object(response)
    }

    private func imageGenerationErrorEnvelope(_ error: Error) -> JSONValue {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let reason: String = {
            guard let e = error as? ImageGenerationToolError else { return "image_generation_failed" }
            switch e {
            case .trustDenied: return "trust_denied"
            case .missingPrompt: return "missing_prompt"
            case .unsupportedProvider: return "unsupported_provider"
            case .codexUnavailable: return "codex_unavailable"
            case .codexFailed: return "codex_failed"
            case .noCodexImagesFound: return "no_codex_images_found"
            case .notConfigured: return "not_configured"
            case .authRejected: return "auth_rejected"
            case .apiError: return "api_error"
            case .transport: return "transport_error"
            case .invalidResponse: return "invalid_response"
            case .invalidImageData: return "invalid_image_data"
            }
        }()
        return .object([
            "status": .string("failed"),
            "tool": .string("image_generate"),
            "reason": .string(reason),
            "error": .string(message),
        ])
    }

    private func normalizedImageProvider(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "codex", "codex_oauth", "codex-oauth", "chatgpt", "subscription":
            return "codex"
        case "codex_cli", "codex-cli", "cli":
            return "codex_cli"
        case "openai", "openai_api", "openai-api", "api", "platform":
            return "openai_api"
        case let other?:
            return other
        }
    }

    private func normalizedImageModel(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SwiftOpenAIImageGenerationClient.defaultModel : trimmed
    }

    private func normalizedImageOutputFormat(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "jpeg", "jpg": return "jpeg"
        case "webp": return "webp"
        default: return "png"
        }
    }
}
