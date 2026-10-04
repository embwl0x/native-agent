import Foundation
import PersistenceCore

// MARK: - AutonomyPolicy

/// Autonomy policy summary. Top-level keys include `status`, `permissionLevel`,
/// `fullMacMode`, and `gates` (array of {id, title, enabled, value,
/// status, detail, source}), plus a long tail of summary/surface fields.
/// We extract the headline scalars typed and keep `rawResponse` so callers
/// can introspect anything off the long tail.
public struct AutonomyPolicy: Sendable, Codable, Equatable {
    public var status: String?
    public var permissionLevel: String?
    public var fullMacMode: String?
    public var gates: [JSONValue]?
    public var rawResponse: JSONValue

    public init(
        status: String? = nil,
        permissionLevel: String? = nil,
        fullMacMode: String? = nil,
        gates: [JSONValue]? = nil,
        rawResponse: JSONValue = .object([:])
    ) {
        self.status = status
        self.permissionLevel = permissionLevel
        self.fullMacMode = fullMacMode
        self.gates = gates
        self.rawResponse = rawResponse
    }
}

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
    ///
    /// `homeDirectory` is kept in the signature: every caller passes the
    /// default, and the parameter is what lets a test point the roots
    /// somewhere else.
    public static func defaultRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        dataRoot: URL = defaultDataRoot()
    ) -> [URL] {
        [NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot)]
    }

    public static func defaultRootPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        dataRoot: URL = defaultDataRoot()
    ) -> [String] {
        defaultRoots(homeDirectory: homeDirectory, dataRoot: dataRoot).map(\.path)
    }
}

// MARK: - Errors

public enum TrustCenterError: Error, LocalizedError {
    case invalidRequest
    case invalidResponse(status: Int)
    case unavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "trust: invalid request"
        case .invalidResponse(let s): return "trust: native implementation returned unexpected status \(s)"
        case .unavailable: return "trust: unavailable"
        case .underlying(let m): return "trust: \(m)"
        }
    }
}
