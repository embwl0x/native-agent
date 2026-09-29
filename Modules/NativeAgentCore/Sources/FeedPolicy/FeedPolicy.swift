import Foundation

/// Shared line-cap constants for append-only JSONL feeds.
public enum JSONLLineCaps {
    /// `<dataRoot>/activity/events.jsonl` — same budget traces/events.jsonl
    /// got in 12126ef2. Activity was the ownerless leftover with NO rotation
    /// anywhere post-daemon.
    public static let activityEvents = 5000
    public static let activityTrimTargetLines = 4000
    /// Within the fixed activity line budget, retain the newest small sample
    /// of every event kind. The shared feed is dominated by chat/history rows;
    /// plain FIFO would erase one-off approval, provider, skill, and security
    /// evidence at the next trim even though those are the rows most useful for
    /// diagnosing a disconnected subsystem.
    public static let activityMinimumRowsPerKind = 8
    /// Marks activity as an amortized feed. The shared writer evaluates its
    /// row budget on the first/every128th append, then retains4k rows. This is
    /// a soft scheduling hint, not a hard byte ceiling.
    public static let activityTrimTriggerBytes = 4 * 1024 * 1024
    /// `<dataRoot>/traces/events.jsonl` — shared cross-subsystem trace feed.
    public static let traceEvents = 5000
    public static let traceTrimTargetLines = 4000
    /// Trace line checks use the same bounded stride as activity. Byte limits
    /// below are separate and are evaluated on every append.
    public static let traceTrimTriggerBytes = 4 * 1024 * 1024
    /// Diagnostic feeds have both a row budget and a hard byte ceiling. The
    /// lower byte target leaves space for ordinary appends after a rotation.
    public static let traceMaximumBytes = 8 * 1024 * 1024
    public static let traceTrimTargetBytes = 4 * 1024 * 1024

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
    /// 2026-09-22: trimming to exactly the 20k cap left a mature ledger one
    /// stride from the next 16 MiB rewrite (~10x/day). Trimming to 16k leaves
    /// 4k rows of headroom, so it rewrites every few days.
    public static let securityAuditTrimTargetLines = 16_000
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

    /// How often amortized `appendJSONLCapped` feeds evaluate the LINE cap in
    /// full, in appends-per-path. An inherited over-cap file is checked first;
    /// afterwards the row trigger can overshoot by at most127 appends. The
    /// explicit byte ceiling, when configured, still applies after every append.
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

public struct JSONLPathOwnedCapPolicy: Sendable, Equatable {
    public var minimumRowsPerKind: Int?
    public var maxLines: Int
    public var trimWhenBytesExceed: Int?
    public var trimToLines: Int?
    public var maxBytes: Int?
    public var trimToBytes: Int?

    public init(
        maxLines: Int,
        minimumRowsPerKind: Int? = nil,
        trimWhenBytesExceed: Int? = nil,
        trimToLines: Int? = nil,
        maxBytes: Int? = nil,
        trimToBytes: Int? = nil
    ) {
        self.minimumRowsPerKind = minimumRowsPerKind
        self.maxLines = maxLines
        self.trimWhenBytesExceed = trimWhenBytesExceed
        self.trimToLines = trimToLines
        self.maxBytes = maxBytes
        self.trimToBytes = trimToBytes
    }
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
            trimWhenBytesExceed: JSONLLineCaps.traceTrimTriggerBytes,
            trimToLines: JSONLLineCaps.traceTrimTargetLines,
            maxBytes: JSONLLineCaps.traceMaximumBytes,
            trimToBytes: JSONLLineCaps.traceTrimTargetBytes
        )
    }
    if file == "events.jsonl", parent == "activity" {
        return JSONLPathOwnedCapPolicy(
            maxLines: JSONLLineCaps.activityEvents,
            minimumRowsPerKind: JSONLLineCaps.activityMinimumRowsPerKind,
            trimWhenBytesExceed: JSONLLineCaps.activityTrimTriggerBytes,
            trimToLines: JSONLLineCaps.activityTrimTargetLines
        )
    }
    if file == "audit.jsonl", parent == "security" {
        return JSONLPathOwnedCapPolicy(
            maxLines: JSONLLineCaps.securityAudit,
            trimWhenBytesExceed: JSONLLineCaps.securityAuditTrimTriggerBytes,
            trimToLines: JSONLLineCaps.securityAuditTrimTargetLines
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
