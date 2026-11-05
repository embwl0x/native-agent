import Foundation
import NativeAgentCore
import ApprovalInbox
import ChatTurnContracts
// Blueprint: | `Turn+Approvals.swift` | `ApprovalResolutionProvenance.resolvingTurn`: card decision held by its verifying door |

extension ApprovalResolutionProvenance {
    /// The person's decision as its own turn: the door that verified them is its envelope, never the agent's own.
    public var resolvingTurn: Turn {
        let envelope: TurnEnvelope = switch self {
        case .local: .personOnMac("mac_ui:approval")
        case .telegram(let chat, let user): TurnEnvelope(surface: "telegram", verifiedChatId: chat, verifiedUserId: user)
        case .signedIOS: TurnEnvelope(surface: "ios")
        }
        return Turn().with(\.envelope, envelope)
    }
}
