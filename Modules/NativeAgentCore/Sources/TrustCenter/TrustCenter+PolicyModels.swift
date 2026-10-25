import Foundation
import PersistenceCore
// Blueprint: | `TrustCenter+PolicyModels.swift` | `TrustCenterDefaultWorkspaceRoots`, `TrustCenterError` |

// MARK: - Default trusted workspace roots

/// Trust Center roots that should be treated as app-approved workspaces even
/// when broad Full Mac mode is off.
public enum TrustCenterDefaultWorkspaceRoots {
    /// The agent's OWN workspace, and nothing else.
    ///
    /// The iCloud Obsidian vault folder used to be seeded here, so a fresh
    /// install — whose autonomy default is `workspace_autonomous` — could edit
    /// a stranger's entire vault with no approval at all. "Everything on" does
    /// not extend to someone's notes (User, 2026-09-17): the vault becomes a
    /// workspace root when the person connects Obsidian, not before. Installs
    /// that already saved it in `filePolicy.workspaceRoots` keep it — this
    /// changes only what a NEW policy is born with.
    public static func defaultRoots(
        dataRoot: URL = defaultDataRoot()
    ) -> [URL] {
        [NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)]
    }

    public static func defaultRootPaths(
        dataRoot: URL = defaultDataRoot()
    ) -> [String] {
        defaultRoots(dataRoot: dataRoot).map(\.path)
    }
}

// MARK: - Errors

public enum TrustCenterError: Error, LocalizedError {
    case invalidRequest
    case policyConflict
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "trust_request_invalid: This request cannot be applied to the current Trust policy. Inspect Trust > Access and policy and correct the request."
        case .policyConflict: return "trust_policy_conflict: Mac control settings changed while you edited. Review current settings at Trust > Mac > Advanced Mac control, reapply your edits, then Save."
        case .underlying(let m): return m
        }
    }
}
