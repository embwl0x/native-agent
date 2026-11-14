import Foundation
import NativeAgentCore
import ChatTurnContracts
// Blueprint: | `Turn+Agents.swift` | `Turn` parts agent conversations own: the person's own send and a person-approved host act |

private enum PersonInitiatedSendPart: TurnPart { static let unset: PersonInitiatedSend? = nil }
private enum PersonApprovedHostPart: TurnPart { static let unset: Bool = false }

extension Turn {
    /// The person's exact send: send-only authority this turn may claim once.
    public var personInitiatedSend: PersonInitiatedSend? {
        get { self[PersonInitiatedSendPart.self] }
        set { self[PersonInitiatedSendPart.self] = newValue }
    }
    /// The turn is the person's own message, or the person's own send from a contact composer: what it asks for goes now, ahead of anything held.
    public var askedByPerson: Bool {
        personInitiatedSend != nil || (envelope != nil && envelope?.agent == nil && originPrincipal == "person")
    }
    /// The person approved this contact-host act.
    package var personApprovedHost: Bool {
        get { self[PersonApprovedHostPart.self] }
        set { self[PersonApprovedHostPart.self] = newValue }
    }
}
