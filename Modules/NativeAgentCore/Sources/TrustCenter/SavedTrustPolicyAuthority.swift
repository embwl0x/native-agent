import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore

/// THE saved-trust-policy authority read for point-of-use gates (memory,
/// multimodal, dream/REM, training). It lives beside the canonical loader and
/// calls the SAME two validators `loadAuthorizationSnapshotChecked` uses —
/// `validateAuthorityPolicyShape` and `validateKnownAuthorityPolicyTypes`
/// against the canonical defaults — so a policy SecurityCenter rejects can
/// never read as "configured" at a gate. One rule, no second copy.
///
/// - `.absent`   no directory entry at all — the ONLY bootstrap case, so the
///               caller applies the shipped defaults ("defaults everything on").
/// - `.damaged`  authority we hold but cannot trust: a dangling symlink (lstat
///               sees the LINK, so the entry is present and unreadable), bytes
///               that will not parse, a non-object root, an authority block
///               replaced by a scalar, a non-Bool `developerMode` /
///               `enableAutonomy`, or any known field whose saved JSON type
///               disagrees with its default. Every gate fails CLOSED on this,
///               whichever field it was asking about.
/// - `.present`  validated saved policy; individual flags still have to be
///               literal booleans.
public enum SavedTrustPolicyAuthority: Sendable {
    case absent
    case damaged
    case present([String: JSONValue])

    public static func policyURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    public static func read(dataRoot: URL) -> SavedTrustPolicyAuthority {
        let path = policyURL(dataRoot: dataRoot)
        // Inspect the entry WITHOUT following its final symlink: a dangling
        // link is saved-but-unreadable authority, never bootstrap.
        var metadata = stat()
        if lstat(path.path, &metadata) != 0 {
            return errno == ENOENT ? .absent : .damaged
        }
        // Shape half (and the parse/read failures) — identical call.
        guard let saved = try? SwiftNativeTrustCenter.loadRawPolicyChecked(at: path) else {
            return .damaged
        }
        // Known-field type half. Folded the way the canonical read folds it, so
        // a future `workshopPolicy` spelling is held to the same types.
        let folded = WorkshopPolicyBlockVocabulary.foldToWireKey(saved)
        let defaults = SwiftNativeTrustCenter(dataRoot: dataRoot).defaultTrustPolicy()
        do {
            try SwiftNativeTrustCenter.validateKnownAuthorityPolicyTypes(
                folded,
                against: defaults
            )
        } catch {
            return .damaged
        }
        return .present(saved)
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
