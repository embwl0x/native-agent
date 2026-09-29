import Foundation

public struct BackupRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var reason: String
    public var scope: [String]
    public var path: String
    public var createdAt: String
}

public struct BackupRestoreResult: Codable, Hashable, Sendable {
    public var id: String
    public var restored: [String]
    public var restoredAt: String
    public var requiresRestart: Bool = false
    public var safetyBackupId: String? = nil
}

