import Foundation
import Darwin
import NativeAgentCore

// MARK: - JSONL line cap (U5 W-G, 2026-06-11)

/// Shared line-cap constants for append-only JSONL feeds.
public enum JSONLLineCaps {
    /// `<dataRoot>/activity/events.jsonl` — same budget traces/events.jsonl
    /// got in 12126ef2. Activity was the ownerless leftover with NO rotation
    /// anywhere post-daemon.
    public static let activityEvents = 5000
    /// Within the fixed activity line budget, retain the newest small sample
    /// of every event kind. The shared feed is dominated by chat/history rows;
    /// plain FIFO would erase one-off approval, provider, skill, and security
    /// evidence at the next trim even though those are the rows most useful for
    /// diagnosing a disconnected subsystem.
    public static let activityMinimumRowsPerKind = 8
    /// Amortizes activity rotation: below this size append remains O(1). Once
    /// crossed, the newest line-cap is restored under the existing feed lock.
    public static let activityTrimTriggerBytes = 4 * 1024 * 1024
    /// `<dataRoot>/traces/events.jsonl` — shared cross-subsystem trace feed.
    public static let traceEvents = 5000
    /// Amortizes trace rotation the same way activity does: under the trigger
    /// append stays O(1), above it the newest retained window is restored.
    public static let traceTrimTriggerBytes = 4 * 1024 * 1024

    // M6 (honesty sweep, 2026-07-09): six audit/receipt ledgers appended
    // forever with no rotation anywhere. Their sibling `workflows/runs.json`
    // WAS capped, so the intent existed — the sweep just never reached these.
    // Audit-class feeds keep a deeper history than receipt-class ones because
    // they are the record of what was allowed to touch the machine.

    /// `<dataRoot>/security/audit.jsonl` — SecurityCenter tool-policy receipts.
    public static let securityAudit = 20_000
    /// Security audit appends stay synchronous and durable, but line-cap
    /// evaluation is amortized behind this bounded byte trigger. Without it,
    /// every tool call rereads the entire multi-megabyte audit ledger merely to
    /// discover that it is still below `securityAudit`. Crossing the trigger
    /// performs the existing locked newest-20k trim; below it, append cost is
    /// independent of accumulated audit history.
    ///
    /// F5 (2026-08-28): 32 MiB never fired in practice — the live file sat at
    /// 23 MiB / 33k rows, 1.65x past the row cap, because typical rows are
    /// small enough that the byte trigger lagged the line budget badly. 16 MiB
    /// makes the trigger reachable; SecurityCenter archives the pre-trim file
    /// once (`security/audit-archive-<date>.jsonl`) before the first trim so
    /// the accumulated history is not lost.
    public static let securityAuditTrimTriggerBytes = 16 * 1024 * 1024
    /// `<dataRoot>/mac_control_audit.jsonl` — blocked Mac-control receipts.
    public static let macControlAudit = 20_000
    /// `<dataRoot>/native_power/browser/receipts.jsonl` and
    /// `<dataRoot>/native_power/actions/receipts.jsonl`.
    public static let actionReceipts = 5000
    // `<dataRoot>/workflows/runs.jsonl` had a 5000-line cap here. The workflow
    // run engine was retired 2026-09-01 (User authorized) and nothing appends to
    // that feed any more; the file stays on disk as frozen history.
    // `<dataRoot>/logs/maintenance_sweep.jsonl` had a 20,000-line cap here. The
    // maintenance pass stopped writing it 2026-09-01 (User's call): 2,921 rows /
    // 613 KB had accumulated with no production reader. The retention work
    // itself is unchanged; the file stays on disk as frozen history.
    /// `<dataRoot>/logs/background_loop_failures.jsonl` — operational loop
    /// failures surfaced through `LoopTickOutcome`.
    public static let backgroundLoopFailures = 5000
    /// `<dataRoot>/memory/retention_receipts.jsonl` — hard-bound evictions.
    public static let memoryRetentionReceipts = 5000
    /// `<dataRoot>/training/journal/audit_ledger.jsonl`.
    public static let trainingAudit = 5000
    /// `~/.config/claude-bridge/message-replies.jsonl` — best-effort bridge
    /// diagnostics; the canonical transcript and completion lifecycle live
    /// elsewhere and must not be duplicated without a bound.
    public static let bridgeMessageReplies = 5000
    /// `~/.config/claude-bridge/claude-inbox.jsonl` — Agent → Claude
    /// durable inbox rows (audit 2026-07-21: raw uncapped append; same
    /// budget as the other bridge feeds).
    public static let claudeBridgeInbox = 5000
    public static let ompBridgeInbox = 5000
    /// `<dataRoot>/slack/receipts.jsonl`, `errors.jsonl`, `ignored.jsonl` —
    /// Socket Mode loop ledgers (audit 2026-07-21: raw uncapped appends).
    public static let slackReceipts = 5000
    /// `<dataRoot>/telegram/receipts.jsonl` — per-turn Telegram reply/voice
    /// receipts. Two raw appenders (recordReceipt, recordVoiceTranscription)
    /// grew this unbounded (1.6MB live, tightness round 2 P-M1); route both
    /// through `appendJSONLCapped` at this budget, the sibling of the already
    /// capped `errors.jsonl` (TelegramErrorLog).
    public static let telegramReceipts = 5000
    /// `<dataRoot>/telegram/blocked.jsonl` — bounded admission/drop evidence.
    public static let telegramBlocked = 5000
    /// `<dataRoot>/memory/<persona>/notes.jsonl` — Telegram `/note` captures
    /// (TelegramSessionStore.appendNote). Bare append until tightness round 2
    /// P-L4; a receipt-class ledger, same budget as the rest.
    public static let telegramNotes = 5000

    /// `<dataRoot>/desk/desk_archive.jsonl` — archived Desk item records
    /// (audit 2026-07-21): the module's last uncapped JSONL. The op-log's
    /// base+tail is the canonical truth; archive records are a receipt-class
    /// display/idempotency feed, so they take the standard receipt budget.
    public static let deskArchive = 5000

    /// `<dataRoot>/notifications/inbox.jsonl` — the LIVE inbox card feed the Mac
    /// UI and the iOS snapshot read — deliberately has NO budget here.
    ///
    /// It had one (1000 lines, added by the 2026-07-21 audit) and three writers
    /// passed it to `appendJSONLCapped`. That was a latent data-loss bug, not
    /// retention: `enforceJSONLLineCap` keeps a `suffix(maxLines)`, so the first
    /// append past 1,000 lines would have HARD-DELETED the oldest cards — an
    /// unread one included — with nothing kept anywhere.
    ///
    /// Retention for this feed is owned by `LiveNotificationInbox` (2026-08-31):
    /// a 500-row cap plus a 30-day cutoff on finished cards, and every evicted
    /// row is moved to `notifications/inbox_archive.jsonl` before it leaves. All
    /// three writers now append through that actor. The constant is gone rather
    /// than merely unused so a future writer cannot reach the destructive route
    /// by reaching for a symbol that looks like the feed's policy.
    /// `<dataRoot>/harness/benchmark/runs.jsonl` — bounded recent benchmark
    /// trend history. This is a receipt-class feed; older benchmark runs are
    /// not the source of truth for any live state.
    public static let harnessBenchmarkRuns = 5000

    /// `<dataRoot>/studio/journal/journal.jsonl` — the agent's aesthetic
    /// journal. DELIBERATELY 20x the receipt-class budget: this is a curated
    /// life record, not telemetry. Entries are written a handful of times a
    /// WEEK by hand, so 100k lines is centuries of a saturated cadence, and the
    /// cap exists only as a runaway-writer backstop — never as retention. The
    /// journal's own contract is additive-only, and nothing in the product may
    /// rely on this trim to bound it.
    public static let studioJournal = 100_000

    /// `<dataRoot>/studio/canon/canon.jsonl` — the museum's promote/demote
    /// ledger. Deliberate acts of tending, a handful a year at most, so this is
    /// a runaway-writer backstop and never retention: like the journal, the
    /// canon's promise is that a decided row never ceases to exist.
    public static let studioCanon = 20_000

    /// Byte threshold below which the turn-trace feed skips its line count
    /// entirely (see `enforceJSONLLineCap(trimWhenBytesExceed:)`). Sized so the
    /// per-turn append never reads a multi-megabyte file just to learn it is
    /// under the 20k-line cap.
    public static let turnTraceTrimTriggerBytes = 8 * 1024 * 1024
    /// Hard daily trace ceiling with hysteresis. Crossing 12 MiB retains the
    /// newest whole rows that fit in 8 MiB, avoiding an 8+ MiB rewrite on every
    /// subsequent append while bounding fourteen retained days to 168 MiB.
    public static let turnTraceMaximumBytes = 12 * 1024 * 1024
    public static let turnTraceTrimTargetBytes = 8 * 1024 * 1024

    // `<dataRoot>/mobile_push/receipts.jsonl` had a 5,000-line budget here
    // (C8, 2026-08-28). RETIRED 2026-09-01 (sweep item 21): the APNs writer is
    // gone — no production code ever read the feed back, the receipt is
    // returned to the caller instead — so a cap on it would bound nothing. The
    // existing rows stay on disk as history and nothing appends to them.

    /// How often `appendJSONLCapped` evaluates the LINE cap in full, in
    /// appends-per-path, regardless of `trimWhenBytesExceed`.
    ///
    /// F8 (2026-08-28): the byte trigger alone DEFEATS the line cap. Live
    /// `activity/events.jsonl` sat at 4,822 of its 5,000-line budget at 3.0 MB
    /// — under the 4 MB trigger, so `enforceJSONLLineCap` returned 0 without
    /// ever counting lines, and the feed would have run to ~6,700 lines (134%
    /// of its cap) before the byte trigger let the line cap fire at all. The
    /// stride restores the line budget as the binding constraint while keeping
    /// the append amortized: at most one full re-read per stride appends per
    /// path, so the overshoot is bounded by the stride, not by row size.
    public static let capCheckStride = 128
}

/// Per-path append counter driving `JSONLLineCaps.capCheckStride`. Process-local
/// and deliberately not persisted: a fresh process checks on its first append to
/// each path, which is exactly when an inherited over-cap file needs trimming.
final class JSONLCapCheckCounter: @unchecked Sendable {
    static let shared = JSONLCapCheckCounter()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// True when this append should evaluate the line cap in full (ignoring any
    /// byte trigger). Fires on the 1st, (stride+1)th, … append to `path`.
    /// Bound on distinct tracked paths. The production feed set is a couple of
    /// dozen fixed paths, but `appendJSONLCapped` also serves per-session and
    /// per-run files, so an unbounded map would creep in a long-lived process.
    /// Overflowing simply forgets the counts — the only cost is one extra full
    /// cap evaluation per path afterwards, which is the SAFE direction.
    private static let maximumTrackedPaths = 4096

    func isFullCheckDue(path: URL, stride: Int) -> Bool {
        guard stride > 1 else { return true }
        let key = path.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if counts.count >= Self.maximumTrackedPaths, counts[key] == nil {
            counts.removeAll(keepingCapacity: true)
        }
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        return next % stride == 1
    }

    /// Read-only preview used by pre-trim evidence owners. The caller holds
    /// the path's file lock, so no same-path capped append can advance between
    /// this preview and the later consuming `isFullCheckDue` call. Keeping the
    /// preview non-mutating also means a failed append does not spend a stride.
    func isFullCheckDueOnNextAppend(path: URL, stride: Int) -> Bool {
        guard stride > 1 else { return true }
        let key = path.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if counts.count >= Self.maximumTrackedPaths, counts[key] == nil {
            return true
        }
        let next = (counts[key] ?? 0) + 1
        return next % stride == 1
    }

    /// Test seam: forget the per-path history so a fresh temp path starts at 1.
    func _testReset() {
        lock.lock(); defer { lock.unlock() }
        counts.removeAll()
    }
}

/// Trim a JSONL file to its newest `maxLines` lines. Returns the number of
/// lines dropped (0 when under the cap or the file is missing). The CALLER
/// must hold the file's flock — this helper is the trim step of an
/// append-then-cap sequence and does no locking of its own (mirrors the
/// notification-inbox 1000-line recipe). Never silent: callers log the
/// returned drop count.
///
/// H3/M6 (2026-07-09): the size check happens FIRST. This helper used to read
/// the entire file into memory on every append just to discover it was under the
/// cap — quadratic on an append-only feed, and it did that read while holding the
/// feed's flock on the chat turn path (a 20k-line trace file meant ~18MB read per
/// appended row). Two cheap `stat`-based early-outs now short-circuit it:
///   - `trimWhenBytesExceed`: an optional soft trigger. Below it the cap is not
///     evaluated at all, so appends are amortized O(1) and the file stays bounded
///     by that byte budget instead of being re-counted every row. Callers that
///     need the exact newest-`maxLines` invariant after EVERY append omit it.
///   - an exact lower bound: a file of `n` bytes holds at most `n` lines (every
///     line but the last carries a newline), so `size < maxLines` cannot be over
///     the cap. Sound for every caller, no semantic change.
@discardableResult
public func enforceJSONLLineCap(
    at path: URL,
    maxLines: Int,
    trimWhenBytesExceed: Int? = nil
) throws -> Int {
    guard maxLines > 0, FileManager.default.fileExists(atPath: path.path) else { return 0 }
    // An unstattable-but-present file falls through to the full read rather than
    // silently skipping the cap.
    if let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue {
        if size == 0 { return 0 }
        if let trigger = trimWhenBytesExceed, size < trigger { return 0 }
        if size < maxLines { return 0 }
    }
    let data = try Data(contentsOf: path)
    guard let s = String(data: data, encoding: .utf8) else {
        // U5 fix-round (2026-06-11, gpt-5.5 NIT): never silent — a non-UTF8
        // feed means the cap cannot run, which the state-lifecycle rule says
        // must be visible, not a quiet `return 0`.
        NSLog("enforceJSONLLineCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    guard lines.count > maxLines else { return 0 }
    let dropped = lines.count - maxLines
    let trimmed = lines.suffix(maxLines).joined(separator: "\n") + "\n"
    // Durable rewrite: the append that preceded this trim was fsync'd, so the
    // trim must not be the weak link — a bare .atomic write + replaceItemAt
    // can commit the rename before the data blocks on power loss, leaving the
    // feed truncated with the old contents already unlinked.
    try SwiftNativePersistenceCore.atomicWrite(Data(trimmed.utf8), to: path)
    return dropped
}

/// Activity-specific line retention. Keeps the total budget unchanged while
/// reserving the newest `minimumRowsPerKind` rows for every decodable `kind`.
/// Remaining slots are the newest rows globally. Output stays in original
/// chronological order, malformed rows still survive when they are recent,
/// and no other JSONL feed inherits this policy.
@discardableResult
func enforceActivityEventsLineCap(
    at path: URL,
    maxLines: Int,
    minimumRowsPerKind: Int = JSONLLineCaps.activityMinimumRowsPerKind,
    trimWhenBytesExceed: Int? = nil
) throws -> Int {
    guard maxLines > 0,
          minimumRowsPerKind > 0,
          FileManager.default.fileExists(atPath: path.path) else { return 0 }
    if let size = ((try? FileManager.default.attributesOfItem(
        atPath: path.path
    ))?[.size] as? NSNumber)?.intValue {
        if size == 0 { return 0 }
        if let trigger = trimWhenBytesExceed, size < trigger { return 0 }
        if size < maxLines { return 0 }
    }
    let data = try Data(contentsOf: path)
    guard let text = String(data: data, encoding: .utf8) else {
        NSLog("enforceActivityEventsLineCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    guard lines.count > maxLines else { return 0 }

    var reserved = Set<Int>()
    var retainedPerKind: [String: Int] = [:]
    for index in lines.indices.reversed() {
        guard let row = try? JSONValue.parse(Data(lines[index].utf8)),
              case .object(let object) = row,
              case .string(let rawKind)? = object["kind"] else { continue }
        let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, retainedPerKind[kind, default: 0] < minimumRowsPerKind else {
            continue
        }
        reserved.insert(index)
        retainedPerKind[kind, default: 0] += 1
    }

    var kept = Set(lines.indices.suffix(maxLines))
    kept.formUnion(reserved)
    while kept.count > maxLines {
        if let oldestUnreserved = kept.sorted().first(where: { !reserved.contains($0) }) {
            kept.remove(oldestUnreserved)
        } else if let oldest = kept.min() {
            // More distinct kinds than the entire line budget: remain bounded
            // and prefer the newest reserved evidence deterministically.
            kept.remove(oldest)
        } else {
            break
        }
    }
    let ordered = kept.sorted().map { lines[$0] }
    let dropped = lines.count - ordered.count
    guard dropped > 0 else { return 0 }
    try SwiftNativePersistenceCore.atomicWrite(
        Data((ordered.joined(separator: "\n") + "\n").utf8),
        to: path
    )
    return dropped
}

/// Trim a JSONL file to the newest whole rows that fit within `trimToBytes`
/// once it crosses `maxBytes`. The caller must hold the file's flock. The
/// lower target provides hysteresis so a busy feed does not reread/rewrite the
/// entire file on every append after reaching its ceiling.
@discardableResult
public func enforceJSONLByteCap(
    at path: URL,
    maxBytes: Int,
    trimToBytes: Int
) throws -> Int {
    guard maxBytes > 0,
          trimToBytes > 0,
          trimToBytes <= maxBytes,
          FileManager.default.fileExists(atPath: path.path) else {
        return 0
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue
    guard size.map({ $0 > maxBytes }) != false else { return 0 }
    let data = try Data(contentsOf: path)
    guard data.count > maxBytes else { return 0 }
    guard let text = String(data: data, encoding: .utf8) else {
        NSLog("enforceJSONLByteCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    var keptReversed: [Substring] = []
    var keptBytes = 0
    for line in lines.reversed() {
        let lineBytes = line.utf8.count + 1
        if !keptReversed.isEmpty, keptBytes + lineBytes > trimToBytes {
            break
        }
        // A single row should already be bounded by its owner. Preserve the
        // newest row even if a corrupt/legacy row exceeds the target so the
        // cap never replaces the feed with an empty file.
        keptReversed.append(line)
        keptBytes += lineBytes
        if keptBytes >= trimToBytes { break }
    }
    let kept = keptReversed.reversed()
    let dropped = max(0, lines.count - kept.count)
    guard dropped > 0 else { return 0 }
    let trimmed = kept.joined(separator: "\n") + "\n"
    // Same durable rewrite as enforceJSONLLineCap — see the note there.
    try SwiftNativePersistenceCore.atomicWrite(Data(trimmed.utf8), to: path)
    return dropped
}

/// U5 fix-round (2026-06-11, gpt-5.5 review): THE shared capped-append for
/// JSONL activity-style feeds. Appends `event` to `path`, then trims the file
/// to its newest `maxLines` lines, logging what the rotation dropped. Every
/// live `activity/events.jsonl` writer routes through here so no append path
/// can grow the feed unbounded again (PersonaEngine doc-save emit, Skills,
/// Executions, SchedulerDueJobRunner).
///
/// Locking: when `takeLock` is true (default) the append+cap runs under
/// `withFileLock(path)` — for EVERY conformer, not just the SwiftNative impl —
/// so the cap's read-trim-replace cannot race a concurrent capped writer. Callers
/// that already hold the events-feed flock pass `takeLock: false` to avoid
/// double-acquiring it.
public func appendJSONLCapped(
    _ event: JSONValue,
    to path: URL,
    using persistence: any PersistenceCoreProtocol,
    maxLines: Int = JSONLLineCaps.activityEvents,
    logLabel: String,
    takeLock: Bool = true,
    trimWhenBytesExceed: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil,
    capCheckStride: Int = JSONLLineCaps.capCheckStride,
    // When the feed is a RECORD rather than telemetry, the append has to be on
    // the platter before this call returns. `appendBytes` refuses a raw durable
    // append to a path-owned feed, so the durable route has to run here, inside
    // the permit — a caller cannot get both guarantees any other way.
    durable: Bool = false,
    beforePotentialLineCap: (@Sendable () async throws -> Void)? = nil
) async throws {
    // F2 (2026-08-28): when the FILE owns its retention, the table wins over
    // whatever budget this call site remembered to pass. A mismatch is logged
    // rather than silently accepted so a stale local constant is visible.
    let policy = jsonlPathOwnedCapPolicy(for: path)
    if let policy, policy.maxLines != maxLines {
        NSLog("%@: %@ has a path-owned cap of %d line(s) — ignoring the call site's %d",
              logLabel, path.lastPathComponent, policy.maxLines, maxLines)
    }
    let effectiveMaxLines = policy?.maxLines ?? maxLines
    let effectiveTrimTrigger = policy?.trimWhenBytesExceed ?? trimWhenBytesExceed
    let work: @Sendable () async throws -> Void = {
        // Decide once, before the append, whether this call can enter the
        // full-read line-cap path. Owners that must preserve pre-trim evidence
        // use the hook to archive at exactly the same amortized checkpoints;
        // they must not independently reread a multi-megabyte feed on every
        // append merely in case this is the one that trims.
        let fullCheckWillBeDue = JSONLCapCheckCounter.shared.isFullCheckDueOnNextAppend(
            path: path, stride: capCheckStride
        )
        if let beforePotentialLineCap {
            let reachesByteTrigger: Bool
            if let effectiveTrimTrigger {
                let currentBytes = ((try? FileManager.default.attributesOfItem(
                    atPath: path.path
                ))?[.size] as? NSNumber)?.intValue
                let appendedBytes = (try? event.serialize(pretty: false).utf8.count + 1)
                reachesByteTrigger = currentBytes == nil
                    || appendedBytes == nil
                    || currentBytes! + appendedBytes! >= effectiveTrimTrigger
            } else {
                reachesByteTrigger = true
            }
            if fullCheckWillBeDue || reachesByteTrigger {
                try await beforePotentialLineCap()
            }
        }
        try await JSONLPathOwnedAppendPermit.$isInsideCappedAppend.withValue(true) {
            if durable {
                try await persistence.appendJSONLDurable(event, to: path)
            } else {
                try await persistence.appendJSONL(event, to: path)
            }
        }
        // F2 note above applies to WHICH cap; this decides WHEN it is counted.
        // On a stride append the byte trigger is dropped so the line budget is
        // actually evaluated — otherwise a feed whose rows are smaller than
        // `trigger / maxLines` never reaches the trigger at its line cap and
        // grows past it (F8: activity/events.jsonl, 4,822/5,000 lines at 3.0 MB
        // against a 4 MB trigger).
        let fullCheckDue = JSONLCapCheckCounter.shared.isFullCheckDue(
            path: path, stride: capCheckStride
        )
        let dropped: Int
        if path.lastPathComponent == "events.jsonl",
           path.deletingLastPathComponent().lastPathComponent == "activity" {
            dropped = try enforceActivityEventsLineCap(
                at: path,
                maxLines: effectiveMaxLines,
                trimWhenBytesExceed: fullCheckDue ? nil : effectiveTrimTrigger
            )
        } else {
            dropped = try enforceJSONLLineCap(
                at: path,
                maxLines: effectiveMaxLines,
                trimWhenBytesExceed: fullCheckDue ? nil : effectiveTrimTrigger
            )
        }
        if dropped > 0 {
            NSLog("%@: %@ cap dropped %d oldest line(s)",
                  logLabel, path.lastPathComponent, dropped)
        }
        if let maxBytes {
            let byteDropped = try enforceJSONLByteCap(
                at: path,
                maxBytes: maxBytes,
                trimToBytes: trimToBytes ?? maxBytes
            )
            if byteDropped > 0 {
                NSLog("%@: %@ byte cap dropped %d oldest line(s)",
                      logLabel, path.lastPathComponent, byteDropped)
            }
        }
    }
    if takeLock {
        // L7 (2026-08-01 audit): this used to downcast to
        // `SwiftNativePersistenceCore` and, on failure, append UNROTATED with no
        // log — a silent fallback that quietly disabled every line/byte cap for
        // any other conformer, letting the feed grow without bound while the
        // call still reported success. The downcast was also gratuitous:
        // `withFileLock` is a PersistenceCoreProtocol EXTENSION
        // (PersistenceCore+FileLock.swift:4), so every conformer already has it,
        // and it locks a local `<path>.lock` sidecar with flock independent of
        // the append backend. The `takeLock: false` branch below has always run
        // the cap for arbitrary conformers, so refusing to run it here was
        // internally inconsistent too. Now uniform: lock, append, cap — and a
        // lock-acquire failure THROWS rather than degrading in silence.
        try await persistence.withFileLock(path, work)
    } else {
        // Caller already holds the events-feed flock.
        try await work()
    }
}

public struct JSONLPathOwnedCapPolicy: Sendable, Equatable {
    public var maxLines: Int
    public var trimWhenBytesExceed: Int?

    public init(
        maxLines: Int,
        trimWhenBytesExceed: Int? = nil
    ) {
        self.maxLines = maxLines
        self.trimWhenBytesExceed = trimWhenBytesExceed
    }
}

public enum JSONLPathOwnedAppendError: Error, Equatable {
    case unregisteredPath(String)
    /// A raw (uncapped) append reached a file whose retention is path-owned.
    /// F2 (2026-08-28): the registry used to be opt-in at the CALL SITE, so the
    /// invariant "this feed is capped" held only as long as every writer
    /// remembered to use `appendPathOwnedJSONL`. It is now enforced at the one
    /// byte-writer every append funnels through, so forgetting fails loudly at
    /// the first write instead of silently growing the feed forever.
    case rawAppendToPathOwnedFeed(String)
}

/// Permit for the sanctioned capped-append route. Set ONLY by
/// `appendJSONLCapped` around the inner raw append; read by
/// `SwiftNativePersistenceCore.appendBytes`. Task-local rather than a flag on
/// the type so it cannot leak across concurrent appends.
enum JSONLPathOwnedAppendPermit {
    @TaskLocal static var isInsideCappedAppend: Bool = false
}

/// Path-owned JSONL retention registry.
///
/// Some feeds are co-written by multiple subsystems. Their retention policy is
/// a property of the FILE, not whichever caller remembered to name a cap at the
/// append site. This resolver keeps those budgets in one chokepoint so new
/// writers can opt in by path rather than copy-pasting another local constant.
public func jsonlPathOwnedCapPolicy(for path: URL) -> JSONLPathOwnedCapPolicy? {
    let file = path.lastPathComponent
    let parent = path.deletingLastPathComponent().lastPathComponent
    if file == "events.jsonl", parent == "traces" {
        return JSONLPathOwnedCapPolicy(
            maxLines: JSONLLineCaps.traceEvents,
            trimWhenBytesExceed: JSONLLineCaps.traceTrimTriggerBytes
        )
    }
    if file == "events.jsonl", parent == "activity" {
        return JSONLPathOwnedCapPolicy(
            maxLines: JSONLLineCaps.activityEvents,
            trimWhenBytesExceed: JSONLLineCaps.activityTrimTriggerBytes
        )
    }
    if file == "runs.jsonl",
       parent == "benchmark",
       path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "harness" {
        return JSONLPathOwnedCapPolicy(maxLines: JSONLLineCaps.harnessBenchmarkRuns)
    }
    if file == "journal.jsonl",
       parent == "journal",
       path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "studio" {
        // No byte trigger: the line budget is the ONLY constraint, and the feed
        // is small enough that evaluating it costs nothing.
        return JSONLPathOwnedCapPolicy(maxLines: JSONLLineCaps.studioJournal)
    }
    if file == "canon.jsonl",
       parent == "canon",
       path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "studio" {
        return JSONLPathOwnedCapPolicy(maxLines: JSONLLineCaps.studioCanon)
    }
    return nil
}

/// Append through the path-owned cap registry. An unregistered path fails loud
/// so a typo or newly introduced writer cannot silently bypass retention.
/// Callers that already hold the feed lock pass `takeLock:false`.
public func appendPathOwnedJSONL(
    _ event: JSONValue,
    to path: URL,
    using persistence: any PersistenceCoreProtocol,
    logLabel: String,
    takeLock: Bool = true,
    durable: Bool = false,
    // Passthrough to `appendJSONLCapped`'s pre-trim hook, for the owners whose
    // feed must not lose a row to a trim. It throws to STOP the append.
    beforePotentialLineCap: (@Sendable () async throws -> Void)? = nil
) async throws {
    guard let policy = jsonlPathOwnedCapPolicy(for: path) else {
        throw JSONLPathOwnedAppendError.unregisteredPath(path.standardizedFileURL.path)
    }
    try await appendJSONLCapped(
        event,
        to: path,
        using: persistence,
        maxLines: policy.maxLines,
        logLabel: logLabel,
        takeLock: takeLock,
        trimWhenBytesExceed: policy.trimWhenBytesExceed,
        durable: durable,
        beforePotentialLineCap: beforePotentialLineCap
    )
}
