import Foundation
// Blueprint: | `ICloudTextDeltaCoalescer.swift` | Owns the accumulating stream text; `push` appends deltas, `flush` emits full-text replacements |

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
    private(set) var text: String = ""
    private var lastFlushedTextCount: Int = 0
    private var lastFlushUptimeNanoseconds: UInt64?

    /// Full-text flushes replace unsent snapshots losslessly; transport publication stays outside stream consumption.
    init(
        minIntervalNanoseconds: UInt64 = 1_000_000_000,
        minCharactersBetweenFlushes: Int = 120,
        maxCharactersBetweenFlushes: Int = 1_200
    ) {
        self.minIntervalNanoseconds = minIntervalNanoseconds
        self.minCharactersBetweenFlushes = max(1, minCharactersBetweenFlushes)
        self.maxCharactersBetweenFlushes = max(self.minCharactersBetweenFlushes, maxCharactersBetweenFlushes)
    }

    mutating func push(delta: String, nowUptimeNanoseconds: UInt64) -> ICloudTextDeltaFlush? {
        text += delta
        return flushIfNeeded(nowUptimeNanoseconds: nowUptimeNanoseconds, force: false)
    }

    mutating func flush(nowUptimeNanoseconds: UInt64) -> ICloudTextDeltaFlush? {
        flushIfNeeded(nowUptimeNanoseconds: nowUptimeNanoseconds, force: true)
    }

    private mutating func flushIfNeeded(
        nowUptimeNanoseconds: UInt64,
        force: Bool
    ) -> ICloudTextDeltaFlush? {
        guard !text.isEmpty else { return nil }
        guard text.count > lastFlushedTextCount else { return nil }

        let reason: ICloudTextDeltaFlush.Reason?
        if force {
            reason = .forced
        } else if lastFlushUptimeNanoseconds == nil {
            reason = .first
        } else {
            let charDelta = text.count - lastFlushedTextCount
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
        lastFlushedTextCount = text.count
        return ICloudTextDeltaFlush(sequence: sequence, text: text, reason: reason)
    }
}
