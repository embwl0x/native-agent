import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Turn+Cognitive.swift` | `Turn` parts cognition owns: the incoming row's after-turn origin, claimed care wakes and what a thought attends |

private enum AfterTurnOriginPart: TurnPart { static let unset: AfterTurnOrigin? = nil }
private enum CareWakesPart: TurnPart { static let unset: [CognitiveCareWake] = [] }
private enum AttendedPart: TurnPart { static let unset: JSONValue? = nil }

extension Turn {
    /// The durable incoming row this turn's after-reply work reads.
    public var afterTurnOrigin: AfterTurnOrigin? {
        get { self[AfterTurnOriginPart.self] }
        set { self[AfterTurnOriginPart.self] = newValue }
    }
    /// The care arrivals this resident wake claimed.
    public var careWakes: [CognitiveCareWake] {
        get { self[CareWakesPart.self] }
        set { self[CareWakesPart.self] = newValue }
    }
    /// What a thought of the agent's attends: the ignited node and its drive, the happenings and the readings it was weighed with. Its turn program
    /// reads it on the opening message.
    public var attended: JSONValue? {
        get { self[AttendedPart.self] }
        set { self[AttendedPart.self] = newValue }
    }
}
