import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore

/// Why a securityPolicy value is effective for one canonical authorization
/// read. This keeps code defaults from being misreported as saved operator
/// intent, while reserving `.unreadable` for the fail-closed nonthrowing
/// projection when checked authority could not be validated.
public enum TrustPolicySecurityValueProvenance: Sendable, Equatable {
    case explicit
    case defaultMissingKey
    case defaultMissingBlock
    case defaultSourceAbsent
    case unreadable
}

/// One checked authority generation for a SecurityCenter decision, read from
/// one set of saved bytes so an effect-time gate cannot splice concurrent
/// policies.
public struct TrustPolicyAuthorizationSnapshot: Sendable, Equatable {
    public let policy: [String: JSONValue]
    /// Per-key origin for the effective `securityPolicy` block in `policy`.
    /// Every known default key is represented; `.unreadable` means this is a
    /// deliberately fail-closed projection, never valid checked authority.
    public let securityPolicyProvenance: [String: TrustPolicySecurityValueProvenance]

    init(
        policy: [String: JSONValue],
        securityPolicyProvenance: [String: TrustPolicySecurityValueProvenance]
    ) {
        self.policy = policy
        self.securityPolicyProvenance = securityPolicyProvenance
    }
}

extension SwiftNativeTrustCenter {
    /// Reads the authoritative saved policy without conflating a missing file
    /// with damaged authority state. Missing is the only bootstrap-empty case.
    public nonisolated static func loadRawPolicyChecked(at path: URL) throws -> [String: JSONValue] {
        guard let data = try policyBytesChecked(at: path) else { return [:] }
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

    nonisolated static func policyBytesChecked(at path: URL) throws -> Data? {
        // 2026-09-06: inspect the entry without following its final symlink.
        // A dangling link is saved but unreadable authority, never bootstrap.
        var metadata = stat()
        if lstat(path.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw TrustCenterError.underlying("saved trust policy cannot be inspected")
            }
            return nil
        }
        let data: Data
        do {
            let fd = Darwin.open(path.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let maximumBytes = 1_048_576
            guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size <= maximumBytes else { throw POSIXError(.EIO) }
            var bytes = Data()
            while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - bytes.count)),
                  !chunk.isEmpty {
                bytes.append(chunk)
                guard bytes.count <= maximumBytes else { throw POSIXError(.EFBIG) }
            }
            data = bytes
        } catch {
            throw TrustCenterError.underlying("saved trust policy is unreadable")
        }
        return data
    }

    /// A saved scalar must never replace one of the policy dictionaries that
    /// owns authority. Normalization merges saved values over safe defaults;
    /// without this check, a value such as `"securityPolicy": "damaged"`
    /// discards the entire default security block and can make corruption look
    /// like an intentionally permissive policy. Missing blocks remain valid so
    /// older policies can receive new defaults during normalization.
    ///
    /// This is HALF the rule. The other half is
    /// `validateKnownAuthorityPolicyTypes`, and both run for every reader —
    /// canonical loads here and the point-of-use gates, which come through
    /// `SavedTrustPolicyAuthority.read`.
    public nonisolated static func validateAuthorityPolicyShape(
        _ policy: [String: JSONValue]
    ) throws {
        // Developer Mode is optional rather than a defaults-schema key, but
        // it is still explicit authority. A truthy string/array must never
        // substitute for the operator's boolean selection. Same for
        // `enableAutonomy`, which alone opens every unattended lane and which
        // the defaults deliberately do not carry, so the recursive known-field
        // check below can never see it.
        for key in ["developerMode", "enableAutonomy"] {
            guard let value = policy[key] else { continue }
            guard case .bool = value else {
                throw TrustCenterError.underlying(
                    "saved trust policy field \(key) must be a JSON boolean"
                )
            }
        }
        let objectPaths: [[String]] = [
            [WorkshopPolicyBlockVocabulary.wireKey],
            // Wave 4 read-both: a saved policy carrying the FUTURE spelling is
            // held to the same must-be-an-object rule, so a scalar under either
            // key fails the same way instead of only the wire one.
            [WorkshopPolicyBlockVocabulary.futureKey],
            ["toolPolicy"],
            ["filePolicy"],
            ["connectorPolicy"],
            ["multimodalPolicy"],
            ["trainingPolicy"],
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

    /// The saved generation checked by both authorization and person-only recovery.
    nonisolated static func loadSavedPolicyChecked(at path: URL, defaults: [String: JSONValue]) throws -> [String: JSONValue] {
        // Fold the future spelling BEFORE type validation, not just before the
        // normalize merge — otherwise a `workshopPolicy` block skips the
        // nested type checks the legacy spelling gets (defaults only carry the
        // wire key), making future-key reads more permissive than old-key
        // reads (review 2026-08-06 blocking #3).
        let saved = WorkshopPolicyBlockVocabulary.foldToWireKey(
            try Self.loadRawPolicyChecked(at: path))
        try Self.validateKnownAuthorityPolicyTypes(saved, against: defaults)
        return saved
    }

    /// Every effect-time check reads one freshly validated authority generation.
    public func loadAuthorizationSnapshotChecked() async throws -> TrustPolicyAuthorizationSnapshot {
        let sourcePresent = FileManager.default.fileExists(atPath: trustPolicyURL.path)
        let defaults = defaultTrustPolicy()
        let saved = try Self.loadSavedPolicyChecked(at: trustPolicyURL, defaults: defaults)
        return TrustPolicyAuthorizationSnapshot(
            // An empty policy file (setup writes `{}` before the person has
            // chosen anything) is a fresh install too.
            policy: normalizedTrustPolicy(saved: saved, defaults: defaults, freshInstall: !sourcePresent || saved.isEmpty),
            securityPolicyProvenance: Self.securityPolicyProvenance(
                saved: saved,
                defaults: defaults,
                sourcePresent: sourcePresent
            )
        )
    }

    /// Compatibility snapshot for readers that cannot surface an authority
    /// error. Unlike a bootstrap source, unreadable authority remains visible
    /// per security key and gets the same fail-closed policy SecurityCenter
    /// uses when its checked read rejects the bytes.
    public func loadAuthorizationSnapshot() async -> TrustPolicyAuthorizationSnapshot {
        do {
            return try await loadAuthorizationSnapshotChecked()
        } catch {
            let closed = failClosedTrustPolicy()
            let provenance = Self.securityPolicyUnreadableProvenance(defaults: closed)
            return TrustPolicyAuthorizationSnapshot(
                policy: closed,
                securityPolicyProvenance: provenance
            )
        }
    }

    public func loadTrustPolicy() async -> [String: JSONValue] {
        await loadAuthorizationSnapshot().policy
    }

    private nonisolated static func securityPolicyProvenance(
        saved: [String: JSONValue],
        defaults: [String: JSONValue],
        sourcePresent: Bool
    ) -> [String: TrustPolicySecurityValueProvenance] {
        guard case .object(let defaultSecurity)? = defaults["securityPolicy"] else { return [:] }
        guard sourcePresent else {
            return Dictionary(uniqueKeysWithValues: defaultSecurity.keys.map {
                ($0, .defaultSourceAbsent)
            })
        }
        guard case .object(let savedSecurity)? = saved["securityPolicy"] else {
            return Dictionary(uniqueKeysWithValues: defaultSecurity.keys.map {
                ($0, .defaultMissingBlock)
            })
        }
        return Dictionary(uniqueKeysWithValues: defaultSecurity.keys.map { key in
            (key, savedSecurity[key] == nil ? .defaultMissingKey : .explicit)
        })
    }

    private nonisolated static func securityPolicyUnreadableProvenance(
        defaults: [String: JSONValue]
    ) -> [String: TrustPolicySecurityValueProvenance] {
        guard case .object(let defaultSecurity)? = defaults["securityPolicy"] else { return [:] }
        return Dictionary(uniqueKeysWithValues: defaultSecurity.keys.map { ($0, .unreadable) })
    }

    private var trustPolicyURL: URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// What a root with NO saved policy file starts with, over and above the
    /// merge defaults. 2026-09-13: a fresh install may work unattended
    /// (bots, practice runs, background improvement). A legacy file that
    /// merely lacks the key is NOT fresh — it keeps the false it has always
    /// read as, and `failClosedTrustPolicy` stays false too.
    ///
    /// `autonomyDefault` is here for the same reason and no more: unattended
    /// work was already granted above, and leaving the SCOPE at "supervised"
    /// made a clean root match none of the four trust presets — every other
    /// field already equals Work — so the Trust Center card and the composer
    /// both read "Custom". This names the posture the rest of the defaults
    /// already describe; it widens nothing outside the workspace (permission
    /// level stays balanced, outside-workspace stays deny, developer mode,
    /// shell and system control stay off). Merge base unchanged, so a saved
    /// policy that omits the key still reads "supervised".
    static let freshInstallTrustPolicyAdditions: [String: JSONValue] = [
        "enableAutonomy": .bool(true),
        "autonomyDefault": .string("workspace_autonomous"),
    ]

    /// - Parameter freshInstall: true only when the caller has proven no
    ///   policy file exists on disk.
    func normalizedTrustPolicy(
        saved savedDict: [String: JSONValue],
        defaults: [String: JSONValue],
        freshInstall: Bool = false
    ) -> [String: JSONValue] {
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
        if freshInstall {
            // Over the merge DEFAULTS, never over a saved value. (On a proven
            // fresh install `savedDict` is empty, so this only ever decides
            // whether an addition may restate a default — which is the point:
            // `autonomyDefault` has a default, `enableAutonomy` does not.)
            for (k, v) in Self.freshInstallTrustPolicyAdditions where savedDict[k] == nil {
                merged[k] = v
            }
        }
        // Provider policy defaults.
        let defaultProviderPolicy: [String: JSONValue] = {
            if case .object(let p)? = defaults["providerPolicy"] { return p }
            return [:]
        }()

        return Self.normalizeTrustPolicy(
            merged,
            defaultProviderPolicy: defaultProviderPolicy
        )
    }

    private func failClosedTrustPolicy() -> [String: JSONValue] {
        var policy = normalizedTrustPolicy(saved: [:], defaults: defaultTrustPolicy())
        policy["developerMode"] = .bool(false)
        policy["permissionLevel"] = .string("balanced")
        policy["autonomyDefault"] = .string("supervised")
        policy["enableAutonomy"] = .bool(false)
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
            "dream_scheduler": .bool(false),
        ])
        policy["memoryPolicy"] = .object([
            "consolidation_enabled": .bool(false),
            "cross_session_recall": .bool(false),
            "knowledge_graph_enabled": .bool(false),
            "adaptive_promotion": .bool(false),
            "hygiene_enabled": .bool(false),
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

    /// Normalize saved trust policy into the shape expected by Swift gates.
    ///
    /// Backfills/coercions covered (in legacy source order):
    ///   1. `autonomyDefault` ∈ {supervised, app_data_autonomous,
    ///      workspace_autonomous}; else → "supervised".
    ///   2. `filePolicy.outsideWorkspaceDefault` backfilled to "deny".
    ///   3. `filePolicy.allowDestructiveActions` follows `developerMode`.
    ///   4. `providerPolicy.active_per_surface` merged: default ∪ saved
    ///      (saved wins).
    ///   5. `personalityPolicy.completion_guard_max_repairs`:
    ///      - bounded to [0,2] (out-of-range → clamp; non-int → 2)
    ///      - floored to 2 when `completion_guard_enabled` is truthy.
    ///
    /// `defaultProviderPolicy` must be the providerPolicy block from a fresh
    /// `defaultTrustPolicy()`.
    nonisolated static func normalizeTrustPolicy(
        _ policy: [String: JSONValue],
        defaultProviderPolicy: [String: JSONValue] = [:]
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

        // 2. filePolicy.outsideWorkspaceDefault backfill.
        var filePolicy: [String: JSONValue] = [:]
        if case .object(let fp)? = out["filePolicy"] { filePolicy = fp }
        if filePolicy["outsideWorkspaceDefault"] == nil {
            filePolicy["outsideWorkspaceDefault"] = .string("deny")
        }
        out["filePolicy"] = .object(filePolicy)

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

        // 4. providerPolicy active_per_surface merge.
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

        providerPolicy["active_per_surface"] = .object(mergedActive)
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
                return Int(exactly: d.rounded(.towardZero)) ?? 2
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
