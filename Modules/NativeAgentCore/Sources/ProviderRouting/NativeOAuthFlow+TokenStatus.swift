import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `NativeOAuthFlow+TokenStatus.swift` | Token clearing and badge projections of each adapter's credential verdict and effective expiry; Sendable sign-in/session-offer values travel in the checked provider snapshot; no independent readiness or credential-selection rules |

extension NativeOAuthFlow {
    public enum CodexCLISessionOffer: Equatable, Sendable {
        case available(email: String?, alreadyDeclined: Bool)
        case unavailable(reason: String)
    }
    /// Delete under the refresh path lock, returning false if locking or deletion fails.
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

    /// Disk-only sign-out: remove the provider's token file. Returns true only
    /// when every credential file this provider owns is gone (or was already
    /// absent) — a lock or delete failure is reported, not swallowed.
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
            // Sign-out deletes only the selected root's app-owned credential.
            let root = dataRoot ?? PersistenceCore.defaultDataRoot()
            var removed = true
            let path = openAIAppOwnedAuthPath(dataRoot: root)
            if !ChatGPTTransport.isUserCodexPath(path) {
                if !removeCredentialFile(at: path) { removed = false }
                // Codex children's access-only copy goes with the sign-in.
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
            // Sign-out deletes only the selected root's app-owned credential.
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

    /// The adapter's effective expiry, including its JWT/persisted precedence.
    public static func expiresAt(providerId: String, dataRoot: URL? = nil) -> Date? {
        try? credentialHealth(providerId: providerId, dataRoot: dataRoot)?.expiresAt
    }

    /// Format `expires_at` as a short status string for the OAuth badge.
    /// For ChatGPT, a sign-in adopted from the shared Codex CLI home is
    /// labeled as such: the reader must be able to tell WHOSE credentials
    /// are live and that they did not come from an in-app sign-in.
    public static func signInStatusDetail(providerId: String, dataRoot: URL? = nil) -> String? {
        guard let health = try? credentialHealth(providerId: providerId, dataRoot: dataRoot) else { return nil }
        return signInStatusDetail(providerId: providerId, health: health)
    }

    fileprivate static func signInStatusDetail(providerId: String, health: OAuthCredentialHealth) -> String? {
        guard health.configured else { return nil }
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

    /// Names an adopted shared CLI session and its account when known.
    public static func openAIAdoptedCLISessionDetail(
        activeAuthPath: URL? = nil,
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome(),
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String? {
        guard let path = activeAuthPath
            ?? openAIStatusAuthPath(dataRoot: dataRoot, sharedCLIHome: sharedCLIHome)
        else { return nil }
        guard ChatGPTTransport.hasAccessToken(at: path) else { return nil }
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

    /// Best-effort account email from the auth blob's JWT claims. The OpenAI
    /// id_token carries `email`; the access_token nests it under the
    /// `https://api.openai.com/profile` claim. Display-only — never used for
    /// authorization.
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

    /// The adapter can use or renew this root's credential.
    public static func isSignedIn(providerId: String, dataRoot: URL? = nil) -> Bool {
        (try? credentialHealth(providerId: providerId, dataRoot: dataRoot))?.configured == true
    }

    // MARK: - Paths (shared with the read-side adapters)

    /// App-owned ChatGPT auth WRITE target (`<dataRoot>/codex_home/auth.json`).
    /// In-app sign-in and re-auth always write here — never to the shared
    /// `~/.codex` session, which belongs to the Codex CLI.
    public static func openAIAppOwnedAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        ChatGPTTransport.preferredAuthPath(
            dataRoot: dataRoot,
            allowSharedFallbacks: false
        )
    }

    /// The adapter's runtime read selection, including process overrides for
    /// the default root and confined CLI consent for alternate roots.
    public static func openAIStatusAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome()
    ) -> URL? {
        let path = ChatGPTTransport.preferredAuthPath(dataRoot: dataRoot, userCodexHome: sharedCLIHome)
        return ChatGPTTransport.hasAccessToken(at: path) ? path : nil
    }

    public static func anthropicTokenPath(dataRoot: URL? = nil) -> URL {
        (dataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }

    /// Persist the exact provider-file shape the Anthropic adapter reads. An
    /// existing malformed credential file is authority evidence, not an empty
    /// starting point: leave it byte-preserved and surface the failed OAuth
    /// completion so Settings never claims a connection that cannot be read.
    public static func persistAnthropicOAuthTokens(
        _ tokens: [String: Any],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws {
        guard let rawAccess = tokens["access_token"] as? String,
              !rawAccess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "NativeOAuthFlow",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Anthropic OAuth response is missing access_token."]
            )
        }

        let path = anthropicTokenPath(dataRoot: dataRoot)
        try ProviderStateValidation.credential(tokens)
        try OAuthGrantOperations.updateProviderCredential(at: path) { existing in
            for key in ["tokens", "id_token", "account", "oauth_account_identity", "refresh_token_account_identity"] {
                existing.removeValue(forKey: key)
            }
            existing["client_id"] = ProviderOAuthConfig.anthropic.clientId
            existing["access_token"] = rawAccess
            // A new sign-in replaces the previous account's identity.
            existing["refresh_token"] = (tokens["refresh_token"] as? String) ?? ""
            let expiresIn: Int
            if let integer = tokens["expires_in"] as? Int {
                expiresIn = integer
            } else if let floating = tokens["expires_in"] as? Double {
                expiresIn = Int(exactly: floating.rounded(.towardZero)) ?? 3_600
            } else if let string = tokens["expires_in"] as? String,
                      let integer = Int(string) {
                expiresIn = integer
            } else {
                expiresIn = 3_600
            }
            existing["expires_at"] = NativeTimestampFormat.basicZulu(Date().addingTimeInterval(TimeInterval(expiresIn)))
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
        guard ChatGPTTransport.hasAccessToken(at: auth) else { return nil }
        return .available(
            email: openAIAccountEmail(at: auth),
            alreadyDeclined: consentState == .declined
        )
    }

    /// Shared CLI-session presence is independent of app sign-in or adoption consent.
    public static func sharedCodexCLISessionRemains(
        providerId: String,
        sharedCLIHome: URL = ChatGPTTransport.defaultUserCodexHome()
    ) -> Bool {
        let id = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id == "openai_oauth_direct" || id == "codex" else { return false }
        return ChatGPTTransport.hasAccessToken(
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

    /// Called only after the Providers UI's destructive confirmation. Core
    /// byte-preserves and verifies the backup before removing the authority.
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

    /// The person's control for signing a direct OAuth provider in again, named
    /// as the Providers page shows it for the saved credential's state
    /// (OAuthSignInPresentation reads the same `signInStatus`).
    public static func signInControl(providerID: String, dataRoot: URL) -> String? {
        let button: (id: String, card: String, short: String)? = switch providerID {
        case "openai_oauth_direct", "codex": ("openai_oauth_direct", "ChatGPT", "ChatGPT")
        case "anthropic_oauth_direct": (providerID, "Anthropic", "Claude")
        case "xai_oauth_direct": (providerID, "xAI", "xAI Grok")
        default: nil
        }
        return button.map { button in
            "Providers → Sign in, reconnect or add an account → " + button.card + " → "
                + (signInStatus(providerID: button.id, dataRoot: dataRoot).isSignedIn ? "Re-authenticate " : "Sign in with ") + button.short
        }
    }

    public static func signInStatus(providerID: String, dataRoot: URL) -> SignInStatus {
        do {
            guard let health = try NativeOAuthFlow.credentialHealth(providerId: providerID, dataRoot: dataRoot) else {
                return SignInStatus(isSignedIn: false, detail: nil, error: nil)
            }
            if providerID == "anthropic_oauth_direct", !health.configured {
                return SignInStatus(isSignedIn: false, detail: nil,
                    error: "Anthropic OAuth credentials unavailable: \(health.detail)")
            }
            return SignInStatus(isSignedIn: health.configured,
                detail: NativeOAuthFlow.signInStatusDetail(providerId: providerID, health: health), error: nil)
        } catch {
            guard providerID == "anthropic_oauth_direct",
                  FileManager.default.fileExists(atPath: NativeOAuthFlow.anthropicTokenPath(dataRoot: dataRoot).path) else {
                return SignInStatus(isSignedIn: false, detail: nil, error: nil)
            }
            let detail = (error as? CocoaError)?.code == .fileReadCorruptFile
                ? "saved credentials are not a JSON object"
                : "saved credentials could not be read: \(error.localizedDescription)"
            return SignInStatus(isSignedIn: false, detail: nil, error: "Anthropic OAuth credentials unavailable: \(detail)")
        }
    }

}
