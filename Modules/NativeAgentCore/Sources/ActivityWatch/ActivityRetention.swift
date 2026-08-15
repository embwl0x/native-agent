import Foundation
import PersistenceCore

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

    public struct Outcome: Sendable, Equatable {
        public let ran: Bool
        public let deleted: Int
        public let nextDueAt: Double

        public init(ran: Bool, deleted: Int, nextDueAt: Double) {
            self.ran = ran
            self.deleted = deleted
            self.nextDueAt = nextDueAt
        }
    }

    public let stateURL: URL
    private let interval: TimeInterval

    public init(dataRoot: URL, interval: TimeInterval = ActivityRetentionRunner.defaultInterval) {
        self.stateURL = ActivityWatchPaths.retentionStateURL(dataRoot: dataRoot)
        self.interval = interval
    }

    public init(stateURL: URL, interval: TimeInterval = ActivityRetentionRunner.defaultInterval) {
        self.stateURL = stateURL
        self.interval = interval
    }

    public func lastRunAt() -> Double? {
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = object["last_run_at"] as? Double else { return nil }
        return stamp
    }

    public func isDue(now: Double) -> Bool {
        guard let last = lastRunAt() else { return true }
        // A last-run stamp in the FUTURE means the clock moved backwards. Treat
        // it as due rather than as a licence to skip pruning until the clock
        // catches up — which, after a large backwards step, could be years.
        if last > now { return true }
        return now - last >= interval
    }

    /// Prune if due. Returns what happened, including when it is next due, so a
    /// caller never has to guess whether retention is actually being enforced.
    @discardableResult
    public func runIfDue(
        store: ActivitySpanStore,
        policy: ActivityPolicy,
        now: Double = Date().timeIntervalSince1970
    ) async throws -> Outcome {
        guard isDue(now: now) else {
            return Outcome(ran: false, deleted: 0, nextDueAt: (lastRunAt() ?? now) + interval)
        }
        let retention = Double(max(1, policy.retentionDays)) * 86_400
        let deleted = try await store.prune(olderThan: retention, now: now)
        try recordRun(at: now)
        return Outcome(ran: true, deleted: deleted, nextDueAt: now + interval)
    }

    public func recordRun(at timestamp: Double) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["last_run_at": timestamp], options: [.sortedKeys]
        )
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: stateURL)
    }
}
