import SwiftUI
import Foundation
import os

// Blueprint: | `TranscriptLayoutProbe.swift` | `TranscriptLayoutProbe`: opt-in per-row layout measurement and bounded diagnostic ledger, without changing transcript content |

/// Measures per-row layout calls and wall time only with `NATIVEAGENT_TRANSCRIPT_LAYOUT_PROBE=1`; otherwise leaves content untouched.
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

    /// Logs the ranked window and clears the counters. Called from the
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

        do {
            let data = try JSONSerialization.data(withJSONObject: record)
            let line = String(decoding: data, as: UTF8.self)
            Self.logger.info("transcript layout: \(line, privacy: .public)")
        } catch {
            Self.logger.error("Transcript layout diagnostic could not be encoded: \(error.localizedDescription, privacy: .public)")
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
