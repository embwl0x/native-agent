import Foundation
// Blueprint: | `FeedPolicy.swift` | `JSONLLineCaps`, `JSONLPathOwnedCapPolicy`; shared trace envelope/retention and native-power browser/action receipt retention; local backup/export/raw phone exclusions, selected telemetry projection and Traces privacy scope; appendPathOwnedJSONL is the existing mutation owner |

/// Shared line-cap constants for append-only JSONL feeds.
public enum JSONLLineCaps {
    /// `<dataRoot>/activity/events.jsonl` — shared activity feed.
    public static let activityEvents = 5000
    public static let activityTrimTargetLines = 4000
    /// Within the fixed activity line budget, retain the newest small sample
    /// of every event kind. The shared feed is dominated by chat/history rows;
    /// plain FIFO would erase one-off approval, provider, skill, and security
    /// evidence at the next trim even though those are the rows most useful for
    /// diagnosing a disconnected subsystem.
    public static let activityMinimumRowsPerKind = 8
    /// Marks activity for amortized line checks; this soft trigger is not a byte ceiling.
    public static let activityTrimTriggerBytes = 4 * 1024 * 1024
    /// `<dataRoot>/traces/events.jsonl` — shared cross-subsystem trace feed.
    /// Shared path-owned trace mutations retain producer envelopes; selected telemetry
    /// reaches the phone, but raw traces are excluded from local/off-disk backups,
    /// production export and raw phone sync. PrivacyMap: traces.
    public static let traceEvents = 5000
    public static let traceTrimTargetLines = 4000
    /// Soft trigger for amortized trace line checks; byte limits are separate.
    public static let traceTrimTriggerBytes = 4 * 1024 * 1024
    /// Diagnostic feeds have both a row budget and a hard byte ceiling. The
    /// lower byte target leaves space for ordinary appends after a rotation.
    public static let traceMaximumBytes = 8 * 1024 * 1024
    public static let traceTrimTargetBytes = 4 * 1024 * 1024

    /// `<dataRoot>/security/audit.jsonl` — SecurityCenter tool-policy receipts.
    public static let securityAudit = 20_000
    /// Soft line-check trigger; SecurityCenter archives pre-trim evidence before its first trim.
    public static let securityAuditTrimTriggerBytes = 16 * 1024 * 1024
    /// Leave row headroom after trimming the audit ledger.
    public static let securityAuditTrimTargetLines = 16_000
    /// `<dataRoot>/mac_control_audit.jsonl` — blocked Mac-control receipts.
    public static let macControlAudit = 20_000
    /// `<dataRoot>/native_power/browser/receipts.jsonl` and
    /// `<dataRoot>/native_power/actions/receipts.jsonl`.
    public static let actionReceipts = 5000
    /// `<dataRoot>/logs/background_loop_failures.jsonl` — operational loop
    /// failures surfaced through `LoopTickOutcome`.
    public static let backgroundLoopFailures = 5000
    /// `~/.config/claude-bridge/claude-inbox.jsonl` — durable bridge inbox rows.
    public static let claudeBridgeInbox = 5000
    public static let ompBridgeInbox = 5000
    /// `<dataRoot>/slack/receipts.jsonl`, `errors.jsonl`, `ignored.jsonl` —
    /// Socket Mode loop ledgers.
    public static let slackReceipts = 5000
    /// `<dataRoot>/telegram/receipts.jsonl` — Telegram reply and voice receipts.
    public static let telegramReceipts = 5000
    public static let receiptTrimTargetLines = 4000
    /// Soft trigger for amortized receipt line checks, with 1,000 rows of trim headroom.
    public static let receiptTrimTriggerBytes = 4 * 1024 * 1024
    /// `<dataRoot>/telegram/blocked.jsonl` — bounded admission/drop evidence.
    public static let telegramBlocked = 5000

    /// `<dataRoot>/desk/desk_archive.jsonl` — display/idempotency receipts; base+tail owns truth.
    public static let deskArchive = 5000

    /// LiveNotificationInbox owns the live notification feed's 500-row cap and
    /// 30-day finished-card cutoff, archiving every eviction before removal.
    /// It must never use destructive JSONL tail retention.
    /// `<dataRoot>/studio/journal/journal.jsonl` — append-only life record; cap is a runaway backstop.
    public static let studioJournal = 100_000

    /// `<dataRoot>/studio/canon/canon.jsonl` — append-only decisions; cap is a runaway backstop.
    public static let studioCanon = 20_000

    /// Byte threshold below which the turn-trace feed skips its line count
    /// entirely (see `enforceJSONLRetention(trimWhenBytesExceed:)`). Sized so the
    /// per-turn append never reads a multi-megabyte file just to learn it is
    /// under the 20k-line cap.
    public static let turnTraceTrimTriggerBytes = 8 * 1024 * 1024
    /// Hard daily trace ceiling with hysteresis. Crossing 12 MiB retains the
    /// newest whole rows that fit in 8 MiB, avoiding an 8+ MiB rewrite on every
    /// subsequent append while bounding fourteen retained days to 168 MiB.
    public static let turnTraceMaximumBytes = 12 * 1024 * 1024
    public static let turnTraceTrimTargetBytes = 8 * 1024 * 1024

    /// How often amortized `appendJSONLCapped` feeds evaluate the LINE cap in
    /// full, in appends-per-path. An inherited over-cap file is checked first;
    /// afterwards the row trigger can overshoot by at most 127 appends. The
    /// explicit byte ceiling, when configured, still applies after every append.
    /// Stride checkpoints ignore soft byte triggers, bounding row overshoot
    /// independently of row size with at most one full read per stride.
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
    if file == "receipts.jsonl", ["browser", "actions"].contains(parent),
       path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "native_power" {
        return JSONLPathOwnedCapPolicy(maxLines: JSONLLineCaps.actionReceipts)
    }
    if file == "receipts.jsonl", parent == "telegram" {
        return JSONLPathOwnedCapPolicy(
            maxLines: JSONLLineCaps.telegramReceipts,
            trimWhenBytesExceed: JSONLLineCaps.receiptTrimTriggerBytes,
            trimToLines: JSONLLineCaps.receiptTrimTargetLines
        )
    }
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
