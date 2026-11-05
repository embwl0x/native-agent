import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Agents.swift` | `Turn` parts agent conversations own: the person's own send and a person-approved host act |

private enum PersonInitiatedSendPart: TurnPart { static let unset: PersonInitiatedSend? = nil }
private enum PersonApprovedHostPart: TurnPart { static let unset: Bool = false }

extension Turn {
    /// The person's exact send: send-only authority this turn may claim once.
    public var personInitiatedSend: PersonInitiatedSend? {
        get { self[PersonInitiatedSendPart.self] }
        set { self[PersonInitiatedSendPart.self] = newValue }
    }
    /// The person approved this contact-host act.
    package var personApprovedHost: Bool {
        get { self[PersonApprovedHostPart.self] }
        set { self[PersonApprovedHostPart.self] = newValue }
    }
}
