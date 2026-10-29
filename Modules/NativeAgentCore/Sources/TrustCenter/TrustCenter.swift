import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustCenter.swift` | Checked policy object and preserved damaged-policy bytes, with backup/export/live-policy phone/Trust privacy decisions; `getTrust`, `applyPolicyPatchChecked` |

// MARK: - Subsystem #12: TrustCenter
//
// Owns trust/policy.json (checked JSON object) and byte-preserved
// policy.unavailable-<UUID>.json recovery evidence. Both are backed up and
// exported; phone sync carries only the live policy. PrivacyMap lists Trust.
//
// TrustCenter is the Swift-owned permission and policy store. It governs
// surface-specific autonomy (Full Mac, Telegram, Slack, iOS remote, shell,
// files, Workshop executions, mac control, connectors), drives the autonomy/policy
// gate surfaces, and signs autonomous-tool manifests through
// SwiftNativeManifestSigner using data/tools/.manifest_signing_key.

// MARK: - SwiftNative impl

public actor SwiftNativeTrustCenter {
    let dataRoot: URL
    let clock: @Sendable () -> Date

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.clock = clock
    }

    public func getTrust() async throws -> TrustPolicy {
        return try TrustPolicy(policyObject: try await loadTrustPolicyChecked())
    }

    /// Called only by the person's recovery control, never a tool. Preserve
    /// damaged authority before explicitly reauthorizing the Safe posture.
    public func reauthorizeSafePolicy() async throws -> TrustPolicy {
        let path = trustPolicyPath, defaults = defaultTrustPolicy()
        let saved = try await SwiftNativePersistenceCore.withFileLock(path) {
            do {
                _ = try Self.loadRawPolicyChecked(at: path, defaults: defaults)
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
                try Self.validateKnownAuthorityPolicyTypes(safe, against: defaults)
                try await SwiftNativePersistenceCore.writeJSON(.object(safe), to: path)
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
        let merged = try await SwiftNativePersistenceCore.withFileLock(path) {
            // Validate both Workshop spellings before folding to the wire key.
            let current = WorkshopPolicyBlockVocabulary.foldToWireKey(
                try Self.loadRawPolicyChecked(at: path, defaults: defaults))
            // Fresh exactly as the canonical read defines it: no file, or a
            // file with nothing in it (setup writes `{}`). Keying this off
            // file existence alone let the first settings write land on that
            // `{}`, leave the file non-empty and never materialize the
            // additions — so `autonomyDefault` fell back to "supervised" and
            // the Trust preset stopped matching.
            let bootstrapWrite = current.isEmpty
            try guardedByLockedPolicy?(current)
            try Self.validateKnownAuthorityPolicyTypes(patch, against: defaults)
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
            try Self.validateKnownAuthorityPolicyTypes(merged, against: defaults)
            try await SwiftNativePersistenceCore.writeJSON(.object(merged), to: path)
            return merged
        }
        return normalizedTrustPolicy(saved: merged, defaults: defaults)
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
