import Foundation
import PersistenceCore

/// The ONE place the watcher's on-disk home is named.
///
/// **Why it is not `<dataRoot>/activity/`** (which is what v0 used): that
/// directory already belongs to a different, older feature — the app's activity
/// *events* feed (`activity/events.jsonl`, traces, receipts, runtime audit
/// rows). It is declared `exportable: true` in the Trust Center privacy map, it
/// is copied verbatim into support bundles
/// (`NativeClient+TrustBackupOps.supportBundleRelativePaths`), and a user
/// clicking "export my data" gets it. Dropping a record of every window the
/// human looked at into that directory would have opted the whole feature into
/// three egress paths W6 explicitly forbids, silently, by filename collision.
///
/// So the watcher gets its own directory, and that directory appears in NO
/// backup, export, support-bundle, or iCloud/CloudKit snapshot list.
/// `ActivityWatchArchitectureTests.activityStoreIsExcludedFromSyncAndBackup`
/// asserts exactly that, by reading those lists out of the app sources.
public enum ActivityWatchPaths {
    /// Directory name under the data root. Deliberately NOT "activity".
    ///
    /// 2026-09-06: the literal itself moved to `HumanPresenceStamp` in
    /// PersistenceCore, because the trigger scheduler has to name this
    /// directory to read the presence stamp and it may not link this module.
    /// This is still the file that EXPLAINS the name; there is still exactly
    /// one string.
    public static let directoryName = HumanPresenceStamp.activityWatchDirectoryName

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

    /// The human-presence stamp (2026-09-06). Deliberately NOT a table in the
    /// spans database: the trigger scheduler reads it synchronously from
    /// inside a flock and must never open this module's SQLite store.
    public static func presenceStampURL(dataRoot: URL) -> URL {
        HumanPresenceStamp.url(dataRoot: dataRoot)
    }
}
