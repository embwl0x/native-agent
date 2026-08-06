import Foundation

/// Canonical LOCAL paths for the Mac↔iOS sync engine's own bookkeeping.
///
/// These live under `<dataRoot>/icloud/` — deliberately on local disk, not in
/// the iCloud container. The failures they exist to survive (disk full, iCloud
/// permission denial, file-provider hiccup) are exactly the ones that make the
/// iCloud container unwritable, so a marker written there would be lost by the
/// same fault it is meant to record.
///
/// Shared here because two modules must agree on them and neither can import
/// the other: `MacSyncEngine` (app target) writes them, `DoctorChecks` reads
/// them for the iCloud Bridge State row.
public enum ICloudSyncStatePaths {
    public static func stateDirectory(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("icloud", isDirectory: true)
    }

    /// The processed-message-id window that stops a restart from re-dispatching
    /// an already-executed iOS command.
    public static func processedIds(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("processed_ids.json")
    }

    /// Where an UNREADABLE `processed_ids.json` is preserved before it is
    /// replaced, so the evidence survives and Doctor can say the window was
    /// lost rather than silently starting from an empty set.
    public static func processedIdsCorruptBackup(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("processed_ids.corrupt.json")
    }

    /// Directory of `<msgId>.completed-unarchived` markers: iOS commands that
    /// RAN and whose response landed, but whose completion could not be
    /// recorded (processed-id save failed and/or the pending file could not be
    /// archived). A marker is a durable "never dispatch this again".
    public static func completedUnarchivedDirectory(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot)
            .appendingPathComponent("completed-unarchived", isDirectory: true)
    }

    public static let completedUnarchivedExtension = "completed-unarchived"

    public static func completedUnarchivedMarker(dataRoot: URL, msgId: String) -> URL {
        completedUnarchivedDirectory(dataRoot: dataRoot)
            .appendingPathComponent("\(msgId).\(completedUnarchivedExtension)")
    }

    /// Snapshot groups the last publish pass could not build, so Doctor can say
    /// the phone is holding stale approvals/inbox/model-preferences rather than
    /// current state. Rewritten every pass; absent means "nothing skipped".
    public static func snapshotSkips(dataRoot: URL) -> URL {
        stateDirectory(dataRoot: dataRoot).appendingPathComponent("snapshot_skips.json")
    }

    /// Marker msgIds currently on disk. Missing directory = none, which is the
    /// normal case and never an error.
    public static func completedUnarchivedMsgIds(dataRoot: URL) -> [String] {
        let dir = completedUnarchivedDirectory(dataRoot: dataRoot)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == completedUnarchivedExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
