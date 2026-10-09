import Foundation
import PersistenceCore

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
        let nested = object["tokens"] as? [String: Any] ?? [:]
        // ChatGPT's adapter accepts only the nested Codex credential shape.
        let tokenObject = OAuthRefreshBinding.tokenSet(object, provider: provider)
        let access = (tokenObject["access_token"] as? String) ?? ""
        let refresh = (tokenObject["refresh_token"] as? String) ?? ""
        let hasRefresh = !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let boundRefresh = OAuthRefreshBinding.permitsRefresh(object, provider: provider)
        let canRefresh = hasRefresh && boundRefresh
        let rawExpiry = object["expires_at"] ?? nested["expires_at"]
        var expiry = rawExpiry.flatMap(AnthropicOAuthDirectAdapter.parseExpiresAt)
        if provider == "openai_oauth_direct" {
            expiry = OpenAIOAuthDirectAdapter.persistedExpiresAt(blob: object, tokens: nested)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
        if rawExpiry != nil && expiry == nil { throw CocoaError(.fileReadCorruptFile) }
        if provider != "anthropic_oauth_direct", let jwt = jwtPayload(access),
           let jwtExpiry = parseExpiresAt(jwt["exp"]) {
            expiry = expiry.map { min($0, jwtExpiry) } ?? jwtExpiry
        }
        let configured: Bool
        switch provider {
        case "anthropic_oauth_direct":
            configured = AnthropicOAuthDirectAdapter.credentialStatus(object).usable
        case "xai_oauth_direct":
            // loadTokenState requires both tokens, even before expiry.
            configured = !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && canRefresh
        default:
            configured = !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return OAuthCredentialHealth(
            configured: configured, expiresAt: expiry,
            canRefresh: canRefresh,
            requiresRefresh: (provider == "openai_oauth_direct" && expiry == nil)
                || (provider == "anthropic_oauth_direct" && access.isEmpty)
                // An unbound refresh token can't refresh once access expires:
                // say so now as a sign-in, not when memory starts failing
                // (ChatGPT, 10-06: 17 h of silent memory loss).
                || (hasRefresh && !boundRefresh)
        )
    }

    public static func credentialPath(provider: String, root: URL) -> URL {
        if provider == "openai_oauth_direct" {
            return NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: root)
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
