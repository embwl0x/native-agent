import Foundation
import PersistenceCore

/// Shares only the lock-sidecar pass; callers own enumeration, cadence and JSON cleanup.
func reapOrphanedChatSessionLockSidecars(
    entries: [URL],
    now: Date,
    ttlSeconds: TimeInterval,
    persistence: any PersistenceCoreProtocol
) async {
    let fm = FileManager.default
    for lockURL in entries where lockURL.pathExtension == "lock" {
        let sibling = lockURL.deletingPathExtension()
        guard sibling.pathExtension == "json" else { continue }
        guard !fm.fileExists(atPath: sibling.path) else { continue }
        guard let vals = try? lockURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let mtime = vals.contentModificationDate,
              now.timeIntervalSince(mtime) > ttlSeconds else { continue }
        // withFileLock(sibling) locks exactly this sidecar. Re-check the
        // sibling INSIDE the lock: a session that revived between the
        // listing and here holds the same lock, so it cannot be racing us.
        try? await persistence.withFileLock(sibling) {
            guard !FileManager.default.fileExists(atPath: sibling.path) else { return }
            try? FileManager.default.removeItem(at: lockURL)
        }
    }
}
