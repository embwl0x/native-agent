import SwiftUI
import Foundation
import os

/// Per-row layout cost for the chat transcript.
///
/// The 04:05 pin (2026-09-04) had no app code in it: `NSHostingView`
/// `beginTransaction` → `updateGraph` → nested `StackLayout` →
/// `StyledTextLayoutEngine`, 3,393 `sizeThatFits` frames in one sample. A
/// stack trace names the engine but not the ROW, so it cannot say whether the
/// cost is one 12-KB markdown reply re-measured eighty times or eighty rows
/// measured once. This probe answers exactly that: it counts `sizeThatFits`
/// calls and sums their wall time per row, so a soak on the real pinned thread
/// produces a ranked ledger instead of another anonymous engine frame.
///
/// OFF BY DEFAULT AND INERT WHEN OFF. Enabled only by
/// `NATIVEAGENT_TRANSCRIPT_LAYOUT_PROBE=1` in the environment, read once at
/// launch. When disabled the modifier returns `content` untouched, so the
/// shipped view tree is byte-for-byte what it is today — no extra `Layout`
/// node, no timing, no allocation. This is a measuring instrument, not a fix.
enum TranscriptLayoutProbe {
    /// Read once: a per-measure `ProcessInfo` lookup would itself be a cost in
    /// the hot path the probe is trying to measure.
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["NATIVEAGENT_TRANSCRIPT_LAYOUT_PROBE"] == "1"
    }()

    /// What the row is, so the ledger can separate a markdown bubble from an
    /// image bubble from a collapsed tool stack without re-deriving it later.
    enum RowKind: String {
        case bubble
        case toolRow
        case toolGroup
        case approval
        case toolPill
    }
}

/// The counters. Main-actor only in practice — SwiftUI layout runs on the main
/// thread — but guarded anyway so a stray off-thread measure cannot corrupt
/// totals and quietly produce a plausible, wrong ledger.
final class TranscriptLayoutLedger: @unchecked Sendable {
    static let shared = TranscriptLayoutLedger()

    struct RowCost {
        var kind: String
        var measures: Int = 0
        var totalNanos: UInt64 = 0
        var maxNanos: UInt64 = 0
    }

    private let lock = NSLock()
    private var rows: [String: RowCost] = [:]
    private var windowStartedAt = Date()
    private var lastFlushedAt = Date()

    /// Rows kept per flush window. The ledger is a diagnosis aid, not an
    /// archive: the tail of a long transcript is what pins, and an unbounded
    /// dictionary in the hot path would be its own leak.
    private static let maximumRowsPerWindow = 400
    private static let flushInterval: TimeInterval = 5

    private static let logger = Logger(
        subsystem: "com.nativeagent.app",
        category: "transcript-layout"
    )

    private init() {}

    /// Test seam: the current window's counters, without flushing them. The
    /// ledger's whole value is that its numbers are real, so they have to be
    /// readable by something other than the file it writes.
    func snapshotForTesting() -> [String: RowCost]? {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    static var maximumRowsPerWindowForTesting: Int { maximumRowsPerWindow }

    func record(rowID: String, kind: String, nanos: UInt64) {
        lock.lock()
        if rows[rowID] == nil, rows.count >= Self.maximumRowsPerWindow {
            lock.unlock()
            return
        }
        var cost = rows[rowID] ?? RowCost(kind: kind)
        cost.measures += 1
        cost.totalNanos &+= nanos
        cost.maxNanos = max(cost.maxNanos, nanos)
        rows[rowID] = cost
        let shouldFlush = Date().timeIntervalSince(lastFlushedAt) >= Self.flushInterval
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// Writes one JSON line per window and clears the counters. Called from the
    /// record path on a timer boundary and safe to call by hand.
    func flush() {
        lock.lock()
        guard !rows.isEmpty else {
            lastFlushedAt = Date()
            lock.unlock()
            return
        }
        let snapshot = rows
        let started = windowStartedAt
        rows = [:]
        windowStartedAt = Date()
        lastFlushedAt = Date()
        lock.unlock()

        let totalMeasures = snapshot.values.reduce(0) { $0 + $1.measures }
        let totalNanos = snapshot.values.reduce(UInt64(0)) { $0 &+ $1.totalNanos }
        let ranked = snapshot
            .sorted { $0.value.totalNanos > $1.value.totalNanos }
            .prefix(12)
            .map { id, cost -> [String: Any] in
                [
                    "row": id,
                    "kind": cost.kind,
                    "measures": cost.measures,
                    "total_ms": Double(cost.totalNanos) / 1_000_000,
                    "max_ms": Double(cost.maxNanos) / 1_000_000,
                ]
            }

        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "window_s": Date().timeIntervalSince(started),
            "rows": snapshot.count,
            "measures": totalMeasures,
            "total_ms": Double(totalNanos) / 1_000_000,
            "top": ranked,
        ]

        Self.logger.info(
            "transcript layout: \(snapshot.count, privacy: .public) rows, \(totalMeasures, privacy: .public) measures, \(Double(totalNanos) / 1_000_000, privacy: .public) ms"
        )

        guard
            let data = try? JSONSerialization.data(withJSONObject: record),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        append(line)
    }

    private func append(_ line: String) {
        let url = NativeAgentPaths.dataRoot
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("transcript_layout.jsonl")
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bytes = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: .atomic)
        }
    }
}

/// A single-subview `Layout` that passes the proposal straight through and
/// returns the child's own size, so the measured tree lays out exactly as it
/// would without it — the only difference is that `sizeThatFits` is timed.
struct TranscriptRowLayoutMeter: Layout {
    let rowID: String
    let kind: String

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let start = DispatchTime.now().uptimeNanoseconds
        let size = subview.sizeThatFits(proposal)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        TranscriptLayoutLedger.shared.record(rowID: rowID, kind: kind, nanos: elapsed)
        return size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: proposal
        )
    }
}

extension View {
    /// Wraps a transcript row in the meter when the probe is on; returns the
    /// row unchanged when it is off.
    @ViewBuilder
    func transcriptLayoutProbe(
        rowID: String,
        kind: TranscriptLayoutProbe.RowKind
    ) -> some View {
        if TranscriptLayoutProbe.isEnabled {
            TranscriptRowLayoutMeter(rowID: rowID, kind: kind.rawValue) {
                self
            }
        } else {
            self
        }
    }
}
