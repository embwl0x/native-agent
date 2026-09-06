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
    static func clearTokens(providerId: String, dataRoot: URL? = nil) -> Bool {
        let normalized = normalizedOAuthProviderId(providerId)
        switch providerId {
        case "openai_oauth_direct":
            let sharedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("auth.json")
                .standardizedFileURL
                .path
            // User, 2026-09-06: honour the root the caller passed. This walked
            // the DEFAULT root's candidates, so a sign-out against an override
            // root (an alternate install, a test root) deleted the wrong
            // install's tokens and left the intended one signed in.
            // User, 2026-09-06: and delete ONLY this root's app-owned file. The
            // full candidate walk also returns the CODEX_HOME and
            // NATIVE_AGENT_DATA_ROOT env paths, the repo checkout's,
            // Application Support's and the default root's — so signing out of
            // one install wiped every other install's ChatGPT token.
            // `allowSharedFallbacks: false` is exactly `<root>/codex_home/
            // auth.json`, which is where in-app sign-in writes
            // (`openAIAppOwnedAuthPath`).
            let root = dataRoot ?? PersistenceCore.defaultDataRoot()
            var removed = true
            for path in OpenAIOAuthDirectAdapter.authPathCandidates(
                dataRoot: root,
                allowSharedFallbacks: false
            ) {
                guard path.standardizedFileURL.path != sharedCodexAuth else { continue }
                if !removeCredentialFile(at: path) { removed = false }
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
            return removeCredentialFile(
                at: XAIOAuthDirectAdapter.tokenPath(dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot())
            )
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

    /// True when the persisted credential carries a non-empty refresh token —
    /// the only thing that makes an expired access token recoverable without
    /// the browser. User, 2026-09-06: the badge promised a refresh on the next
    /// chat for every expired credential, including ones with nothing to
    /// refresh with, so a dead sign-in looked like it would heal itself.
    static func hasRefreshToken(providerId: String, dataRoot: URL? = nil) -> Bool {
        guard let path = statusCredentialPath(providerId: providerId, dataRoot: dataRoot),
              let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let candidates = [
            obj["refresh_token"] as? String,
            (obj["tokens"] as? [String: Any])?["refresh_token"] as? String,
        ]
        return candidates.contains {
            ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    /// Read the persisted `expires_at` for a provider, or nil if not
    /// signed in / no expiry persisted.
    static func expiresAt(providerId: String, dataRoot: URL? = nil) -> Date? {
        guard let path = statusCredentialPath(providerId: providerId, dataRoot: dataRoot) else {
            return nil
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
        if remaining <= 0 {
            guard hasRefreshToken(providerId: providerId, dataRoot: dataRoot) else {
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
            guard hasRefreshToken(providerId: providerId, dataRoot: dataRoot) else {
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
    static func openAIAdoptedCLISessionDetail(
        activeAuthPath: URL? = nil,
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome(),
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String? {
        guard let path = activeAuthPath
            ?? openAIStatusAuthPath(dataRoot: dataRoot, sharedCLIHome: sharedCLIHome)
        else { return nil }
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
            // User, 2026-09-06: same root confinement as `statusCredentialPath`
            // — the badge said "Signed in" off a credential belonging to a
            // different root than the one the screen is showing.
            guard let path = openAIStatusAuthPath(
                dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot()),
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
            guard let data = try? Data(contentsOf: XAIOAuthDirectAdapter.tokenPath(
                      dataRoot: dataRoot ?? PersistenceCore.defaultDataRoot())),
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

    static func openAIAuthPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        OpenAIOAuthDirectAdapter.preferredAuthPath(dataRoot: dataRoot)
    }

    /// App-owned ChatGPT auth WRITE target (`<dataRoot>/codex_home/auth.json`).
    /// In-app sign-in and re-auth always write here — never to the shared
    /// `~/.codex` session, which belongs to the Codex CLI.
    static func openAIAppOwnedAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: dataRoot,
            allowSharedFallbacks: false
        )
    }

    /// The ChatGPT credential a badge for `dataRoot` is allowed to read: that
    /// root's own app-owned file, or — only when THAT root's consent record
    /// allows it — the shared Codex CLI file. Nil when neither holds usable
    /// tokens.
    ///
    /// User, 2026-09-06: the badge went through `preferredAuthPath`, which walks
    /// every candidate on the machine (cwd repo, Application Support, the
    /// default root) and returns the first usable one — so status for an
    /// override root reported another root's sign-in, expiry and refreshability.
    /// A root's status may never come from a different root's credential.
    ///
    /// `CODEX_HOME` stays a candidate for the DEFAULT root only: execution
    /// there honours the process env unconditionally, while a client bound to
    /// an override root rebinds `CODEX_HOME` to that root, so the process value
    /// says nothing about it.
    static func openAIStatusAuthPath(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome()
    ) -> URL? {
        var candidates: [URL] = []
        if dataRoot.standardizedFileURL.path
            == PersistenceCore.defaultDataRoot().standardizedFileURL.path,
           let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            candidates.append(
                URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                    .appendingPathComponent("auth.json"))
        }
        candidates.append(openAIAppOwnedAuthPath(dataRoot: dataRoot))
        if OpenAIOAuthDirectAdapter.cliAdoptionConsent(dataRoot: dataRoot) == .allowed {
            candidates.append(sharedCLIHome.appendingPathComponent("auth.json"))
        }
        return candidates.first { OpenAIOAuthDirectAdapter.hasUsableTokens(at: $0) }
    }

    /// The auth path chat execution will actually use, or nil when it holds
    /// no usable tokens. This is the ONLY source for the sign-in badge:
    /// `preferredAuthPath` honors `CODEX_HOME`/`NATIVE_AGENT_DATA_ROOT`
    /// overrides unconditionally, so a badge built from a first-usable
    /// candidate scan could report "Signed in" off credentials execution
    /// never reads (gpt-5.5 review 2026-08-06). Injectable for tests only.
    static func openAIActiveAuthPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userCodexHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome(),
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL? {
        let path = OpenAIOAuthDirectAdapter.preferredAuthPath(
            dataRoot: dataRoot,
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
    ///
    /// User, 2026-09-06: the consent record is per-root
    /// (`<dataRoot>/providers/cli_session_adoption.json`), so the offer reads
    /// the root the screen is showing — it read the DEFAULT root's record
    /// whatever root was selected, and an override root's own decision was
    /// invisible here.
    static func codexCLISessionOffer(
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
        let auth = sharedCLIHome.appendingPathComponent("auth.json")
        guard OpenAIOAuthDirectAdapter.hasUsableTokens(at: auth) else { return nil }
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
    static func sharedCodexCLISessionRemains(
        providerId: String,
        sharedCLIHome: URL = OpenAIOAuthDirectAdapter.defaultUserCodexHome()
    ) -> Bool {
        let id = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id == "openai_oauth_direct" || id == "codex" else { return false }
        return OpenAIOAuthDirectAdapter.hasUsableTokens(
            at: sharedCLIHome.appendingPathComponent("auth.json")
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
    static func recordCodexCLISessionDecision(
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
    static func repairCodexCLISessionConsent(dataRoot: URL? = nil) throws -> URL {
        try OpenAIOAuthDirectAdapter.backupAndResetCorruptCLIAdoptionConsent(dataRoot: dataRoot)
    }
}
