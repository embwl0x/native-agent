import Foundation
import ApprovalInbox
import NativeAgentShared

/// Every place an approval is decided (the chat's inline card, Today's
/// Approvals) is a view of one durable queue. A second tap is therefore an
/// observed no-op, never a second request to execute the approved effect.
enum CapabilitiesApprovalInboxResolution: Equatable, Sendable {
    case applied(ApprovalRecord)
    case noOpInFlight(id: String)
    case noOpAlreadyResolved(id: String, status: String)
    case unavailable(String)

    var visibleMessage: String {
        switch self {
        case .applied(let approval):
            let decision = approval.decision ?? approval.status
            return "Approval recorded as \(decision)."
        case .noOpInFlight:
            return "This approval is already being decided on another screen."
        case .noOpAlreadyResolved:
            return "This approval was already decided; no second action was run."
        case .unavailable(let detail):
            return "Approval update failed: \(detail)"
        }
    }

    static func boundedUnavailable(_ error: any Error) -> String {
        UserFacingError.cause(error, action: "update that approval")
    }
}
