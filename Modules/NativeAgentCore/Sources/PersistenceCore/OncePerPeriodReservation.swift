import Foundation

/// Outcome of a `reserveOncePerPeriod` attempt.
public enum OncePerPeriodReservation: Sendable {
    /// This tick won the slot. `stamp` is the exact marker value this
    /// reservation wrote. `rollback` restores the marker's prior contents
    /// (or removes it if it was absent) — but ONLY when the marker still
    /// holds OUR stamp, compare-and-restore under the same flock.
    case reserved(stamp: String, rollback: @Sendable () async -> Void)
    /// The current period is already reserved by an earlier tick; skip.
    case alreadyReserved
    /// Marker IO, decoding, locking, or stamping failed. Periodic work must
    /// fail closed rather than run without a durable exclusion claim.
    case failed(Error)
}

/// Dependency-neutral, cross-process check-and-stamp for periodic work.
///
/// PersistenceCore owns this primitive because both lower-level organs (for
/// example DreamREMCycle) and BackgroundLoops need the same durable exclusion
/// boundary. Keeping it in a loop module forced lower-level organs to hand-roll
/// weaker copies or create a dependency cycle.
public func reserveOncePerPeriod(
    at marker: URL,
    stamp: String,
    core: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
    isFresh: @Sendable (_ stored: String?) throws -> Bool
) async -> OncePerPeriodReservation {
    do {
        // Capture prior bytes INSIDE the same claim lock. Reading them before
        // lock admission creates a stale-rollback race: another process can
        // stamp between the read and our claim, after which our failed work
        // would restore a marker older than the claim we actually replaced.
        let claim = try await core.withFileLock(marker) { () -> (reserved: Bool, prior: Data?) in
            let prior: Data?
            let stored: String?
            if FileManager.default.fileExists(atPath: marker.path) {
                let data = try Data(contentsOf: marker)
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw PersistenceCoreError.ioFailure(
                        "period marker is not valid UTF-8: \(marker.path)"
                    )
                }
                prior = data
                stored = decoded
            } else {
                prior = nil
                stored = nil
            }
            if try isFresh(stored) { return (false, prior) }
            guard let stampData = stamp.data(using: .utf8) else {
                throw PersistenceCoreError.ioFailure("could not encode period marker stamp")
            }
            try stampData.write(to: marker, options: .atomic)
            return (true, prior)
        }
        guard claim.reserved else { return .alreadyReserved }
        let prior = claim.prior
        return .reserved(stamp: stamp, rollback: {
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
                FileHandle.standardError.write(Data(
                    "OncePerPeriodReservation: rollback failed for \(marker.lastPathComponent): \(error)\n".utf8
                ))
            }
        })
    } catch {
        return .failed(error)
    }
}

/// Period-keyed convenience: reserve iff the stored key differs from `key`.
public func reserveOncePerPeriod(
    key: String,
    at marker: URL,
    core: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
) async -> OncePerPeriodReservation {
    await reserveOncePerPeriod(at: marker, stamp: key, core: core) { $0 == key }
}
