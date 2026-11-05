import Foundation
// Blueprint: | `ICloudTextDeltaCoalescer.swift` | Immediate full snapshots; clock sequences outrank prior runs. |

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

    /// Intake cannot await publication; the phone accepts only increasing sequences for a run. Millisecond clock sequences let a restarted run outrank its
    /// prior snapshots.
    mutating func push(delta: String) -> ICloudTextDeltaFlush? {
        guard !delta.isEmpty else { return nil }
        let first = text.isEmpty
        text += delta
        sequence = max(sequence + 1, Int(Date().timeIntervalSince1970 * 1000))
        return ICloudTextDeltaFlush(sequence: sequence, text: text, reason: first ? .first : .delta)
    }
}
