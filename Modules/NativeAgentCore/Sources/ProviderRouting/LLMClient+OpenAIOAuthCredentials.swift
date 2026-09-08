import Foundation
import NativeAgentCore
import PersistenceCore

extension OpenAIOAuthDirectAdapter {
    /// Candidate ChatGPT OAuth auth.json paths in the same order the runtime
    /// should trust them. This is public so the Mac app's provider picker and
    /// OAuth badge can use the exact same discovery as chat execution.
    public static func authPathCandidates(
        dataRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        appSupportRoot: URL = libraryAppSupportFallback(),
        userCodexHome: URL = defaultUserCodexHome(),
        allowSharedFallbacks: Bool = true,
        defaultRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> [URL] {
        if !allowSharedFallbacks, let dataRoot {
            return [dataRoot.standardizedFileURL
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")]
        }
        var candidates: [URL] = []
        var seen: Set<String> = []
        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard !seen.contains(standardized.path) else { return }
            seen.insert(standardized.path)
            candidates.append(standardized)
        }

        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            append(URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json"))
        }
        if let dataRoot = environment["NATIVE_AGENT_DATA_ROOT"], !dataRoot.isEmpty {
            append(URL(fileURLWithPath: (dataRoot as NSString).expandingTildeInPath)
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json"))
        }
        let cwd = URL(fileURLWithPath: currentDirectoryPath)
        let repoAuth = cwd
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        append(repoAuth)
        let appSupport = appSupportRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        append(appSupport)
        if let dataRoot {
            append(dataRoot
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json"))
        }
        append(defaultRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json"))
        // The shared Codex CLI session is the LAST candidate, and only after
        // an explicit recorded user decision: every app-owned path outranks
        // the foreign-owned CLI file, so an in-app (re-)auth always wins over
        // an adopted session on the next resolution. `CODEX_HOME` above stays
        // consent-free: an env override is itself a deliberate user act.
        // (0.3.8 lesson — silent adoption on a fresh install; gpt-5.5 review
        // 2026-08-06 round 2 — shared-before-dataRoot let a stale adopted
        // session outrank a fresh in-app re-auth on stamped dev roots.)
        if cliAdoptionConsent(dataRoot: dataRoot) == .allowed {
            append(userCodexHome.appendingPathComponent("auth.json"))
        }
        return candidates
    }

    /// Preferred auth path for chat execution. Uses the first candidate with
    /// usable tokens; when none exist, returns the first writable candidate.
    public static func preferredAuthPath(
        dataRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        appSupportRoot: URL = libraryAppSupportFallback(),
        userCodexHome: URL = defaultUserCodexHome(),
        allowSharedFallbacks: Bool = true,
        defaultRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> URL {
        if !allowSharedFallbacks, let dataRoot {
            return dataRoot.standardizedFileURL
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        }
        if let dataRoot = environment["NATIVE_AGENT_DATA_ROOT"], !dataRoot.isEmpty {
            return URL(fileURLWithPath: (dataRoot as NSString).expandingTildeInPath)
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        let candidates = authPathCandidates(
            dataRoot: dataRoot,
            environment: environment,
            currentDirectoryPath: currentDirectoryPath,
            appSupportRoot: appSupportRoot,
            userCodexHome: userCodexHome,
            allowSharedFallbacks: allowSharedFallbacks,
            defaultRoot: defaultRoot
        )
        // Only honor the repo path when the FILE exists AND it carries real
        // tokens. Mere presence of `data/` (or worse, root-relative `/data/`)
        // shouldn't shadow the app-support candidate.
        for candidate in candidates where Self.hasUsableTokens(at: candidate) {
            return candidate
        }
        return appSupportRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// True iff the file at `url` parses and has a non-empty
    /// tokens.access_token. Used by `resolveAuthPath` to decide between the
    /// repo dev path and the production AppSupport path.
    public static func hasUsableTokens(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty else {
            return false
        }
        return true
    }

    public static func defaultUserCodexHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    // MARK: - Shared CLI session adoption consent

    /// Whether the user has decided about adopting the shared Codex CLI
    /// session (`~/.codex/auth.json`) as the app's ChatGPT sign-in.
    public enum CLISessionAdoptionConsent: String {
        case allowed
        case declined
    }

    /// Checked authority read. Compatibility callers may still ask only for
    /// the decision, but UI/repair paths must preserve the distinction between
    /// a genuinely missing record and existing bytes that cannot be trusted.
    public enum CLISessionAdoptionConsentState: Equatable, Sendable {
        case missing
        case allowed
        case declined
        case corrupt(reason: String)

        public var decision: CLISessionAdoptionConsent? {
            switch self {
            case .allowed: return .allowed
            case .declined: return .declined
            case .missing, .corrupt: return nil
            }
        }
    }

    /// Consent record path: `<dataRoot>/providers/cli_session_adoption.json`.
    public static func cliAdoptionConsentPath(dataRoot: URL? = nil) -> URL {
        (dataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("cli_session_adoption.json")
    }

    /// Read the recorded decision. Missing file means NO decision — the
    /// shared CLI candidate stays out of auth resolution until the user
    /// explicitly allows it (0.3.8 lesson: a fresh install silently adopting
    /// the machine's CLI session looked signed-in with nobody having
    /// consented). Unreadable or malformed existing state is treated as
    /// no-consent and is never rewritten.
    public static func cliAdoptionConsent(dataRoot: URL? = nil) -> CLISessionAdoptionConsent? {
        cliAdoptionConsentState(dataRoot: dataRoot).decision
    }

    public static func cliAdoptionConsentState(
        dataRoot: URL? = nil
    ) -> CLISessionAdoptionConsentState {
        let path = cliAdoptionConsentPath(dataRoot: dataRoot)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            return .corrupt(reason: "The saved consent record cannot be read: \(error.localizedDescription)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["decision"] as? String,
              let decision = CLISessionAdoptionConsent(rawValue: raw) else {
            return .corrupt(reason: "The saved consent record is malformed or contains an unknown decision.")
        }
        return decision == .allowed ? .allowed : .declined
    }

    /// Persist an explicit user decision. `source` names the UI moment that
    /// captured it (for the receipt, not for authority). An existing record
    /// that does not parse to a known decision is corrupt authority: it is
    /// byte-preserved and this write fails loud rather than papering over it
    /// (standard corrupt-authority contract; gpt-5.5 review 2026-08-06).
    public static func recordCLIAdoptionConsent(
        _ decision: CLISessionAdoptionConsent,
        source: String,
        dataRoot: URL? = nil
    ) throws {
        let path = cliAdoptionConsentPath(dataRoot: dataRoot)
        if case .corrupt = cliAdoptionConsentState(dataRoot: dataRoot) {
            throw NSError(
                domain: "ProviderRouting.CLISessionAdoptionConsent", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "existing consent record is unreadable; refusing to overwrite it"])
        }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "decision": decision.rawValue,
            "decidedAt": ISO8601DateFormatter().string(from: Date()),
            "source": source,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: path, options: [.atomic])
    }

    /// Explicit repair for corrupt authority. The exact bytes are copied and
    /// read back before the authoritative path is removed. The next read is
    /// therefore genuinely `.missing`; no decision is invented by repair.
    @discardableResult
    public static func backupAndResetCorruptCLIAdoptionConsent(
        dataRoot: URL? = nil
    ) throws -> URL {
        let path = cliAdoptionConsentPath(dataRoot: dataRoot)
        guard case .corrupt = cliAdoptionConsentState(dataRoot: dataRoot) else {
            throw NSError(
                domain: "ProviderRouting.CLISessionAdoptionConsent", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "the consent record is not corrupt; no repair was performed"]
            )
        }
        let original = try Data(contentsOf: path)
        let backup = path.deletingLastPathComponent().appendingPathComponent(
            "cli_session_adoption.corrupt-\(UUID().uuidString.lowercased()).backup"
        )
        try original.write(to: backup, options: [.atomic])
        guard try Data(contentsOf: backup) == original else {
            throw NSError(
                domain: "ProviderRouting.CLISessionAdoptionConsent", code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "the corrupt consent backup could not be verified"]
            )
        }
        try FileManager.default.removeItem(at: path)
        return backup
    }

    /// True when a signed-in ChatGPT OAuth credential is on disk at this
    /// adapter's own resolved path (User, 2026-09-06 — see
    /// `OAuthCredentialPresence`).
    var hasStoredOAuthCredential: Bool {
        guard let blob = loadAuthBlob(),
              let tokens = blob["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String
        else { return false }
        return !access.isEmpty
    }

    /// Load the auth blob from disk. Returns `nil` when the file is missing
    /// or unparseable — mirroring Python's `_load_codex_auth` which returns
    /// `{}` in both cases. We use `nil` here so the "needs OAuth" path is a
    /// clean `.notConfigured` throw at the caller.
    func loadAuthBlob() -> [String: Any]? {
        Self.loadAuthBlob(at: resolveAuthPath())
    }

    /// Read the blob at ONE already-resolved path. User, 2026-09-06: candidate
    /// resolution probes the filesystem, so any code that resolved a path and
    /// then called `loadAuthBlob()` could be handed a different file's bytes
    /// — a sign-out mid-refresh moves the answer to the shared Codex CLI file.
    static func loadAuthBlob(at path: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The stored access token at ONE already-resolved path, or nil.
    static func storedAccessToken(at path: URL) -> String? {
        guard let blob = loadAuthBlob(at: path),
              let tokens = blob["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty else { return nil }
        return access
    }

    /// Atomic writer for the flock-guarded refresh path, whose closure
    /// captures only `Data`/`URL`.
    static func writeAuthBytesAtomically(_ data: Data, to path: URL) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Atomic write via a sibling tempfile + rename — same pattern as
        // Python's `atomic_write_text` (which the provider also uses).
        let tmp = parent.appendingPathComponent(
            ".\(path.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.prefix(8)).tmp"
        )
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try? FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Decode the (unverified) payload of a JWT. Mirrors `_jwt_payload`
    /// at L375-L385. We only use this to read claims for account_id + exp —
    /// the JWT is still server-side validated on every API call.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
        // base64url -> base64
        b64 = b64.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let pad = b64.count % 4
        if pad != 0 { b64.append(String(repeating: "=", count: 4 - pad)) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Read a persisted `expires_at` from the auth blob. Looks at both
    /// the top level (where some flows write) and `tokens.expires_at`
    /// (where others write). Accepts ISO basic / ISO with fractional / or
    /// numeric (seconds-from-epoch). Returns nil if absent or unparseable.
    static func persistedExpiresAt(blob: [String: Any], tokens: [String: Any]) -> Int? {
        let raw: Any? = blob["expires_at"] ?? tokens["expires_at"]
        guard let raw = raw else { return nil }
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(exactly: d.rounded(.towardZero)) }
        guard let s = raw as? String, !s.isEmpty else { return nil }
        if let unix = TimeInterval(s) { return Int(exactly: unix.rounded(.towardZero)) }
        let basic = DateFormatter()
        basic.calendar = Calendar(identifier: .iso8601)
        basic.locale = Locale(identifier: "en_US_POSIX")
        basic.timeZone = TimeZone(secondsFromGMT: 0)
        basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        if let d = basic.date(from: s) { return Int(d.timeIntervalSince1970) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970) }
        return nil
    }

    /// Read `exp` claim from a JWT payload. Returns nil when missing.
    static func tokenExpiresAt(_ token: String) -> Int? {
        guard let payload = jwtPayload(token) else { return nil }
        if let exp = payload["exp"] as? Int { return exp }
        if let exp = payload["exp"] as? Double { return Int(exactly: exp.rounded(.towardZero)) }
        return nil
    }

    /// Extract chatgpt_account_id from a JWT payload's
    /// `https://api.openai.com/auth` claim. Mirrors the lookup chain in
    /// `_account_id()` at L751-L764 + the persistence path at L678-L684.
    static func extractAccountIDFromJWT(_ token: String) -> String? {
        guard let payload = jwtPayload(token) else { return nil }
        guard let authClaim = payload["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return authClaim["chatgpt_account_id"] as? String
    }

    /// account_id resolution. Mirrors `_account_id()` exactly — checks the
    /// persisted `tokens.account_id` first, then falls back to extracting
    /// from the JWT.
    func currentAccountID() -> String? {
        guard let blob = loadAuthBlob() else { return nil }
        let tokens = (blob["tokens"] as? [String: Any]) ?? [:]
        if let acct = tokens["account_id"] as? String, !acct.isEmpty {
            return acct
        }
        if let access = tokens["access_token"] as? String, !access.isEmpty {
            return Self.extractAccountIDFromJWT(access)
        }
        return nil
    }
}
