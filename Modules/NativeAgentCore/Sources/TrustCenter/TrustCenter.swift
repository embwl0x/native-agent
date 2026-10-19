import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #12: TrustCenter
//
// Swift-native implementation owns the trust policy store.
//
// TrustCenter is the Swift-owned permission and policy store. It governs
// surface-specific autonomy (Full Mac, Telegram, Slack, iOS remote, shell,
// files, Workshop executions, mac control, connectors), drives the autonomy/policy
// gate surfaces, and signs autonomous-tool manifests through
// SwiftNativeManifestSigner using data/tools/.manifest_signing_key.

// MARK: - SwiftNative impl

public actor SwiftNativeTrustCenter {
    let dataRoot: URL
    let persistence: any PersistenceCoreProtocol
    let clock: @Sendable () -> Date

    /// Valid autonomy levels for Swift policy evaluation. Exposed so
    /// consumers do not duplicate the accepted values.
    public static let unifiedPolicyAutonomyLevels: Set<String> = [
        "auto", "draft_auto", "send_approval",
        "confirm", "destructive_strong", "blocked",
    ]

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
    }

    public func getTrust() async throws -> TrustPolicy {
        return try TrustPolicy(policyObject: try await loadTrustPolicyChecked())
    }

    /// Called only by the person's recovery control, never a tool. Preserve
    /// damaged authority before explicitly reauthorizing the Safe posture.
    public func reauthorizeSafePolicy() async throws -> TrustPolicy {
        let path = trustPolicyPath, defaults = defaultTrustPolicy()
        let saved = try await persistence.withFileLock(path) { [persistence] in
            do {
                _ = try Self.loadSavedPolicyChecked(at: path, defaults: defaults)
                throw TrustCenterError.invalidRequest
            } catch TrustCenterError.invalidRequest { throw TrustCenterError.invalidRequest }
            catch {
                guard let bytes = try Self.policyBytesChecked(at: path) else { throw TrustCenterError.invalidRequest }
                let backup = path.deletingLastPathComponent().appendingPathComponent("policy.unavailable-\(UUID().uuidString).json")
                try bytes.write(to: backup, options: .withoutOverwriting)
                var safe = defaults
                safe["permissionLevel"] = .string("strict")
                safe["enableAutonomy"] = .bool(false)
                safe["developerMode"] = .bool(false)
                try Self.validateAuthorityPolicyShape(safe)
                try Self.validateKnownAuthorityPolicyTypes(safe, against: defaults)
                try await persistence.writeJSON(.object(safe), to: path)
                return safe
            }
        }
        return try TrustPolicy(policyObject: saved)
    }

    /// Canonical checked trust-policy mutation. Every patch is merged against
    /// one freshly validated raw generation under the cross-process file lock,
    /// and the returned normalized policy is derived from that exact written
    /// generation rather than a later reread.
    ///
    /// `guardedByLockedPolicy` is checked against the raw policy generation the
    /// patch is about to merge into, INSIDE the lock. A caller that verified
    /// something about the posture before calling (the quiet self-administration
    /// tools verify Full Mac) re-verifies it there, so a posture lowered between
    /// the check and the write refuses the write instead of being written back.
    /// A throw from it leaves the file untouched.
    public func applyPolicyPatchChecked(
        _ patch: [String: JSONValue],
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> [String: JSONValue] {
        let path = trustPolicyPath
        let defaults = defaultTrustPolicy()
        let merged = try await persistence.withFileLock(path) {
            // Wave 4 read-both (phase A): BOTH the caller's patch and the
            // current on-disk object may carry the future `workshopPolicy`
            // spelling (the patch from a future caller; the disk from a write
            // that slipped through before the fold existed). Fold BOTH onto
            // the WIRE key before validation and merge, so every write leaves
            // the file with exactly one spelling — the old one — and a
            // stray future key is normalized away instead of rewritten
            // forever. Folding current BEFORE type validation also gives a
            // future-spelled block the same nested type checks the legacy
            // spelling gets (review 2026-08-06 blocking #2/#3).
            let current = WorkshopPolicyBlockVocabulary.foldToWireKey(
                try Self.loadRawPolicyChecked(at: path))
            // Fresh exactly as the canonical read defines it: no file, or a
            // file with nothing in it (setup writes `{}`). Keying this off
            // file existence alone let the first settings write land on that
            // `{}`, leave the file non-empty and never materialize the
            // additions — so `autonomyDefault` fell back to "supervised" and
            // the Trust preset stopped matching.
            let bootstrapWrite = current.isEmpty
            try Self.validateKnownAuthorityPolicyTypes(current, against: defaults)
            try guardedByLockedPolicy?(current)
            var patch = WorkshopPolicyBlockVocabulary.foldToWireKey(patch)
            // The first write on a fresh root persists what that root already
            // reads (Self.freshInstallTrustPolicyAdditions); without this the
            // fresh-install grant would silently disappear on the first save.
            if bootstrapWrite {
                for (k, v) in Self.freshInstallTrustPolicyAdditions where patch[k] == nil {
                    patch[k] = v
                }
            }
            let merged = Self.deepMerge(current, patch)
            try Self.validateAuthorityPolicyShape(merged)
            try Self.validateKnownAuthorityPolicyTypes(merged, against: defaults)
            try await persistence.writeJSON(.object(merged), to: path)
            return merged
        }
        return normalizedTrustPolicy(saved: merged, defaults: defaults)
    }

    /// Checked compare-and-set used by the human-approved autonomy promotion
    /// reconciler. Only the named raw override is changed, and only while its
    /// locked value remains one of the caller's already-reviewed tiers.
    public func compareAndSetToolAutonomy(
        tool: String,
        expectedCurrentTiers: Set<String>,
        newTier: String
    ) async throws -> Bool {
        let cleanTool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTool.isEmpty,
              !expectedCurrentTiers.isEmpty,
              Self.unifiedPolicyAutonomyLevels.contains(newTier)
        else {
            throw TrustCenterError.invalidRequest
        }

        let path = trustPolicyPath
        let defaults = defaultTrustPolicy()
        return try await persistence.withFileLock(path) {
            var current = WorkshopPolicyBlockVocabulary.foldToWireKey(
                try Self.loadRawPolicyChecked(at: path))
            try Self.validateKnownAuthorityPolicyTypes(current, against: defaults)
            var autonomy: [String: JSONValue]
            if case .object(let value)? = current["toolAutonomy"] {
                autonomy = value
            } else {
                autonomy = [:]
            }
            guard case .string(let lockedTier)? = autonomy[cleanTool],
                  expectedCurrentTiers.contains(lockedTier)
            else {
                return false
            }
            autonomy[cleanTool] = .string(newTier)
            current["toolAutonomy"] = .object(autonomy)
            try Self.validateAuthorityPolicyShape(current)
            try Self.validateKnownAuthorityPolicyTypes(current, against: defaults)
            try await persistence.writeJSON(.object(current), to: path)
            return true
        }
    }

    private var trustPolicyPath: URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    private nonisolated static func deepMerge(
        _ base: [String: JSONValue],
        _ patch: [String: JSONValue]
    ) -> [String: JSONValue] {
        var out = base
        for (key, value) in patch {
            if case .object(let patchObj) = value,
               case .object(let baseObj)? = out[key] {
                out[key] = .object(deepMerge(baseObj, patchObj))
            } else {
                out[key] = value
            }
        }
        return out
    }
}
