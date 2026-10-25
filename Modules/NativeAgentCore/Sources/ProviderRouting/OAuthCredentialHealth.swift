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
        switch provider {
        case "anthropic_oauth_direct":
            return AnthropicOAuthDirectAdapter.credentialStatus(object).health
        case "xai_oauth_direct":
            return XAIOAuthDirectAdapter.credentialStatus(object).health
        default:
            return OpenAIOAuthDirectAdapter.credentialStatus(object, path: path).health
        }
    }

    public static func credentialPath(provider: String, root: URL) -> URL {
        if provider == "openai_oauth_direct" {
            return OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: root)
        }
        return root.appendingPathComponent("providers/\(provider).json")
    }

    public static func refresh(provider: String, root: URL) async throws {
        let path = credentialPath(provider: provider, root: root)
        switch provider {
        case "xai_oauth_direct":
            _ = try await XAIOAuthDirectAdapter(tokenPathOverride: path, telemetryDataRootOverride: root)
                .ensureFreshAccessToken(forceRefresh: false)
        case "anthropic_oauth_direct":
            _ = try await AnthropicOAuthDirectAdapter(authPathOverride: path, telemetryDataRootOverride: root)
                .ensureFreshAccessToken()
        case "openai_oauth_direct":
            _ = try await OpenAIOAuthDirectAdapter(authPathOverride: path, telemetryDataRootOverride: root)
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
