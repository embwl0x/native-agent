import Foundation

struct ICloudTextDeltaFlush: Equatable, Sendable {
    enum Reason: String, Sendable {
        case first
        case interval
        case size
        case forced
    }

    var sequence: Int
    var text: String
    var reason: Reason
}

struct ICloudTextDeltaCoalescer: Sendable {
    var minIntervalNanoseconds: UInt64
    var minCharactersBetweenFlushes: Int
    var maxCharactersBetweenFlushes: Int

    private(set) var sequence: Int = 0
    private var pendingText: String = ""
    private var lastFlushedTextCount: Int = 0
    private var lastFlushUptimeNanoseconds: UInt64?

    /// 2026-10-07: 1 s / 120 characters, from 1.5 s / 320. A short reply
    /// never reached 320 between flushes, so the phone saw its first words and
    /// then the whole answer. Each flush is one awaited CloudKit write, so the
    /// writes still come at most about once a second.
    init(
        minIntervalNanoseconds: UInt64 = 1_000_000_000,
        minCharactersBetweenFlushes: Int = 120,
        maxCharactersBetweenFlushes: Int = 1_200
    ) {
        self.minIntervalNanoseconds = minIntervalNanoseconds
        self.minCharactersBetweenFlushes = max(1, minCharactersBetweenFlushes)
        self.maxCharactersBetweenFlushes = max(self.minCharactersBetweenFlushes, maxCharactersBetweenFlushes)
    }

    mutating func push(snapshot: String, nowUptimeNanoseconds: UInt64) -> ICloudTextDeltaFlush? {
        pendingText = snapshot
        return flushIfNeeded(nowUptimeNanoseconds: nowUptimeNanoseconds, force: false)
    }

    mutating func flush(nowUptimeNanoseconds: UInt64) -> ICloudTextDeltaFlush? {
        flushIfNeeded(nowUptimeNanoseconds: nowUptimeNanoseconds, force: true)
    }

    private mutating func flushIfNeeded(
        nowUptimeNanoseconds: UInt64,
        force: Bool
    ) -> ICloudTextDeltaFlush? {
        guard !pendingText.isEmpty else { return nil }
        guard pendingText.count > lastFlushedTextCount else { return nil }

        let reason: ICloudTextDeltaFlush.Reason?
        if force {
            reason = .forced
        } else if lastFlushUptimeNanoseconds == nil {
            reason = .first
        } else {
            let charDelta = pendingText.count - lastFlushedTextCount
            let elapsed = nowUptimeNanoseconds &- (lastFlushUptimeNanoseconds ?? nowUptimeNanoseconds)
            if charDelta >= maxCharactersBetweenFlushes {
                reason = .size
            } else if charDelta >= minCharactersBetweenFlushes && elapsed >= minIntervalNanoseconds {
                reason = .interval
            } else {
                reason = nil
            }
        }

        guard let reason else { return nil }
        sequence += 1
        lastFlushUptimeNanoseconds = nowUptimeNanoseconds
        lastFlushedTextCount = pendingText.count
        return ICloudTextDeltaFlush(sequence: sequence, text: pendingText, reason: reason)
    }
}
