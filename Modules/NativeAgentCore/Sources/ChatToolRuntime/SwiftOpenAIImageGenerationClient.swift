import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Dispatcher
import ImageIO
import Desk
import Experiences
import ToolExecution
// Blueprint: | `SwiftOpenAIImageGenerationClient.swift` | OpenAI image request/result values and HTTP transport; default-deny admission, API credentials and named response failures |

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

final class SwiftOpenAIImageGenerationClient: Sendable {
    static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!
    static let userAgent = "NativeAgent/0.2.0"
    static let timeoutSeconds: TimeInterval = 180
    static let maxImageCount = 4

    private let dataRoot: URL

    init(dataRoot: URL? = nil) {
        self.dataRoot = dataRoot ?? PersistenceCore.defaultDataRoot()
    }

    func generate(_ request: OpenAIImageGenerationRequest) async throws -> OpenAIImageGenerationResult {
        guard try await ImageGenerationAdmission.allowed(dataRoot: dataRoot) else { throw ImageGenerationToolError.trustDenied }

        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw ImageGenerationToolError.missingPrompt }

        guard let key = LLMCredentialResolver.resolveAPIKey(
            providerConfigFile: "openai.json",
            dataRoot: dataRoot),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageGenerationToolError.notConfigured
        }

        var body: [String: Any] = [
            "model": request.model,
            "prompt": ImageGenerationAdmission.clippedPrompt(trimmedPrompt),
            "n": max(1, min(Self.maxImageCount, request.count)),
            "output_format": request.outputFormat,
        ]
        if let size = request.size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
            body["size"] = size
        }
        if let quality = request.quality?.trimmingCharacters(in: .whitespacesAndNewlines), !quality.isEmpty {
            body["quality"] = quality
        }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.timeoutSeconds
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
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
