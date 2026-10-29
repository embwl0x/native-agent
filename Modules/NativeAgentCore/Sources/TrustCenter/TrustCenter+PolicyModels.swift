import Foundation
import PersistenceCore
// Blueprint: | `TrustCenter+PolicyModels.swift` | `TrustCenterDefaultWorkspaceRoots`, `TrustCenterError` |

// MARK: - Default trusted workspace roots

/// Trust Center roots that should be treated as app-approved workspaces even
/// when broad Full Mac mode is off.
public enum TrustCenterDefaultWorkspaceRoots {
    /// Only the agent's workspace is seeded; Obsidian roots require connection or an existing saved grant.
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
