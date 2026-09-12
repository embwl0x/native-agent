import Foundation
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import ProviderRouting

/// ONE doctor snapshot refresh after this launch's first completed turn.
///
/// A3 / audit finding 10 (2026-09-11): auto-doctor runs WEEKLY by default, so
/// `data/doctor/latest.json` is in practice the launch snapshot — written
/// seconds after the process started, before a single turn existed. Every check
/// that measures turn behaviour (prompt prefix reuse, the cognitive capsule,
/// tool-array stability) can only report UNMEASURED in it, which is honest but
/// useless: the one reading that would have caught the cross-turn cache misses
/// was a row that said "0 rows in window".
///
/// BOUNDED BY CONSTRUCTION: one observer, one run, then it removes itself. No
/// loop, no cadence change, and the persisted auto-doctor toggle is still
/// honoured because the refresh goes through the same configured loop the
/// scheduler mounts.
///
/// GPT-5.6 round review (2026-09-11): the trigger used to be the per-provider
/// usage receipt, which fires on the FIRST provider call of a multi-call tool
/// loop — so the one-shot snapshot could be taken mid turn and miss the tool
/// failures, schema churn and terminal outcome it exists to expose. Its
/// replacement, `.chatTurnCompleted`, was no better: that is an overloaded UI
/// refresh notification and transcript compaction posts it with no turn behind
/// it, which could consume the one-shot observer before the first real turn.
/// The trigger is now `.turnTraceTerminalPersisted`, posted by the trace lane
/// itself once a turn's terminal row is on disk — so the observer is kept
/// until a REAL terminal is seen, and the rows Doctor reads are already
/// written. Still exactly once per launch.
@MainActor
enum DoctorFirstTurnRefresh {
    private static var observer: NSObjectProtocol?
    private static var didRun = false

    static func arm() {
        guard observer == nil, !didRun else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .turnTraceTerminalPersisted,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { fire() }
        }
    }

    private static func fire() {
        guard !didRun else { return }
        didRun = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Task.detached(priority: .utility) {
            // The completed turn's trace rows are persisted off the turn path;
            // Doctor reads those files, so settle them first.
            await TurnTraceBus.shared.drainForProcessExit()
            // `freshMeasurement` is the whole point of this refresh. Without it
            // the two behavioural checks replay the 60-second memo they stored
            // at launch — "zero rows since launch" — and this path republishes
            // that under a new timestamp, having never opened the files it just
            // drained (Astra audit 2026-09-11 finding 6).
            let outcome = await BackgroundLoopsAssembly
                .makeAutoDoctorLoop(freshMeasurement: true)
                .tickOutcome()
            if case .failed(let error) = outcome {
                FileHandle.standardError.write(
                    Data("DoctorFirstTurnRefresh: refresh failed: \(error)\n".utf8)
                )
            }
        }
    }
}
