import Foundation

// Blueprint: | `ActivityWatchPaths.swift` | `ActivityWatchPaths`: one directory and file vocabulary for private ambient history, separate from activity event feeds |

/// The ONE place the watcher's on-disk home is named.
///
/// **Why it is not `<dataRoot>/activity/`** (which is what v0 used): that
/// directory already belongs to a different, older feature — the app's activity
/// *events* feed (`activity/events.jsonl`) and its runtime receipts. Support
/// bundles select that feed; data exports do not.
/// Ambient window history must stay outside that selected feed.
///
/// So the watcher gets its own directory, and that directory appears in NO
/// backup, export, support-bundle, or iCloud/CloudKit snapshot list.
/// `ActivityWatchArchitectureTests.activityStoreIsExcludedFromSyncAndBackup`
/// asserts exactly that, by reading those lists out of the app sources.
public enum ActivityWatchPaths {
    /// Directory name under the data root. Deliberately NOT "activity".
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
