import Foundation
import PersistenceCore
import Synchronization
// Blueprint: | `PersonParkedCalls.swift` | `PersonParkedCalls`: the cards a call the person decided waits on, so the call resumes as the person's when the person answers |

/// A call the person decided (`PermissionLaw.personDecided`) that parks on an interaction card resumes as the person's own act when the
/// person answers that card: one resume path, no second ask. The mark is held in this process only, because a persisted mark would be
/// authority anyone able to write a transcript could forge; after a relaunch the parked call replays as the agent's and the gate judges it
/// as such. Any answer by the agent takes the mark away, so an agent's answer never runs the person's call.
public enum PersonParkedCalls {
    private static let parked = Mutex<[String: (tool: String, input: [String: JSONValue])]>([:])

    /// The person decided this exact call, parked on this card. The call itself is held here, never read back from the card's record.
    public static func park(_ card: String, tool: String, input: [String: JSONValue]) {
        parked.withLock { $0[card] = (tool, input) }
    }

    /// The agent answered this card: its parked call is the agent's.
    public static func agentAnswered(_ card: String) { _ = parked.withLock { $0.removeValue(forKey: card) } }

    /// The call the person decided that parked on this card, taken so it admits one replay; nil when it is not the person's.
    public static func take(_ card: String) -> (tool: String, input: [String: JSONValue])? {
        parked.withLock { $0.removeValue(forKey: card) }
    }
}
