import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LLMClient+OpenAIOAuthCredentials.swift` | `OpenAIOAuthDirectAdapter.preferredAuthPath`: the single ChatGPT/Codex credential-path resolver for readiness, all adapters, maintenance, child execution and explicit CLI inspection; app-owned writes and root-consented CLI adoption share this owner; child homes derive from an already-selected credential; hasAccessToken checks presence only, not execution readiness |

extension OpenAIOAuthDirectAdapter {
    /// Inspection of the independently signed-in Codex program is distinct
    /// from permission for NativeAgent providers to use that account.
    public enum AuthPathSource {
        case runtime
        case sharedCLI
        case commandCLI
    }

    /// The only ChatGPT/Codex credential-path resolver, shared by readiness,
    /// adapters and child processes. The default root honors process overrides;
    /// alternate roots use their own sign-in or explicitly adopted CLI session.
    /// Writes pass `allowSharedFallbacks: false`; CLI inspection is explicit and
    /// never grants provider execution permission. A selected path is pinned
    /// through execution/refresh, including an explicit injected path.
    public static func preferredAuthPath(
        dataRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        appSupportRoot: URL = libraryAppSupportFallback(),
        userCodexHome: URL = defaultUserCodexHome(),
        allowSharedFallbacks: Bool = true,
        defaultRoot: URL = PersistenceCore.defaultDataRoot(),
        authPathOverride: URL? = nil,
        source: AuthPathSource = .runtime
    ) -> URL {
        if let authPathOverride { return authPathOverride }
        let shared = userCodexHome.appendingPathComponent("auth.json")
        switch source {
        case .sharedCLI: return shared
        case .commandCLI:
            if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
                return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                    .appendingPathComponent("auth.json")
            }
            return shared
        case .runtime: break
        }
        func ownedPath(_ root: URL) -> URL {
            root.standardizedFileURL
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        func boundRootPath(_ root: URL) -> URL {
            let owned = ownedPath(root)
            if !hasAccessToken(at: owned), cliAdoptionConsent(dataRoot: root) == .allowed,
               hasAccessToken(at: shared) { return shared }
            return owned
        }
        if !allowSharedFallbacks {
            return ownedPath(dataRoot ?? defaultRoot)
        }
        if let dataRoot,
           dataRoot.standardizedFileURL != defaultRoot.standardizedFileURL {
            return boundRootPath(dataRoot)
        }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        }
        if let dataRoot = environment["NATIVE_AGENT_DATA_ROOT"], !dataRoot.isEmpty {
            let root = URL(fileURLWithPath: (dataRoot as NSString).expandingTildeInPath)
            return boundRootPath(root)
        }
        let repoRoot = URL(fileURLWithPath: currentDirectoryPath).appendingPathComponent("data", isDirectory: true)
        var candidates = [ownedPath(repoRoot), ownedPath(appSupportRoot)]
        if let dataRoot { candidates.append(ownedPath(dataRoot)) }
        candidates.append(ownedPath(defaultRoot))
        // All app-owned sign-ins outrank an adopted CLI session. Process
        // overrides above are exact, and alternate roots never scan this list.
        if cliAdoptionConsent(dataRoot: dataRoot) == .allowed { candidates.append(shared) }
        // Only honor the repo path when the FILE exists AND it carries real
        // tokens. Mere presence of `data/` (or worse, root-relative `/data/`)
        // shouldn't shadow the app-support candidate.
        for candidate in candidates where Self.hasAccessToken(at: candidate) {
            return candidate
        }
        return ownedPath(appSupportRoot)
    }

    /// True iff the file at `url` parses and has a non-empty
    /// tokens.access_token. Used by `preferredAuthPath` to decide between the
    /// repo dev path and the production AppSupport path.
    public static func hasAccessToken(at url: URL) -> Bool {
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

    /// Shared CLI credentials stay read-only, including explicit overrides
    /// and app-owned paths that resolve through a symlink into ~/.codex.
    static func isUserCodexPath(_ path: URL) -> Bool {
        let lexicalHome = defaultUserCodexHome().standardizedFileURL.path
        let lexicalPath = path.standardizedFileURL.path
        if lexicalPath == lexicalHome || lexicalPath.hasPrefix(lexicalHome + "/") { return true }
        let home = defaultUserCodexHome().resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == home || resolved.hasPrefix(home + "/")
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
        guard !isUserCodexPath(path) else {
            throw LLMError.failure(.codexCLISessionExpired)
        }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path)
    }

    // MARK: - Codex child home

    /// CODEX_HOME for every Codex child the app runs on its own ChatGPT sign-in
    /// (the `codex` chat provider, swarm workers, the workshop planner, image
    /// generation). It holds an access-only copy of `<root>/codex_home/auth.json`,
    /// so the app stays the only refresher. 2026-10-07: the Codex CLI rewrites
    /// auth.json from a typed struct when it refreshes, which drops the refresh
    /// binding (the 10-06 17 h outage class), and it rotates the single-use
    /// refresh token behind the app's back.
    public static func codexChildHome(dataRoot: URL) -> URL {
        // Credential/session copy: excluded from backup/export/phone sync;
        // PrivacyMap: codex_child_home. Codex owns its internal file schemas.
        dataRoot.standardizedFileURL.appendingPathComponent("codex_child_home", isDirectory: true)
    }

    /// Derive the child home from ONE already-resolved credential. Missing
    /// credentials fail at execution; they never remove CODEX_HOME and let the
    /// CLI choose a different account.
    public static func codexHomeForChild(authPath: URL) -> URL {
        codexChildHome(mirroring: authPath) ?? authPath.deletingLastPathComponent()
    }

    /// The child home that mirrors `authPath`, or nil when `authPath` is not an
    /// app-owned `<root>/codex_home/auth.json`.
    public static func codexChildHome(mirroring authPath: URL) -> URL? {
        let home = authPath.standardizedFileURL.deletingLastPathComponent()
        guard authPath.lastPathComponent == "auth.json",
              home.lastPathComponent == "codex_home",
              !isUserCodexPath(authPath) else { return nil }
        return codexChildHome(dataRoot: home.deletingLastPathComponent())
    }

    /// `<home>/auth.json` once its real path is proven to sit directly in the
    /// data root, apart from `codex_home` and ~/.codex. A symlinked child home
    /// or auth.json pointing anywhere else is refused, never followed.
    private static func checkedCodexChildAuthPath(home: URL) throws -> URL {
        let root = home.standardizedFileURL.deletingLastPathComponent()
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let realHome = home.resolvingSymlinksInPath().standardizedFileURL
        let auth = home.appendingPathComponent("auth.json")
        let realAuth = auth.resolvingSymlinksInPath().standardizedFileURL
        let realAppHome = root.appendingPathComponent("codex_home", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard realHome.path == realRoot.appendingPathComponent("codex_child_home").path,
              realAuth.path == realHome.appendingPathComponent("auth.json").path,
              realHome.path != realAppHome.path,
              !isUserCodexPath(realHome), !isUserCodexPath(realAuth) else {
            throw LLMError.underlying(message: "Codex child credential path leaves the data root; refusing to write it.")
        }
        return auth
    }

    /// Write the child copy of the credential bytes just written to `authPath`:
    /// the same tokens with an empty refresh token. Caller holds `authPath`'s
    /// `CredentialFileLock`.
    static func writeCodexChildCopy(_ bytes: Data, of authPath: URL) throws {
        guard let home = codexChildHome(mirroring: authPath) else { return }
        guard let blob = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let tokens = blob["tokens"] as? [String: Any] else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        var childTokens: [String: Any] = ["refresh_token": ""]
        for key in ["id_token", "access_token", "account_id"] {
            if let value = tokens[key] { childTokens[key] = value }
        }
        let copy: [String: Any] = [
            "auth_mode": blob["auth_mode"] ?? "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": childTokens,
            "last_refresh": blob["last_refresh"] ?? NSNull(),
        ]
        try writeAuthBytesAtomically(
            JSONSerialization.data(withJSONObject: copy, options: [.prettyPrinted, .sortedKeys]),
            to: checkedCodexChildAuthPath(home: home)
        )
    }

    /// Bring the child copy in line with the app credential at `authPath`, or
    /// remove it when the app is signed out.
    static func syncCodexChildCopy(from authPath: URL) throws {
        guard let home = codexChildHome(mirroring: authPath) else { return }
        try CredentialFileLock.withLock(authPath) {
            if FileManager.default.fileExists(atPath: authPath.path) {
                try writeCodexChildCopy(Data(contentsOf: authPath), of: authPath)
            } else {
                let copy = try checkedCodexChildAuthPath(home: home)
                if FileManager.default.fileExists(atPath: copy.path) {
                    try FileManager.default.removeItem(at: copy)
                }
            }
        }
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
        if let s = raw as? String, let unix = TimeInterval(s) { return Int(exactly: unix.rounded(.towardZero)) }
        guard let expiry = parseExpiresAt(raw) else { return nil }
        return Int(exactly: expiry.timeIntervalSince1970.rounded(.towardZero))
    }

    /// Read `exp` claim from a JWT payload. Returns nil when missing.
    static func tokenExpiresAt(_ token: String) -> Int? {
        guard let payload = jwtPayload(token, omittingEmptySubsequences: false) else { return nil }
        if let exp = payload["exp"] as? Int { return exp }
        if let exp = payload["exp"] as? Double { return Int(exactly: exp.rounded(.towardZero)) }
        return nil
    }

    /// Extract chatgpt_account_id from a JWT payload's
    /// `https://api.openai.com/auth` claim. Mirrors the lookup chain in
    /// `_account_id()` at L751-L764 + the persistence path at L678-L684.
    static func extractAccountIDFromJWT(_ token: String) -> String? {
        guard let payload = jwtPayload(token, omittingEmptySubsequences: false) else { return nil }
        guard let authClaim = payload["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return authClaim["chatgpt_account_id"] as? String
    }

    /// The account header must belong to the token this request will send.
    func currentAccountID(accessToken: String) throws -> String? {
        if let account = Self.extractAccountIDFromJWT(accessToken) { return account }
        guard let blob = loadAuthBlob() else { return nil }
        let tokens = (blob["tokens"] as? [String: Any]) ?? [:]
        guard tokens["access_token"] as? String == accessToken else {
            throw OAuthRequestAccount.changed("openai_oauth_direct")
        }
        if let acct = tokens["account_id"] as? String, !acct.isEmpty {
            return acct
        }
        if let access = tokens["access_token"] as? String, !access.isEmpty {
            return Self.extractAccountIDFromJWT(access)
        }
        return nil
    }
}
