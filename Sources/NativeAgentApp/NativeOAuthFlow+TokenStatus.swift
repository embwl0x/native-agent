import Foundation
import PersistenceCore
import ProviderRouting

enum AnthropicOAuthCredentialReadState: Equatable {
    case missing
    case ready
    case unavailable(String)
}

extension NativeOAuthFlow {
    enum CodexCLISessionOffer: Equatable {
        case available(email: String?, alreadyDeclined: Bool)
        case unavailable(reason: String)
    }
    /// Disk-only sign-out: remove the provider's token file. Returns true if
    /// a file was removed (or absent).
    static func clearTokens(providerId: String, dataRoot: URL? = nil) -> Bool {
        let normalized = normalizedOAuthProviderId(providerId)
        switch providerId {
        case "openai_oauth_direct":
            let sharedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("auth.json")
                .standardizedFileURL
                .path
            for path in OpenAIOAuthDirectAdapter.authPathCandidates(dataRoot: PersistenceCore.defaultDataRoot()) {
                guard path.standardizedFileURL.path != sharedCodexAuth else { continue }
                if FileManager.default.fileExists(atPath: path.path) {
                    try? FileManager.default.removeItem(at: path)
                }
            }
            // Sign-out must also revoke CLI-session adoption: the shared
            // ~/.codex file is deliberately never deleted (it belongs to the
            // CLI), so without this the very next status refresh would
            // silently re-adopt it and the user would stay signed in
            // (gpt-5.5 review 2026-08-06, blocking).
            if OpenAIOAuthDirectAdapter.cliAdoptionConsent() == .allowed {
                recordCodexCLISessionDecision(allow: false, source: "sign_out")
            }
            return true
        case "anthropic_oauth_direct":
            let path = anthropicTokenPath(dataRoot: dataRoot)
            if FileManager.default.fileExists(atPath: path.path) {
                try? FileManager.default.removeItem(at: path)
            }
            return true
        default:
            guard normalized == "xai_oauth_direct" else { return false }
            let path = XAIOAuthDirectAdapter.tokenPath()
            if FileManager.default.fileExists(atPath: path.path) {
                try? FileManager.default.removeItem(at: path)
            }
            return true
        }
    }

    /// Read the persisted `expires_at` for a provider, or nil if not
    /// signed in / no expiry persisted.
    static func expiresAt(providerId: String, dataRoot: URL? = nil) -> Date? {
        let path: URL
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct":    path = openAIActiveAuthPath() ?? openAIAuthPath()
        case "anthropic_oauth_direct": path = anthropicTokenPath(dataRoot: dataRoot)
        case "xai_oauth_direct":       path = XAIOAuthDirectAdapter.tokenPath()
        default: return nil
        }
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let d = parseExpiresAt(obj["expires_at"]) { return d }
        if let tokens = obj["tokens"] as? [String: Any] {
            if let d = parseExpiresAt(tokens["expires_at"]) { return d }
            if let access = tokens["access_token"] as? String,
               let payload = jwtPayload(access) {
                if let exp = payload["exp"] as? Int {
                    return Date(timeIntervalSince1970: TimeInterval(exp))
                }
                if let exp = payload["exp"] as? Double {
                    return Date(timeIntervalSince1970: exp)
                }
            }
        }
        if let access = obj["access_token"] as? String,
           let payload = jwtPayload(access) {
            if let exp = payload["exp"] as? Int {
                return Date(timeIntervalSince1970: TimeInterval(exp))
            }
            if let exp = payload["exp"] as? Double {
                return Date(timeIntervalSince1970: exp)
            }
        }
        return nil
    }

    /// Format `expires_at` as a short status string for the OAuth badge.
    /// For ChatGPT, a sign-in adopted from the shared Codex CLI home is
    /// labeled as such: the reader must be able to tell WHOSE credentials
    /// are live and that they did not come from an in-app sign-in.
    static func signInStatusDetail(providerId: String, dataRoot: URL? = nil) -> String? {
        guard isSignedIn(providerId: providerId, dataRoot: dataRoot) else { return nil }
        let base = expiryStatusText(providerId: providerId, dataRoot: dataRoot)
        if normalizedOAuthProviderId(providerId) == "openai_oauth_direct",
           let adoption = openAIAdoptedCLISessionDetail() {
            return "\(base) — \(adoption)"
        }
        return base
    }

    private static func expiryStatusText(providerId: String, dataRoot: URL?) -> String {
        guard let exp = expiresAt(providerId: providerId, dataRoot: dataRoot) else { return "Signed in" }
        let now = Date()
        let remaining = exp.timeIntervalSince(now)
        if remaining <= 0 {
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
    /// The active path comes from the SAME resolver chat execution uses
    /// (`preferredAuthPath`, via `openAIAuthPath()`), not the first-usable
    /// candidate scan: `preferredAuthPath` honors `CODEX_HOME` /
    /// `NATIVE_AGENT_DATA_ROOT` overrides unconditionally, so a badge built
    /// from a different resolver could label a source execution never reads
    /// (gpt-5.5 review 2026-08-06, blocking). Both sides resolve symlinks
    /// before comparing.
    static func openAIAdoptedCLISessionDetail(
        activeAuthPath: URL? = nil,
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome()
    ) -> String? {
        let path = activeAuthPath ?? openAIAuthPath()
        guard OpenAIOAuthDirectAdapter.hasUsableTokens(at: path) else { return nil }
        let sharedCLIAuth = sharedCLIHome
            .appendingPathComponent("auth.json")
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
    static func openAIAccountEmail(at path: URL) -> String? {
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

    /// Best-effort on-disk auth check used by the UI status badge.
    static func isSignedIn(providerId: String, dataRoot: URL? = nil) -> Bool {
        switch normalizedOAuthProviderId(providerId) {
        case "openai_oauth_direct":
            guard let path = openAIActiveAuthPath(),
                  let data = try? Data(contentsOf: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = obj["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String,
                  !access.isEmpty
            else { return false }
            return true
        case "anthropic_oauth_direct":
            return anthropicOAuthCredentialState(dataRoot: dataRoot) == .ready
        case "xai_oauth_direct":
            guard let data = try? Data(contentsOf: XAIOAuthDirectAdapter.tokenPath()),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            if let s = obj["access_token"] as? String, !s.isEmpty { return true }
            if let nested = (obj["tokens"] as? [String: Any])?["access_token"] as? String,
               !nested.isEmpty { return true }
            return false
        default: return false
        }
    }

    // MARK: - Paths (shared with the read-side adapters)

    static func openAIAuthPath() -> URL {
        OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: PersistenceCore.defaultDataRoot())
    }

    /// App-owned ChatGPT auth WRITE target (`<dataRoot>/codex_home/auth.json`).
    /// In-app sign-in and re-auth always write here — never to the shared
    /// `~/.codex` session, which belongs to the Codex CLI.
    static func openAIAppOwnedAuthPath() -> URL {
        OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: PersistenceCore.defaultDataRoot(),
            allowSharedFallbacks: false
        )
    }

    /// The auth path chat execution will actually use, or nil when it holds
    /// no usable tokens. This is the ONLY source for the sign-in badge:
    /// `preferredAuthPath` honors `CODEX_HOME`/`NATIVE_AGENT_DATA_ROOT`
    /// overrides unconditionally, so a badge built from a first-usable
    /// candidate scan could report "Signed in" off credentials execution
    /// never reads (gpt-5.5 review 2026-08-06). Injectable for tests only.
    static func openAIActiveAuthPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userCodexHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome()
    ) -> URL? {
        let path = OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: PersistenceCore.defaultDataRoot(),
            environment: environment,
            userCodexHome: userCodexHome
        )
        return OpenAIOAuthDirectAdapter.hasUsableTokens(at: path) ? path : nil
    }

    static func anthropicTokenPath(dataRoot: URL? = nil) -> URL {
        (dataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }

    /// Existing malformed provider credentials are unavailable authority, not
    /// an unsigned account. The mounted OAuth panel shows this state before a
    /// user attempts a browser flow that would otherwise fail late.
    static func anthropicOAuthCredentialState(
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
            let access = (object["access_token"] as? String)
                ?? ((object["tokens"] as? [String: Any])?["access_token"] as? String)
            guard let access,
                  !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable("saved credentials contain no access token")
            }
            return .ready
        } catch {
            return .unavailable("saved credentials could not be read: \(error.localizedDescription)")
        }
    }

    /// Persist the exact provider-file shape the Anthropic adapter reads. An
    /// existing malformed credential file is authority evidence, not an empty
    /// starting point: leave it byte-preserved and surface the failed OAuth
    /// completion so Settings never claims a connection that cannot be read.
    static func persistAnthropicOAuthTokens(
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
        var existing: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            let decoded = try JSONSerialization.jsonObject(with: data)
            guard let object = decoded as? [String: Any] else {
                throw NSError(
                    domain: "NativeOAuthFlow",
                    code: -22,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Existing Anthropic OAuth credentials are malformed. Repair or remove them before signing in again."]
                )
            }
            existing = object
        }

        existing["client_id"] = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        existing["access_token"] = rawAccess
        if let refresh = tokens["refresh_token"] as? String {
            existing["refresh_token"] = refresh
        } else if existing["refresh_token"] == nil {
            existing["refresh_token"] = ""
        }
        let expiresIn: Int
        if let integer = tokens["expires_in"] as? Int {
            expiresIn = integer
        } else if let floating = tokens["expires_in"] as? Double {
            expiresIn = Int(floating)
        } else if let string = tokens["expires_in"] as? String,
                  let integer = Int(string) {
            expiresIn = integer
        } else {
            expiresIn = 3_600
        }
        existing["expires_at"] = isoBasic(Date().addingTimeInterval(TimeInterval(expiresIn)))
        existing["scope"] = (tokens["scope"] as? String) ?? ""
        existing["token_type"] = (tokens["token_type"] as? String) ?? "Bearer"
        if existing["user_info"] == nil { existing["user_info"] = [String: Any]() }
        try writeJSONObject(existing, to: path)
    }

    // MARK: - Codex CLI session adoption offer

    /// Non-nil when a usable Codex CLI session exists at `~/.codex` and the
    /// user has not ALLOWED adopting it. The Providers UI renders this as an
    /// explicit one-click offer; nothing uses the session until the user
    /// accepts (the consent gate lives in the Core candidate walk). A prior
    /// decline keeps the offer visible but passive — declining stops the
    /// default adoption, not the capability.
    static func codexCLISessionOffer(
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome(),
        consentState: OpenAIOAuthDirectAdapter.CLISessionAdoptionConsentState =
            OpenAIOAuthDirectAdapter.cliAdoptionConsentState()
    ) -> CodexCLISessionOffer? {
        if case .corrupt(let reason) = consentState {
            return .unavailable(reason: reason)
        }
        guard consentState != .allowed else { return nil }
        let auth = sharedCLIHome.appendingPathComponent("auth.json")
        guard OpenAIOAuthDirectAdapter.hasUsableTokens(at: auth) else { return nil }
        return .available(
            email: openAIAccountEmail(at: auth),
            alreadyDeclined: consentState == .declined
        )
    }

    /// Record the user's decision from the Providers offer UI. Returns false
    /// when the write fails (the offer stays visible; nothing is adopted).
    @discardableResult
    static func recordCodexCLISessionDecision(allow: Bool, source: String) -> Bool {
        do {
            try OpenAIOAuthDirectAdapter.recordCLIAdoptionConsent(
                allow ? .allowed : .declined, source: source)
            return true
        } catch {
            print("[oauth] failed to record CLI adoption consent: \(error)")
            return false
        }
    }

    /// Called only after the Providers UI's destructive confirmation. Core
    /// byte-preserves and verifies the backup before removing the authority.
    static func repairCodexCLISessionConsent() throws -> URL {
        try OpenAIOAuthDirectAdapter.backupAndResetCorruptCLIAdoptionConsent()
    }
}
