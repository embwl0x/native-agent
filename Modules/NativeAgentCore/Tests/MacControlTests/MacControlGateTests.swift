import Foundation
import Testing
@testable import MacControl

// MARK: - Subsystem #19 wave 29 W4 — _gate pipeline port tests.
//
// Pins the Swift port of the retired daemon's gate pipeline to the SAME
// decisions and the SAME user-facing refusal-reason strings as Python. Each
// gate condition has at least one passing test AND one rejecting test that
// asserts both the bool and the refusal-reason string.

// Helper: a fully-permissive policy (master ON, all categories ON, bridge
// off so it doesn't interfere with category tests).
private func permissivePolicy() -> MacControlPolicy {
    MacControlPolicy(
        enabled: true,
        remoteFromIOSAllowed: true,
        requireAppBridgeForTCC: false,
        categoryAllowed: [
            "applescript_allowed": true,
            "jxa_allowed": true,
            "shortcuts_allowed": true,
            "accessibility_allowed": true,
            "system_control_allowed": true,
            "file_ops_allowed": true,
            "shell_allowed": true,
            "notifications_allowed": true,
            "spotlight_allowed": true,
        ],
        trustPolicy: nil,
        workspaceRoots: []
    )
}

// MARK: - category → policy key map

@Suite("MacControlGate category key map")
struct CategoryKeyMapTests {
    @Test func mappedCategoriesMatchPython() {
        #expect(categoryPolicyKey("applescript") == "applescript_allowed")
        #expect(categoryPolicyKey("jxa") == "jxa_allowed")
        #expect(categoryPolicyKey("shortcuts") == "shortcuts_allowed")
        #expect(categoryPolicyKey("accessibility") == "accessibility_allowed")
        #expect(categoryPolicyKey("system") == "system_control_allowed")
        #expect(categoryPolicyKey("file_ops") == "file_ops_allowed")
        #expect(categoryPolicyKey("shell") == "shell_allowed")
        #expect(categoryPolicyKey("notifications") == "notifications_allowed")
        #expect(categoryPolicyKey("spotlight") == "spotlight_allowed")
    }

    @Test func unmappedCategoryFallsBackToSuffix() {
        // Mirrors `_CATEGORY_KEY.get(category, f"{category}_allowed")`.
        #expect(categoryPolicyKey("mystery") == "mystery_allowed")
    }
}

// MARK: - masterEnabled gate

@Suite("MacControlGate master gate")
struct MasterGateTests {
    @Test func passesWhenEnabled() {
        let policy = permissivePolicy()
        #expect(MacControlGate.masterEnabled(policy) == true)
        let d = MacControlGate.gate(policy, category: "shell", trigger: "user")
        #expect(d.allowed == true)
        #expect(d.reason == "")
    }

    @Test func rejectsWhenDisabledWithExactReason() {
        var policy = permissivePolicy()
        policy.enabled = false
        #expect(MacControlGate.masterEnabled(policy) == false)
        let d = MacControlGate.gate(policy, category: "shell", trigger: "user")
        #expect(d.allowed == false)
        #expect(d.reason == "mac_control_disabled: master gate off")
    }

    @Test func masterGateCheckedBeforeRemoteAndCategory() {
        // Even with ios trigger + category off, master-off wins (order parity).
        var policy = MacControlPolicy.default // master off, remote off
        policy.categoryAllowed["shell_allowed"] = false
        let d = MacControlGate.gate(policy, category: "shell", trigger: "ios")
        #expect(d.reason == "mac_control_disabled: master gate off")
    }
}

// MARK: - remoteIOSAllowed gate

@Suite("MacControlGate remote-ios gate")
struct RemoteIOSGateTests {
    @Test func userTriggerNotGatedOnRemote() {
        var policy = permissivePolicy()
        policy.remoteFromIOSAllowed = false
        #expect(MacControlGate.remoteIOSAllowed(policy, trigger: "user") == true)
        let d = MacControlGate.gate(policy, category: "shell", trigger: "user")
        #expect(d.allowed == true)
    }

    @Test func iosTriggerPassesWhenRemoteAllowed() {
        let policy = permissivePolicy() // remoteFromIOSAllowed = true
        #expect(MacControlGate.remoteIOSAllowed(policy, trigger: "ios") == true)
        let d = MacControlGate.gate(policy, category: "shell", trigger: "ios")
        #expect(d.allowed == true)
        #expect(d.reason == "")
    }

    @Test func iosTriggerRejectsWhenRemoteOffWithExactReason() {
        var policy = permissivePolicy()
        policy.remoteFromIOSAllowed = false
        #expect(MacControlGate.remoteIOSAllowed(policy, trigger: "ios") == false)
        let d = MacControlGate.gate(policy, category: "shell", trigger: "ios")
        #expect(d.allowed == false)
        #expect(d.reason == "remote_ios_disabled: remote_from_ios_allowed is off")
    }

    @Test func remoteCheckedBeforeCategory() {
        // ios + remote off + category off → remote reason wins (order parity).
        var policy = permissivePolicy()
        policy.remoteFromIOSAllowed = false
        policy.categoryAllowed["shell_allowed"] = false
        let d = MacControlGate.gate(policy, category: "shell", trigger: "ios")
        #expect(d.reason == "remote_ios_disabled: remote_from_ios_allowed is off")
    }
}

// MARK: - perCategoryEnabled gate

@Suite("MacControlGate per-category gate")
struct PerCategoryGateTests {
    @Test func passesWhenCategoryAllowed() {
        let policy = permissivePolicy()
        #expect(MacControlGate.perCategoryEnabled(policy, category: "file_ops") == true)
        let d = MacControlGate.gate(policy, category: "file_ops", trigger: "user")
        #expect(d.allowed == true)
        #expect(d.reason == "")
    }

    @Test func rejectsWhenCategoryOffWithExactKeyInReason() {
        var policy = permissivePolicy()
        policy.categoryAllowed["shell_allowed"] = false
        #expect(MacControlGate.perCategoryEnabled(policy, category: "shell") == false)
        let d = MacControlGate.gate(policy, category: "shell", trigger: "user")
        #expect(d.allowed == false)
        // The reason names the POLICY KEY, not the category.
        #expect(d.reason == "category_disabled: shell_allowed is off")
    }

    @Test func missingCategoryKeyReadsAsOff() {
        // policy.get(key, False) — a key absent from the map is False.
        var policy = permissivePolicy()
        policy.categoryAllowed.removeValue(forKey: "system_control_allowed")
        #expect(MacControlGate.perCategoryEnabled(policy, category: "system") == false)
        let d = MacControlGate.gate(policy, category: "system", trigger: "user")
        #expect(d.reason == "category_disabled: system_control_allowed is off")
    }

    @Test func unmappedCategoryUsesSuffixKeyInReason() {
        let policy = permissivePolicy() // no "mystery_allowed" key → off
        let d = MacControlGate.gate(policy, category: "mystery", trigger: "user")
        #expect(d.allowed == false)
        #expect(d.reason == "category_disabled: mystery_allowed is off")
    }

    @Test func defaultPolicyShortcutsAndNotificationsAndSpotlightOn() {
        // DEFAULT_MAC_CONTROL_POLICY has these three ON, the rest OFF.
        let p = MacControlPolicy.default
        #expect(MacControlGate.perCategoryEnabled(p, category: "shortcuts") == true)
        #expect(MacControlGate.perCategoryEnabled(p, category: "notifications") == true)
        #expect(MacControlGate.perCategoryEnabled(p, category: "spotlight") == true)
        #expect(MacControlGate.perCategoryEnabled(p, category: "shell") == false)
        #expect(MacControlGate.perCategoryEnabled(p, category: "file_ops") == false)
    }
}

// MARK: - fullMacActive

@Suite("MacControlGate fullMacActive")
struct FullMacActiveTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000) // fixed clock

    @Test func inactiveWhenPermissionInsufficient() {
        // outside != "allow" AND permission not in {wide_open_receipts, full_mac_os}.
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "deny",
            permissionLevel: "balanced",
            fullMacNeverExpires: true // would otherwise be active
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }

    @Test func activeViaNeverExpiresWhenOutsideAllow() {
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            permissionLevel: "balanced",
            fullMacNeverExpires: true
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == true)
    }

    @Test func activeViaNeverStringWhenPermissionWideOpen() {
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "deny",
            permissionLevel: "wide_open_receipts",
            fullMacExpiresAt: "never"
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == true)
    }

    @Test func activeWhenExpiryInFuture() {
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacExpiresAt: future
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == true)
    }

    @Test func inactiveWhenExpiryInPast() {
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacExpiresAt: past
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }

    @Test func inactiveWhenExpiryUnparseable() {
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacExpiresAt: "not-a-timestamp"
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }

    @Test func activeWithinConfirmedWindow() {
        // confirmed 1h ago, 4h window → active.
        let confirmed = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacConfirmedAt: confirmed,
            fullMacMaxDurationHours: 4
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == true)
    }

    @Test func inactivePastConfirmedWindow() {
        // confirmed 5h ago, 4h window → expired.
        let confirmed = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5 * 3600))
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacConfirmedAt: confirmed,
            fullMacMaxDurationHours: 4
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }

    @Test func inactiveWhenNoConfirmedAndNoExpiry() {
        let trust = MacControlTrustPolicy(outsideWorkspaceDefault: "allow")
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }

    @Test func developerModeDoesNotBypassFullMacExpiry() {
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacExpiresAt: "not-a-timestamp",
            developerMode: true
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }

    @Test func durationClampedToTwentyFourHours() {
        // confirmed 25h ago, requested 100h window → clamped to 24h → expired.
        let confirmed = ISO8601DateFormatter().string(from: now.addingTimeInterval(-25 * 3600))
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacConfirmedAt: confirmed,
            fullMacMaxDurationHours: 100
        )
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }
}

@Suite("MacControlGate destructive actions")
struct DestructiveActionTests {
    @Test func blockedWithoutDeveloperModeOrDestructiveFlag() {
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            permissionLevel: "full_mac_os",
            fullMacNeverExpires: true,
            developerMode: false,
            allowDestructiveActions: false
        )
        #expect(MacControlGate.destructiveActionsAllowed(trust) == false)
    }

    @Test func allowedWithDeveloperMode() {
        let trust = MacControlTrustPolicy(developerMode: true)
        #expect(MacControlGate.destructiveActionsAllowed(trust) == true)
    }

    @Test func destructiveFlagAloneDoesNotBypassDeveloperMode() {
        let trust = MacControlTrustPolicy(allowDestructiveActions: true)
        #expect(MacControlGate.destructiveActionsAllowed(trust) == false)
    }
}

// MARK: - fileReason / fileAllowed (file policy)

@Suite("MacControlGate file policy")
struct FilePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func allowedWhenNoTrustPolicy() {
        // Python: `if not trust: return ""` — file policy OFF without trust.
        var policy = permissivePolicy()
        policy.trustPolicy = nil
        #expect(MacControlGate.fileReason(policy, forPaths: ["/tmp/anything"], now: now) == nil)
        #expect(MacControlGate.fileAllowed(policy, forPaths: ["/tmp/anything"], now: now) == true)
    }

    @Test func allowedInsideWorkspaceRoot() {
        var policy = permissivePolicy()
        policy.workspaceRoots = ["/Users/test/ws"]
        policy.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
        #expect(MacControlGate.fileReason(policy, forPaths: ["/Users/test/ws/file.txt"], now: now) == nil)
        #expect(MacControlGate.fileAllowed(policy, forPaths: ["/Users/test/ws/file.txt"], now: now) == true)
    }

    @Test func workspaceRootSelfIsAllowed() {
        var policy = permissivePolicy()
        policy.workspaceRoots = ["/Users/test/ws"]
        policy.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
        #expect(MacControlGate.fileReason(policy, forPaths: ["/Users/test/ws"], now: now) == nil)
    }

    @Test func deniedOutsideWorkspaceWithExactReason() {
        var policy = permissivePolicy()
        policy.workspaceRoots = ["/Users/test/ws"]
        policy.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
        // W4-fix 2026-06-01: Python `Path.resolve` rewrites /etc -> /private/etc
        // on macOS via firmlinks. Swift parity requires the same prefix in the
        // refusal string and workspace-membership comparisons.
        let reason = MacControlGate.fileReason(policy, forPaths: ["/etc/hosts"], now: now)
        #expect(reason == "file_policy_denied: /private/etc/hosts is outside configured workspaces")
        #expect(MacControlGate.fileAllowed(policy, forPaths: ["/etc/hosts"], now: now) == false)
    }

    @Test func requiresApprovalWhenOutsideAsk() {
        var policy = permissivePolicy()
        policy.workspaceRoots = ["/Users/test/ws"]
        policy.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "ask")
        let reason = MacControlGate.fileReason(policy, forPaths: ["/etc/hosts"], now: now)
        #expect(reason == "file_policy_requires_approval: /private/etc/hosts is outside configured workspaces")
        #expect(MacControlGate.fileAllowed(policy, forPaths: ["/etc/hosts"], now: now) == false)
    }

    @Test func fullMacActiveBypassesFilePolicy() {
        // outside == "deny" but full-mac active → path allowed even outside ws.
        var policy = permissivePolicy()
        policy.workspaceRoots = ["/Users/test/ws"]
        policy.trustPolicy = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow", // makes full-mac eligible
            fullMacNeverExpires: true
        )
        #expect(MacControlGate.fileReason(policy, forPaths: ["/etc/hosts"], now: now) == nil)
        #expect(MacControlGate.fileAllowed(policy, forPaths: ["/etc/hosts"], now: now) == true)
    }

    @Test func firstOffendingPathWins() {
        // Multiple paths: first one inside ws, second outside → second's reason.
        var policy = permissivePolicy()
        policy.workspaceRoots = ["/Users/test/ws"]
        policy.trustPolicy = MacControlTrustPolicy(outsideWorkspaceDefault: "deny")
        let reason = MacControlGate.fileReason(
            policy,
            forPaths: ["/Users/test/ws/ok.txt", "/var/secret"],
            now: now
        )
        // W4-fix 2026-06-01: /var rewrites to /private/var (firmlink parity).
        #expect(reason == "file_policy_denied: /private/var/secret is outside configured workspaces")
    }

    @Test func privateFirmlinkRewriteAppliesToEtcTmpVar() {
        // Top-level prefix rewrite is segment-aligned: /etc, /tmp, /var.
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/etc") == "/private/etc")
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/etc/hosts") == "/private/etc/hosts")
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/tmp") == "/private/tmp")
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/tmp/foo") == "/private/tmp/foo")
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/var/secret") == "/private/var/secret")
        // /etcetera is NOT a firmlink prefix; segment-aligned check protects it.
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/etcetera") == "/etcetera")
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/Users/example") == "/Users/example")
        #expect(MacControlGate._applyPrivateFirmlinkRewrite("/private/etc/hosts") == "/private/etc/hosts")
    }
}

// MARK: - parseISO8601 strict date validation (W4-fix 2026-06-01)

@Suite("MacControlGate parseISO8601 strict validation")
struct ParseISO8601Tests {
    @Test func acceptsValidUTC() {
        // 2026-06-01T00:00:00Z is valid; parses + round-trip-validates.
        #expect(MacControlGate.parseISO8601("2026-06-01T00:00:00Z") != nil)
    }

    @Test func acceptsValidWithOffset() {
        #expect(MacControlGate.parseISO8601("2026-06-01T12:34:56+05:30") != nil)
    }

    @Test func acceptsOffsetCrossingUTCDateLine() {
        // Round-2 W4-fix 2026-06-01: an earlier UTC-round-trip validator
        // FALSELY rejected `2026-06-01T01:00:00+05:00` because the parsed
        // Date in UTC formats as 2026-05-31. Python `datetime.fromisoformat`
        // accepts it (its `.date()` attribute is `2026-06-01` in local frame).
        // The component-direct validator now accepts.
        #expect(MacControlGate.parseISO8601("2026-06-01T01:00:00+05:00") != nil)
        #expect(MacControlGate.parseISO8601("2026-12-31T22:00:00-05:00") != nil)
        #expect(MacControlGate.parseISO8601("2026-01-01T00:30:00+12:00") != nil)
    }

    @Test func acceptsValidNaiveAsUTC() {
        // No offset → Swift treats as UTC, matching Python's manual tzinfo replace.
        #expect(MacControlGate.parseISO8601("2026-06-01T00:00:00") != nil)
    }

    @Test func acceptsDateOnly() {
        #expect(MacControlGate.parseISO8601("2026-06-01") != nil)
    }

    @Test func rejectsInvalidDayInMonth() {
        // 2026 is NOT a leap year; Feb 30 does not exist. Python rejects; Swift's
        // pre-fix lenient parser rolled forward to 2026-03-02.
        #expect(MacControlGate.parseISO8601("2026-02-30T00:00:00Z") == nil)
        #expect(MacControlGate.parseISO8601("2026-02-30") == nil)
    }

    @Test func rejectsInvalidMonth() {
        #expect(MacControlGate.parseISO8601("2026-13-01T00:00:00Z") == nil)
        // Pre-fix Foundation rolls 13 forward to next year's January.
    }

    @Test func rejectsUnparseable() {
        #expect(MacControlGate.parseISO8601("not-a-timestamp") == nil)
        #expect(MacControlGate.parseISO8601("") == nil)
    }

    @Test func rejectsFeb29InNonLeapYear() {
        // 2026 is not a leap year. 2024 IS a leap year (sanity check).
        #expect(MacControlGate.parseISO8601("2026-02-29T00:00:00Z") == nil)
        #expect(MacControlGate.parseISO8601("2024-02-29T00:00:00Z") != nil)
    }

    @Test func invalidExpiryDoesNotMakeFullMacActive() {
        // The security-relevant case: a malformed future expiry must NOT make
        // full-mac active. Pre-fix Foundation would have rolled 2099-02-30 to
        // 2099-03-02 (a future date) and the gate would report active.
        let trust = MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            fullMacExpiresAt: "2099-02-30T00:00:00Z"
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(MacControlGate.fullMacActive(trust, now: now) == false)
    }
}

// MARK: - bridgeRequired

@Suite("MacControlGate bridge-required")
struct BridgeRequiredTests {
    @Test func requiredForTCCSensitiveCategory() {
        let policy = MacControlPolicy(requireAppBridgeForTCC: true)
        #expect(MacControlGate.bridgeRequired(policy, category: "shell") == true)
        #expect(MacControlGate.bridgeRequired(policy, category: "applescript") == true)
        #expect(MacControlGate.bridgeRequired(policy, category: "file_ops") == true)
        #expect(MacControlGate.bridgeRequired(policy, category: "system") == true)
    }

    @Test func notRequiredForSafeCategory() {
        let policy = MacControlPolicy(requireAppBridgeForTCC: true)
        // notifications/spotlight/shortcuts are NOT in bridge_required_categories.
        #expect(MacControlGate.bridgeRequired(policy, category: "notifications") == false)
        #expect(MacControlGate.bridgeRequired(policy, category: "spotlight") == false)
        #expect(MacControlGate.bridgeRequired(policy, category: "shortcuts") == false)
    }

    @Test func requiredViaArgv0Basename() {
        let policy = MacControlPolicy(requireAppBridgeForTCC: true)
        // Even a safe category triggers bridge-required if argv0 is a shell/osascript.
        #expect(MacControlGate.bridgeRequired(policy, category: "shortcuts", argv0: "/usr/bin/osascript") == true)
        #expect(MacControlGate.bridgeRequired(policy, category: "notifications", argv0: "/bin/bash") == true)
        #expect(MacControlGate.bridgeRequired(policy, category: nil, argv0: "/bin/zsh") == true)
        #expect(MacControlGate.bridgeRequired(policy, category: nil, argv0: "sh") == true)
    }

    @Test func notRequiredForBenignArgv0() {
        let policy = MacControlPolicy(requireAppBridgeForTCC: true)
        #expect(MacControlGate.bridgeRequired(policy, category: "spotlight", argv0: "/usr/bin/mdfind") == false)
    }

    @Test func neverRequiredWhenPolicyDisablesBridge() {
        // require_app_bridge_for_tcc = false short-circuits to false.
        let policy = MacControlPolicy(requireAppBridgeForTCC: false)
        #expect(MacControlGate.bridgeRequired(policy, category: "shell") == false)
        #expect(MacControlGate.bridgeRequired(policy, category: "shell", argv0: "/bin/bash") == false)
    }

    @Test func unavailableReasonStringMatchesPython() {
        #expect(
            MacControlGate.bridgeRequiredUnavailableReason
            == "mac_control_bridge_required: NativeAgent.app bridge is unavailable"
        )
    }
}
