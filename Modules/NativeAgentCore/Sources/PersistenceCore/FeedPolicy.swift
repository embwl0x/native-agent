import Foundation
// Blueprint: | `FeedPolicy.swift` | `JSONLLineCaps`, `JSONLPathOwnedCapPolicy`; Path-owned retention budgets. |

public enum JSONLLineCaps {
    public static let activityEvents = 5000
    public static let activityTrimTargetLines = 4000
    /// Reserve samples per event kind so chat-heavy FIFO retention cannot erase rare diagnostic evidence.
    public static let activityMinimumRowsPerKind = 8
    /// Marks activity for amortized line checks; this soft trigger is not a byte ceiling.
    public static let activityTrimTriggerBytes = 4 * 1024 * 1024
    /// Model-call first outputs kept per key by provider vitals.
    public static let traceEvents = 5000
    /// The largest model-call trace row a writer builds (the record's detail bound matches it).
    public static let traceMaximumBytes = 8 * 1024 * 1024

    public static let actionReceipts = 5000
    public static let slackReceipts = 5000
    public static let telegramReceipts = 5000
    public static let receiptTrimTargetLines = 4000
    /// Soft trigger for amortized receipt line checks, with 1,000 rows of trim headroom.
    public static let receiptTrimTriggerBytes = 4 * 1024 * 1024
    public static let telegramBlocked = 5000

    /// Desk receipts are display/idempotency evidence; base and tail own truth.
    public static let deskArchive = 5000

    /// Inbox retention archives first and exempts held deliveries; destructive JSONL tail trimming is forbidden. The journal is a life record; its cap is only
    /// a runaway backstop.
    public static let studioJournal = 100_000

    /// Canon decisions are a life record; their cap is only a runaway backstop.
    public static let studioCanon = 20_000

    /// Check inherited files on first append, then each stride, bounding overshoot independently of row size. Hard byte ceilings still apply on every append.
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

/// Retention belongs to the path because multiple subsystems co-write feeds; callers must not copy local budgets.
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
    if file == "events.jsonl", parent == "activity" {
        return JSONLPathOwnedCapPolicy(
            maxLines: JSONLLineCaps.activityEvents,
            minimumRowsPerKind: JSONLLineCaps.activityMinimumRowsPerKind,
            trimWhenBytesExceed: JSONLLineCaps.activityTrimTriggerBytes,
            trimToLines: JSONLLineCaps.activityTrimTargetLines
        )
    }
    if file == "journal.jsonl",
       parent == "journal",
       path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "studio" {
        // This small feed has only a line budget, so each append can evaluate it directly.
        return JSONLPathOwnedCapPolicy(maxLines: JSONLLineCaps.studioJournal)
    }
    if file == "canon.jsonl",
       parent == "canon",
       path.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "studio" {
        return JSONLPathOwnedCapPolicy(maxLines: JSONLLineCaps.studioCanon)
    }
    return nil
}
