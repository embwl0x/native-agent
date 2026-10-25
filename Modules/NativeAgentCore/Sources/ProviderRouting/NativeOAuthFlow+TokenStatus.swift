import Foundation
import PersistenceCore
// Blueprint: | `NativeOAuthFlow+TokenStatus.swift` | Token clearing and badge projections of each adapter's credential verdict and effective expiry; Sendable sign-in/session-offer values travel in the checked provider snapshot; no independent readiness or credential-selection rules |

public enum AnthropicOAuthCredentialReadState: Equatable {
    case missing
    case ready
    case unavailable(String)
}

extension NativeOAuthFlow {
    public enum CodexCLISessionOffer: Equatable, Sendable {
        case available(email: String?, alreadyDeclined: Bool)
        case unavailable(reason: String)
    }
    /// Remove one credential file under the SAME per-path lock the adapters'
    /// token refresh takes. User, 2026-09-06: sign-out deleted the file with no
    /// lock, so a refresh that had already compared the bytes wrote them back
    /// afterwards and the user was silently signed back in.
    ///
    /// Returns false when the lock could not be taken or the file could not be
    /// deleted. User, 2026-09-06: both failures were swallowed by `try?`, so a
    /// sign-out that left the token on disk still reported success and the user
    /// was told they were signed out while the credential was still usable.
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
            // User, 2026-09-06: honour the root the caller passed. This walked
            // the DEFAULT root's candidates, so a sign-out against an override
            // root (an alternate install, a test root) deleted the wrong
            // install's tokens and left the intended one signed in.
            // User, 2026-09-06: and delete ONLY this root's app-owned file. The
            // full candidate walk also returns the CODEX_HOME and
            // NATIVE_AGENT_DATA_ROOT env paths, the repo checkout's,
            // Application Support's and the default root's — so signing out of
            // one install wiped every other install's ChatGPT token.
            let root = dataRoot ?? PersistenceCore.defaultDataRoot()
            var removed = true
            let path = openAIAppOwnedAuthPath(dataRoot: root)
            if !OpenAIOAuthDirectAdapter.isUserCodexPath(path) {
                if !removeCredentialFile(at: path) { removed = false }
                // Codex children's access-only copy goes with the sign-in.
                do { try OpenAIOAuthDirectAdapter.syncCodexChildCopy(from: path) } catch { removed = false }
            }
            // Sign-out must also revoke CLI-session adoption: the shared
            // ~/.codex file is deliberately never deleted (it belongs to the
            // CLI), so without this the very next status refresh would
            // silently re-adopt it and the user would stay signed in
            // (gpt-5.5 review 2026-08-06, blocking).
            // User, 2026-09-06: revoke THIS root's consent record, not the
            // default root's — the read and the write disagreed, so a
            // sign-out against an override root left its adoption consent
            // in place and re-adopted the CLI session on the next refresh.
            if OpenAIOAuthDirectAdapter.cliAdoptionConsent(dataRoot: root) == .allowed,
               !recordCodexCLISessionDecision(allow: false, source: "sign_out", dataRoot: root) {
                removed = false
            }
            return removed
        case "anthropic_oauth_direct":
            return removeCredentialFile(at: anthropicTokenPath(dataRoot: dataRoot))
        default:
            guard normalized == "xai_oauth_direct" else { return false }
            // User, 2026-09-06: same root scoping as the ChatGPT branch above.
            do {
                try XAIOAuthCredentialStore.remove(at: XAIOAuthDirectAdapter.tokenPath(
                    dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()))
                return true
            } catch { return false }
        }
    }

    /// The credential file the badge reads for a provider under `dataRoot`.
    /// User, 2026-09-06: the ChatGPT and xAI arms read the DEFAULT root's files
    /// whatever root the caller passed, so a badge for an override root
    /// reported the default install's state.
    private static func statusCredentialPath(providerId: String, dataRoot: URL?) -> URL? {
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct":
            return openAIStatusAuthPath(dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot())
        case "anthropic_oauth_direct":
            return anthropicTokenPath(dataRoot: dataRoot)
        case "xai_oauth_direct":
            return XAIOAuthDirectAdapter.tokenPath(
                dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot())
        default:
            return nil
        }
    }

    private static func credentialHealth(providerId: String, dataRoot: URL?) -> OAuthCredentialHealth? {
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct":
            return try? ProviderOAuthCredentialMaintenance.status(provider: normalizedOAuthProviderId(providerId),
                root: dataRoot ?? PersistenceCore.defaultDataRoot())
        default: return nil
        }
    }

    private static func canRefresh(providerId: String, dataRoot: URL?) -> Bool {
        credentialHealth(providerId: providerId, dataRoot: dataRoot)?.canRefresh == true
    }

    /// The adapter's effective expiry, including its JWT/persisted precedence.
    public static func expiresAt(providerId: String, dataRoot: URL? = nil) -> Date? {
        credentialHealth(providerId: providerId, dataRoot: dataRoot)?.expiresAt
    }

    /// Format `expires_at` as a short status string for the OAuth badge.
    /// For ChatGPT, a sign-in adopted from the shared Codex CLI home is
    /// labeled as such: the reader must be able to tell WHOSE credentials
    /// are live and that they did not come from an in-app sign-in.
    public static func signInStatusDetail(providerId: String, dataRoot: URL? = nil) -> String? {
        guard isSignedIn(providerId: providerId, dataRoot: dataRoot) else { return nil }
        let base = expiryStatusText(providerId: providerId, dataRoot: dataRoot)
        if normalizedOAuthProviderId(providerId) == "openai_oauth_direct",
           let adoption = openAIAdoptedCLISessionDetail(
            dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()) {
            return "\(base) — \(adoption)"
        }
        return base
    }

    private static func expiryStatusText(providerId: String, dataRoot: URL?) -> String {
        guard let exp = expiresAt(providerId: providerId, dataRoot: dataRoot) else { return "Signed in" }
        let now = Date()
        let remaining = exp.timeIntervalSince(now)
        let isCLI = normalizedOAuthProviderId(providerId) == "openai_oauth_direct"
            && statusCredentialPath(providerId: providerId, dataRoot: dataRoot)
                .map { OpenAIOAuthDirectAdapter.isUserCodexPath($0) } == true
        if remaining <= 0 {
            if isCLI { return "Expired — renew your Codex CLI sign-in" }
            guard canRefresh(providerId: providerId, dataRoot: dataRoot) else {
                return "Expired — sign in again"
            }
            return "Expired — refresh on next chat"
        }
        let totalSec = Int(remaining)
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
            // User, 2026-09-06: a credential minutes from expiry with no refresh
            // token cannot refresh on the next chat any more than an already
            // expired one can — the same check the expired arm makes.
            if isCLI { return "Signed in (expires in \(label) — renew your Codex CLI sign-in)" }
            guard canRefresh(providerId: providerId, dataRoot: dataRoot) else {
                return "Signed in (expires in \(label) — sign in again)"
            }
            return "Signed in (refresh on next chat)"
        }
        return "Signed in (expires in \(label))"
    }

    /// Non-nil iff the ChatGPT auth the app is actually USING resolved to the
    /// shared Codex CLI home (`~/.codex/auth.json`) rather than an app-owned
    /// path. The runtime deliberately adopts an existing CLI session so setup
    /// is zero-step on a developer machine — but on a shared or second-hand
    /// machine that adoption is invisible and looks like a fresh sign-in.
    /// The badge must name the source (and the account, when the token
    /// carries one) so the user can tell whose credentials are live.
    ///
    /// The active path comes from the SAME resolver the rest of the badge uses
    /// (`openAIStatusAuthPath`), never a wider scan, so the label can only ever
    /// name a source this root's status was actually read from (gpt-5.5 review
    /// 2026-08-06, blocking; root confinement User, 2026-09-06). Both sides
    /// resolve symlinks before comparing.
    public static func openAIAdoptedCLISessionDetail(
        activeAuthPath: URL? = nil,
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome(),
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String? {
        guard let path = activeAuthPath
            ?? openAIStatusAuthPath(dataRoot: dataRoot, sharedCLIHome: sharedCLIHome)
        else { return nil }
        guard OpenAIOAuthDirectAdapter.hasAccessToken(at: path) else { return nil }
        let sharedCLIAuth = OpenAIOAuthDirectAdapter.preferredAuthPath(
            userCodexHome: sharedCLIHome, source: .sharedCLI)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let activePath = path.resolvingSymlinksInPath().standardizedFileURL.path
        guard activePath == sharedCLIAuth else { return nil }
        if let email = openAIAccountEmail(at: path) {
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any] else { return nil }
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
        credentialHealth(providerId: providerId, dataRoot: dataRoot)?.configured == true
    }

    // MARK: - Paths (shared with the read-side adapters)

    /// App-owned ChatGPT auth WRITE target (`<dataRoot>/codex_home/auth.json`).
    /// In-app sign-in and re-auth always write here — never to the shared
    /// `~/.codex` session, which belongs to the Codex CLI.
    public static func openAIAppOwnedAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: dataRoot,
            allowSharedFallbacks: false
        )
    }

    /// The adapter's runtime read selection, including process overrides for
    /// the default root and confined CLI consent for alternate roots.
    public static func openAIStatusAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome()
    ) -> URL? {
        let path = OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: dataRoot, userCodexHome: sharedCLIHome)
        return OpenAIOAuthDirectAdapter.hasAccessToken(at: path) ? path : nil
    }

    public static func anthropicTokenPath(dataRoot: URL? = nil) -> URL {
        (dataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }

    /// Existing malformed provider credentials are unavailable authority, not
    /// an unsigned account. The mounted OAuth panel shows this state before a
    /// user attempts a browser flow that would otherwise fail late.
    public static func anthropicOAuthCredentialState(
        dataRoot: URL? = nil
    ) -> AnthropicOAuthCredentialReadState {
        let path = anthropicTokenPath(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: path.path) else { return .missing }
        do {
            let data = try Data(contentsOf: path)
            let decoded = try JSONSerialization.jsonObject(with: data)
            guard let object = decoded as? [String: Any] else {
                return .unavailable("saved credentials are not a JSON object")
            }
            let status = AnthropicOAuthDirectAdapter.credentialStatus(object)
            return status.usable ? .ready : .unavailable(status.detail)
        } catch {
            return .unavailable("saved credentials could not be read: \(error.localizedDescription)")
        }
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
        try NativeOAuthSupport.updateProviderCredential(at: path) { existing in
            for key in ["tokens", "id_token", "account", "oauth_account_identity", "refresh_token_account_identity"] {
                existing.removeValue(forKey: key)
            }
            existing["client_id"] = ProviderOAuthConfig.anthropic.clientId
            existing["access_token"] = rawAccess
            // 2026-09-06: this is a new sign-in, not a refresh of the old account.
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
            existing["expires_at"] = NativeOAuthSupport.isoBasic(Date().addingTimeInterval(TimeInterval(expiresIn)))
            existing["scope"] = (tokens["scope"] as? String) ?? ""
            existing["token_type"] = (tokens["token_type"] as? String) ?? "Bearer"
            existing["user_info"] = (tokens["user_info"] as? [String: Any]) ?? [:]
            existing["account"] = tokens["account"] as? [String: Any]
            OAuthRefreshBinding.bindSignIn(&existing, provider: "anthropic_oauth_direct")
        }
    }

    // MARK: - Codex CLI session adoption offer

    /// Non-nil when a usable Codex CLI session exists at `~/.codex` and the
    /// user has not ALLOWED adopting it. The Providers UI renders this as an
    /// explicit one-click offer; nothing uses the session until the user
    /// accepts (the consent gate lives in the Core candidate walk). A prior
    /// decline keeps the offer visible but passive — declining stops the
    /// default adoption, not the capability.
    ///
    /// User, 2026-09-06: the consent record is per-root
    /// (`<dataRoot>/providers/cli_session_adoption.json`), so the offer reads
    /// the root the screen is showing — it read the DEFAULT root's record
    /// whatever root was selected, and an override root's own decision was
    /// invisible here.
    public static func codexCLISessionOffer(
        dataRoot: URL? = nil,
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome(),
        consentState: OpenAIOAuthDirectAdapter.CLISessionAdoptionConsentState? = nil
    ) -> CodexCLISessionOffer? {
        let consentState = consentState
            ?? OpenAIOAuthDirectAdapter.cliAdoptionConsentState(dataRoot: dataRoot)
        if case .corrupt(let reason) = consentState {
            return .unavailable(reason: reason)
        }
        guard consentState != .allowed else { return nil }
        let auth = OpenAIOAuthDirectAdapter.preferredAuthPath(userCodexHome: sharedCLIHome, source: .sharedCLI)
        guard OpenAIOAuthDirectAdapter.hasAccessToken(at: auth) else { return nil }
        return .available(
            email: openAIAccountEmail(at: auth),
            alreadyDeclined: consentState == .declined
        )
    }

    /// True when the shared Codex CLI session at `~/.codex/auth.json` is still
    /// on disk for a ChatGPT / Codex provider row.
    ///
    /// User, 2026-09-06: removal must say so, and `isSignedIn` cannot answer the
    /// question — `clearTokens` deliberately leaves that file alone (it belongs
    /// to the CLI) and flips adoption consent to declined in the same breath,
    /// so the very next status read reports "not signed in" and the sheet
    /// claimed a removal that did not happen. Presence of the shared session is
    /// the fact being disclosed, independent of whether the app will use it.
    public static func sharedCodexCLISessionRemains(
        providerId: String,
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome()
    ) -> Bool {
        let id = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id == "openai_oauth_direct" || id == "codex" else { return false }
        return OpenAIOAuthDirectAdapter.hasAccessToken(
            at: OpenAIOAuthDirectAdapter.preferredAuthPath(userCodexHome: sharedCLIHome, source: .sharedCLI)
        )
    }

    /// Record the user's decision from the Providers offer UI. Returns false
    /// when the write fails (the offer stays visible; nothing is adopted).
    ///
    /// User, 2026-09-06: the decision landed in the DEFAULT root's consent file
    /// whatever root the screen was showing, so accepting the offer under an
    /// override root granted adoption to a different install and left the
    /// selected one still asking.
    @discardableResult
    public static func recordCodexCLISessionDecision(
        allow: Bool,
        source: String,
        dataRoot: URL? = nil
    ) -> Bool {
        do {
            try OpenAIOAuthDirectAdapter.recordCLIAdoptionConsent(
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
        try OpenAIOAuthDirectAdapter.backupAndResetCorruptCLIAdoptionConsent(dataRoot: dataRoot)
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
        if providerID == "anthropic_oauth_direct" {
            switch NativeOAuthFlow.anthropicOAuthCredentialState(dataRoot: dataRoot) {
            case .missing:
                return SignInStatus(isSignedIn: false, detail: nil, error: nil)
            case .unavailable(let detail):
                return SignInStatus(
                    isSignedIn: false,
                    detail: nil,
                    error: "Anthropic OAuth credentials unavailable: \(detail)"
                )
            case .ready:
                break
            }
        }

        guard NativeOAuthFlow.isSignedIn(providerId: providerID, dataRoot: dataRoot) else {
            return SignInStatus(isSignedIn: false, detail: nil, error: nil)
        }
        return SignInStatus(
            isSignedIn: true,
            detail: NativeOAuthFlow.signInStatusDetail(providerId: providerID, dataRoot: dataRoot)
                ?? "Signed in",
            error: nil
        )
    }

}
