import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeOAuthFlow+TokenStatus.swift` | adapter-owned sign-in verdicts |

extension NativeOAuthFlow {
    public enum CodexCLISessionOffer: Equatable, Sendable {
        case available(email: String?, alreadyDeclined: Bool)
        case unavailable(reason: String)
    }
    /// Deletion failures must remain visible even when the credential lock cannot be acquired.
    private static func removeCredentialFile(at path: URL) -> Bool {
        do {
            return try CredentialFileLock.withLock(path) {
                guard FileManager.default.fileExists(atPath: path.path) else { return true }
                do {
                    try FileManager.default.removeItem(at: path)
                    return true
                } catch {
                    return false
                }
            }
        } catch {
            return false
        }
    }

    /// Sign-out succeeds only when every owned credential file is confirmed gone; lock and delete failures remain failures.
    public static func clearTokens(providerId: String, dataRoot: URL? = nil) -> Bool {
        let root = dataRoot ?? PersistenceCore.defaultDataRoot()
        return signInAttempts.clear(providerId: providerId, dataRoot: root) {
            clearTokensAfterRetiringSignIn(providerId: providerId, dataRoot: root)
        }
    }

    private static func clearTokensAfterRetiringSignIn(providerId: String, dataRoot: URL?) -> Bool {
        let normalized = normalizedOAuthProviderId(providerId)
        switch providerId {
        case "openai_oauth_direct":
            // Sign-out may delete only this root's app-owned credential.
            let root = dataRoot ?? PersistenceCore.defaultDataRoot()
            var removed = true
            let path = openAIAppOwnedAuthPath(dataRoot: root)
            if !ChatGPTTransport.isUserCodexPath(path) {
                if !removeCredentialFile(at: path) { removed = false }
                // Child credentials must disappear with the app sign-in.
                do { try ChatGPTTransport.syncCodexChildCopy(from: path) } catch { removed = false }
            }
            // Sign-out revokes this root's CLI-session adoption while preserving the shared CLI file.
            if ChatGPTTransport.cliAdoptionConsent(dataRoot: root) == .allowed,
               !recordCodexCLISessionDecision(allow: false, source: "sign_out", dataRoot: root) {
                removed = false
            }
            return removed
        case "anthropic_oauth_direct":
            return removeCredentialFile(at: anthropicTokenPath(dataRoot: dataRoot))
        default:
            guard normalized == "xai_oauth_direct" else { return false }
            // Sign-out may delete only this root's app-owned credential.
            do {
                try XAIOAuthCredentialStore.remove(at: XAIOAuthTransport.tokenPath(
                    dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()))
                return true
            } catch { return false }
        }
    }

    fileprivate static func credentialHealth(providerId: String, dataRoot: URL?) throws -> OAuthCredentialHealth? {
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct":
            return try ProviderOAuthCredentialMaintenance.status(provider: normalizedOAuthProviderId(providerId),
                root: dataRoot ?? PersistenceCore.defaultDataRoot())
        default: return nil
        }
    }

    fileprivate static func signInStatusDetail(providerId: String, health: OAuthCredentialHealth) -> String? {
        guard health.configured else { return health.detail.isEmpty ? nil : health.detail }
        let base = expiryStatusText(providerId: providerId, health: health)
        if normalizedOAuthProviderId(providerId) == "openai_oauth_direct",
           let path = health.authPath,
           let adoption = openAIAdoptedCLISessionDetail(activeAuthPath: path, accountEmail: health.accountEmail) {
            return "\(base) — \(adoption)"
        }
        return base
    }

    private static func expiryStatusText(providerId: String, health: OAuthCredentialHealth) -> String {
        guard let exp = health.expiresAt else { return "Signed in" }
        let now = Date()
        let remaining = exp.timeIntervalSince(now)
        let isCLI = normalizedOAuthProviderId(providerId) == "openai_oauth_direct"
            && health.authPath.map { ChatGPTTransport.isUserCodexPath($0) } == true
        if remaining <= 0 {
            if isCLI { return "Expired — renew your Codex CLI sign-in" }
            guard health.canRefresh else {
                return "Expired — sign in again"
            }
            return "Expired — refresh on next chat"
        }
        guard let totalSec = Int(exactly: remaining.rounded(.towardZero)) else {
            return "Saved expiry is invalid — repair the credential or sign in again"
        }
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let label: String
        if hours >= 1 {
            label = "\(hours)h \(minutes)m"
        } else if minutes >= 1 {
            label = "\(minutes)m"
        } else {
            label = "<1m"
        }
        if remaining <= 120 {
            if isCLI { return "Signed in (expires in \(label) — renew your Codex CLI sign-in)" }
            guard health.canRefresh else {
                return "Signed in (expires in \(label) — sign in again)"
            }
            return "Signed in (refresh on next chat)"
        }
        return "Signed in (expires in \(label))"
    }

    /// Shared-session offers name the account only when known.
    public static func openAIAdoptedCLISessionDetail(
        activeAuthPath: URL? = nil,
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome(),
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> String? {
        guard let path = try activeAuthPath
            ?? openAIStatusAuthPath(dataRoot: dataRoot, sharedCLIHome: sharedCLIHome)
        else { return nil }
        guard try ChatGPTTransport.hasAccessToken(at: path) else { return nil }
        return openAIAdoptedCLISessionDetail(activeAuthPath: path, accountEmail: openAIAccountEmail(at: path), sharedCLIHome: sharedCLIHome)
    }

    private static func openAIAdoptedCLISessionDetail(
        activeAuthPath path: URL, accountEmail: String?,
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome()
    ) -> String? {
        let sharedCLIAuth = ChatGPTTransport.preferredAuthPath(
            userCodexHome: sharedCLIHome, source: .sharedCLI)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let activePath = path.resolvingSymlinksInPath().standardizedFileURL.path
        guard activePath == sharedCLIAuth else { return nil }
        if let email = accountEmail {
            return "using your Codex CLI sign-in (\(email))"
        }
        return "using your Codex CLI sign-in (~/.codex)"
    }

    /// JWT email is display-only and must never authorize access.
    public static func openAIAccountEmail(at path: URL) -> String? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return openAIAccountEmail(in: obj)
    }

    static func openAIAccountEmail(in object: [String: Any]) -> String? {
        guard let tokens = object["tokens"] as? [String: Any] else { return nil }
        for key in ["id_token", "access_token"] {
            guard let token = tokens[key] as? String,
                  let payload = jwtPayload(token) else { continue }
            if let email = payload["email"] as? String, !email.isEmpty { return email }
            if let profile = payload["https://api.openai.com/profile"] as? [String: Any],
               let email = profile["email"] as? String, !email.isEmpty { return email }
        }
        return nil
    }

    // MARK: - Paths (shared with the read-side adapters)

    /// App sign-in writes only app-owned auth; the shared CLI session belongs to the CLI.
    public static func openAIAppOwnedAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        ChatGPTTransport.preferredAuthPath(
            dataRoot: dataRoot,
            allowSharedFallbacks: false
        )
    }

    /// Status must use the adapter's selected root, overrides and consent rules.
    public static func openAIStatusAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome()
    ) throws -> URL? {
        let path = ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot, userCodexHome: sharedCLIHome)
        return try ChatGPTTransport.hasAccessToken(at: path) ? path : nil
    }

    public static func anthropicTokenPath(dataRoot: URL? = nil) -> URL {
        (dataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }

    /// An unreadable credential is authority evidence, never an empty starting point; preserve it and fail sign-in rather than claim an unreadable
    /// connection.
    public static func persistAnthropicOAuthTokens(
        _ tokens: [String: Any],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws {
        let answer = try OAuthGrantOperations.validateTokenResponse(tokens, requiringRefreshToken: true)
        let path = anthropicTokenPath(dataRoot: dataRoot)
        try OAuthGrantOperations.updateProviderCredential(at: path) { existing in
            for key in ["tokens", "id_token", "account", "oauth_account_identity", "refresh_token_account_identity"] {
                existing.removeValue(forKey: key)
            }
            existing["client_id"] = ProviderOAuthConfig.anthropic.clientId
            existing["access_token"] = answer.accessToken
            // A new sign-in replaces the previous account's identity.
            existing["refresh_token"] = answer.refreshToken
            existing.removeValue(forKey: "expires_in")
            existing["expires_at"] = answer.expiresIn.map { NativeTimestampFormat.basicZulu(Date().addingTimeInterval($0)) }
            existing["scope"] = (tokens["scope"] as? String) ?? ""
            existing["token_type"] = (tokens["token_type"] as? String) ?? "Bearer"
            existing["user_info"] = (tokens["user_info"] as? [String: Any]) ?? [:]
            existing["account"] = tokens["account"] as? [String: Any]
            OAuthRefreshBinding.bindSignIn(&existing, provider: "anthropic_oauth_direct")
        }
    }

    // MARK: - Codex CLI session adoption offer

    /// A usable CLI session without this root's consent remains an explicit offer, including after decline.
    public static func codexCLISessionOffer(
        dataRoot: URL? = nil,
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome(),
        consentState: ChatGPTTransport.CLISessionAdoptionConsentState? = nil
    ) -> CodexCLISessionOffer? {
        let consentState = consentState
            ?? ChatGPTTransport.cliAdoptionConsentState(dataRoot: dataRoot)
        if case .corrupt(let reason) = consentState {
            return .unavailable(reason: reason)
        }
        guard consentState != .allowed else { return nil }
        let auth = ChatGPTTransport.preferredAuthPath(userCodexHome: sharedCLIHome, source: .sharedCLI)
        do {
            guard try ChatGPTTransport.hasAccessToken(at: auth) else { return nil }
        } catch {
            return .unavailable(reason: ProviderFailure.diagnosticDescription(error))
        }
        return .available(
            email: openAIAccountEmail(at: auth),
            alreadyDeclined: consentState == .declined
        )
    }

    /// Shared CLI-session presence is independent of app sign-in or adoption consent.
    public static func sharedCodexCLISessionRemains(
        providerId: String,
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome()
    ) throws -> Bool {
        let id = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id == "openai_oauth_direct" || id == "codex" else { return false }
        return try ChatGPTTransport.hasAccessToken(
            at: ChatGPTTransport.preferredAuthPath(userCodexHome: sharedCLIHome, source: .sharedCLI)
        )
    }

    /// Consent writes target the selected root; failure returns false and leaves the offer unaccepted.
    @discardableResult
    public static func recordCodexCLISessionDecision(
        allow: Bool,
        source: String,
        dataRoot: URL? = nil
    ) -> Bool {
        do {
            try ChatGPTTransport.recordCLIAdoptionConsent(
                allow ? .allowed : .declined, source: source, dataRoot: dataRoot)
            return true
        } catch {
            print("[oauth] failed to record CLI adoption consent: \(error)")
            return false
        }
    }

    /// Called only after the Providers UI's destructive confirmation. Core byte-preserves and verifies the backup before removing the authority.
    public static func repairCodexCLISessionConsent(dataRoot: URL? = nil) throws -> URL {
        try ChatGPTTransport.backupAndResetCorruptCLIAdoptionConsent(dataRoot: dataRoot)
    }
}

extension NativeOAuthFlow {
    public struct SignInStatus: Equatable, Sendable {
        public let isSignedIn: Bool
        public let detail: String?
        public let error: String?
    }

    /// The Providers face sends sign-in through the account's protected connection card.
    public static func signInControl(providerID: String, dataRoot: URL) -> String? {
        guard ["openai_oauth_direct", "codex", "anthropic_oauth_direct", "xai_oauth_direct"].contains(providerID) else { return nil }
        return "Providers → Accounts → " + SwiftNativeProviderRouting.displayName(for: providerID) + " → Sign in"
    }

    public static func signInStatus(providerID: String, dataRoot: URL) -> SignInStatus {
        do {
            guard let health = try NativeOAuthFlow.credentialHealth(providerId: providerID, dataRoot: dataRoot) else {
                return SignInStatus(isSignedIn: false, detail: nil, error: nil)
            }
            return SignInStatus(isSignedIn: health.configured,
                detail: NativeOAuthFlow.signInStatusDetail(providerId: providerID, health: health), error: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return SignInStatus(isSignedIn: false, detail: "No saved sign-in. Sign in through Providers.", error: nil)
        } catch {
            return SignInStatus(isSignedIn: false, detail: nil,
                error: """
                    \(providerID) credentials are unavailable: \(ProviderFailure.diagnosticDescription(error)). Repair the saved credential before \
                    reconnecting.
                    """)
        }
    }

}
