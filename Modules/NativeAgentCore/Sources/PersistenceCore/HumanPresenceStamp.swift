import Foundation

/// 2026-09-06: whether a PERSON is at this Mac — as distinct from "has the chat
/// been quiet", which is all the idle trigger could see before.
///
/// One tiny file, `<dataRoot>/activity_watch/last_input.json`, written by the
/// ActivityWatch tick (at most once a minute) and read synchronously by the
/// trigger scheduler.
///
/// **Why a file and not the spans database.** The ActivityWatch spans store is
/// GRDB SQLite and is deliberately walled off: nothing outside the
/// `ActivityWatch` module may open it, and `ActivityWatchArchitectureTests`
/// pins that. The scheduler could not read it even if it were allowed —
/// `scheduledInstantIfDue` is a `nonisolated`, SYNCHRONOUS recompute running
/// inside the state-file flock, where there is no actor hop and no room for a
/// SQLite open. So the watcher PUBLISHES the one scalar an idle trigger needs,
/// next to the database the scheduler may not read, and the wall stands.
///
/// **Egress.** The file lives inside `activity_watch/`, the directory that
/// already appears in no backup, export, support-bundle or iCloud list (see
/// `ActivityWatchPaths`), so the stamp inherits that exclusion for free. It
/// carries two timestamps and an away flag and nothing else — no app, no
/// window, no title. That is what lets the writer keep publishing while the
/// person works in a PRIVACY-EXCLUDED app (2026-09-06): the stamp records only
/// "human input at time T", never which app produced it, so refreshing it
/// there discloses nothing the exclusion is meant to withhold.
///
/// **The transition file.** `presence_transition.json` sits beside the stamp
/// and is touched ONLY when the person crosses present <-> away. The stamp
/// itself moves every minute and is far too noisy to wake a background loop
/// on; the transition file changes a handful of times a day and is exactly the
/// edge the trigger scheduler has to recompute its next crossing at.
public struct HumanPresenceStamp: Sendable, Equatable {
    /// The watcher's on-disk directory under the data root. The literal lives
    /// here because BOTH sides of the wall need it and only one of them may
    /// link `ActivityWatch`; `ActivityWatchPaths.directoryName` — which carries
    /// the full justification for why the directory is not `activity/` — is
    /// defined from this constant, so there is still exactly one string.
    public static let activityWatchDirectoryName = "activity_watch"
    public static let fileName = "last_input.json"
    /// Touched only on a present <-> away crossing — see the type's note.
    public static let transitionFileName = "presence_transition.json"

    /// The last input the writer could positively attribute to a HUMAN. The
    /// agent's own synthesized motor events are excluded by the writer; this is
    /// never "something moved the mouse".
    public let lastInputAt: Date

    /// When this stamp was last refreshed. Load-bearing: `lastInputAt` alone
    /// cannot distinguish "the person left an hour ago" from "the writer died
    /// an hour ago", and those must not produce the same answer.
    public let writtenAt: Date

    /// The writer's last word on whether the person is AT the Mac. `true` is
    /// only ever written as a FINAL stamp at a lock or sleep edge: the screen
    /// locked, so the person is away as of `lastInputAt`, and no further stamp
    /// will be written until they are back. It is the difference between "the
    /// person left" and "the writer died", which is why such a stamp is
    /// believed past `freshness` and an ordinary one is not.
    public let away: Bool

    /// How stale an ORDINARY stamp may be and still be believed. The writer
    /// refreshes on the watcher's 60 s tick, so five minutes absorbs a few
    /// missed ticks (a slow disk, a coalesced timer) without ever letting a
    /// STOPPED watcher — capture switched off, the app killed — pass for a
    /// person who walked away. The lock and sleep edges do not rely on this:
    /// they write a final `away` stamp, which is believed for as long as it
    /// stands (see `away`).
    public static let freshness: TimeInterval = 300

    /// Minimum gap between writes. The tick is already a minute, but the tick
    /// interval is injectable, and this file is not worth an unbounded write rate.
    public static let writeInterval: TimeInterval = 60

    /// How far ahead of the reader's clock a `writtenAt` may sit and still be
    /// read as a real write rather than a clock that moved. Seconds, not
    /// minutes: writer and reader are the same machine, so anything beyond
    /// ordinary jitter is a clock step and the file is untrusted (2026-09-06 —
    /// this used to be `abs(...) <= freshness`, i.e. five minutes of the
    /// future, which the comment beside it already said it would not accept).
    public static let futureTolerance: TimeInterval = 5

    /// Largest stamp this reader will even open. A regular file of two
    /// timestamps is ~100 bytes; 4 KiB is orders of magnitude of slack. The
    /// read runs inside the trigger scheduler's state-file flock, where an
    /// unbounded `Data(contentsOf:)` on a fifo, a device node, or a huge file
    /// dropped in that directory would hold the cross-process lock (2026-09-06).
    public static let maximumFileSize = 4096

    public init(lastInputAt: Date, writtenAt: Date, away: Bool = false) {
        self.lastInputAt = lastInputAt
        self.writtenAt = writtenAt
        self.away = away
    }

    public static func url(dataRoot: URL) -> URL {
        directory(dataRoot: dataRoot).appendingPathComponent(fileName)
    }

    /// The present <-> away crossing file. Watched by the trigger scheduler's
    /// event loop; the per-minute stamp deliberately is NOT.
    public static func transitionURL(dataRoot: URL) -> URL {
        directory(dataRoot: dataRoot).appendingPathComponent(transitionFileName)
    }

    /// The transition file beside a stamp whose URL is already known — the
    /// writer holds one URL, not the data root.
    public static func transitionURL(besideStampAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(transitionFileName)
    }

    private static func directory(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(activityWatchDirectoryName, isDirectory: true)
    }

    // MARK: - Read (the trigger scheduler's side)

    /// The last human input instant this data root can VOUCH for, or nil.
    ///
    /// nil means "unknown", never "nobody is here": a missing file (the feature
    /// has never run), one that is not an ordinary small regular file, an
    /// unparseable one, one written ahead of this clock, or a stale one all
    /// return nil so the caller falls back to whatever signal it had before.
    /// Fail-open in the direction that cannot invent an absence.
    public static func lastHumanInputInstant(dataRoot: URL, reference: Date) -> Date? {
        guard let stamp = read(dataRoot: dataRoot) else { return nil }
        let age = reference.timeIntervalSince(stamp.writtenAt)
        // A stamp from the future is a clock that moved, not a fresher truth.
        guard age >= -futureTolerance else { return nil }
        // An AWAY stamp is the writer's deliberate last word at a lock or sleep
        // edge, not a frozen tick from a writer that died, so it stays true for
        // as long as it stands — the watcher overwrites it the moment the
        // person is back. Every other stamp has to be fresh.
        guard stamp.away || age <= freshness else { return nil }
        // A `lastInputAt` past `reference` would read as negative idleness
        // downstream; clamp to "active right now", which suppresses rather than
        // fires.
        return min(stamp.lastInputAt, reference)
    }

    public static func read(dataRoot: URL) -> HumanPresenceStamp? {
        read(at: url(dataRoot: dataRoot))
    }

    public static func read(at url: URL) -> HumanPresenceStamp? {
        // STAT FIRST (2026-09-06). This runs inside the trigger scheduler's
        // state-file flock: only an ordinary small regular file is opened, so
        // a fifo, a device node, a directory or an oversized file left in
        // `activity_watch/` cannot block or balloon the locked section.
        var info = stat()
        guard stat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumFileSize else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lastRaw = object["last_input_at"] as? String,
              let writtenRaw = object["written_at"] as? String,
              let last = parseTimestamp(lastRaw),
              let written = parseTimestamp(writtenRaw) else { return nil }
        return HumanPresenceStamp(
            lastInputAt: last, writtenAt: written, away: object["away"] as? Bool ?? false
        )
    }

    // MARK: - Write (the ActivityWatch side)

    /// Atomic replace. Returns false on any failure — the caller keeps going;
    /// a stamp that could not be written degrades to the fallback path, which
    /// is the behaviour that shipped before this file existed.
    @discardableResult
    public func write(to url: URL) -> Bool {
        let body: [String: Any] = [
            "last_input_at": Self.formatTimestamp(lastInputAt),
            "written_at": Self.formatTimestamp(writtenAt),
            "away": away,
        ]
        return Self.atomicallyPublish(body, to: url)
    }

    /// Touch the present <-> away crossing file. One line of state, written
    /// only at a crossing, so a background loop can watch it without waking
    /// once a minute for the stamp (2026-09-06).
    @discardableResult
    public static func writeTransition(present: Bool, at date: Date, to url: URL) -> Bool {
        atomicallyPublish([
            "at": formatTimestamp(date),
            "state": present ? "present" : "away",
        ], to: url)
    }

    /// 2026-09-06: was `Data.write(.atomic)`, which leaves the mode to the
    /// process umask — 0644 on a default Mac. Both files live under the data
    /// root and go through PersistenceCore's canonical writer instead: 0600
    /// temp, fsync, rename, 0600 target.
    private static func atomicallyPublish(_ body: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys]
        ) else { return false }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        do {
            try SwiftNativePersistenceCore.atomicWrite(data, to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Timestamps

    static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
