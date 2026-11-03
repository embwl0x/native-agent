import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustCenter+PolicyLoading.swift` | Canonical checked policy bytes, authority types and closed posture validation before normalization; shared with SavedTrustPolicyAuthority's exact-byte validation cache; absent files and validated empty objects alone receive fresh-install additions |

/// One checked authority generation for a SecurityCenter decision, read from
/// one set of saved bytes so an effect-time gate cannot splice concurrent
/// policies.
public struct TrustPolicyAuthorizationSnapshot: Sendable, Equatable {
    public let policy: [String: JSONValue]

}

extension SwiftNativeTrustCenter {
    private nonisolated static func policyReadFailure(_ code: String, _ detail: String) -> ToolFailureError {
        ToolFailureError(detail, effects: .none, owner: "trust/policy.json",
            tap: "Trust > Access and policy > Preserve damaged policy and authorize Safe",
            code: code, instruction: "Ask the owner to preserve the damaged policy and authorize Safe.")
    }

    /// Reads the authoritative saved policy without conflating a missing file
    /// with damaged authority state. Missing is the only bootstrap-empty case.
    public nonisolated static func loadRawPolicyChecked(at path: URL, defaults: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let data = try policyBytesChecked(at: path) else { return [:] }
        return try decodeRawPolicyChecked(data, defaults: defaults)
    }

    /// One decode/shape owner for canonical loading and exact-byte gate caching.
    nonisolated static func decodeRawPolicyChecked(_ data: Data, defaults: [String: JSONValue]) throws -> [String: JSONValue] {
        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw Self.policyReadFailure("trust_policy_malformed", "Saved Trust policy is not valid JSON: \(error.localizedDescription)")
        }
        guard case .object(let object) = decoded else {
            throw Self.policyReadFailure("trust_policy_invalid_root", "Saved Trust policy must be a JSON object.")
        }
        try validateKnownAuthorityPolicyTypes(object, against: defaults)
        return object
    }

    nonisolated static func policyBytesChecked(at path: URL) throws -> Data? {
        // Inspect the entry without following its final symlink.
        // A dangling link is saved but unreadable authority, never bootstrap.
        var metadata = stat()
        if lstat(path.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ToolFailureError("Saved Trust policy cannot be inspected: \(String(cString: strerror(errno))).",
                    effects: .none, owner: path.path, tap: "Finder > Go > Go to Folder > \(path.deletingLastPathComponent().path) > policy.json > Get Info > Sharing & Permissions",
                    code: "trust_policy_uninspectable", instruction: "Ask the owner to repair file access; preserve the policy bytes and authority.")
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
            throw ToolFailureError("Saved Trust policy could not be read: \(error.localizedDescription). It must be a regular file of at most 1 MiB.",
                effects: .none, owner: path.path, tap: "Finder > Go > Go to Folder > \(path.deletingLastPathComponent().path) > policy.json > Get Info",
                code: "trust_policy_unreadable", instruction: "Ask the owner to repair the named file; preserve its bytes and authority.")
        }
        return data
    }

    /// Canonical defaults define known field types. Optional authority booleans
    /// share the current policy schema.
    /// Unknown metadata is retained without acquiring authority.
    public nonisolated static func validateKnownAuthorityPolicyTypes(
        _ policy: [String: JSONValue],
        against defaults: [String: JSONValue]
    ) throws {
        var schema = defaults
        schema["developerMode"] = .bool(false)
        schema["enableAutonomy"] = .bool(false)
        var security = defaults["securityPolicy"]?.objectValue ?? [:]
        security["trustedRemoteHighRiskAllowed"] = .bool(true)
        security["shellSandboxEnabled"] = .bool(true)
        schema["securityPolicy"] = .object(security)
        for (key, value) in policy {
            guard let expected = schema[key] else { continue }
            try validateKnownAuthorityPolicyValue(
                value,
                against: expected,
                path: key
            )
        }
        for (path, value, accepted) in [
            ("permissionLevel", policy["permissionLevel"], ["strict", "balanced", "full_mac_os"]),
            ("autonomyDefault", policy["autonomyDefault"], ["supervised", "app_data_autonomous", "workspace_autonomous"]),
            ("filePolicy.outsideWorkspaceDefault", policy["filePolicy"]?.objectValue?["outsideWorkspaceDefault"], ["deny", "ask", "allow"]),
        ] {
            if let value, !accepted.contains(value.stringValue ?? "") {
                throw Self.policyReadFailure("trust_policy_invalid_field", "Saved Trust policy field \(path) must be one of: \(accepted.joined(separator: ", ")).")
            }
        }
    }

    private nonisolated static func validateKnownAuthorityPolicyValue(
        _ value: JSONValue,
        against expected: JSONValue,
        path: String
    ) throws {
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
            throw Self.policyReadFailure("trust_policy_invalid_field",
                "Saved Trust policy field \(path) has the wrong JSON type."
            )
        }
    }

    public func loadTrustPolicyChecked() async throws -> [String: JSONValue] {
        let snapshot = try await loadAuthorizationSnapshotChecked()
        return snapshot.policy
    }

    /// Every effect-time check reads one freshly validated authority generation.
    public func loadAuthorizationSnapshotChecked() async throws -> TrustPolicyAuthorizationSnapshot {
        let sourcePresent = FileManager.default.fileExists(atPath: trustPolicyURL.path)
        let defaults = defaultTrustPolicy()
        let saved = try Self.loadRawPolicyChecked(at: trustPolicyURL, defaults: defaults)
        return TrustPolicyAuthorizationSnapshot(
            // An empty policy file (setup writes `{}` before the person has
            // chosen anything) is a fresh install too.
            policy: normalizedTrustPolicy(saved: saved, defaults: defaults, freshInstall: !sourcePresent || saved.isEmpty)
        )
    }

    private var trustPolicyURL: URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// Workspace autonomy defaults apply only to absent or validated empty policies, never missing keys or fail-closed state.
    static let freshInstallTrustPolicyAdditions: [String: JSONValue] = [
        "enableAutonomy": .bool(true),
        "autonomyDefault": .string("workspace_autonomous"),
    ]

    /// - Parameter freshInstall: true only when the caller has proven no
    ///   policy file exists on disk, or its validated object is empty.
    func normalizedTrustPolicy(
        saved savedDict: [String: JSONValue],
        defaults: [String: JSONValue],
        freshInstall: Bool = false
    ) -> [String: JSONValue] {
        var merged = defaults
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
        return Self.normalizeTrustPolicy(merged)
    }

    /// Normalize saved trust policy into the shape expected by Swift gates.
    ///
    /// Live authority normalization:
    ///   1. `filePolicy.outsideWorkspaceDefault` backfilled to "deny".
    ///   2. Shell and system control are disabled outside `developerMode`.
    /// Closed posture values are validated before normalization, never replaced.
    nonisolated static func normalizeTrustPolicy(
        _ policy: [String: JSONValue]
    ) -> [String: JSONValue] {
        var out = policy

        // Absent selection uses the shipped outside-workspace default.
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
        if !developerModeEnabled, case .object(var macPolicy)? = out["macControlPolicy"] {
            macPolicy["shell_allowed"] = .bool(false)
            macPolicy["system_control_allowed"] = .bool(false)
            out["macControlPolicy"] = .object(macPolicy)
        }

        return out
    }
}
