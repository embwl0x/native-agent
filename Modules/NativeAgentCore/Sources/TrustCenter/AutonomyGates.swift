import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #17 wave 8 (2026-05-31) — Trust + Autonomy gates port.
//
// Swift implementation of the two autonomy preflight gates plus the rebuild
// mutex ahead of system_rebuild / git_stash_recover (and the wider
// write-action surface). The gate preserves the historical boolean refusal
// shape so SystemOps paths can run with the same dashboard/log surface.
//
// Historical source references:
//
//   _check_trust_policy_for_action — composite of the two boolean
//     guards repeated at L45110 / L45112 (system_rebuild),
//     L45193 / L45195 (git_push), L45254 / L45256 (git_stash_recover),
//     L45334 / etc.  Both must hold for any autonomy-write to proceed:
//
//       if not self.enable_autonomy:
//           raise PermissionError(
//               "autonomy disabled — enable_autonomy is False")
//       if not bool((self.trust_policy() or {})
//                   .get("enableAutonomy", False)):
//           raise PermissionError(
//               "autonomy disabled in Trust Center — enable it in Settings")
//
//     Plus a per-action enabled flag for the highest-risk actions:
//
//       if not bool(_tp.get("systemRebuild", {}).get("enabled", False)):
//           raise PermissionError(
//               "system_rebuild requires "
//               "trust_policy.systemRebuild.enabled=true (default false).")
//
//   _autonomy_approval_gate — composite that is the standard pre-write
//     gate around `system_rebuild()` (L45110-L45169) and
//     `git_stash_recover()` (L45254-L45257). It is the layered
//     "global autonomy + user trust + per-action enabled" check
//     that callers must pass before a side-effectful daemon route runs.
//
//   _rebuild_lock — `threading.Lock()` created at L2538 and acquired
//     non-blocking at L45168 inside `system_rebuild()`. The Python lock
//     intentionally is NOT released after subprocess.Popen kicks off
//     `install_app.sh` (L45185 comment: "lock intentionally NOT released
//     here — the daemon is about to die"). The Swift mirror uses a
//     cross-process flock(2) on a `.rebuild.lock` file inside the data
//     root so a second daemon process or second Swift caller can detect
//     contention deterministically. The lock is auto-released when the
//     fd closes (process death drops fd refs), which matches the
//     "daemon dies mid-install" semantic without leaving a stale flag.

// MARK: - Gate result type

/// Outcome of `checkTrustPolicyForAction` / `autonomyApprovalGate`. Preserves
/// the historical boolean refusal shape as a typed value so SwiftNative callers
/// can pattern-match without unwinding through Swift error propagation. Each
/// `.denied(reason:)` case carries the human-readable string used by log-grep
/// and dashboard tooling.
public enum AutonomyGateResult: Sendable, Equatable {
    case allowed
    case denied(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Outcome of `autonomyApprovalGate`. Currently the same shape as
/// `AutonomyGateResult` (the daemon's pre-write gate is boolean today —
/// approval-flow integration is wave-9+). Kept distinct so the public API
/// can grow a `requiresApproval(id:)` case without breaking call sites of
/// the simpler `checkTrustPolicyForAction`.
public enum AutonomyApprovalResult: Sendable, Equatable {
    case allowed
    case denied(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

// MARK: - Trust policy reader

/// Minimal trust-policy view consumed by the gates. Mirrors the daemon
/// shape produced by `Daemon.trust_policy()`.
/// Only the four fields the gates actually read are typed; everything
/// else stays in `raw` so callers can introspect surface-specific blocks
/// without re-decoding.
public struct AutonomyTrustPolicyView: Sendable, Equatable {
    public let enableAutonomy: Bool
    public let systemRebuildEnabled: Bool
    public let gitStashRecoverEnabled: Bool
    public let raw: JSONValue

    public init(
        enableAutonomy: Bool,
        systemRebuildEnabled: Bool,
        gitStashRecoverEnabled: Bool,
        raw: JSONValue
    ) {
        self.enableAutonomy = enableAutonomy
        self.systemRebuildEnabled = systemRebuildEnabled
        self.gitStashRecoverEnabled = gitStashRecoverEnabled
        self.raw = raw
    }

    /// Parse a JSON trust-policy blob the way the daemon does. Missing keys
    /// default to `false` — same default as Python `(_tp or {}).get(...,
    /// False)`. Non-object inputs degrade to "all gates closed" so a
    /// corrupted trust file fails closed, matching Python's
    /// `isinstance(saved, dict)` defensive cast.
    public static func parse(_ value: JSONValue) -> AutonomyTrustPolicyView {
        guard case .object(let obj) = value else {
            return AutonomyTrustPolicyView(
                enableAutonomy: false,
                systemRebuildEnabled: false,
                gitStashRecoverEnabled: false,
                raw: value
            )
        }

        func boolAt(_ key: String) -> Bool {
            if case .bool(let b) = obj[key] ?? .null { return b }
            return false
        }
        func nestedBool(_ outer: String, _ inner: String) -> Bool {
            guard case .object(let nested) = obj[outer] ?? .null else { return false }
            if case .bool(let b) = nested[inner] ?? .null { return b }
            return false
        }

        return AutonomyTrustPolicyView(
            enableAutonomy: boolAt("enableAutonomy"),
            systemRebuildEnabled: nestedBool("systemRebuild", "enabled"),
            gitStashRecoverEnabled: nestedBool("gitStashRecover", "enabled"),
            raw: value
        )
    }

    /// Closed-everything view. Useful for tests + the "policy file is
    /// missing on disk" path. Mirrors Python's `(_tp or {}).get(...)` chain
    /// when `trust_path` does not exist yet.
    public static let denyAll = AutonomyTrustPolicyView(
        enableAutonomy: false,
        systemRebuildEnabled: false,
        gitStashRecoverEnabled: false,
        raw: .object([:])
    )
}

// MARK: - Gate predicates

/// Tagged action enum used by `checkTrustPolicyForAction`. Limited to the
/// actions wave-8 actually wires through Swift; new actions add a case +
/// the matching per-action enabled-key lookup in `requiresPerActionFlag`.
public enum AutonomyGatedAction: String, Sendable, Equatable, CaseIterable {
    case systemRebuild
    case gitStashRecover
    /// "gitPush" mirrors the daemon's `git_push()` gate at L45193-45195.
    /// It uses only the global autonomy + trust gates; no per-action
    /// enabled flag (the daemon hasn't added one yet — see L45114 TODO).
    case gitPush

    /// Returns the trust-policy nested-bool key the action requires beyond
    /// the global autonomy gate (or `nil` if the action only needs the
    /// global gate). Mirrors the Python check at L45120 verbatim:
    /// `_tp.get("systemRebuild", {}).get("enabled", False)`.
    fileprivate func perActionEnabled(_ policy: AutonomyTrustPolicyView) -> Bool? {
        switch self {
        case .systemRebuild:    return policy.systemRebuildEnabled
        case .gitStashRecover:  return policy.gitStashRecoverEnabled
        case .gitPush:          return nil
        }
    }

    /// Human-readable label used in refusal strings. Matches the daemon's
    /// log line wording.
    fileprivate var label: String {
        switch self {
        case .systemRebuild:    return "system_rebuild"
        case .gitStashRecover:  return "git_stash_recover"
        case .gitPush:          return "git_push"
        }
    }

    /// The exact trust-policy key path the per-action gate consults, used
    /// to build a byte-identical refusal string when the per-action flag
    /// is off. Matches Python L45122 verbatim.
    fileprivate var perActionPolicyPath: String {
        switch self {
        case .systemRebuild:    return "trust_policy.systemRebuild.enabled"
        case .gitStashRecover:  return "trust_policy.gitStashRecover.enabled"
        case .gitPush:          return ""
        }
    }
}

/// Public port of `_check_trust_policy_for_action`. Both the global
/// `enableAutonomy` master switch (daemon startup flag) AND the
/// user-toggled Trust Center `enableAutonomy` must be true; for high-risk
/// actions (systemRebuild today) the per-action enabled flag must also be
/// true. Returns the first failing reason — same order Python checks.
///
/// - Parameters:
///   - action:           The action being gated.
///   - daemonAutonomy:   The static daemon-startup flag (Python
///                       `self.enable_autonomy` — set at boot from CLI/env).
///   - policy:           The current user-toggled trust policy view (read
///                       fresh from `data/trust/policy.json` via
///                       PersistenceCore — caller controls freshness).
public func checkTrustPolicyForAction(
    _ action: AutonomyGatedAction,
    daemonAutonomy: Bool,
    policy: AutonomyTrustPolicyView
) -> AutonomyGateResult {
    // Order matches Python L45110 → L45112 → L45120 byte-for-byte: the
    // global master switch is checked first so a daemon booted with
    // `enable_autonomy=False` always refuses regardless of trust file
    // contents.
    if !daemonAutonomy {
        return .denied(reason: "autonomy disabled — enable_autonomy is False")
    }
    if !policy.enableAutonomy {
        return .denied(reason: "autonomy disabled in Trust Center — enable it in Settings")
    }
    if let perAction = action.perActionEnabled(policy), !perAction {
        // L3#15 (2026-08-11): this deny copy used to close by promising that a
        // numbered future phase would add a full approval-request flow for the
        // action. No such phase exists in any current plan, and no
        // approval-request flow exists for these actions —
        // the trust setting IS the only way to allow them. Deny copy states the
        // requirement and stops there; it does not promise a roadmap.
        return .denied(reason:
            "\(action.label) requires \(action.perActionPolicyPath)=true (default false). " +
            "Enable it in Trust Center to allow \(action.label); there is no per-request " +
            "approval path for this action."
        )
    }
    return .allowed
}

/// Public port of `_autonomy_approval_gate`. This gate is exactly the same
/// composite as `checkTrustPolicyForAction` — there is no approval-request
/// flow behind `system_rebuild` / `git_stash_recover`, and none is planned;
/// the Trust Center per-action setting is the whole decision. The function
/// stays a separate symbol only so its two callers keep a stable name if an
/// approval flow is ever built; it makes no promise that one will be.
public func autonomyApprovalGate(
    action: AutonomyGatedAction,
    daemonAutonomy: Bool,
    policy: AutonomyTrustPolicyView
) async throws -> AutonomyApprovalResult {
    switch checkTrustPolicyForAction(action, daemonAutonomy: daemonAutonomy, policy: policy) {
    case .allowed:
        return .allowed
    case .denied(let reason):
        return .denied(reason: reason)
    }
}

// MARK: - Cross-process rebuild mutex

/// Cross-process rebuild mutex implemented with `flock(2)` on a
/// `.rebuild.lock` file inside the data root so a second Swift caller —
/// can detect that a rebuild is already in progress.
///
/// Semantics:
///   • `acquire()` returns `true` on first acquire, `false` if another
///     process already holds the lock. Non-blocking (LOCK_EX | LOCK_NB).
///   • `release()` releases the flock and closes the fd. Called only in
///     the error path inside SwiftNativeSystemRebuildClient — the happy
///     path intentionally leaks the fd so the lock stays held until
///     install_app.sh kills the daemon (matches Python L45185 comment).
///   • The lock auto-releases on process exit (the kernel drops the fd),
///     so a daemon crash mid-rebuild does not leave a permanent block —
///     same recovery story as the Python lock.
public actor RebuildLock {
    private let lockPath: URL
    private var fd: Int32 = -1

    /// - Parameter dataRoot: Directory containing `data/`. The lock file
    ///   is `<dataRoot>/.rebuild.lock` — outside any subdirectory that
    ///   `data/` writers might rotate.
    public init(dataRoot: URL) {
        self.lockPath = dataRoot.appendingPathComponent(".rebuild.lock")
    }

    /// Convenience initializer using `PersistenceCore.defaultDataRoot()`.
    public init() {
        self.init(dataRoot: PersistenceCore.defaultDataRoot())
    }

    /// Attempt to acquire the lock non-blocking. Returns `true` if this
    /// process now holds it; `false` if another process already holds it.
    public func acquire() -> Bool {
        if fd >= 0 { return true } // already held by this actor
        let parent = lockPath.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let newFd = Darwin.open(lockPath.path, O_CREAT | O_WRONLY, 0o600)
        if newFd < 0 { return false }
        let result = flock(newFd, LOCK_EX | LOCK_NB)
        if result != 0 {
            Darwin.close(newFd)
            return false
        }
        fd = newFd
        return true
    }

    /// Release the lock if held. Called only in the rebuild error path —
    /// the happy path lets the fd leak (daemon is about to be killed by
    /// install_app.sh).
    public func release() {
        if fd < 0 { return }
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }

    /// Whether this actor currently holds the lock. Test-only introspection.
    public func isHeld() -> Bool {
        return fd >= 0
    }
}

// MARK: - Default trust-policy reader

/// Helper that reads the on-disk trust policy at `<dataRoot>/trust/policy.json`
/// via PersistenceCore. Mirrors the path convention pinned in Python at
/// L2297: `self.trust_path = root / "trust" / "policy.json"`. Returns
/// `AutonomyTrustPolicyView.denyAll` if the file is missing or unreadable
/// — matches Python's `read_json(self.trust_path, {})` default behavior.
public func readAutonomyTrustPolicy(
    dataRoot: URL? = nil,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async -> AutonomyTrustPolicyView {
    let root = dataRoot ?? PersistenceCore.defaultDataRoot()
    let path = root.appendingPathComponent("trust").appendingPathComponent("policy.json")
    let value = await persistence.readJSON(path, defaultValue: .object([:]))
    return AutonomyTrustPolicyView.parse(value)
}
