import Foundation

/// The single source of truth for the per-execution record filename inside
/// `<dataRoot>/workshop/executions/<id>/`.
///
/// De-mission wave P2-1 renamed that file from `mission.json` to
/// `execution.json`. `WorkshopStorageMigrator` performs the one-time on-disk
/// rename at launch, but the rename can be incomplete for two reasons that
/// outlive a single launch: a crash mid-pass, and an execution directory that
/// arrives AFTER the pass ran (an iCloud straggler syncing a pre-rename dir, a
/// restored backup). So every reader resolves the name instead of hardcoding
/// it, and every existence probe accepts EITHER name — a probe that only knew
/// the canonical name would classify an unmigrated record directory as "no
/// record here", which is the one misreading that silently drops work
/// (reservation sweep leaks a slot, Desk renders an empty bench).
///
/// Writers never choose: they call `resolve(in:)`, which returns the canonical
/// name on a directory that has neither file, so every NEW record lands as
/// `execution.json`.
///
/// FENCE: this moves the FILENAME only. Every serialized JSON key
/// (`missionId` / `mission_id` / `missionPolicy` / `related_mission_id`),
/// event kind, surface string and tool name is a compatibility wire ID and
/// stays exactly as it is.
public enum ExecutionRecordFile {
    /// Name every new record is written under.
    public static let canonicalName = "execution.json"

    /// Pre-P2-1 name. Still read; never written.
    public static let legacyName = "mission.json"

    /// Canonical (write-target) path inside an execution directory.
    public static func canonicalPath(in directory: URL) -> URL {
        directory.appendingPathComponent(canonicalName)
    }

    /// Legacy path inside an execution directory. Migration/tests only.
    public static func legacyPath(in directory: URL) -> URL {
        directory.appendingPathComponent(legacyName)
    }

    /// The record path to read from / write to for `directory`.
    ///
    /// Canonical wins when both exist (the migrator's conflict branch moves the
    /// stale legacy file aside, so "both present" is a transient state at
    /// worst). Falls back to the legacy name for an unmigrated directory, and
    /// returns the canonical name when neither exists so a fresh write lands on
    /// the new name.
    public static func resolve(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let canonical = canonicalPath(in: directory)
        if fileManager.fileExists(atPath: canonical.path) { return canonical }
        let legacy = legacyPath(in: directory)
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return canonical
    }

    /// True when `directory` holds a record under EITHER name.
    ///
    /// Use this for every "is this a record directory?" probe. Checking only
    /// the canonical name would misclassify an unmigrated directory as empty.
    public static func exists(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: canonicalPath(in: directory).path)
            || fileManager.fileExists(atPath: legacyPath(in: directory).path)
    }
}
