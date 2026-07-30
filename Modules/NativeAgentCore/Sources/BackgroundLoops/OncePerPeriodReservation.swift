import Foundation
import PersistenceCore

/// Outcome of a `reserveOncePerPeriod` attempt.
public enum OncePerPeriodReservation: Sendable {
    /// This tick won the slot. `stamp` is the exact marker value this
    /// reservation wrote. `rollback` restores the marker's prior contents
    /// (or removes it if it was absent) — but ONLY when the marker still
    /// holds OUR stamp, compare-and-restore under the same flock, so a
    /// concurrent re-claim is never clobbered. Call it when the guarded
    /// work FAILED, so the next tick retries this period.
    case reserved(stamp: String, rollback: @Sendable () async -> Void)
    /// The current period is already reserved by an earlier tick; skip.
    case alreadyReserved
    /// The marker IO / lock failed. The caller decides whether to surface this
    /// as `.failed` or a soft skip.
    case failed(Error)
}

/// Check-and-stamp a marker file under its cross-process file lock so a unit of
/// periodic work runs AT MOST ONCE per period across every driver — a BGTask
/// wake and the in-app scheduler can both fire the same loop, and without a
/// shared reservation a same-period double-tick double-runs the work.
///
/// This is the shared engine behind GoldenEvalLoop's weekly cohort,
/// WeeklySelfImprovementLoop's weekly pass, and AutonomyPromotionLoop's daily
/// scan — each previously hand-rolled the identical read → decide → stamp →
/// restore dance around `withFileLock`.
///
/// - `marker`: the reservation file (its `.lock` sibling is the lock target).
///   The parent directory must already exist (the lock acquisition also creates
///   it, but callers typically mkdir explicitly so a mkdir failure is surfaced).
/// - `stamp`: the value written to the marker on reservation.
/// - `isFresh`: given the currently-stored marker string (nil when the marker
///   is absent or unreadable), return true when this period is ALREADY covered
///   ⇒ skip. Runs INSIDE the lock, so a caller may perform a lock-scoped side
///   effect there (e.g. consuming a one-shot manual-run request) and may throw
///   to abort the reservation.
///
/// The prior marker bytes are captured before stamping so `.reserved` can
/// hand back a `rollback` restoring them; a caller that never needs
/// retry-on-failure simply ignores it. The rollback is async because the
/// restore runs under the marker's flock (compare-and-restore) — a `defer`
/// cannot await, so callers roll back explicitly on their failure paths.
public func reserveOncePerPeriod(
    at marker: URL,
    stamp: String,
    core: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
    isFresh: @Sendable (_ stored: String?) throws -> Bool
) async -> OncePerPeriodReservation {
    // Fail CLOSED on an unreadable EXISTING marker (gpt-5.5 review, MED): the
    // hand-rolled loops this replaced did. Treating exists-but-unreadable as
    // absent would (a) stamp over a live reservation and double-run the work,
    // and (b) leave `prior` nil so a later rollback DELETES the original
    // marker instead of restoring it. Absent stays absent (nil).
    let prior: Data?
    do {
        prior = FileManager.default.fileExists(atPath: marker.path)
            ? try Data(contentsOf: marker)
            : nil
    } catch {
        return .failed(error)
    }
    do {
        let reserved = try await core.withFileLock(marker) { () -> Bool in
            let stored: String?
            if FileManager.default.fileExists(atPath: marker.path) {
                // Same fail-closed rule under the lock: an IO error must
                // surface as .failed, never as "absent → stamp anyway".
                stored = String(data: try Data(contentsOf: marker), encoding: .utf8)
            } else {
                stored = nil
            }
            if try isFresh(stored) { return false }
            guard let stampData = stamp.data(using: .utf8) else {
                throw NSError(domain: "OncePerPeriodReservation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "could not encode marker stamp"
                ])
            }
            try stampData.write(to: marker, options: .atomic)
            return true
        }
        guard reserved else { return .alreadyReserved }
        return .reserved(stamp: stamp, rollback: {
            // 2026-07-21 audit (MED): the rollback used to write/remove the
            // marker UNLOCKED and unconditionally — a newer claim a concurrent
            // driver stamped between our reservation and our failure got
            // clobbered, reopening the period for a double-run (the race
            // REMConsolidator's compare-and-restore fixed,
            // REMConsolidator.swift:241-246). Restore under the SAME flock,
            // and only when the marker still holds OUR stamp. A missing or
            // different marker means someone re-claimed: leave it alone.
            do {
                try await core.withFileLock(marker) {
                    guard let current = try? Data(contentsOf: marker),
                          String(data: current, encoding: .utf8) == stamp
                    else { return }
                    if let prior {
                        try prior.write(to: marker, options: .atomic)
                    } else {
                        try FileManager.default.removeItem(at: marker)
                    }
                }
            } catch {
                // Never silent (state-lifecycle rule): a failed restore leaves
                // the period consumed once, which a loud log can explain.
                FileHandle.standardError.write(Data(
                    "OncePerPeriodReservation: rollback failed for \(marker.lastPathComponent): \(error)\n".utf8
                ))
            }
        })
    } catch {
        return .failed(error)
    }
}

/// Period-keyed convenience: reserve iff the stored key differs from `key`
/// (i.e. the period rolled over). Equivalent to the `isFresh: { $0 == key }`
/// form. GoldenEvalLoop keys by ISO-week; any caller with a discrete period
/// bucket (day, week, month) can use this directly.
public func reserveOncePerPeriod(
    key: String,
    at marker: URL,
    core: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
) async -> OncePerPeriodReservation {
    await reserveOncePerPeriod(at: marker, stamp: key, core: core) { $0 == key }
}
