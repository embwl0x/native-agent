import Foundation
// Blueprint: | `ICloudTextDeltaCoalescer.swift` | Accumulates each nonempty delta into an immediate full-text snapshot; transport mailboxes conflate unsent snapshots without a time or character hold; sequences rise with the clock, so a restarted run's new snapshots outrank its old ones on the phone |

struct ICloudTextDeltaFlush: Equatable, Sendable {
    enum Reason: String, Sendable {
        case first
        case delta
    }

    var sequence: Int
    var text: String
    var reason: Reason
}

struct ICloudTextDeltaCoalescer: Sendable {
    private(set) var sequence: Int = 0
    private(set) var text: String = ""

    /// The retained transport worker replaces unsent full snapshots. Intake
    /// never waits for a send, more characters, a timer or the next tool call.
    /// The phone keeps only snapshots above the highest sequence it has seen
    /// for a run; a run restarted under the same id gets a fresh coalescer, so
    /// sequences follow the clock (milliseconds) and never fall back to 1.
    mutating func push(delta: String) -> ICloudTextDeltaFlush? {
        guard !delta.isEmpty else { return nil }
        let first = text.isEmpty
        text += delta
        sequence = max(sequence + 1, Int(Date().timeIntervalSince1970 * 1000))
        return ICloudTextDeltaFlush(sequence: sequence, text: text, reason: first ? .first : .delta)
    }
}
