import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Legacy HTTP seam

/// Retained temporarily for older constructor call sites. SwiftNativeMacControl
/// does not call this in the zero-daemon runtime.
public protocol HTTPClient: Sendable {
    func postJSON(
        url: URL,
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, data: Data)
}

public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }
    public func postJSON(
        url: URL,
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, data: Data) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

// MARK: - Result type

public struct MacControlResult: Sendable, Equatable {
    public let ok: Bool
    public let action: String
    public let output: JSONValue
    public let error: String?
    public let durationMs: Int
    /// True for Swift-handled results. Zero-daemon MacControl always returns
    /// Swift-shaped results.
    public let viaSwift: Bool
    /// Status code hint for refusal/unsupported results. Successful native
    /// in-process results leave this nil.
    public let httpStatus: Int?
    /// Durable payload-free operation identity. Present when a canonical
    /// MacControlOperationStore owns this dispatch.
    public let operationId: String?
    public let operationState: MacControlOperationState?
    public let verification: MotorVerificationState?

    public init(
        ok: Bool,
        action: String,
        output: JSONValue,
        error: String?,
        durationMs: Int,
        viaSwift: Bool,
        httpStatus: Int? = nil,
        operationId: String? = nil,
        operationState: MacControlOperationState? = nil,
        verification: MotorVerificationState? = nil
    ) {
        self.ok = ok
        self.action = action
        self.output = output
        self.error = error
        self.durationMs = durationMs
        self.viaSwift = viaSwift
        self.httpStatus = httpStatus
        self.operationId = operationId
        self.operationState = operationState
        self.verification = verification
    }

    public func toJSON() -> JSONValue {
        .object([
            "ok": .bool(ok),
            "action": .string(action),
            "output": output,
            "error": error.map { .string($0) } ?? .null,
            "durationMs": .int(Int64(durationMs)),
            "viaSwift": .bool(viaSwift),
            "httpStatus": httpStatus.map { .int(Int64($0)) } ?? .null,
            "operationId": operationId.map { .string($0) } ?? .null,
            "operationState": operationState.map { .string($0.rawValue) } ?? .null,
            "verification": verification.map { .string($0.rawValue) } ?? .null,
        ])
    }
}

public struct MacControlCancellationResult: Sendable, Equatable {
    public let operationId: String
    public let state: MacControlOperationState
    /// True only once the underlying work has stopped. A mere signal/request
    /// returns false and remains `cancel_requested`.
    public let acknowledged: Bool

    public init(operationId: String, state: MacControlOperationState, acknowledged: Bool) {
        self.operationId = operationId
        self.state = state
        self.acknowledged = acknowledged
    }
}

// MARK: - Errors

public enum MacControlError: Error, Sendable, Equatable, LocalizedError {
    case unknownAction(String)
    case missingField(String)
    case sensitivePathDenied(String)
    case shellNotWhitelisted(String)
    case appControlFailed(String)
    case applescriptFailed(String)
    case notificationFailed(String)
    case proxyFailed(status: Int, detail: String)
    case transport(String)
    case malformedResponse(String)
    case ioFailure(String)
    case operation(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let a): return "unknown mac_control action: \(a)"
        case .missingField(let f): return "missing required field: \(f)"
        case .sensitivePathDenied(let p): return "sensitive_path_denied: \(p)"
        case .shellNotWhitelisted(let c): return "shell command not in whitelist: \(c)"
        case .appControlFailed(let s): return "app control failed: \(s)"
        case .applescriptFailed(let s): return "applescript failed: \(s)"
        case .notificationFailed(let s): return "notification failed: \(s)"
        case .proxyFailed(let status, let detail): return "legacy proxy disabled: HTTP \(status) \(detail)"
        case .transport(let s): return "transport error: \(s)"
        case .malformedResponse(let s): return "malformed response: \(s)"
        case .ioFailure(let s): return "io failure: \(s)"
        case .operation(let s): return "operation error: \(s)"
        }
    }
}

// MARK: - Protocol

public protocol MacControlClient: MotorActionReadModelProviding, Sendable {
    /// Dispatch a mac_control sub-action. `action` is the sub-path under
    /// `/v1/mac_control/` (e.g. `"notify"`, `"file/read"`, `"shortcut/run"`).
    /// `body` is the JSON body the daemon route expects (mirrors the iOS
    /// payload shape — see the retired daemon–53747).
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult
    func cancel(operationId: String) async throws -> MacControlCancellationResult
}

// MARK: - Sub-action classification

    /// The set of sub-actions implemented in-process by Swift.
public let macControlNativePortedActions: Set<String> = [
    "notify",
    "applescript",
    "file/read",
    "file/write",
    "file/list",
    "file/move",
    "file/trash",
    "focus_app",
    "quit_app",
    "spotlight",
    "shell",
]

/// Known MacControl actions that are intentionally not implemented in Swift
/// yet. They fail closed with a Swift 501 result rather than proxying.
public let macControlUnsupportedActions: Set<String> = [
    "jxa",
    "shortcut",
    "shortcut/run",
    "keystroke",
    "click",
    "system",
    "self_test",
]

/// All sub-actions the daemon exposes. Used by tests to assert no route
/// gets accidentally dropped from the dispatch table. KEEP IN SYNC with
/// the retired daemon–53747.
public let macControlAllActions: Set<String> =
    macControlNativePortedActions.union(macControlUnsupportedActions)

// MARK: - Sub-action → gate category map (wave 30 W01)

/// Maps a dispatch sub-action to the gate CATEGORY the daemon's
/// `MacControl.<method>` passes to `self._gate(category, trigger)`. Verified
/// byte-for-byte against the retired daemon (the `self._gate("<cat>", …)`
/// call in each method):
///
///   applescript                                  → "applescript"  (L497)
///   jxa                                          → "jxa"          (L548)
///   shortcut / shortcut/run                      → "shortcuts"    (L587)
///   focus_app / quit_app / keystroke / click     → "accessibility"(L615/631/690/718)
///   system                                       → "system"       (L770…826)
///   file/read|write|list|move|trash              → "file_ops"     (L846…950)
///   notify                                       → "notifications"(L996)
///   shell                                        → "shell"        (L1026)
///   spotlight                                    → "spotlight"    (L973)
///
/// `self_test` deliberately returns `nil`: its Python
/// impl gates EVERY category in a loop (L1189 `for cat in …: self._gate(cat)`),
/// so there is no single pre-flight category. Returning `nil` means "do not
/// pre-gate"; unsupported actions fail closed after inventory classification.
public func macControlGateCategory(forAction action: String) -> String? {
    switch action {
    case "applescript":                                   return "applescript"
    case "jxa":                                           return "jxa"
    case "shortcut", "shortcut/run":                      return "shortcuts"
    case "focus_app", "quit_app", "keystroke", "click":   return "accessibility"
    case "system":                                        return "system"
    case "file/read", "file/write", "file/list",
         "file/move", "file/trash":                       return "file_ops"
    case "notify":                                        return "notifications"
    case "shell":                                         return "shell"
    case "spotlight":                                     return "spotlight"
    case "self_test":                                     return nil  // multi-category sweep — daemon-owned
    default:                                              return nil
    }
}

/// The path fields the gate's file-policy check (`_file_policy_reason`) must
/// see for a given file_ops action — mirrors which `path`/`src`/`dst` keys the
/// daemon method passes into `self._file_policy_reason(...)`:
///   read_file / write_file / list_directory / trash_file → ["path"]
///   move_file                                            → ["src", "dst"]
/// Returns the body-key names to extract; empty for non-file actions.
public func macControlFilePolicyPathKeys(forAction action: String) -> [String] {
    switch action {
    case "file/read", "file/write", "file/list", "file/trash": return ["path"]
    case "file/move": return ["src", "dst"]
    default: return []
    }
}

// MARK: - Live-policy provider seam (wave 30 W01)

/// Supplies the live `MacControlPolicy` to `SwiftNativeMacControl` so its
/// `dispatch` can run the W4 `MacControlGate` pre-flight in-process before
/// any native execution. Swift is the execution authority in the zero-daemon
/// runtime.
///
/// `nil` provider is intended for direct unit tests only; production wires a
/// TrustCenter-backed provider.
public protocol MacControlPolicyProvider: Sendable {
    /// Return the current policy, or nil if it can't be resolved (in which
    /// case production callers fail closed before any side effect. Tests can
    /// omit the provider when they need to exercise a handler directly.
    func currentPolicy() async -> MacControlPolicy?
}

public extension MacControlPolicy {
    /// Build the gate policy from the normalized TrustCenter policy object.
    /// This keeps production MacControl fully Swift-native while preserving the
    /// same macControlPolicy/filePolicy fields the UI already edits.
    static func fromTrustPolicyObject(_ root: [String: JSONValue]) -> MacControlPolicy {
        let defaults = MacControlPolicy.default
        let mac: [String: JSONValue] = {
            if case .object(let obj)? = root["macControlPolicy"] { return obj }
            return [:]
        }()
        let filePolicy: [String: JSONValue] = {
            if case .object(let obj)? = root["filePolicy"] { return obj }
            return [:]
        }()

        func bool(_ obj: [String: JSONValue], _ key: String, default def: Bool) -> Bool {
            if case .bool(let value)? = obj[key] { return value }
            return def
        }
        func string(_ obj: [String: JSONValue], _ key: String, default def: String = "") -> String {
            if case .string(let value)? = obj[key] { return value }
            return def
        }
        func double(_ obj: [String: JSONValue], _ key: String, default def: Double) -> Double {
            switch obj[key] {
            case .double(let value): return value
            case .int(let value): return Double(value)
            default: return def
            }
        }
        func stringArray(_ obj: [String: JSONValue], _ key: String) -> [String]? {
            guard case .array(let values)? = obj[key] else { return nil }
            return values.compactMap { value in
                if case .string(let s) = value { return s }
                return nil
            }
        }

        var categoryAllowed = defaults.categoryAllowed
        for key in categoryAllowed.keys {
            categoryAllowed[key] = bool(mac, key, default: categoryAllowed[key] ?? false)
        }

        let approvalRequiredFor = stringArray(mac, "approval_required_for") ?? defaults.approvalRequiredFor
        let workspaceRoots =
            stringArray(root, "workspaceRoots")
            ?? stringArray(root, "workspace_roots")
            ?? stringArray(filePolicy, "workspaceRoots")
            ?? []

        let trustPolicy = MacControlTrustPolicy(
            outsideWorkspaceDefault: string(filePolicy, "outsideWorkspaceDefault", default: "deny"),
            permissionLevel: string(root, "permissionLevel", default: "balanced"),
            fullMacExpiresAt: string(root, "fullMacExpiresAt"),
            fullMacNeverExpires: bool(root, "fullMacNeverExpires", default: false),
            fullMacConfirmedAt: string(root, "fullMacConfirmedAt"),
            fullMacMaxDurationHours: double(root, "fullMacMaxDurationHours", default: 4),
            developerMode: bool(root, "developerMode", default: false),
            allowDestructiveActions: bool(filePolicy, "allowDestructiveActions", default: false)
        )

        return MacControlPolicy(
            enabled: bool(mac, "enabled", default: defaults.enabled),
            remoteFromIOSAllowed: bool(mac, "remote_from_ios_allowed", default: defaults.remoteFromIOSAllowed),
            requireAppBridgeForTCC: bool(mac, "require_app_bridge_for_tcc", default: defaults.requireAppBridgeForTCC),
            categoryAllowed: categoryAllowed,
            trustPolicy: trustPolicy,
            workspaceRoots: workspaceRoots,
            approvalRequiredFor: approvalRequiredFor
        )
    }
}

// MARK: - Shell whitelist

/// Sub-action `shell` is the most dangerous surface in the entire module.
/// Even when policy is permissive, the Swift path enforces a hard executable-prefix whitelist
/// so a compromised LLM tool-call surface CAN NOT pivot from a Mac-app
    /// permission slip to arbitrary code execution.
public enum MacControlShellWhitelist {
    /// First word (split on whitespace) MUST appear here. Absolute-path
    /// commands have the basename checked. Empty / multi-statement chains
    /// (`;`, `&&`, `||`, `|`, backticks, `$(...)`) are rejected outright
    /// regardless of whitelist match — see `validate(_:)`.
    public static let allowed: Set<String> = [
        "echo", "true", "false", "pwd", "whoami", "uname", "date",
        "hostname", "id", "uptime", "df", "uptime",
    ]

    /// Returns nil on accept, or a rejection reason string on deny.
    public static func validate(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty command" }
        // Hard reject any shell-metachar that could chain or substitute.
        let banned: [Character] = [";", "&", "|", "`", "$", ">", "<", "\n", "\r", "\\"]
        for ch in trimmed {
            if banned.contains(ch) {
                return "disallowed metacharacter: \(ch)"
            }
        }
        let firstWord = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        if firstWord.isEmpty { return "no executable" }
        // The whitelist is a NAME whitelist, not a basename whitelist —
        // `/tmp/date` and `./date` MUST be rejected even though basename
        // matches. Attacker-controlled executables on PATH are out of scope.
        if firstWord.hasPrefix(".") {
            return "executable relative path not allowed: \(firstWord)"
        }
        if firstWord.contains("/") {
            return "executable path not allowed: \(firstWord)"
        }
        if !allowed.contains(firstWord) {
            return "executable not whitelisted: \(firstWord)"
        }
        return nil
    }
}

// MARK: - Sensitive-path fence (parity subset)

/// Pared-down port of `MacControl._sensitive_path_reason` (mac_control.py
/// :211–290). Returns the first reason found, empty string when path is
/// allowed. The trust-policy file-policy layer runs separately in
/// `gatePreflightOutcome`.
///
/// **TOCTOU residual**: the fence resolves the symlink chain once at check
/// time, but Foundation does not expose O_NOFOLLOW open semantics so an
/// attacker who can race a symlink swap BETWEEN the fence's resolution and
/// the FileManager call can still bypass the check. Callers shrink the
/// window by re-resolving + re-fencing immediately before the syscall
/// (see `handleFileRead` / `handleFileList`), but the gap is not closed.
/// Sensitive-path safety against an active local attacker is the daemon's
/// responsibility, not Swift's.
public enum MacControlSensitivePathFence {
    /// File basenames that are NEVER touched (credentials, paired
    /// secrets). Case-insensitive.
    public static let bannedFilenames: Set<String> = [
        "config.json",
        "trust_policy.json",
        "trust.json",
        "macctl_bridge.json",
        "browser_ipc_token",
        "browser_ipc.json",
        "auth.json",
        "credentials.json",
        "icloud_pairing_secret.bin",
        "pairing_secret.bin",
    ]

    /// Directory prefixes (relative to $HOME) that are NEVER touched.
    public static let bannedHomePrefixes: [String] = [
        ".config/claude-bridge",
        ".ssh",
        ".gnupg",
        "Library/Keychains",
        "Library/Accounts",
        "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CloudDocs",
        "Library/Application Support/com.apple.TCC",
        "Library/Application Support/Knowledge",
        "Library/Application Support/SyncServices",
        "Library/Messages",
        "Library/Mail",
        "Library/Calendars",
        "Library/Containers/com.apple.Home",
        "Library/Containers/com.apple.reminders",
        "Library/Group Containers/group.com.apple.reminders",
        "Library/Group Containers/group.com.apple.notes",
        "Library/Mobile Documents",
        "Library/Safari",
        "Pictures/Photos Library.photoslibrary",
    ]

    /// Directory prefixes (relative to $HOME) for the NativeAgent default
    /// data root. Mirrors the retired daemon which derives these
    /// from `_data_dir`. The Swift path also checks relocated `/data/...`
    /// segment patterns below.
    public static let bannedDataRootPrefixes: [String] = [
        "Library/Application Support/NativeAgent/oauth",
        "Library/Application Support/NativeAgent/oauth_tokens",
        "Library/Application Support/NativeAgent/providers",
        "Library/Application Support/NativeAgent/trust",
        "Library/Application Support/NativeAgent/pairings",
        "Library/Application Support/NativeAgent/secrets",
        "Library/Application Support/NativeAgent/nextgen/remote",
        "Library/Application Support/NativeAgent/memory/vault",
        "Library/Application Support/NativeAgent/codex_home",
    ]

    /// Path SEGMENTS (relative to any `/data/` boundary) marking a NativeAgent
    /// data-root subdirectory regardless of WHERE on disk the data root lives
    /// (repo `data/`, the Swift-native `NATIVE_AGENT_DATA_ROOT`-relocated
    /// root, or the default AppSupport one covered above). Each entry is a
    /// list of consecutive path components expected immediately after a
    /// `data` component.
    ///
    /// Matched by path-component walk, NOT substring — `/tmp/notdata/oauth`
    /// is allowed because `notdata` is not the component `data`.
    public static let bannedDataRootSegments: [[String]] = [
        ["oauth"],
        ["oauth_tokens"],
        ["providers"],
        ["trust"],
        ["pairings"],
        ["secrets"],
        ["nextgen", "remote"],
        ["memory", "vault"],
        ["codex_home"],
    ]

    /// Non-bypassable OS mutation floor. Full Mac grants broad user-space
    /// access, but it must not authorize mutation of the operating system,
    /// launch services, or app bundles.
    public static let protectedSystemMutationPrefixes: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/Applications",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools",
        "/Library/StartupItems",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/etc",
        "/var/db",
        "/var/root",
    ]

    /// Swift-native data root, resolved per call. Mirrors whatever
    /// `PersistenceCore.defaultDataRoot()` returns — which honors
    /// `NATIVE_AGENT_DATA_ROOT` when set, otherwise the AppSupport default.
    private static var swiftDataRootPath: String {
        PersistenceCore.defaultDataRoot().path
    }

    /// Legacy daemon data-root override. DENY-ONLY: this env var is no longer
    /// read as a config source anywhere in the Swift port, but if a user (or
    /// a stale launchctl plist) still has `NATIVE_AGENT_DATA` exported, the
    /// sensitive-path fence MUST still cover whatever it points at. Without
    /// this, an attacker who can set the env var could pivot read/write tools
    /// at the daemon-era root and bypass the explicit AppSupport coverage.
    /// gpt-5.5 review LOW/MED. Path returned only for fence-extension; the
    /// rest of the codebase ignores this variable.
    private static var legacyDaemonDataRootPath: String? {
        let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA"]
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (raw as NSString).expandingTildeInPath
    }

    /// Returns nil when path is allowed, or a rejection reason string.
    public static func reason(forPath rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty path" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if let r = checkSingle(path: expanded) { return r }
        // Symlink follow: catch a benign-looking path whose target lands in
        // a sensitive prefix. Python uses Path.resolve(strict=False); we
        // approximate with URL.resolvingSymlinksInPath and re-run the fence
        // checks against the resolved path if it differs from the raw one.
        let resolved = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath().path
        if resolved != expanded {
            if let r = checkSingle(path: resolved) { return r }
        }
        return nil
    }

    public static func protectedSystemMutationReason(forPath rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "protected_system_path_denied: empty path" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidates = [
            URL(fileURLWithPath: expanded).standardizedFileURL.path,
            URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path,
        ]
        for path in candidates {
            if let prefix = protectedSystemMutationPrefixes.first(where: { isSelfOrAncestor(root: $0, path: path) }) {
                return "protected_system_path_denied: \(prefix)"
            }
        }
        return nil
    }

    private static func isSelfOrAncestor(root: String, path: String) -> Bool {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path.lowercased()
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private static func checkSingle(path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let basename = url.lastPathComponent.lowercased()

        let bannedLower = Set(bannedFilenames.map { $0.lowercased() })
        if bannedLower.contains(basename) {
            return "sensitive_path_denied: \(url.lastPathComponent)"
        }

        let home = (NSHomeDirectory() as NSString).expandingTildeInPath
        let pathLower = url.path.lowercased()
        let homeLower = home.lowercased()
        for prefix in bannedHomePrefixes {
            let fullPrefix = (homeLower as NSString)
                .appendingPathComponent(prefix.lowercased())
            if pathLower == fullPrefix || pathLower.hasPrefix(fullPrefix + "/") {
                return "sensitive_path_denied: \(prefix)"
            }
        }
        for prefix in bannedDataRootPrefixes {
            let fullPrefix = (homeLower as NSString)
                .appendingPathComponent(prefix.lowercased())
            if pathLower == fullPrefix || pathLower.hasPrefix(fullPrefix + "/") {
                return "sensitive_path_denied: \(prefix)"
            }
        }

        // Swift-native data root coverage. `PersistenceCore.defaultDataRoot()`
        // honors `NATIVE_AGENT_DATA_ROOT` when set, so a relocated data root
        // gets the same explicit-prefix coverage as the AppSupport default.
        //
        // Also covers the legacy daemon `NATIVE_AGENT_DATA` if it's still
        // exported. We do NOT consult that env var as a config source — this
        // is the DENY half only, so a stale plist can't be used to pivot
        // tools at a root the fence forgot about.
        var dataRootCandidates: [String] = [swiftDataRootPath]
        if let legacy = legacyDaemonDataRootPath {
            dataRootCandidates.append(legacy)
        }
        for rootRaw in dataRootCandidates {
            let rootLower = rootRaw.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rootLower.isEmpty else { continue }
            for segs in bannedDataRootSegments {
                let suffix = segs.joined(separator: "/").lowercased()
                let full = "/\(rootLower)/\(suffix)"
                if pathLower == full || pathLower.hasPrefix(full + "/") {
                    return "sensitive_path_denied: data/\(segs.joined(separator: "/"))"
                }
            }
        }

        // Path-component walk: catch any `…/data/<bannedSegs…>/…` regardless
        // of where on disk the `data` root lives (repo, alt location, etc).
        // SEGMENT match — `/tmp/notdata/oauth` MUST pass.
        let components = pathLower.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        for (i, comp) in components.enumerated() where comp == "data" {
            for segs in bannedDataRootSegments {
                let needed = segs.map { $0.lowercased() }
                let endIdx = i + 1 + needed.count
                guard endIdx <= components.count else { continue }
                let slice = Array(components[(i + 1)..<endIdx])
                if slice == needed {
                    return "sensitive_path_denied: data/\(segs.joined(separator: "/"))"
                }
            }
        }
        return nil
    }
}
