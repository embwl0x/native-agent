import Foundation
import PersistenceCore

// Blueprint: | `ActivityRetention.swift` | `ActivityRetentionRunner`: checked completed-run cadence before pruning; unreadable state preserves bytes and pauses retention; durable stamp follows successful pruning |

/// W10 — retention enforcement.
///
/// Configurable (`ActivityPolicy.retentionDays`, default 30), scheduled, and
/// durable across restarts: the last-run stamp lives next to the DB, so a
/// process that never stays up for a whole day still prunes. A prune that only
/// runs on a timer inside a long-lived process is a prune that never runs on a
/// laptop.
public struct ActivityRetentionRunner: Sendable {
    /// How often the prune is allowed to run. Retention is a 30-day window;
    /// enforcing it hourly buys nothing and VACUUMs the file for no reason.
    public static let defaultInterval: TimeInterval = 6 * 3600

    public let stateURL: URL
    private struct Cadence: Codable {
        let last_run_at: Double
    }

    public init(dataRoot: URL) {
        self.stateURL = ActivityWatchPaths.retentionStateURL(dataRoot: dataRoot)
    }

    /// Unavailable state throws: scheduling pauses until its exact file changes.
    public func nextRunDelay(now: Double = Date().timeIntervalSince1970) throws -> TimeInterval {
        guard let last = try lastRunAt(), last <= now,
              last + Self.defaultInterval > now else { return 0 }
        return last + Self.defaultInterval - now
    }

    /// nil: no state file yet (fresh). Throws: the file is there and unreadable or corrupt (a fault, not fresh).
    public func lastRunAt() throws -> Double? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch CocoaError.fileNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: stateURL.path])
        }
        let data = try Data(contentsOf: stateURL)
        let stamp = try JSONDecoder().decode(Cadence.self, from: data).last_run_at
        guard stamp.isFinite else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: stateURL.path])
        }
        return stamp
    }

    public func isDue(now: Double) throws -> Bool {
        guard let last = try lastRunAt() else { return true }
        // A last-run stamp in the FUTURE means the clock moved backwards. Treat
        // it as due rather than as a licence to skip pruning until the clock
        // catches up — which, after a large backwards step, could be years.
        if last > now { return true }
        return now - last >= Self.defaultInterval
    }

    /// Prune if due, then durably record the completed maintenance pass.
    /// A failed cadence read stops before pruning or writing the stamp. The
    /// existing bytes remain available for repair; unknown cadence is not due.
    public func runIfDue(
        store: ActivitySpanStore,
        policy: ActivityPolicy,
        now: Double = Date().timeIntervalSince1970
    ) async throws {
        guard try isDue(now: now) else { return }
        let retention = Double(max(1, policy.retentionDays)) * 86_400
        try await store.prune(olderThan: retention, now: now)
        try recordRun(at: now)
    }

    public func recordRun(at timestamp: Double) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Cadence(last_run_at: timestamp))
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: stateURL)
    }
}
