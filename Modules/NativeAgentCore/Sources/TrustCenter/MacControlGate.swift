import Foundation
import PersistenceCore

// Blueprint: | `MacControlGate.swift` | `MacControlGate`: effective Mac policy admission, private-path rules and admitted Full Mac handling through checked Trust |

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
    /// Per-category allow flags keyed by POLICY KEY (e.g. `shell_allowed`).
    /// A missing key reads as `false` — matching `policy.get(key, False)`.
    public var categoryAllowed: [String: Bool]
    /// `_trustPolicy` (filePolicy + saved Full Mac posture). `nil` ⇔ Python's
    /// empty / missing `_trustPolicy` (file policy then short-circuits to
    /// allow — see `fileReason`).
    public var trustPolicy: MacControlTrustPolicy?
    /// `_workspaceRoots` — paths inside these are always file-allowed.
    public var workspaceRoots: [String]
    /// Receipt/UI metadata, not the approval decision (PermissionLaw owns it).
    /// A missing list gives blocked receipts the legacy shell-only default.
    public var approvalRequiredFor: [String]?

    public init(
        enabled: Bool = false,
        remoteFromIOSAllowed: Bool = false,
        categoryAllowed: [String: Bool] = [:],
        trustPolicy: MacControlTrustPolicy? = nil,
        workspaceRoots: [String] = [],
        approvalRequiredFor: [String]? = nil
    ) {
        self.enabled = enabled
        self.remoteFromIOSAllowed = remoteFromIOSAllowed
        self.categoryAllowed = categoryAllowed
        self.trustPolicy = trustPolicy
        self.workspaceRoots = workspaceRoots
        self.approvalRequiredFor = approvalRequiredFor
    }

    /// The gate projection of TrustCenter's canonical Mac schema.
    public static let `default`: MacControlPolicy = {
        let mac = SwiftNativeTrustCenter.defaultMacControlPolicy
        return MacControlPolicy(enabled: mac["enabled"] == .bool(true),
            remoteFromIOSAllowed: mac["remote_from_ios_allowed"] == .bool(true),
            categoryAllowed: mac.filter { $0.key.hasSuffix("_allowed") && $0.key != "remote_from_ios_allowed" }
                .mapValues { $0 == .bool(true) },
            approvalRequiredFor: SwiftNativeSecurityCenter.stringArray(mac["approval_required_for"]))
    }()
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
    /// Top-level developer-mode projection; PermissionLaw still owns approval.
    public var developerMode: Bool
    /// Normalized from developerMode; does not waive destructive approval.
    public var allowDestructiveActions: Bool

    public init(
        outsideWorkspaceDefault: String = "deny",
        permissionLevel: String = "balanced",
        developerMode: Bool = false,
        allowDestructiveActions: Bool = false
    ) {
        self.outsideWorkspaceDefault = outsideWorkspaceDefault
        self.permissionLevel = permissionLevel
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
    public let remedy: JSONValue?
    public init(allowed: Bool, reason: String, remedy: JSONValue? = nil) {
        self.allowed = allowed
        self.reason = reason
        self.remedy = remedy
    }
    public static let allow = MacControlGateDecision(allowed: true, reason: "")
}

/// Canonical Mac-control admission and the policy gate pipeline.
public enum MacControlGate {

    public static func continuationCaptureRefusal(dataRoot: URL) async -> String? {
        do {
            let snapshot = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            let authority = SwiftNativeSecurityCenter.fullMacYoloAuthority(tool: "mac_control",
                surface: "chat", originTrusted: true, snapshot: snapshot)
            let policy = policyForAdmittedFullMac(
                MacControlPolicy.fromTrustPolicyObject(snapshot.policy, dataRoot: dataRoot), admitted: authority.state == .admitted)
            guard fullMacActive(policy.trustPolicy ?? MacControlTrustPolicy()),
                  gate(policy, category: "accessibility", trigger: "user").allowed else {
                return "accessibility_read_not_authorized"
            }
            return nil
        } catch {
            return "trust_policy_unavailable"
        }
    }

    /// Project current Full Mac authority into the legacy category policy for
    /// this admitted call only. The caller must obtain `admitted` from the
    /// canonical origin-aware authority check; a saved Full Mac bit is not
    /// origin proof. Never persist this projection over lower-mode settings.
    public static func policyForAdmittedFullMac(
        _ policy: MacControlPolicy, admitted: Bool
    ) -> MacControlPolicy {
        guard admitted, let trust = policy.trustPolicy, fullMacActive(trust) else { return policy }
        var effective = policy
        effective.enabled = true
        effective.remoteFromIOSAllowed = true
        for key in MacControlPolicy.default.categoryAllowed.keys {
            effective.categoryAllowed[key] = true
        }
        effective.trustPolicy?.developerMode = true
        effective.trustPolicy?.allowDestructiveActions = true
        return effective
    }

    // MARK: master / remote / per-category

    /// Master, remote and category gates retain their order and name the
    /// saved field and the person's matching control.
    public static func gate(
        _ policy: MacControlPolicy,
        category: String,
        trigger: String = "user"
    ) -> MacControlGateDecision {
        if !policy.enabled {
            return refusal("enabled", control: "Mac control > Mac control", category: category)
        }
        if trigger == "ios" && !policy.remoteFromIOSAllowed {
            return refusal("remote_from_ios_allowed", control: "iPhone remote control > Allow iPhone remote control", category: category)
        }
        let key = categoryPolicyKey(category)
        if !(policy.categoryAllowed[key] ?? false) {
            let label = ["shell": "Shell commands > Shell commands", "file_ops": "Kinds of control > File operations",
                "accessibility": "Kinds of control > Accessibility", "applescript": "Kinds of control > AppleScript",
                "jxa": "Kinds of control > JavaScript for Automation (JXA)", "notifications": "Kinds of control > Notifications",
                "spotlight": "Kinds of control > Spotlight search"][category]
            return refusal(key, control: label, category: category)
        }
        return .allow
    }

    private static func refusal(_ key: String, control: String?, category: String) -> MacControlGateDecision {
        let owner = "trust/policy.json macControlPolicy.\(key)"
        if let control {
            let tap = "Trust > Mac > Advanced Mac control > \(control); then Mac control > Save"
            return MacControlGateDecision(allowed: false,
                reason: "mac_control_policy_disabled: \(owner)=false blocks this action. Only the owner can enable it at \(tap).",
                remedy: Repair.why(owner: owner, tap: tap, instruction: "Only the owner can enable this Mac control switch."))
        }
        return MacControlGateDecision(allowed: false,
            reason: "mac_control_category_denied: \(owner)=false blocks category '\(category)'. This category has no matching switch.",
            remedy: .object(["kind": .string("correct_arguments"), "owner": .string(owner),
                "instruction": .string("Inspect supported Mac actions with next_call and choose one with an available control."),
                "next_call": .object(["tool": .string("app"), "input": .object(["find": .string("mac")])])]))
    }

    // MARK: full-mac trust state

    /// Full Mac is on when the SAVED policy is Full Mac. There is no timer
    /// (2026-09-10, User): the grant lasts until the person turns it off in
    /// Trust. Any `fullMacExpiresAt` / `fullMacConfirmedAt` /
    /// `fullMacNeverExpires` / `fullMacMaxDurationHours` left in an old
    /// install's `trust/policy.json` is ignored - nothing reads it, so a
    /// stored 4-hour window keeps Full Mac on.
    ///
    /// Active iff `outsideWorkspaceDefault == "allow"` OR
    /// `permissionLevel` is `wide_open_receipts` or `full_mac_os`.
    public static func fullMacActive(_ trust: MacControlTrustPolicy) -> Bool {
        let outside = trust.outsideWorkspaceDefault.isEmpty ? "deny" : trust.outsideWorkspaceDefault
        let permission = trust.permissionLevel.isEmpty ? "balanced" : trust.permissionLevel
        return outside == "allow"
            || permission == "wide_open_receipts"
            || permission == "full_mac_os"
    }

    // MARK: file policy

    /// SecurityCenter checks containment of the resolved absolute paths used
    /// by file operations. Outside paths meet Full Mac, then ask/deny.
    /// Nil trust leaves this gate inactive.
    public static func fileReason(
        _ policy: MacControlPolicy,
        forPaths paths: [String]
    ) -> String? {
        guard let trust = policy.trustPolicy else { return nil }
        let workspaceRoots = policy.workspaceRoots.map { URL(fileURLWithPath: resolvedPath($0)) }
        for raw in paths {
            if raw.isEmpty { continue }
            let resolved = resolvedPath(raw)
            if SwiftNativeSecurityCenter.pathIsInsideRoots(resolved, roots: workspaceRoots) {
                continue
            }
            if fullMacActive(trust) { continue }
            let outside = trust.outsideWorkspaceDefault.isEmpty ? "deny" : trust.outsideWorkspaceDefault
            if outside == "ask" {
                return "file_policy_requires_approval: \(resolved) is outside configured workspaces"
            }
            return "file_policy_denied: \(resolved) is outside configured workspaces"
        }
        return nil
    }

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
    public static func resolvedPath(_ raw: String) -> String {
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

    /// Parse an ISO-8601 timestamp the way Python's
    /// `datetime.fromisoformat(s.replace("Z", "+00:00"))` does, treating a
    /// naive (offset-less) timestamp as UTC. Returns nil on parse failure
    /// (Python's `except: return False`).
    ///
    /// **Strict-component validation (2026-06-01 W4-fix).** Foundation's
    /// `ISO8601DateFormatter` rolls invalid date components forward
    /// (`2026-02-30` → `2026-03-02`). Python's `datetime.fromisoformat`
    /// raises ValueError on the same input. The gpt-5.5 review flagged
    /// this as security-relevant when the Full Mac grant was still a timed
    /// window (removed 2026-09-10): a malformed future timestamp could
    /// become an "active" window in Swift while Python treated it as
    /// inactive. The strict validation stays. We round-trip-
    /// validate every parsed timestamp: extract the YYYY-MM-DD prefix
    /// from the input, format the parsed Date back to YYYY-MM-DD in UTC,
    /// and reject when they diverge. Invalid month/day combinations now
    /// return nil exactly like Python.
    ///
    /// PUBLIC so any consumer that must agree with the gate about what a
    /// timestamp MEANS reuses this parser read-only rather than keeping a
    /// byte-for-byte copy. The Full Mac callers are gone with the timer
    /// (2026-09-10); the parser and its strict-validation suite stay
    /// because the parity rules they encode are not Full-Mac-specific.
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

public extension MacControlPolicy {
    /// Build the gate policy from the normalized TrustCenter policy object.
    /// This keeps production MacControl fully Swift-native while preserving the
    /// same macControlPolicy/filePolicy fields the UI already edits.
    static func fromTrustPolicyObject(_ root: [String: JSONValue], dataRoot: URL = defaultDataRoot()) -> MacControlPolicy {
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
        let workspaceRoots = SwiftNativeSecurityCenter.normalizedUniqueRoots([dataRoot]
            + SwiftNativeSecurityCenter.trustedWorkspaceRoots(policy: root, filePolicy: filePolicy, dataRoot: dataRoot))
            .map(\.path)

        let trustPolicy = MacControlTrustPolicy(
            outsideWorkspaceDefault: string(filePolicy, "outsideWorkspaceDefault", default: "deny"),
            permissionLevel: string(root, "permissionLevel", default: "balanced"),
            developerMode: bool(root, "developerMode", default: false),
            allowDestructiveActions: bool(filePolicy, "allowDestructiveActions", default: false)
        )

        return MacControlPolicy(
            enabled: bool(mac, "enabled", default: defaults.enabled),
            remoteFromIOSAllowed: bool(mac, "remote_from_ios_allowed", default: defaults.remoteFromIOSAllowed),
            categoryAllowed: categoryAllowed,
            trustPolicy: trustPolicy,
            workspaceRoots: workspaceRoots,
            approvalRequiredFor: approvalRequiredFor
        )
    }
}
