import NativeAgentShared
import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TrustCenter+PolicyLoading.swift` | One checked generation; only proven fresh policy bootstraps. |

/// One checked byte generation prevents effect-time gates from splicing concurrent policies.
public struct TrustPolicyAuthorizationSnapshot: Sendable, Equatable {
    public let policy: [String: JSONValue]

}

extension SwiftNativeTrustCenter {
    public nonisolated static func policyURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    }

    /// Synchronous consumers use the same checked read as authorization, retaining saved values before normalization.
    public nonisolated func loadSavedPolicyChecked() throws -> [String: JSONValue] {
        try Self.loadRawPolicyChecked(at: Self.policyURL(dataRoot: dataRoot), defaults: defaultTrustPolicy())
    }

    public nonisolated func savedPolicyFlag(block: String, key: String, default defaultValue: Bool) throws -> Bool {
        try Self.policyFlag(loadSavedPolicyChecked(), block: block, key: key, default: defaultValue)
    }

    public nonisolated static func policyFlag(
        _ policy: [String: JSONValue], block: String, key: String, default defaultValue: Bool
    ) throws -> Bool {
        guard let value = policy[block] else { return defaultValue }
        guard case .object(let fields) = value else { throw Self.policyUnavailable("\(block) must be an object") }
        guard let value = fields[key] else { return defaultValue }
        guard case .bool(let enabled) = value else { throw Self.policyUnavailable("\(block).\(key) must be a Boolean") }
        return enabled
    }

    public nonisolated static func policyUnavailable(_ cause: String) -> ToolFailureError {
        ToolFailureError("Saved Trust policy is unavailable: \(cause). Preserve its bytes and repair the policy before continuing.",
            effects: .none, owner: "Trust policy",
            nextCall: ToolFailureError.call("app", ["action": .string("doctor.run")]),
            code: "trust_policy_unavailable", instruction: "Repair the saved Trust policy, preserving its original bytes.", recovery: .repair)
    }

    private nonisolated static func policyReadFailure(_ code: String, _ detail: String) -> ToolFailureError {
        ToolFailureError(detail, effects: .none, owner: "trust/policy.json",
            tap: "Trust > Access and policy > Preserve damaged policy and authorize Safe",
            code: code, instruction: "Ask the owner to preserve the damaged policy and authorize Safe.")
    }

    /// Only absence may bootstrap; damaged saved authority remains unavailable.
    public nonisolated static func loadRawPolicyChecked(at path: URL, defaults: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let data = try policyBytesChecked(at: path) else { return [:] }
        return try decodeRawPolicyChecked(data, defaults: defaults)
    }

    /// One decode/shape owner for every checked policy read.
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
        // Inspect the entry without following its final symlink. A dangling link is saved but unreadable authority, never bootstrap.
        var metadata = stat()
        if lstat(path.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw ToolFailureError("Saved Trust policy cannot be inspected: \(String(cString: strerror(errno))).",
                    effects: .none, owner: path.path,
                        tap: "Finder > Go > Go to Folder > \(path.deletingLastPathComponent().path) > policy.json > Get Info > Sharing & Permissions",
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

    /// Canonical defaults define authority field types; unknown metadata is retained without granting authority.
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
                throw Self.policyReadFailure("trust_policy_invalid_field",
                    "Saved Trust policy field \(path) must be one of: \(accepted.joined(separator: ", ")).")
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
        let snapshot = try loadAuthorizationSnapshotChecked()
        return snapshot.policy
    }

    public nonisolated func loadAuthorizationSnapshotChecked() throws -> TrustPolicyAuthorizationSnapshot {
        let sourcePresent = FileManager.default.fileExists(atPath: trustPolicyURL.path)
        let defaults = defaultTrustPolicy()
        let saved = try loadSavedPolicyChecked()
        return TrustPolicyAuthorizationSnapshot(
            // Setup's validated empty object is fresh state, like an absent policy.
            policy: normalizedTrustPolicy(saved: saved, defaults: defaults, freshInstall: !sourcePresent || saved.isEmpty)
        )
    }

    private nonisolated var trustPolicyURL: URL {
        Self.policyURL(dataRoot: dataRoot)
    }

    /// Workspace autonomy defaults apply only to absent or validated empty policies, never missing keys or fail-closed state.
    static let freshInstallTrustPolicyAdditions: [String: JSONValue] = [
        "enableAutonomy": .bool(true),
        "autonomyDefault": .string("workspace_autonomous"),
    ]

    /// Fresh additions require proven absence or a validated empty policy object.
    nonisolated func normalizedTrustPolicy(
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
            // Merge additions over defaults only; a saved value must never be replaced.
            for (k, v) in Self.freshInstallTrustPolicyAdditions where savedDict[k] == nil {
                merged[k] = v
            }
        }
        return Self.normalizeTrustPolicy(merged)
    }

    /// Validate closed posture values before normalization; only missing fields receive defaults and developer gates stay enforced.
    nonisolated static func normalizeTrustPolicy(
        _ policy: [String: JSONValue]
    ) -> [String: JSONValue] {
        var out = policy

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
