import Foundation
import NativeAgentCore
import ApprovalInbox
import ChatTurnContracts
// Blueprint: | `Turn+Approvals.swift` | `ApprovalResolutionProvenance.resolvingTurn`: tap envelopes; message records recreate no person authority |

extension ApprovalResolutionProvenance {
    /// A tap holds its verifying door; a message record cannot recreate the invoking turn's person authority.
    public var resolvingTurn: Turn {
        let envelope: TurnEnvelope = switch self {
        case .local: .personOnMac("mac_ui:approval")
        case .telegram(let chat, let user): TurnEnvelope(surface: "telegram", verifiedChatId: chat, verifiedUserId: user)
        case .signedIOS: TurnEnvelope(surface: "ios")
        case .personMessage: .native("approval:person_message")
        }
        return Turn().with(\.envelope, envelope)
    }
}
