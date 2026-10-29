import Foundation
import NativeAgentShared
import PersistenceCore
import TrustPersistence
// Blueprint: | `AppToolExecutor+UpkeepTarget.swift` | backup restore target validation |

public struct QuietBackupRestoreFailure: Error {
    public let detail: String
    public let fields: [String: JSONValue]
    public var refusal: JSONValue {
        .object(fields.merging(["status": .string("failed"), "detail": .string(detail), "effects": .string("none")]) { $1 })
    }
}

extension AppToolExecutor {
    public static func quietBackupRestoreTarget(_ input: [String: JSONValue], dataRoot: URL) async -> Result<BackupRecord, QuietBackupRestoreFailure> {
        let id = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let backups: [BackupRecord]
        do { backups = try TrustBackupPersistence.readBackupRecords(root: dataRoot) }
        catch {
            return .failure(QuietBackupRestoreFailure(
                detail: "Backups could not be read: \(error.localizedDescription). Nothing was restored.",
                fields: ["reason": .string("backups_unavailable")]))
        }
        guard let backup = backups.first(where: { $0.id == id }) else {
            return .failure(QuietBackupRestoreFailure(
                detail: "No backup has id \(id.isEmpty ? "(none passed)" : id). Pass id, one of these.",
                fields: ["reason": .string("backup_not_found"), "argument_path": .string("args.id"),
                "backups": .array(backups.prefix(8).map {
                    .object(["id": .string($0.id), "reason": .string($0.reason), "created_at": .string($0.createdAt),
                             "scope": .array($0.scope.map(JSONValue.string))])
                })]))
        }
        return .success(backup)
    }
}
