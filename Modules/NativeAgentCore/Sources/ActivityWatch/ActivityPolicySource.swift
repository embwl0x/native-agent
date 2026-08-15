import Foundation

/// Where a RUNNING watcher re-reads its policy from.
///
/// **Why this exists** (live-run defect, 2026-08-14): the "instant pause"
/// guarantee held only for the in-app Trust Center toggle, which calls
/// `ActivityWatcher.updatePolicy` directly. Any OUT-OF-BAND write to
/// `activity_watch/activity_policy.json` — `activity-probe policy --disable`,
/// a second process, a user editing the file, a restore — was invisible to a
/// watcher that was already running. A live run proved it: capture was disabled
/// on disk and 40 further seconds of app switching still added 4 rows.
///
/// The watcher polls this from its existing 60 s tick (and on every activation),
/// so the bound is: **an out-of-band disable takes effect within one tick.**
///
/// ONE-WAY BY CONSTRUCTION. What comes back from here is a SAFETY VALVE, not a
/// control channel: `ActivityWatcher.pollPolicySource` clamps it so it can only
/// ever make capture less permissive (never enable, never un-exclude, never
/// re-enable titles). The reason is this file's own decoder — every missing key
/// defaults, so a torn write of `{"captureEnabled":true}` decodes as a perfectly
/// valid ENABLED policy with default exclusions. See `ActivityWatcher.safelyPolled`.
public protocol ActivityPolicySource: Sendable {
    /// The policy, but ONLY when the underlying source changed since the last
    /// call. `nil` means "unchanged — do not decode, do not re-apply".
    ///
    /// Returning nil on no-change is the contract, not an optimisation: the
    /// caller runs this on the capture thread once a minute and once per app
    /// switch, and a JSON decode on every one of those would be a real cost for
    /// a file that changes a handful of times a year.
    func reloadIfChanged() -> ActivityPolicy?
}

/// `ActivityPolicySource` backed by the policy JSON file in `activity_watch/`.
///
/// CHEAP BY CONSTRUCTION: every poll is a single `stat`. The file is only opened
/// and decoded when its modification date or size actually moved.
///
/// The path is never hardcoded — it comes from
/// `ActivityWatchPaths.policyURL(dataRoot:)` via `ActivityPolicyStore`, so this
/// watches the same file the Trust Center and the probe CLI write.
public final class ActivityPolicyFileSource: ActivityPolicySource, @unchecked Sendable {
    /// Modification date + size + existence. Deliberately not a content hash:
    /// hashing means reading, and not reading is the entire point.
    ///
    /// Honest limit: a rewrite landing in the same filesystem timestamp tick
    /// AND producing a byte-identical size would be missed. APFS timestamps are
    /// nanosecond-resolution, and the writer is an atomic replace, so this is
    /// theoretical rather than a live hazard — and the failure mode is one
    /// missed poll, not a wrong policy, because the next real change re-syncs.
    private struct Stamp: Equatable {
        var exists: Bool
        var modified: Double
        var size: Int64
    }

    private let store: ActivityPolicyStore
    private let lock = NSLock()
    private var lastStamp: Stamp?

    public init(dataRoot: URL) {
        self.store = ActivityPolicyStore(dataRoot: dataRoot)
    }

    public init(store: ActivityPolicyStore) {
        self.store = store
    }

    public var fileURL: URL { store.fileURL }

    /// Records the file's current stamp WITHOUT reporting a change, so a watcher
    /// constructed with a policy it just loaded does not immediately re-apply
    /// that same policy on its first poll.
    public func prime() {
        let current = stamp()
        lock.lock()
        lastStamp = current
        lock.unlock()
    }

    public func reloadIfChanged() -> ActivityPolicy? {
        let current = stamp()
        lock.lock()
        let unchanged = lastStamp == current
        lastStamp = current
        lock.unlock()
        guard !unchanged else { return nil }
        // Missing / unreadable / garbage → `ActivityPolicyStore.load()`'s SAFE
        // default, which is capture OFF. A policy file we cannot read must
        // never fail open into capturing.
        return store.load()
    }

    private func stamp() -> Stamp {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: store.fileURL.path)
        else {
            return Stamp(exists: false, modified: 0, size: 0)
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return Stamp(exists: true, modified: modified, size: size)
    }
}
