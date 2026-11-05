import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustCenter.swift` | `getTrust`, `applyPolicyPatchChecked`; Locked exact-generation writes preserve damaged authority. |

// MARK: - Subsystem #12: TrustCenter
// Preserve unavailable policy bytes for recovery; phone projection carries only the live authority.

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

    /// Called only by the person's recovery control, never a tool. Preserve damaged authority before explicitly reauthorizing the Safe posture.
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

    /// Merge under the cross-process lock and return that exact written generation, never a later read. Recheck guards inside the lock so a concurrent posture
    /// downgrade refuses the write without changing bytes.
    public func applyPolicyPatchChecked(
        _ patch: [String: JSONValue],
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> [String: JSONValue] {
        let path = trustPolicyPath
        let defaults = defaultTrustPolicy()
        let merged = try await SwiftNativePersistenceCore.withFileLock(path) {
            let current = try Self.loadRawPolicyChecked(at: path, defaults: defaults)
            // Absence and validated empty setup state are both fresh, matching canonical reads.
            let bootstrapWrite = current.isEmpty
            try guardedByLockedPolicy?(current)
            try Self.validateKnownAuthorityPolicyTypes(patch, against: defaults)
            var patch = patch
            // Persist fresh additions on first write so the root does not lose the grant it already reads.
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
