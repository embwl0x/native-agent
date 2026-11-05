import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Cognitive.swift` | `Turn` parts cognition owns: the incoming row's after-turn origin and claimed care wakes |

private enum AfterTurnOriginPart: TurnPart { static let unset: AfterTurnOrigin? = nil }
private enum CareWakesPart: TurnPart { static let unset: [CognitiveCareWake] = [] }

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
}
