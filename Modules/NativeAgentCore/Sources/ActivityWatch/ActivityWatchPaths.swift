import Foundation

// Blueprint: | `ActivityWatchPaths.swift` | `ActivityWatchPaths`: private ambient history paths, separate from exported activity event feeds |

/// Keep ambient window history outside activity/events.jsonl, which support bundles select.
/// The directory is local-only: PrivacyMap and TrustBackupOffDisk exclude it from exports and backups.
public enum ActivityWatchPaths {
    /// Use a distinct directory so event-feed selection never includes ambient history.
    public static let directoryName = "activity_watch"

    public static func directory(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func databaseURL(dataRoot: URL) -> URL {
        directory(dataRoot: dataRoot).appendingPathComponent("activity_spans.sqlite")
    }

    public static func policyURL(dataRoot: URL) -> URL {
        directory(dataRoot: dataRoot).appendingPathComponent("activity_policy.json")
    }

    public static func retentionStateURL(dataRoot: URL) -> URL {
        directory(dataRoot: dataRoot).appendingPathComponent("activity_retention_state.json")
    }

}
