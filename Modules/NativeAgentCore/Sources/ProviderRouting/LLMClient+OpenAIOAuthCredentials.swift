import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LLMClient+OpenAIOAuthCredentials.swift` | `ChatGPTTransport.preferredAuthPath`: one pinned credential source |

extension ChatGPTTransport {
    /// Inspection of the independently signed-in Codex program is distinct from permission for NativeAgent providers to use that account.
    public enum AuthPathSource {
        case runtime
        case sharedCLI
        case commandCLI
    }

    /// One resolver pins credentials through execution and refresh. App writes stay app-owned; shared CLI adoption requires consent and CLI inspection
    /// grants no execution authority.
    public static func preferredAuthPath(
        dataRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userCodexHome: URL = defaultUserCodexHome(),
        allowSharedFallbacks: Bool = true,
        defaultRoot: URL = PersistenceCore.defaultDataRoot(),
        authPathOverride: URL? = nil,
        source: AuthPathSource = .runtime
    ) -> URL {
        if let authPathOverride { return authPathOverride }
        let shared = userCodexHome.appendingPathComponent("auth.json")
        let commandCLI = environment["CODEX_HOME"].flatMap { home in
            home.isEmpty ? nil : URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
        }
        switch source {
        case .sharedCLI: return shared
        case .commandCLI: return commandCLI ?? shared
        case .runtime: break
        }
        func ownedPath(_ root: URL) -> URL {
            root.standardizedFileURL
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        func boundRootPath(_ root: URL) -> URL {
            let owned = ownedPath(root)
            if !credentialFileExists(at: owned), cliAdoptionConsent(dataRoot: root) == .allowed,
               credentialFileExists(at: shared) { return shared }
            return owned
        }
        if !allowSharedFallbacks {
            return ownedPath(dataRoot ?? defaultRoot)
        }
        let root = dataRoot ?? (!(environment["NATIVE_AGENT_DATA_ROOT"] ?? "").isEmpty
            ? PersistenceCore.defaultDataRoot(environment: environment) : defaultRoot)
        return boundRootPath(root)
    }

    private static func credentialFileExists(at url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        // Only an absent path admits discovery/adoption. Inaccessible paths and dangling credential symlinks must reach the checked reader.
        return errno != ENOENT
    }

    /// Checked token presence, not path selection or execution readiness. An absent access token (including CLI API-key mode) is false;
    /// malformed/unreadable saved bytes throw.
    public static func hasAccessToken(at url: URL) throws -> Bool {
        try storedAccessToken(at: url) != nil
    }

    public static func defaultUserCodexHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// Shared CLI credentials stay read-only, including explicit overrides and app-owned paths that resolve through a symlink into ~/.codex.
    static func isUserCodexPath(_ path: URL) -> Bool {
        let home = defaultUserCodexHome()
        return NativeAgentWorkspaceRoot.relativePath(path.standardizedFileURL.path, under: home.standardizedFileURL.path) != nil
            || NativeAgentWorkspaceRoot.relativePath(path.resolvingSymlinksInPath().standardizedFileURL.path,
                under: home.resolvingSymlinksInPath().standardizedFileURL.path) != nil
    }

    // MARK: - Shared CLI session adoption consent

    /// Adoption consent is independent of the shared CLI session's presence.
    public enum CLISessionAdoptionConsent: String {
        case allowed
        case declined
    }

    /// Checked reads distinguish absent consent from damaged authority so repair/UI cannot treat corruption as a decision.
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

    public static func cliAdoptionConsentPath(dataRoot: URL? = nil) -> URL {
        (dataRoot ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("cli_session_adoption.json")
    }

    /// Only explicit consent admits the shared CLI session. Missing or unreadable consent grants nothing; damaged bytes stay untouched.
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

    /// Persist explicit consent with a receipt source; corrupt authority stays byte-preserved and fails the write.
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

    /// Verify a byte-preserved backup before removing corrupt authority so repair invents no decision.
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

    /// Load only this selected credential. Confirmed absence is nil; present unreadable or invalid bytes retain the owning read failure.
    func loadAuthBlob() throws -> [String: Any]? {
        try Self.loadAuthBlob(at: resolveAuthPath())
    }

    /// Read only the already-resolved path so a concurrent sign-out cannot switch credential sources.
    static func loadAuthBlob(at path: URL) throws -> [String: Any]? {
        do {
            guard let data = try ProviderStateValidation.dataIfPresent(at: path) else { return nil }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try ProviderStateValidation.credential(object)
            // Codex also writes API-key sessions with no ChatGPT token set. Valid metadata without access_token is absence, not corruption.
            if let tokens = object["tokens"] as? [String: Any],
               let access = tokens["access_token"] as? String,
               access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CocoaError(.fileReadCorruptFile)
            }
            return object
        } catch {
            throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                detail: "ChatGPT credential \(path.path) could not be read: \(error.localizedDescription). Repair the saved credential before reconnecting.")
        }
    }

    /// A valid file without an access token has no ChatGPT session to adopt.
    static func storedAccessToken(at path: URL) throws -> String? {
        guard let blob = try loadAuthBlob(at: path),
              let tokens = blob["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty else { return nil }
        return access
    }

    /// Atomic writer for the flock-guarded refresh path, whose closure captures only `Data`/`URL`.
    static func writeAuthBytesAtomically(_ data: Data, to path: URL) throws {
        guard !isUserCodexPath(path) else {
            throw LLMError.failure(.codexCLISessionExpired)
        }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path.resolvingSymlinksInPath())
    }

    // MARK: - Codex child home

    /// App-authenticated Codex children use an access-only CODEX_HOME so the app owns token refresh.
    public static func codexChildHome(dataRoot: URL) -> URL {
        // Exclude child credentials from backup, export and phone sync; PrivacyMap: codex_child_home. The CLI owns its file schemas.
        dataRoot.standardizedFileURL.appendingPathComponent("codex_child_home", isDirectory: true)
    }

    /// Derive the child home from ONE already-resolved credential. Missing credentials fail at execution; they never remove CODEX_HOME and let the CLI
    /// choose a different account.
    public static func codexHomeForChild(authPath: URL) -> URL {
        codexChildHome(mirroring: authPath) ?? authPath.deletingLastPathComponent()
    }

    /// Only app-owned credentials may have a mirrored child home.
    public static func codexChildHome(mirroring authPath: URL) -> URL? {
        let home = authPath.standardizedFileURL.deletingLastPathComponent()
        guard authPath.lastPathComponent == "auth.json",
              home.lastPathComponent == "codex_home",
              !isUserCodexPath(authPath) else { return nil }
        return codexChildHome(dataRoot: home.deletingLastPathComponent())
    }

    /// `<home>/auth.json` once its real path is proven to sit directly in the data root, apart from `codex_home` and ~/.codex. A symlinked child home or
    /// auth.json pointing anywhere else is refused, never followed.
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

    /// Caller holds the credential lock; child copies omit refresh authority. Returns the access token the copy holds.
    @discardableResult
    static func writeCodexChildCopy(_ bytes: Data, of authPath: URL) throws -> String? {
        guard let home = codexChildHome(mirroring: authPath) else { return nil }
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
        return childTokens["access_token"] as? String
    }

    /// Child credentials must track app rotation and sign-out. Returns the access token the child copy now holds; nil when sign-out removed it.
    @discardableResult
    static func syncCodexChildCopy(from authPath: URL) throws -> String? {
        guard let home = codexChildHome(mirroring: authPath) else { return nil }
        return try CredentialFileLock.withLock(authPath) { () -> String? in
            if FileManager.default.fileExists(atPath: authPath.path) {
                return try writeCodexChildCopy(Data(contentsOf: authPath), of: authPath)
            }
            let copy = try checkedCodexChildAuthPath(home: home)
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            return nil
        }
    }

    /// Flows persist expiry at the top level or under tokens; both ISO and numeric forms are current inputs. Unknown expiry stays nil.
    static func persistedExpiresAt(blob: [String: Any], tokens: [String: Any]) -> Int? {
        let raw: Any? = blob["expires_at"] ?? tokens["expires_at"]
        guard let raw = raw else { return nil }
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(exactly: d.rounded(.towardZero)) }
        if let s = raw as? String, let unix = TimeInterval(s) { return Int(exactly: unix.rounded(.towardZero)) }
        guard let expiry = parseExpiresAt(raw) else { return nil }
        return Int(exactly: expiry.timeIntervalSince1970.rounded(.towardZero))
    }

    static func tokenExpiresAt(_ token: String) -> Int? {
        guard let payload = jwtPayload(token, omittingEmptySubsequences: false) else { return nil }
        if let exp = payload["exp"] as? Int { return exp }
        if let exp = payload["exp"] as? Double { return Int(exactly: exp.rounded(.towardZero)) }
        return nil
    }

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
        guard let blob = try loadAuthBlob() else { return nil }
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
