// E3 (upgrade-sweep 2026-08): the Mac's CloudKit drain fallback ran at a flat
// 8s forever — ~10,800 fetches a day on a Mac whose phone is asleep. The fast
// cadence only buys something while a peer correlation is outstanding or the
// phone was recently active; otherwise a 120s backstop is enough, because a
// silent push already resets the policy to fast the moment the phone speaks.
import Foundation

/// Pure state machine for the device-transport drain cadence. Kept value-only
/// so the interval decision can be tested without a CloudKit container.
struct AdaptiveDrainPolicy: Equatable {
    /// Cadence while a correlation is outstanding or the peer is recently active.
    var fastInterval: TimeInterval = 8
    /// Cadence when nothing is in flight and the peer has gone quiet.
    var idleInterval: TimeInterval = 120
    /// How long after the last peer message/reply the fast cadence is kept.
    var peerActivityWindow: TimeInterval = 120
    /// A correlation nobody ever answered must not pin the fast cadence forever.
    var correlationMaxAge: TimeInterval = 300

    private(set) var outstanding: [String: Date] = [:]
    private(set) var lastPeerActivityAt: Date?

    /// An inbound peer message was delivered to the runtime; its reply is owed.
    mutating func noteOutstanding(_ correlationID: String, at date: Date) {
        outstanding[correlationID] = date
        lastPeerActivityAt = date
    }

    /// The reply or action response for `correlationID` has been sent.
    mutating func resolve(_ correlationID: String, at date: Date) {
        outstanding.removeValue(forKey: correlationID)
        lastPeerActivityAt = date
    }

    /// Any traffic with the phone — including a push wake — keeps us fast.
    mutating func notePeerActivity(at date: Date) {
        lastPeerActivityAt = date
    }

    /// Drop correlations older than `correlationMaxAge` so an unanswered turn
    /// cannot hold the fast cadence for the life of the process.
    mutating func prune(now: Date) {
        outstanding = outstanding.filter { now.timeIntervalSince($0.value) <= correlationMaxAge }
    }

    func hasFreshOutstanding(now: Date) -> Bool {
        outstanding.contains { now.timeIntervalSince($0.value) <= correlationMaxAge }
    }

    func interval(now: Date) -> TimeInterval {
        if hasFreshOutstanding(now: now) { return fastInterval }
        if let lastPeerActivityAt, now.timeIntervalSince(lastPeerActivityAt) <= peerActivityWindow {
            return fastInterval
        }
        return idleInterval
    }

    /// True when `lastDrainAt` is old enough that the next tick should drain.
    func isDrainDue(now: Date, lastDrainAt: Date) -> Bool {
        now.timeIntervalSince(lastDrainAt) >= interval(now: now)
    }

    /// Delay for a one-shot fallback timer. A transport that has never drained
    /// gets one prompt fast-cadence check; after that, the timer sleeps exactly
    /// until the policy's next useful deadline instead of waking every eight
    /// seconds merely to rediscover that the idle cadence is not due.
    func nextDrainDelay(
        now: Date,
        lastDrainAt: Date,
        minimumDelay: TimeInterval = 1
    ) -> TimeInterval {
        let desiredInterval = lastDrainAt == .distantPast
            ? fastInterval
            : interval(now: now)
        guard lastDrainAt != .distantPast else {
            return max(minimumDelay, desiredInterval)
        }
        let elapsed = max(0, now.timeIntervalSince(lastDrainAt))
        return max(minimumDelay, desiredInterval - elapsed)
    }
}
