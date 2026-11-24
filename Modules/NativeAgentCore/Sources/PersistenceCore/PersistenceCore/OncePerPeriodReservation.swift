import Foundation

// Blueprint: | `OncePerPeriodReservation.swift` | `OncePerPeriodReservation`; Locked durable periodic admission. |

public enum OncePerPeriodReservation: Sendable {
    /// Restore prior marker bytes only while our exact stamp still holds under the same flock.
    case reserved(stamp: String, rollback: @Sendable () async -> Void)
    case alreadyReserved
    /// Persistence failures cannot admit periodic work without a durable exclusion claim.
    case failed(Error)
}

/// PersistenceCore owns durable exclusion shared by background loops and lower-level organs.
public func reserveOncePerPeriod(
    at marker: URL,
    stamp: String,
    isFresh: @Sendable (_ stored: String?) throws -> Bool
) async -> OncePerPeriodReservation {
    do {
        // Capture prior bytes under the claim lock so failure cannot restore a value older than the claim it replaced.
        let claim = try await SwiftNativePersistenceCore.withFileLock(marker) { () -> (reserved: Bool, prior: Data?) in
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
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(stamp.utf8), to: marker)
            return (true, prior)
        }
        guard claim.reserved else { return .alreadyReserved }
        let prior = claim.prior
        return .reserved(stamp: stamp, rollback: {
            do {
                try await SwiftNativePersistenceCore.withFileLock(marker) {
                    guard let current = try? Data(contentsOf: marker),
                          String(data: current, encoding: .utf8) == stamp
                    else { return }
                    if let prior {
                        try SwiftNativePersistenceCore.writeDataAtomicDurable(prior, to: marker)
                    } else {
                        try FileManager.default.removeItem(at: marker)
                        try SwiftNativePersistenceCore.syncDirectory(marker.deletingLastPathComponent())
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

public func reserveOncePerPeriod(
    key: String,
    at marker: URL
) async -> OncePerPeriodReservation {
    await reserveOncePerPeriod(at: marker, stamp: key) { $0 == key }
}
