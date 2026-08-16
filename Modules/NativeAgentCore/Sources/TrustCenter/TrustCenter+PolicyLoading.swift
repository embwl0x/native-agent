import Foundation
import NativeAgentCore
import PersistenceCore

/// One checked authority generation for a SecurityCenter decision. The
/// normalized policy and raw user-only autonomy overrides are derived from the
/// same saved bytes so an effect-time gate cannot splice concurrent policies.
public struct TrustPolicyAuthorizationSnapshot: Sendable, Equatable {
    public let policy: [String: JSONValue]
    public let userConfiguredAutonomyOverrides: [String: JSONValue]

    init(
        policy: [String: JSONValue],
        userConfiguredAutonomyOverrides: [String: JSONValue]
    ) {
        self.policy = policy
        self.userConfiguredAutonomyOverrides = userConfiguredAutonomyOverrides
    }
}

extension SwiftNativeTrustCenter {
    /// Reads the authoritative saved policy without conflating a missing file
    /// with damaged authority state. Missing is the only bootstrap-empty case.
    public nonisolated static func loadRawPolicyChecked(at path: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw TrustCenterError.underlying("saved trust policy is unreadable")
        }
        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw TrustCenterError.underlying("saved trust policy is malformed")
        }
        guard case .object(let object) = decoded else {
            throw TrustCenterError.underlying("saved trust policy must be a JSON object")
        }
        try validateAuthorityPolicyShape(object)
        return object
    }

    /// A saved scalar must never replace one of the policy dictionaries that
    /// owns authority. Normalization merges saved values over safe defaults;
    /// without this check, a value such as `"securityPolicy": "damaged"`
    /// discards the entire default security block and can make corruption look
    /// like an intentionally permissive policy. Missing blocks remain valid so
    /// older policies can receive new defaults during normalization.
    public nonisolated static func validateAuthorityPolicyShape(
        _ policy: [String: JSONValue]
    ) throws {
        let objectPaths: [[String]] = [
            [WorkshopPolicyBlockVocabulary.wireKey],
            // Wave 4 read-both: a saved policy carrying the FUTURE spelling is
            // held to the same must-be-an-object rule, so a scalar under either
            // key fails the same way instead of only the wire one.
            [WorkshopPolicyBlockVocabulary.futureKey],
            ["toolAutonomy"],
            ["toolPolicy"],
            ["filePolicy"],
            ["connectorPolicy"],
            ["multimodalPolicy"],
            ["trainingPolicy"],
            ["promotionPolicy"],
            ["personalityPolicy"],
            ["memoryPolicy"],
            ["skillBuilderPolicy"],
            ["swarmPolicy"],
            ["inboxPolicy"],
            ["mcpPolicy"],
            ["macControlPolicy"],
            ["macControlPolicy", "riskGatePolicy"],
            ["securityPolicy"],
            ["providerPolicy"],
            ["providerPolicy", "active_per_surface"],
            ["providerPolicy", "fallback_chain"],
        ]

        for path in objectPaths {
            var current = policy
            for (index, component) in path.enumerated() {
                guard let value = current[component] else { break }
                guard case .object(let nested) = value else {
                    throw TrustCenterError.underlying(
                        "saved trust policy block \(path.joined(separator: ".")) must be a JSON object"
                    )
                }
                if index < path.count - 1 {
                    current = nested
                }
            }
        }
    }

    /// Validate every saved key that has a canonical default against that
    /// default's JSON type, recursively. Unknown keys remain untouched for
    /// forward-compatible and connector-specific extensions. The one explicit
    /// legacy coercion retained here is completion-guard repair count, whose
    /// normalizer intentionally accepts a non-int and replaces it with 2.
    public nonisolated static func validateKnownAuthorityPolicyTypes(
        _ policy: [String: JSONValue],
        against defaults: [String: JSONValue]
    ) throws {
        for (key, value) in policy {
            guard let expected = defaults[key] else { continue }
            try validateKnownAuthorityPolicyValue(
                value,
                against: expected,
                path: key
            )
        }
    }

    private nonisolated static func validateKnownAuthorityPolicyValue(
        _ value: JSONValue,
        against expected: JSONValue,
        path: String
    ) throws {
        if path == "personalityPolicy.completion_guard_max_repairs" {
            return
        }

        switch (value, expected) {
        case (.object(let actual), .object(let expectedObject)):
            for (key, child) in actual {
                guard let expectedChild = expectedObject[key] else { continue }
                try validateKnownAuthorityPolicyValue(
                    child,
                    against: expectedChild,
                    path: path + "." + key
                )
            }
        case (.array(let actual), .array(let expectedArray)):
            guard let expectedElement = expectedArray.first else { return }
            for child in actual {
                try validateKnownAuthorityPolicyValue(
                    child,
                    against: expectedElement,
                    path: path + "[]"
                )
            }
        case (.null, .null),
             (.bool, .bool),
             (.int, .int),
             (.double, .double),
             (.string, .string):
            return
        default:
            throw TrustCenterError.underlying(
                "saved trust policy field \(path) has the wrong JSON type"
            )
        }
    }

    public func loadTrustPolicyChecked() async throws -> [String: JSONValue] {
        let snapshot = try await loadAuthorizationSnapshotChecked()
        return snapshot.policy
    }

    /// SecurityCenter authorization read. Keep this as a value snapshot rather
    /// than a cache: every effect-time check still rereads canonical authority,
    /// but all fields used by that one check come from one validated generation.
    public func loadAuthorizationSnapshotChecked() async throws
        -> TrustPolicyAuthorizationSnapshot
    {
        // Fold the future spelling BEFORE type validation, not just before the
        // normalize merge — otherwise a `workshopPolicy` block skips the
        // nested type checks the legacy spelling gets (defaults only carry the
        // wire key), making future-key reads more permissive than old-key
        // reads (review 2026-08-06 blocking #3).
        let saved = WorkshopPolicyBlockVocabulary.foldToWireKey(
            try Self.loadRawPolicyChecked(at: trustPolicyURL))
        try Self.validateKnownAuthorityPolicyTypes(saved, against: defaultTrustPolicy())
        let overrides: [String: JSONValue]
        if case .object(let value)? = saved["toolAutonomy"] {
            overrides = value
        } else {
            overrides = [:]
        }
        return TrustPolicyAuthorizationSnapshot(
            policy: normalizedTrustPolicy(saved: saved),
            userConfiguredAutonomyOverrides: overrides
        )
    }

    public func loadTrustPolicy() async -> [String: JSONValue] {
        do {
            return try await loadTrustPolicyChecked()
        } catch {
            // Compatibility callers cannot surface an error, but authority
            // corruption must never look like a fresh install. Return a
            // deliberately closed projection: SecurityCenter blocks dispatch,
            // and autonomous/background lanes stay off until the exact saved
            // bytes are repaired through a checked owner.
            return failClosedTrustPolicy()
        }
    }

    /// 2026-07-21 audit fix support: the USER-FILE-ONLY toolAutonomy
    /// overrides (raw saved policy, no code defaults merged). The yolo /
    /// full-Mac broad posture must consult THIS — not the merged view — when
    /// deciding whether a deliberate user override exists to outrank it;
    /// merged defaults would make every catalogued tool look "explicitly
    /// configured" and silently disable the posture (the first version of
    /// the audit fix did exactly that and tripped the characterization net).
    /// Fail-soft: a missing/corrupt file reads as no user overrides (the
    /// merged loadTrustPolicy path fail-closes separately).
    public func userConfiguredAutonomyOverrides() async -> [String: JSONValue] {
        guard let saved = try? Self.loadRawPolicyChecked(at: trustPolicyURL),
              case .object(let ta)? = saved["toolAutonomy"] else {
            return [:]
        }
        return ta
    }

    /// Read one raw user-configured tier through the checked authority seam.
    /// Missing means no explicit override; corrupt authority throws rather than
    /// looking like a fresh/default policy.
    public func userConfiguredAutonomyLevel(for tool: String) async throws -> String? {
        let snapshot = try await loadAuthorizationSnapshotChecked()
        guard case .string(let tier)? = snapshot.userConfiguredAutonomyOverrides[tool] else {
            return nil
        }
        return tier
    }

    private var trustPolicyURL: URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    func normalizedTrustPolicy(saved savedDict: [String: JSONValue]) -> [String: JSONValue] {
        let defaults = defaultTrustPolicy()
        var merged = defaults
        // Wave 4 read-both (phase A): a saved policy written by a future build
        // may carry `workshopPolicy`. Fold it onto the WIRE key here, at the one
        // read seam, so the merge below and every gate downstream keep looking
        // at exactly one key — and so the normalized result still carries the
        // old spelling, which is what every writer emits and what a 0.3.7 iOS
        // install decodes. A policy with only the old key is untouched.
        let savedDict = WorkshopPolicyBlockVocabulary.foldToWireKey(savedDict)
        for (k, v) in savedDict {
            if case .object(let savedNested) = v,
               case .object(let defNested)? = merged[k] {
                var nested = defNested
                for (nk, nv) in savedNested { nested[nk] = nv }
                merged[k] = .object(nested)
            } else {
                merged[k] = v
            }
        }
        // Provider policy defaults + clock injection for Full-Mac timestamps.
        let defaultProviderPolicy: [String: JSONValue] = {
            if case .object(let p)? = defaults["providerPolicy"] { return p }
            return [:]
        }()
        let nowISO = Self.isoTimestamp(clock())
        var normalized = Self.normalizeTrustPolicy(
            merged,
            defaultProviderPolicy: defaultProviderPolicy,
            nowISO: nowISO
        )
        // Backfill Workshop executions.DEFAULT_TOOL_AUTONOMY into toolAutonomy. Saved
        // values always win; missing default keys are added so new bootstraps
        // pick up new defaults without resetting saved policies.
        var toolAutonomy: [String: JSONValue] = Self.workshopExecutionsDefaultToolAutonomy
        if case .object(let saved)? = normalized["toolAutonomy"] {
            for (k, v) in saved { toolAutonomy[k] = v }
        }
        Self.normalizeBrowserAutonomy(&toolAutonomy)
        normalized["toolAutonomy"] = .object(toolAutonomy)
        return normalized
    }

    private func failClosedTrustPolicy() -> [String: JSONValue] {
        var policy = normalizedTrustPolicy(saved: [:])
        policy["developerMode"] = .bool(false)
        policy["permissionLevel"] = .string("balanced")
        policy["autonomyDefault"] = .string("supervised")
        policy["enableAutonomy"] = .bool(false)
        policy["toolAutonomy"] = .object(["default": .string("blocked")])
        policy["toolPolicy"] = .object([
            "autoPromoteSafeTools": .bool(false),
            "autoRunSafeTools": .bool(false),
            "riskyToolApproval": .string("deny"),
        ])
        // Wave 4 phase A: still the old key (see defaultTrustPolicy).
        policy[WorkshopPolicyBlockVocabulary.wireKey] = .object([
            "allowBackgroundMissions": .bool(false),
            "requireReceipts": .bool(true),
            "autoCreateMissionFromChat": .bool(false),
            "enabled": .bool(false),
            "showTimeline": .bool(true),
        ])
        policy["trainingPolicy"] = .object([
            "autonomous_training": .bool(false),
            "dream_scheduler": .bool(false),
            "route_through_promotion": .bool(true),
        ])
        policy["promotionPolicy"] = .object([
            "enabled": .bool(false),
            "auto_promote_tier_a": .bool(false),
            "run_smoke_in_harness": .bool(true),
        ])
        policy["memoryPolicy"] = .object([
            "consolidation_enabled": .bool(false),
            "cross_session_recall": .bool(false),
            "auto_promote_consolidated": .bool(false),
            "knowledge_graph_enabled": .bool(false),
            "adaptive_promotion": .bool(false),
            "hygiene_enabled": .bool(false),
            "archive_noisy_reflections": .bool(false),
            "reject_low_value_proposals": .bool(true),
            "vault_enabled": .bool(false),
            "vault_require_encryption": .bool(true),
        ])
        policy["connectorPolicy"] = .object([
            "defaultEnabled": .bool(false),
            "sendExternalMessagesRequiresApproval": .bool(true),
        ])
        policy["multimodalPolicy"] = .object([
            "screen_capture": .bool(false),
            "vision_api_calls": .bool(false),
            "file_ingestion_pdf": .bool(false),
            "file_ingestion_docx": .bool(false),
            "image_generation_openai": .bool(false),
            "tts_openai": .bool(false),
        ])
        policy["skillBuilderPolicy"] = .object([
            "allow_ui_panels": .bool(false),
            "v2_enabled": .bool(false),
        ])
        policy["inboxPolicy"] = .object(["enabled": .bool(false)])
        policy["mcpPolicy"] = .object(["allow_lifecycle_ops": .bool(false)])
        policy["swarmPolicy"] = .object([
            "enabled": .bool(false),
            "maxAgents": .int(0),
            "maxParallel": .int(0),
            "storeReceipts": .bool(true),
        ])
        policy["macControlPolicy"] = .object([
            "enabled": .bool(false),
            "applescript_allowed": .bool(false),
            "jxa_allowed": .bool(false),
            "shortcuts_allowed": .bool(false),
            "accessibility_allowed": .bool(false),
            "system_control_allowed": .bool(false),
            "file_ops_allowed": .bool(false),
            "shell_allowed": .bool(false),
            "notifications_allowed": .bool(false),
            "spotlight_allowed": .bool(false),
            "remote_from_ios_allowed": .bool(false),
        ])
        policy["securityPolicy"] = .object([
            "securityCenterEnabled": .bool(true),
            "capabilityPolicyEnabled": .bool(true),
            "originTrustEnabled": .bool(true),
            "signedRemoteCommandsRequired": .bool(true),
            "promptInjectionShieldEnabled": .bool(true),
            "dangerGatesEnabled": .bool(true),
            "rollbackByDefault": .bool(true),
            "secretFirewallEnabled": .bool(true),
            "toolSigningRequired": .bool(false),  // USER YOLO 2026-08-12
            "auditReceiptsEnabled": .bool(true),
            "allowAppNotifications": .bool(false),
            "killSwitchEnabled": .bool(true),
            "remoteHighRiskDefault": .string("block"),
            "criticalRequiresDeveloperMode": .bool(false),  // USER YOLO 2026-08-12
        ])
        return policy
    }

    private nonisolated static func normalizeBrowserAutonomy(_ toolAutonomy: inout [String: JSONValue]) {
        for key in ["browser.open_url", "browser_open_url", "browser.navigate", "browser_navigate"] {
            guard case .string(let value)? = toolAutonomy[key] else { continue }
            if ["draft_auto", "send_approval", "confirm", "destructive_strong"].contains(value) {
                toolAutonomy[key] = .string("auto")
            }
        }
    }

    /// Normalize saved trust policy into the shape expected by Swift gates.
    ///
    /// Backfills/coercions covered (in legacy source order):
    ///   1. `autonomyDefault` ∈ {supervised, app_data_autonomous,
    ///      workspace_autonomous}; else → "supervised".
    ///   2. `filePolicy.outsideWorkspaceDefault` backfilled to "deny".
    ///   3. Full-Mac detection from `permissionLevel` +
    ///      `filePolicy.outsideWorkspaceDefault`. When Full-Mac:
    ///      - `developerMode` backfilled to false when absent or malformed;
    ///        an explicit operator-enabled true is preserved as the separate
    ///        destructive/system-level escalation.
    ///      - `fullMacExpiresAt == "never"` (case-insensitive, trimmed) ↔
    ///        `fullMacNeverExpires == true` are kept in sync
    ///      - `fullMacConfirmedAt` backfilled with the injected `nowISO`
    ///        when missing/empty/null.
    ///      When NOT Full-Mac AND outsideDefault != "allow":
    ///      - `fullMacNeverExpires` forced to false if previously truthy
    ///      - `fullMacExpiresAt` removed if present.
    ///   4. `providerPolicy`:
    ///      - `active_per_surface` merged: default ∪ saved (saved wins).
    ///      - `fallback_chain` merged per surface; for each of
    ///        ("chat","ios","telegram") the chain is taken from saved-or-chat-
    ///        default, then `anthropic_oauth_direct` is INSERTED at the
    ///        canonical position if missing (after openai_oauth_direct if
    ///        present, taking min with an existing anthropic index.
    ///   5. `personalityPolicy.completion_guard_max_repairs`:
    ///      - bounded to [0,2] (out-of-range → clamp; non-int → 2)
    ///      - floored to 2 when `completion_guard_enabled` is truthy.
    ///
    /// `defaultProviderPolicy` must be the providerPolicy block from a fresh
    /// `defaultTrustPolicy()`. `nowISO` is injected so tests can pin the
    /// timestamp without changing the actor clock.
    nonisolated static func normalizeTrustPolicy(
        _ policy: [String: JSONValue],
        defaultProviderPolicy: [String: JSONValue] = [:],
        nowISO: String = ""
    ) -> [String: JSONValue] {
        var out = policy

        // 1. autonomyDefault validity.
        let validAutonomy: Set<String> = [
            "supervised", "app_data_autonomous", "workspace_autonomous",
        ]
        let currentAutonomy: String = {
            if case .string(let s)? = out["autonomyDefault"] { return s }
            return ""
        }()
        if !validAutonomy.contains(currentAutonomy) {
            out["autonomyDefault"] = .string("supervised")
        }

        // 2. filePolicy.outsideWorkspaceDefault backfill + Full-Mac detection.
        let permissionLevel: String = {
            if case .string(let s)? = out["permissionLevel"] { return s }
            return ""
        }()
        var filePolicy: [String: JSONValue] = [:]
        if case .object(let fp)? = out["filePolicy"] { filePolicy = fp }
        let outsideDefault: String = {
            if case .string(let s)? = filePolicy["outsideWorkspaceDefault"] {
                return s
            }
            return "deny"
        }()
        if filePolicy["outsideWorkspaceDefault"] == nil {
            filePolicy["outsideWorkspaceDefault"] = .string("deny")
        }
        out["filePolicy"] = .object(filePolicy)

        let isFullMac =
            permissionLevel == "full_mac_os"
            || (permissionLevel == "wide_open_receipts" && outsideDefault == "allow")

        // 3. Full-Mac vs non-Full-Mac stamps.
        if isFullMac {
            // Full Mac and Developer Mode are separate controls in the
            // Swift-native app. Full Mac gets a default false; an explicit true
            // from the operator is preserved.
            let devModeIsExplicitBool: Bool = {
                if case .bool(_)? = out["developerMode"] { return true }
                return false
            }()
            if !devModeIsExplicitBool {
                out["developerMode"] = .bool(false)
            }

            // fullMacExpiresAt == "never" (trimmed, lowercased) → fullMacNeverExpires = true.
            let expiresRaw: String = {
                if case .string(let s)? = out["fullMacExpiresAt"] { return s }
                return ""
            }()
            let expiresNormalized = expiresRaw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let neverIsTrue: Bool = {
                if case .bool(let b)? = out["fullMacNeverExpires"] { return b }
                return false
            }()
            if expiresNormalized == "never" && !neverIsTrue {
                out["fullMacNeverExpires"] = .bool(true)
            }
            // If fullMacNeverExpires is truthy (post-flip), force expiresAt → "never"
            // unless already the literal string "never".
            let neverIsTrueAfter: Bool = {
                if case .bool(let b)? = out["fullMacNeverExpires"] { return b }
                return false
            }()
            let expiresIsLiteralNever: Bool = {
                if case .string(let s)? = out["fullMacExpiresAt"] {
                    return s == "never"
                }
                return false
            }()
            if neverIsTrueAfter && !expiresIsLiteralNever {
                out["fullMacExpiresAt"] = .string("never")
            }

            // fullMacConfirmedAt backfill: treat missing/null/empty as unset.
            let confirmedAtMissing: Bool = {
                guard let v = out["fullMacConfirmedAt"] else { return true }
                switch v {
                case .null: return true
                case .string(let s): return s.isEmpty
                default: return false
                }
            }()
            if confirmedAtMissing {
                out["fullMacConfirmedAt"] = .string(nowISO)
            }
        } else if outsideDefault != "allow" {
            let neverIsTruthy: Bool = {
                if case .bool(let b)? = out["fullMacNeverExpires"] { return b }
                return false
            }()
            if neverIsTruthy {
                out["fullMacNeverExpires"] = .bool(false)
            }
            if out["fullMacExpiresAt"] != nil {
                out.removeValue(forKey: "fullMacExpiresAt")
            }
        }

        let developerModeEnabled: Bool = {
            if case .bool(let b)? = out["developerMode"] { return b }
            return false
        }()
        filePolicy["allowDestructiveActions"] = .bool(developerModeEnabled)
        out["filePolicy"] = .object(filePolicy)
        if !developerModeEnabled, case .object(var macPolicy)? = out["macControlPolicy"] {
            macPolicy["shell_allowed"] = .bool(false)
            macPolicy["system_control_allowed"] = .bool(false)
            if case .object(var riskGate)? = macPolicy["riskGatePolicy"] {
                riskGate["critical"] = .string("deny")
                macPolicy["riskGatePolicy"] = .object(riskGate)
            }
            out["macControlPolicy"] = .object(macPolicy)
        }

        // 4. providerPolicy active_per_surface + fallback_chain backfill.
        var providerPolicy: [String: JSONValue] = [:]
        if case .object(let pp)? = out["providerPolicy"] { providerPolicy = pp }

        let defaultActive: [String: JSONValue] = {
            if case .object(let a)? = defaultProviderPolicy["active_per_surface"] {
                return a
            }
            return [:]
        }()
        let savedActive: [String: JSONValue] = {
            if case .object(let a)? = providerPolicy["active_per_surface"] {
                return a
            }
            return [:]
        }()
        var mergedActive = defaultActive
        for (k, v) in savedActive { mergedActive[k] = v }

        let defaultFallback: [String: JSONValue] = {
            if case .object(let f)? = defaultProviderPolicy["fallback_chain"] {
                return f
            }
            return [:]
        }()
        let savedFallback: [String: JSONValue] = {
            if case .object(let f)? = providerPolicy["fallback_chain"] {
                return f
            }
            return [:]
        }()
        var mergedFallback = defaultFallback
        for (k, v) in savedFallback { mergedFallback[k] = v }

        // anthropic_oauth_direct insertion per surface.
        // Provider fallback insertion for surfaces that should include the
        // Anthropic OAuth direct path next to the OpenAI OAuth direct path.
        for surface in ["chat", "ios", "telegram"] {
            var chain: [String] = []
            let surfaceVal = mergedFallback[surface] ?? mergedFallback["chat"]
            if case .array(let arr)? = surfaceVal {
                for el in arr {
                    if case .string(let s) = el { chain.append(s) }
                }
            }
            if !chain.contains("anthropic_oauth_direct") {
                var insertAt = chain.contains("openai_oauth_direct") ? 1 : 0
                if let anthropicIdx = chain.firstIndex(of: "anthropic") {
                    let alt = (insertAt != 0) ? insertAt : anthropicIdx
                    insertAt = min(anthropicIdx, alt)
                }
                if insertAt > chain.count { insertAt = chain.count }
                chain.insert("anthropic_oauth_direct", at: insertAt)
                mergedFallback[surface] = .array(chain.map { .string($0) })
            }
        }

        providerPolicy["active_per_surface"] = .object(mergedActive)
        providerPolicy["fallback_chain"] = .object(mergedFallback)
        out["providerPolicy"] = .object(providerPolicy)

        // 5. personalityPolicy.completion_guard_max_repairs floor.
        var personalityPolicy: [String: JSONValue] = [:]
        if case .object(let pp)? = out["personalityPolicy"] { personalityPolicy = pp }

        // completion_guard_enabled: Legacy truthiness for `completion_guard_enabled`.
        // Missing defaults to enabled; explicit null is treated as disabled.
        let guardEnabled: Bool = {
            guard let v = personalityPolicy["completion_guard_enabled"] else {
                return true  // missing → default True
            }
            switch v {
            case .bool(let b): return b
            case .null: return false  // bool(None) == False
            case .int(let i): return i != 0
            case .double(let d): return d != 0.0
            case .string(let s): return !s.isEmpty
            case .array(let a): return !a.isEmpty
            case .object(let o): return !o.isEmpty
            }
        }()

        // completion_guard_max_repairs: int(...), catch TypeError/ValueError → 2.
        var repairs: Int = {
            guard let v = personalityPolicy["completion_guard_max_repairs"] else {
                return 2
            }
            switch v {
            case .int(let i): return Int(i)
            case .double(let d):
                if d.isFinite && d >= Double(Int.min) && d <= Double(Int.max) {
                    return Int(d)
                }
                return 2
            case .string(let s):
                // String values are trimmed before integer parsing.
                if let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return n
                }
                return 2
            case .bool(let b): return b ? 1 : 0
            default: return 2
            }
        }()
        if repairs < 0 { repairs = 0 }
        if repairs > 2 { repairs = 2 }
        if guardEnabled && repairs < 2 { repairs = 2 }
        personalityPolicy["completion_guard_max_repairs"] = .int(Int64(repairs))
        out["personalityPolicy"] = .object(personalityPolicy)

        return out
    }
}
