import Foundation
// Blueprint: | `TrustBackupModels.swift` | Backup records and restore results; requiresRestart distinguishes staged scopes/time from completed installation; notCarried records unreadable pieces, causes and losses |

public struct BackupRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var reason: String
    public var scope: [String]
    public var path: String
    public var createdAt: String
}

public struct BackupRestoreResult: Codable, Hashable, Sendable {
    public var id: String
    /// Staged scopes when requiresRestart is true; installed scopes otherwise.
    public var restored: [String]
    /// Staging time when requiresRestart is true; installation time otherwise.
    public var restoredAt: String
    public var requiresRestart: Bool = false
    /// Each unreadable current piece, its cause, and the state not carried.
    public var notCarried: [String] = []
}

