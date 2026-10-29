import Foundation
import PersistenceCore
// Blueprint: | `OAuthCredentialHealth.swift` | Secret-free maintenance projection of adapter-owned expiry, refresh binding and readiness verdicts |

/// Secret-free credential metadata. No expiry means no scheduled expiry, not
/// an expired token or proof that a remote service will accept it.
public struct OAuthCredentialHealth: Sendable {
    public let configured: Bool
    public let expiresAt: Date?
    public let canRefresh: Bool
    public let requiresRefresh: Bool
    public var detail = ""
    public var authPath: URL? = nil
    public var accountEmail: String? = nil

    public init(configured: Bool, expiresAt: Date?, canRefresh: Bool, requiresRefresh: Bool = false) {
        self.configured = configured
        self.expiresAt = expiresAt
        self.canRefresh = canRefresh
        self.requiresRefresh = requiresRefresh
    }
}

public enum ProviderOAuthCredentialMaintenance {
    public static func status(provider: String, root: URL) throws -> OAuthCredentialHealth {
        let path = credentialPath(provider: provider, root: root)
        let object: [String: Any]
        if provider == "xai_oauth_direct" {
            object = try XAIOAuthCredentialStore.read(at: path)
        } else {
            let data = try Data(contentsOf: path)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = parsed
        }
        let verdict: (usable: Bool, detail: String, health: OAuthCredentialHealth)
        switch provider {
        case "anthropic_oauth_direct": verdict = AnthropicOAuthTransport.credentialStatus(object)
        case "xai_oauth_direct": verdict = XAIOAuthTransport.credentialStatus(object)
        default: verdict = ChatGPTTransport.credentialStatus(object, path: path)
        }
        var health = verdict.health
        health.detail = verdict.detail
        health.authPath = path
        if provider == "openai_oauth_direct" { health.accountEmail = NativeOAuthFlow.openAIAccountEmail(in: object) }
        return health
    }

    public static func credentialPath(provider: String, root: URL) -> URL {
        if provider == "openai_oauth_direct" {
            return ChatGPTTransport.preferredAuthPath(dataRoot: root)
        }
        return root.appendingPathComponent("providers/\(provider).json")
    }

    public static func refresh(provider: String, root: URL) async throws {
        let path = credentialPath(provider: provider, root: root)
        switch provider {
        case "xai_oauth_direct":
            _ = try await XAIOAuthTransport(tokenPathOverride: path, telemetryDataRootOverride: root)
                .ensureFreshAccessToken(forceRefresh: false)
        case "anthropic_oauth_direct":
            _ = try await AnthropicOAuthTransport(authPathOverride: path, telemetryDataRootOverride: root)
                .ensureFreshAccessToken()
        case "openai_oauth_direct":
            _ = try await ChatGPTTransport(authPathOverride: path, telemetryDataRootOverride: root)
                .ensureFreshAccessToken()
        default:
            throw LLMError.notConfigured(provider: provider)
        }
    }

    public static func requiresSignIn(_ error: Error) -> Bool {
        guard let error = error as? LLMError else { return false }
        if case .authRejected = error { return true }
        return false
    }
}
