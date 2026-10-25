import Foundation
import PersistenceCore

// Blueprint: | `ActivityRetention.swift` | `ActivityRetentionRunner`: durable last-run stamp, prune deadlines and policy-selected retention |

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

    public init(dataRoot: URL) {
        self.stateURL = ActivityWatchPaths.retentionStateURL(dataRoot: dataRoot)
    }

    /// Throws when the state file exists but cannot be read; the caller records that and keeps its cadence.
    public func nextRunDelay(now: Double = Date().timeIntervalSince1970) throws -> TimeInterval {
        guard let last = try lastRunAt(), last <= now,
              last + Self.defaultInterval > now else { return Self.defaultInterval }
        return last + Self.defaultInterval - now
    }

    /// nil: no state file yet (fresh). Throws: the file is there and unreadable or corrupt (a fault, not fresh).
    public func lastRunAt() throws -> Double? {
        let data: Data
        do { data = try Data(contentsOf: stateURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = object["last_run_at"] as? Double, stamp.isFinite else {
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
    /// Returns the cadence fault when the last-run state could not be read: the
    /// pass still runs (unknown cadence is due) and the caller records the fault.
    public func runIfDue(
        store: ActivitySpanStore,
        policy: ActivityPolicy,
        now: Double = Date().timeIntervalSince1970
    ) async throws -> String? {
        var fault: String?
        let due: Bool
        do { due = try isDue(now: now) } catch { due = true; fault = error.localizedDescription }
        guard due else { return nil }
        let retention = Double(max(1, policy.retentionDays)) * 86_400
        try await store.prune(olderThan: retention, now: now)
        try recordRun(at: now)
        return fault
    }

    public func recordRun(at timestamp: Double) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["last_run_at": timestamp], options: [.sortedKeys]
        )
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: stateURL)
    }
}
