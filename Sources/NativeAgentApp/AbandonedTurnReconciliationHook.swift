import Foundation
import PersistenceCore

/// Bounded terminal reconciliation: once at launch, and after a completed turn
/// (throttled), never during one.
///
/// A3 / audit (2026-09-11): 33 accepted turns since Aug 29 have no terminal row
/// of any kind — a process that died mid-turn wrote neither an outcome nor an
/// error, so the turn reads as accepted forever. The sweep writes the one row
/// the evidence supports and replays nothing.
///
/// GPT-5.6 round review (2026-09-11): the trigger used to be the per-provider
/// usage receipt, which fires MID TOOL LOOP. A long productive turn whose last
/// provider call crossed the 6h ceiling could therefore stamp itself abandoned
/// before writing its real terminal. The trigger is now the completed-turn
/// boundary, and the sweep waits for trace persistence to settle first so the
/// terminal it is about to look for is actually on disk.
@MainActor
enum AbandonedTurnReconciliationHook {
    /// The sweep reads at most three day files and writes at most 25 rows, so
    /// the throttle is about not repeating pointless work, not about cost.
    private static let minimumIntervalSeconds: TimeInterval = 300

    private static var observer: NSObjectProtocol?
    private static var lastSweepAt: Date?
    private static var running = false

    static func arm() {
        guard observer == nil else { return }
        // Pin the process epoch at launch: only turns accepted BEFORE it are
        // ever reconcilable.
        _ = AbandonedTurnReconciler.processEpoch
        observer = NotificationCenter.default.addObserver(
            forName: .chatTurnCompleted,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sweepIfDue() }
        }
        sweepIfDue()
    }

    private static func sweepIfDue() {
        guard !running else { return }
        let now = Date()
        if let lastSweepAt, now.timeIntervalSince(lastSweepAt) < minimumIntervalSeconds {
            return
        }
        lastSweepAt = now
        running = true
        Task.detached(priority: .utility) {
            // Let the finished turn's own terminal row reach disk before the
            // sweep reads the day files looking for it.
            await TurnTraceBus.shared.drainForProcessExit()
            let outcome = await AbandonedTurnReconciler().sweep()
            await MainActor.run { running = false }
            guard !outcome.reconciled.isEmpty else { return }
            FileHandle.standardError.write(
                Data(
                    ("AbandonedTurnReconciler: wrote \(outcome.reconciled.count) abandoned"
                        + " terminal row(s) across \(outcome.acceptedScanned) accepted turn(s)\n").utf8
                )
            )
        }
    }
}
