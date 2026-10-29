import Foundation
import NativeAgentCore
import PersistenceCore
import os

// Blueprint: | `SavedTrustPolicyAuthority.swift` | `SavedTrustPolicyAuthority`: point-of-use saved policy reads through canonical shape/type validators; invalid authority never reads as configured |

/// THE saved-trust-policy authority read for point-of-use gates (memory,
/// multimodal, dream/REM, training). It lives beside the canonical loader and
/// uses the same canonical schema validation as `loadAuthorizationSnapshotChecked`,
/// so a policy SecurityCenter rejects can
/// never read as "configured" at a gate. One rule, no second copy.
///
/// - `.absent`   no directory entry; the caller applies shipped defaults.
/// - `.damaged`  authority we hold but cannot trust: a dangling symlink (lstat
///               sees the LINK, so the entry is present and unreadable), bytes
///               that will not parse, a non-object root, an authority block
///               replaced by a scalar, a non-Bool `developerMode` /
///               `enableAutonomy`, or any known field whose saved JSON type
///               disagrees with its default. Every gate fails CLOSED on this,
///               whichever field it was asking about.
/// - `.present`  validated saved policy; flags must be literal booleans. An
///               empty object is fresh for checked loading and first mutation.
/// Every gate securely reads current bytes. Only an identical checked policy
/// reuses validation; absence and read failures never borrow a saved result.
/// policy.json is locally backed up/exported, phone-projected and listed in
/// PrivacyMap's Trust category; this owner alone defines the saved schema.
public enum SavedTrustPolicyAuthority: Sendable {
    case absent
    case damaged
    case present([String: JSONValue])

    private static let checkedGeneration = OSAllocatedUnfairLock<(
        path: URL, bytes: Data, authority: SavedTrustPolicyAuthority
    )?>(initialState: nil)

    public static func policyURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    public static func read(dataRoot: URL) -> SavedTrustPolicyAuthority {
        let path = policyURL(dataRoot: dataRoot)
        do {
            // The canonical bounded, no-follow read retains the distinction
            // between an absent entry and unreadable/nonregular authority.
            guard let bytes = try SwiftNativeTrustCenter.policyBytesChecked(at: path) else { return .absent }
            return try checkedGeneration.withLock { generation in
                if let generation, generation.path == path, generation.bytes == bytes { return generation.authority }
                let defaults = SwiftNativeTrustCenter(dataRoot: dataRoot).defaultTrustPolicy()
                let saved = try SwiftNativeTrustCenter.decodeRawPolicyChecked(bytes, defaults: defaults)
                let authority = SavedTrustPolicyAuthority.present(saved)
                generation = (path, bytes, authority)
                return authority
            }
        } catch {
            return .damaged
        }
    }

    /// One boolean out of one policy block, read fresh from saved authority.
    /// Absent policy / absent block / absent key → `fallback` (which callers
    /// keep equal to the shipped default, so the gate and the switch can never
    /// disagree about "unset"); damaged authority or a non-Bool value → false.
    public static func flag(
        block: String,
        key: String,
        default fallback: Bool,
        dataRoot: URL
    ) -> Bool {
        read(dataRoot: dataRoot).flag(block: block, key: key, default: fallback)
    }

    public func flag(block blockKey: String, key: String, default fallback: Bool) -> Bool {
        switch self {
        case .absent:
            return fallback
        case .damaged:
            return false
        case .present(let root):
            guard let blockValue = root[blockKey] else { return fallback }
            guard case .object(let block) = blockValue else { return false }
            guard let raw = block[key] else { return fallback }
            guard case .bool(let value) = raw else { return false }
            return value
        }
    }
}
