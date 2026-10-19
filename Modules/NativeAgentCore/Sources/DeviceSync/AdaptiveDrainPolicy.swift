import Foundation

/// Receive deadlines exist only while delivery or a transport without proven
/// push needs them. The sender owns recovery from a lost individual push.
struct AdaptiveDrainPolicy: Equatable {
    /// Cadence while a correlation is outstanding or the peer is recently active.
    var fastInterval: TimeInterval = 8
    /// Without proven push, polling is the receive mechanism.
    let receivePollInterval: TimeInterval = 10
    /// How long after the last peer message/reply the fast cadence is kept.
    var peerActivityWindow: TimeInterval = 120

    private(set) var outstanding: Set<String> = []
    private(set) var lastPeerActivityAt: Date?

    /// The runtime currently owns an inbound delivery.
    mutating func noteOutstanding(_ correlationID: String, at date: Date) {
        outstanding.insert(correlationID)
        lastPeerActivityAt = date
    }

    /// Runtime ownership ended: a reply was sent or retry returned to the sender.
    mutating func resolve(_ correlationID: String, at date: Date) {
        outstanding.remove(correlationID)
        lastPeerActivityAt = date
    }

    /// Verified traffic with the phone keeps the receive window open.
    mutating func notePeerActivity(at date: Date) {
        lastPeerActivityAt = date
    }

    func interval(now: Date, polling: Bool, active: Bool) -> TimeInterval? {
        if active || !outstanding.isEmpty { return fastInterval }
        if let lastPeerActivityAt, now.timeIntervalSince(lastPeerActivityAt) < peerActivityWindow {
            return fastInterval
        }
        return polling ? receivePollInterval : nil
    }

    /// A one-shot delivery deadline, absent when the receiver is resting.
    func nextDrainDelay(
        now: Date,
        lastDrainAt: Date,
        polling: Bool,
        active: Bool,
        minimumDelay: TimeInterval = 1
    ) -> TimeInterval? {
        guard let desiredInterval = interval(now: now, polling: polling, active: active) else { return nil }
        guard lastDrainAt != .distantPast else {
            return max(minimumDelay, desiredInterval)
        }
        let elapsed = max(0, now.timeIntervalSince(lastDrainAt))
        let delay = max(minimumDelay, desiredInterval - elapsed)
        guard !polling, !active, outstanding.isEmpty, let lastPeerActivityAt else { return delay }
        return min(delay, max(0, lastPeerActivityAt.addingTimeInterval(peerActivityWindow).timeIntervalSince(now)))
    }
}
