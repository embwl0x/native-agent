import Foundation

// MARK: - Subsystem #19 wave 29 W4 (2026-06-01) — MacControl _gate pipeline port.
//
// Faithful Swift port of the Python gate pipeline in the retired daemon:
//
//   • _gate                  → MacControlGate.gate(category:trigger:)
//       (master enabled + remote_ios + per-category)
//   • DEFAULT_MAC_CONTROL_POLICY / _CATEGORY_KEY
//                            → MacControlPolicy + categoryPolicyKey(_:)
//   • _full_mac_active       → MacControlGate.fullMacActive(_:now:)
//   • _file_policy_reason    → MacControlGate.fileReason(forPaths:now:)
//   • bridge-required (in _run, the retired daemon)
//                            → MacControlGate.bridgeRequired(category:argv0:)
//
// PURPOSE: unblock the 14 DORMANT-PROXY mac_control routes for a FUTURE
// cutover wave. This port reproduces the SAME order of checks and the SAME
// user-facing refusal-reason strings as Python so a flipped route is
// behaviourally identical. THIS WAVE DOES NOT FLIP ANY ROUTE — the dispatch
// table in MacControl.swift is unchanged; this is pure library code + tests.
//
// Refusal-reason parity is load-bearing: these strings surface to the user
// (block_reason on the receipt). They are reproduced verbatim from Python:
//   "mac_control_disabled: master gate off"
//   "remote_ios_disabled: remote_from_ios_allowed is off"
//   "category_disabled: <key> is off"
//   "file_policy_denied: <resolved> is outside configured workspaces"
//   "file_policy_requires_approval: <resolved> is outside configured workspaces"
//   "mac_control_bridge_required: NativeAgent.app bridge is unavailable"

// MARK: - Policy input shapes

/// Swift mirror of the gate-relevant subset of `DEFAULT_MAC_CONTROL_POLICY`
/// merged with the live `macControlPolicy`.
///
/// Only the fields the gate pipeline reads are modelled. `categoryAllowed`
/// keys are the policy keys (`applescript_allowed`, …) so a category can be
/// resolved through `categoryPolicyKey(_:)` exactly like `_CATEGORY_KEY` +
/// `f"{category}_allowed"` fallback in Python.
public struct MacControlPolicy: Sendable, Equatable {
    /// master gate (`enabled`).
    public var enabled: Bool
    /// `remote_from_ios_allowed`.
    public var remoteFromIOSAllowed: Bool
    /// `require_app_bridge_for_tcc`.
    public var requireAppBridgeForTCC: Bool
    /// Per-category allow flags keyed by POLICY KEY (e.g. `shell_allowed`).
    /// A missing key reads as `false` — matching `policy.get(key, False)`.
    public var categoryAllowed: [String: Bool]
    /// `_trustPolicy` (filePolicy + full-mac window). `nil` ⇔ Python's
    /// empty / missing `_trustPolicy` (file policy then short-circuits to
    /// allow — see `fileReason`).
    public var trustPolicy: MacControlTrustPolicy?
    /// `_workspaceRoots` — paths inside these are always file-allowed.
    public var workspaceRoots: [String]
    /// `approval_required_for` — the live list of CATEGORIES that require an
    /// approval gate. `nil` ⇔ the key is absent from the policy, in which
    /// case `MacControl._approval_required` defaults to
    /// `["shell"]` for the `shell` category and `[]` for everything else.
    /// Carried here so a Swift-side refusal audit row records the SAME
    /// `approval_required` value the daemon's `_blocked_receipt` would
    /// (`approval_required=self._approval_required(category)`,
    /// the retired daemon) instead of a hardcoded default — see
    /// `SwiftNativeMacControl.approvalRequired(forCategory:policy:)`.
    public var approvalRequiredFor: [String]?

    public init(
        enabled: Bool = false,
        remoteFromIOSAllowed: Bool = false,
        requireAppBridgeForTCC: Bool = true,
        categoryAllowed: [String: Bool] = [:],
        trustPolicy: MacControlTrustPolicy? = nil,
        workspaceRoots: [String] = [],
        approvalRequiredFor: [String]? = nil
    ) {
        self.enabled = enabled
        self.remoteFromIOSAllowed = remoteFromIOSAllowed
        self.requireAppBridgeForTCC = requireAppBridgeForTCC
        self.categoryAllowed = categoryAllowed
        self.trustPolicy = trustPolicy
        self.workspaceRoots = workspaceRoots
        self.approvalRequiredFor = approvalRequiredFor
    }

    /// The hard-OFF default, mirroring `DEFAULT_MAC_CONTROL_POLICY`. Note
    /// the defaults that are ON in Python: `shortcuts`, `notifications`,
    /// `spotlight`. Everything else is OFF.
    public static let `default` = MacControlPolicy(
        enabled: false,
        remoteFromIOSAllowed: false,
        requireAppBridgeForTCC: true,
        categoryAllowed: [
            "applescript_allowed": false,
            "jxa_allowed": false,
            "shortcuts_allowed": true,
            "accessibility_allowed": false,
            "system_control_allowed": false,
            "file_ops_allowed": false,
            "shell_allowed": false,
            "notifications_allowed": true,
            "spotlight_allowed": true,
        ],
        trustPolicy: nil,
        workspaceRoots: [],
        // DEFAULT_MAC_CONTROL_POLICY["approval_required_for"]
        // — so a default-policy refusal logs the SAME
        // approval_required value the daemon would (e.g. file_ops → true).
        approvalRequiredFor: [
            "shell", "file_ops", "applescript", "jxa", "accessibility",
        ]
    )
}

/// Swift mirror of the gate-relevant subset of the trust policy
/// (`_trustPolicy`) — the fields read by `_full_mac_active` and
/// `_file_policy_reason` in the retired daemon.
public struct MacControlTrustPolicy: Sendable, Equatable {
    /// `filePolicy.outsideWorkspaceDefault` — "deny" | "ask" | "allow".
    /// Defaults to "deny" (matching `or "deny"` in Python).
    public var outsideWorkspaceDefault: String
    /// `permissionLevel` — defaults "balanced".
    public var permissionLevel: String
    /// `fullMacExpiresAt` — ISO-8601 string or "never" or "".
    public var fullMacExpiresAt: String
    /// `fullMacNeverExpires`.
    public var fullMacNeverExpires: Bool
    /// `fullMacConfirmedAt` — ISO-8601 string or "".
    public var fullMacConfirmedAt: String
    /// `fullMacMaxDurationHours` — clamped to [0.01, 24.0]; default 4.
    public var fullMacMaxDurationHours: Double
    /// Top-level `developerMode`. This is the operator-only escalation for
    /// destructive/system-level Mac actions.
    public var developerMode: Bool
    /// `filePolicy.allowDestructiveActions`.
    public var allowDestructiveActions: Bool

    public init(
        outsideWorkspaceDefault: String = "deny",
        permissionLevel: String = "balanced",
        fullMacExpiresAt: String = "",
        fullMacNeverExpires: Bool = false,
        fullMacConfirmedAt: String = "",
        fullMacMaxDurationHours: Double = 4,
        developerMode: Bool = false,
        allowDestructiveActions: Bool = false
    ) {
        self.outsideWorkspaceDefault = outsideWorkspaceDefault
        self.permissionLevel = permissionLevel
        self.fullMacExpiresAt = fullMacExpiresAt
        self.fullMacNeverExpires = fullMacNeverExpires
        self.fullMacConfirmedAt = fullMacConfirmedAt
        self.fullMacMaxDurationHours = fullMacMaxDurationHours
        self.developerMode = developerMode
        self.allowDestructiveActions = allowDestructiveActions
    }
}

// MARK: - Category → policy key map (mirror of _CATEGORY_KEY)

/// Mirror of `_CATEGORY_KEY`. Returns the
/// policy key for a category, with the `f"{category}_allowed"` fallback for
/// unmapped categories — byte-for-byte the same as
/// `_CATEGORY_KEY.get(category, f"{category}_allowed")`.
public func categoryPolicyKey(_ category: String) -> String {
    switch category {
    case "applescript":   return "applescript_allowed"
    case "jxa":           return "jxa_allowed"
    case "shortcuts":     return "shortcuts_allowed"
    case "accessibility": return "accessibility_allowed"
    case "system":        return "system_control_allowed"
    case "file_ops":      return "file_ops_allowed"
    case "shell":         return "shell_allowed"
    case "notifications": return "notifications_allowed"
    case "spotlight":     return "spotlight_allowed"
    default:              return "\(category)_allowed"
    }
}

// MARK: - Gate decision

/// Result of the master/remote/category gate. `(allowed, reason)` mirrors
/// the Python `(bool, str)` tuple — `reason` is empty when allowed.
public struct MacControlGateDecision: Sendable, Equatable {
    public let allowed: Bool
    public let reason: String
    public init(allowed: Bool, reason: String) {
        self.allowed = allowed
        self.reason = reason
    }
    public static let allow = MacControlGateDecision(allowed: true, reason: "")
}

/// Pure, side-effect-free port of the daemon gate pipeline. Every method is
/// static and takes its inputs explicitly so it is trivially unit-testable
/// (no clock, FS, or actor dependency except the injectable `now`).
public enum MacControlGate {

    /// Categories that require the NativeAgent.app bridge (TCC attribution)
    /// — `bridge_required_categories` in `_run`.
    public static let bridgeRequiredCategories: Set<String> = [
        "applescript", "jxa", "accessibility", "system", "file_ops", "shell",
    ]

    /// argv[0] basenames that force bridge-required regardless of category —
    /// the `Path(cmd[0]).name in {...}` clause in `_run`.
    public static let bridgeRequiredArgv0: Set<String> = [
        "osascript", "bash", "zsh", "sh",
    ]

    // MARK: master / remote / per-category

    /// Mirror of `_gate` master clause:
    /// `policy.get("enabled", False)`.
    public static func masterEnabled(_ policy: MacControlPolicy) -> Bool {
        policy.enabled
    }

    /// Mirror of `_gate` remote clause: only the
    /// `ios` trigger is gated on `remote_from_ios_allowed`. Returns true
    /// (allowed) for any non-ios trigger.
    public static func remoteIOSAllowed(_ policy: MacControlPolicy, trigger: String) -> Bool {
        if trigger == "ios" { return policy.remoteFromIOSAllowed }
        return true
    }

    /// Mirror of `_gate` category clause:
    /// `policy.get(_CATEGORY_KEY.get(category, f"{category}_allowed"), False)`.
    public static func perCategoryEnabled(_ policy: MacControlPolicy, category: String) -> Bool {
        let key = categoryPolicyKey(category)
        return policy.categoryAllowed[key] ?? false
    }

    /// Full port of `MacControl._gate`. Preserves
    /// the EXACT order of checks and the EXACT refusal strings:
    ///   1. master gate  → "mac_control_disabled: master gate off"
    ///   2. remote ios   → "remote_ios_disabled: remote_from_ios_allowed is off"
    ///   3. per-category → "category_disabled: <key> is off"
    public static func gate(
        _ policy: MacControlPolicy,
        category: String,
        trigger: String = "user"
    ) -> MacControlGateDecision {
        if !masterEnabled(policy) {
            return MacControlGateDecision(allowed: false, reason: "mac_control_disabled: master gate off")
        }
        if trigger == "ios" && !policy.remoteFromIOSAllowed {
            return MacControlGateDecision(allowed: false, reason: "remote_ios_disabled: remote_from_ios_allowed is off")
        }
        let key = categoryPolicyKey(category)
        if !(policy.categoryAllowed[key] ?? false) {
            return MacControlGateDecision(allowed: false, reason: "category_disabled: \(key) is off")
        }
        return .allow
    }

    // MARK: full-mac trust window

    /// Swift-native Full Mac window check.
    ///
    /// Logic, in order:
    ///   1. Gate on permission: unless `outsideWorkspaceDefault == "allow"`
    ///      OR `permissionLevel ∈ {wide_open_receipts, full_mac_os}`, NOT active.
    ///   2. `fullMacNeverExpires` true OR `fullMacExpiresAt == "never"` → active.
    ///   3. explicit `fullMacExpiresAt` → active iff now <= expiry (bad parse → false).
    ///   4. else `fullMacConfirmedAt` + `fullMacMaxDurationHours` sliding window
    ///      (max clamped to [0.01, 24.0], default 4); empty confirmed → false;
    ///      bad parse → false.
    public static func fullMacActive(
        _ trust: MacControlTrustPolicy,
        now: Date = Date()
    ) -> Bool {
        let outside = trust.outsideWorkspaceDefault.isEmpty ? "deny" : trust.outsideWorkspaceDefault
        let permission = trust.permissionLevel.isEmpty ? "balanced" : trust.permissionLevel
        if outside != "allow" && !(permission == "wide_open_receipts" || permission == "full_mac_os") {
            return false
        }
        let expires = trust.fullMacExpiresAt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trust.fullMacNeverExpires || expires.lowercased() == "never" {
            return true
        }
        if !expires.isEmpty {
            guard let exp = parseISO8601(expires) else { return false }
            return now <= exp
        }
        let confirmed = trust.fullMacConfirmedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        if confirmed.isEmpty { return false }
        guard let ts = parseISO8601(confirmed) else { return false }
        // max(0.01, min(hours or 4, 24.0)) — Python clamp order.
        let raw = trust.fullMacMaxDurationHours == 0 ? 4 : trust.fullMacMaxDurationHours
        let maxHours = max(0.01, min(raw, 24.0))
        return now.timeIntervalSince(ts) <= maxHours * 3600
    }

    /// Destructive/system-level Mac actions require the explicit operator
    /// escalation. Full Mac alone is broad access, not deletion/shell authority.
    public static func destructiveActionsAllowed(_ trust: MacControlTrustPolicy?) -> Bool {
        guard let trust else { return false }
        return trust.developerMode
    }

    // MARK: file policy

    /// Faithful port of `_file_policy_reason`.
    ///
    /// Returns the first reason found, or `nil` when all paths pass.
    /// Order, per path:
    ///   1. inside a workspace root → continue (allowed).
    ///   2. full-mac active → continue (allowed).
    ///   3. `outsideWorkspaceDefault == "ask"` →
    ///        "file_policy_requires_approval: <resolved> is outside configured workspaces"
    ///   4. else →
    ///        "file_policy_denied: <resolved> is outside configured workspaces"
    ///
    /// SHORT-CIRCUIT: when `trustPolicy` is nil (Python `if not trust: return ""`),
    /// every path is allowed — file policy enforcement is OFF without trust.
    public static func fileReason(
        _ policy: MacControlPolicy,
        forPaths paths: [String],
        now: Date = Date()
    ) -> String? {
        guard let trust = policy.trustPolicy else { return nil }
        let workspaceRoots: [String] = policy.workspaceRoots
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { resolvedPath($0) }
        for raw in paths {
            if raw.isEmpty { continue }
            let resolved = resolvedPath(raw)
            // inside any workspace root (root == resolved OR an ancestor)?
            if workspaceRoots.contains(where: { isSelfOrAncestor(root: $0, of: resolved) }) {
                continue
            }
            if fullMacActive(trust, now: now) { continue }
            let outside = trust.outsideWorkspaceDefault.isEmpty ? "deny" : trust.outsideWorkspaceDefault
            if outside == "ask" {
                return "file_policy_requires_approval: \(resolved) is outside configured workspaces"
            }
            return "file_policy_denied: \(resolved) is outside configured workspaces"
        }
        return nil
    }

    /// Convenience boolean form: true when the file ops are allowed
    /// (no reason). Mirrors the `if reason := self._file_policy_reason(...)`
    /// idiom where empty reason ⇒ proceed.
    public static func fileAllowed(
        _ policy: MacControlPolicy,
        forPaths paths: [String],
        now: Date = Date()
    ) -> Bool {
        fileReason(policy, forPaths: paths, now: now) == nil
    }

    // MARK: bridge-required

    /// Faithful port of the bridge-required computation in `_run`
    ///:
    ///   bridge_required = require_app_bridge_for_tcc AND
    ///       (category ∈ bridge_required_categories
    ///        OR basename(argv0) ∈ {osascript, bash, zsh, sh})
    ///
    /// `argv0` is the first element of the command vector (the executable);
    /// pass `nil`/empty when there is no command (pure category check).
    public static func bridgeRequired(
        _ policy: MacControlPolicy,
        category: String?,
        argv0: String? = nil
    ) -> Bool {
        guard policy.requireAppBridgeForTCC else { return false }
        let cat = category ?? ""
        if bridgeRequiredCategories.contains(cat) { return true }
        if let a = argv0, !a.isEmpty {
            let base = (a as NSString).lastPathComponent
            if bridgeRequiredArgv0.contains(base) { return true }
        }
        return false
    }

    /// Mirror of the refusal in `_run` when bridge is required and the
    /// local fallback is not allowed. The exact
    /// stderr string a blocked caller sees. NOTE: in Python this rides on a
    /// 125 exit code, not a block_reason; reproduced here so a future
    /// Swift execution path can surface the identical message.
    public static let bridgeRequiredUnavailableReason =
        "mac_control_bridge_required: NativeAgent.app bridge is unavailable"

    // MARK: - helpers

    /// Mirror of Python `Path(os.path.expanduser(raw)).resolve(strict=False)`
    /// for the comparison purpose used by `_file_policy_reason`. We expand
    /// `~`, then standardize (collapse `..`/`.`), then resolve symlinks
    /// where they exist. Non-existent paths still standardize cleanly
    /// (strict=False parity).
    ///
    /// **macOS prefix parity (2026-06-01 W4-fix).** Python's `Path.resolve`
    /// on macOS rewrites the legacy top-level synonyms `/etc`, `/tmp`, and
    /// `/var` to `/private/etc`, `/private/tmp`, `/private/var` (those are
    /// the canonical locations on Apple's `firmlink`-mediated root). Swift's
    /// `URL.resolvingSymlinksInPath()` does NOT rewrite them for paths whose
    /// leaf does not exist (the firmlink is resolved by the kernel, not the
    /// Foundation API on a non-existent file). The gpt-5.5 review caught
    /// this: refusal strings like `file_policy_denied: /etc/hosts ...` were
    /// diverging from Python's `/private/etc/hosts ...`. We apply the
    /// well-known three-prefix rewrite explicitly to recover parity for
    /// the refusal-string surface AND for workspace-root containment checks.
    static func resolvedPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        return _applyPrivateFirmlinkRewrite(resolved)
    }

    /// Rewrite `/etc`, `/tmp`, `/var` (top-level only) to their `/private`
    /// canonical forms, matching Python's `Path.resolve` macOS behavior.
    /// A bare `/etc` rewrites to `/private/etc`; `/etc/hosts` to
    /// `/private/etc/hosts`. A path like `/etcetera` is NOT rewritten
    /// (segment-aligned check).
    static func _applyPrivateFirmlinkRewrite(_ path: String) -> String {
        for prefix in ["/etc", "/tmp", "/var"] {
            if path == prefix { return "/private" + prefix }
            if path.hasPrefix(prefix + "/") { return "/private" + path }
        }
        return path
    }

    /// True when `root` is `candidate` itself or an ancestor directory of it.
    /// Mirrors `any(root in [resolved, *resolved.parents] ...)`.
    static func isSelfOrAncestor(root: String, of candidate: String) -> Bool {
        if root == candidate { return true }
        // ancestor: candidate path begins with root + "/".
        let rootSlash = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(rootSlash)
    }

    /// Parse an ISO-8601 timestamp the way Python's
    /// `datetime.fromisoformat(s.replace("Z", "+00:00"))` does, treating a
    /// naive (offset-less) timestamp as UTC. Returns nil on parse failure
    /// (Python's `except: return False`).
    ///
    /// **Strict-component validation (2026-06-01 W4-fix).** Foundation's
    /// `ISO8601DateFormatter` rolls invalid date components forward
    /// (`2026-02-30` → `2026-03-02`). Python's `datetime.fromisoformat`
    /// raises ValueError on the same input. The gpt-5.5 review flagged
    /// this as security-relevant: a malformed future `fullMacExpiresAt`
    /// or `fullMacConfirmedAt` could become an "active" trust window in
    /// Swift while Python would treat it as inactive. We now round-trip-
    /// validate every parsed timestamp: extract the YYYY-MM-DD prefix
    /// from the input, format the parsed Date back to YYYY-MM-DD in UTC,
    /// and reject when they diverge. Invalid month/day combinations now
    /// return nil exactly like Python.
    ///
    /// PUBLIC (review blocker fix, 2026-06-10): consumers that must agree
    /// with the gate about what a trust timestamp MEANS (the Full Mac
    /// duration picker's expiry derivation, FullMacExpiry's mirror) reuse
    /// THIS parser read-only instead of maintaining byte-for-byte copies —
    /// `AppModel.tolerantISO8601Date` rejects naive/date-only timestamps
    /// the gate accepts, which made a gate-valid `fullMacConfirmedAt`
    /// silently drop the 48h explicit expiry. No gate behavior change.
    public static func parseISO8601(_ raw: String) -> Date? {
        let normalized = raw.replacingOccurrences(of: "Z", with: "+00:00")
        let withTZ = ISO8601DateFormatter()
        withTZ.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withTZNoFrac = ISO8601DateFormatter()
        withTZNoFrac.formatOptions = [.withInternetDateTime]

        var parsed: Date? = nil
        if let d = withTZ.date(from: normalized) {
            parsed = d
        } else if let d = withTZNoFrac.date(from: normalized) {
            parsed = d
        } else if !hasTimezone(normalized) {
            // Naive timestamp (no offset) — Python replaces tzinfo with UTC.
            let utc = normalized + "+00:00"
            if let d = withTZ.date(from: utc) {
                parsed = d
            } else if let d = withTZNoFrac.date(from: utc) {
                parsed = d
            } else {
                // Date-only ("2026-06-01") — parse as midnight UTC.
                let dateOnly = DateFormatter()
                dateOnly.calendar = Calendar(identifier: .iso8601)
                dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
                dateOnly.dateFormat = "yyyy-MM-dd"
                dateOnly.isLenient = false  // reject 2026-02-30 etc.
                parsed = dateOnly.date(from: normalized)
            }
        }
        guard let date = parsed else { return nil }
        return _validateDateComponents(date, against: raw) ? date : nil
    }

    /// Raw-component validation: parse the YYYY-MM-DD prefix of the input
    /// AS LITERAL DATE COMPONENTS and confirm Calendar.date(from:) accepts
    /// the same year/month/day under strict (non-lenient) settings.
    ///
    /// **Why component-direct, not UTC-round-trip (2026-06-01 round-2 W4-fix).**
    /// An earlier version round-tripped the parsed `Date` back to UTC
    /// YYYY-MM-DD and compared. That FALSELY REJECTED valid offset-bearing
    /// timestamps that cross the UTC date line: e.g. `2026-06-01T01:00:00+05:00`
    /// is valid Python (`datetime.fromisoformat`), and its date attribute
    /// IS `2026-06-01` in the local frame, but UTC-formats as `2026-05-31`.
    /// We now validate the raw string's year-month-day fields against
    /// Calendar directly, independent of the parsed `Date` instant.
    static func _validateDateComponents(_ parsed: Date, against raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return true }
        let prefix = String(trimmed.prefix(10))
        let shape = #"^\d{4}-\d{2}-\d{2}$"#
        guard prefix.range(of: shape, options: .regularExpression) != nil else {
            return true
        }
        let parts = prefix.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return false
        }
        // Cheap pre-check that catches the obvious out-of-range cases that
        // Calendar.date(from:) would reject under any settings.
        if month < 1 || month > 12 { return false }
        if day < 1 || day > 31 { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        // DateComponents.isValidDate(in:) returns true ONLY if the
        // year+month+day triple identifies a real date in the calendar
        // (2026-02-30 → false; 2024-02-29 → true; 2026-02-29 → false).
        // This is the strict check Python's datetime.fromisoformat does.
        return components.isValidDate(in: calendar)
    }

    private static func hasTimezone(_ s: String) -> Bool {
        if s.hasSuffix("Z") || s.contains("+") { return true }
        // A trailing "-HH:MM" offset (avoid matching the date separators).
        // Look for a '-' in the time portion (after a 'T').
        if let tIdx = s.firstIndex(of: "T") {
            let timePart = s[s.index(after: tIdx)...]
            if timePart.contains("-") { return true }
        }
        return false
    }
}
