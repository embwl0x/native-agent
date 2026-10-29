// OpenAI speech uses the caller's model, a 4096-scalar input cap and a
// 60-second timeout. The unread remainder is reported with the raw audio.
// SavedTrustPolicyAuthority denies before credential/network work unless
// multimodalPolicy.tts_openai is enabled. LLMCredentialResolver owns keys.

import Foundation
import ProviderRouting
import PersistenceCore
import TrustCenter
// Blueprint: | `MultimodalTTS.swift` | `MultimodalTTSError`, `SwiftOpenAITTSClient` |

/// Typed failures retain diagnostic details while `LocalizedError` supplies
/// plain messages for the read-aloud UI.
public enum MultimodalTTSError: Error, Equatable, Sendable, LocalizedError {
    /// Saved policy denies OpenAI speech (default off).
    case trustDenied
    /// The configured OpenAI platform key could not be resolved.
    case notConfigured
    /// HTTP 401: the key was rejected.
    case authRejected
    /// A non-2xx HTTP status other than 401.
    case apiError(status: Int)
    /// Transport failed or returned a non-HTTP response.
    case transport(message: String)
    /// No text was supplied.
    case emptyText
    /// A route without a speech model refuses read-aloud without borrowing another provider's voice.
    case routeHasNoSpeech(route: String)

    public var errorDescription: String? {
        switch self {
        case .trustDenied:
            return "OpenAI read-aloud is disabled in Trust Center."
        case .notConfigured:
            return "OpenAI read-aloud needs an API key. "
                + "Add one in Settings → Providers → OpenAI."
        case .authRejected:
            return "OpenAI rejected the read-aloud API key. "
                + "Check the key in Settings → Providers → OpenAI."
        case .apiError:
            return "OpenAI could not create read-aloud audio. Try again later."
        case .transport:
            return "OpenAI read-aloud could not finish. Check your connection and try again."
        case .emptyText:
            return "There is no text to read aloud."
        case .routeHasNoSpeech(let route):
            return "\(route) offers no read-aloud voice."
        }
    }
}

/// SwiftNative OpenAI TTS client. Calls https://api.openai.com/v1/audio/speech
/// directly via URLSession, using the caller's model and the shared credential resolver.
public final class SwiftOpenAITTSClient: Sendable {
    public static let ttsURL = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// The caller supplies the speech model from its route's catalog entry.
    public let model: String
    public static let userAgent = "NativeAgent/0.2.0"
    public static let maxInputChars = 4096
    public static let timeoutSeconds: TimeInterval = 60

    private let dataRoot: URL

    public init(model: String) {
        self.model = model
        self.dataRoot = PersistenceCore.defaultDataRoot()
    }

    /// Read the flag through canonical saved authority; damaged policies deny.
    private func ttsOpenAIAllowed() -> Bool {
        SavedTrustPolicyAuthority.flag(
            block: "multimodalPolicy", key: "tts_openai", default: false, dataRoot: dataRoot
        )
    }

    /// The audio, and how many scalars past the provider's per-request cap it does not read.
    public func synthesize(text: String, voice: String, format: String) async throws -> (audio: Data, unread: Int) {
        // Deny before input validation, credential resolution or network work.
        guard ttsOpenAIAllowed() else { throw MultimodalTTSError.trustDenied }

        if text.isEmpty { throw MultimodalTTSError.emptyText }

        // Resolve the platform key through the shared owner at this data root.
        guard let key = LLMCredentialResolver.resolveAPIKey(
                providerConfigFile: "openai.json",
                dataRoot: dataRoot),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MultimodalTTSError.notConfigured
        }

        // Truncate by Unicode scalar and report the remainder as unread.
        let truncated = String(String.UnicodeScalarView(text.unicodeScalars.prefix(SwiftOpenAITTSClient.maxInputChars)))
        let unread = max(0, text.unicodeScalars.count - SwiftOpenAITTSClient.maxInputChars)

        var req = URLRequest(url: SwiftOpenAITTSClient.ttsURL)
        req.httpMethod = "POST"
        req.timeoutInterval = SwiftOpenAITTSClient.timeoutSeconds
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SwiftOpenAITTSClient.userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": model,
            "input": truncated,
            "voice": voice,
            "response_format": format,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // Propagate cancellation cleanly (same convention as the ProviderRouting adapters).
            if error is CancellationError { throw CancellationError() }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw MultimodalTTSError.transport(message: nsError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MultimodalTTSError.transport(message: "non-HTTP response")
        }
        if http.statusCode == 401 {
            throw MultimodalTTSError.authRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MultimodalTTSError.apiError(status: http.statusCode)
        }
        return (data, unread)
    }
}
