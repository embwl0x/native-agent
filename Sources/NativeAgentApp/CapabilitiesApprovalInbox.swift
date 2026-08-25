import Foundation
import NativeAgentShared

/// The compact Capabilities inbox and the full Approvals screen are two views
/// of one durable queue. A second tap is therefore an observed no-op, never a
/// second request to execute the approved effect.
enum CapabilitiesApprovalInboxResolution: Equatable, Sendable {
    case applied(ApprovalRequest)
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
        let detail = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { return "The approval store returned no error details." }
        return String(detail.prefix(240))
    }
}

enum CapabilitiesApprovalInboxPresentation {
    enum ReadState: Equatable {
        case loading
        case empty
        case available
        case stale
        case unavailable
    }

    static func readState(
        approvalCount: Int,
        refresh: AppModel.PanelRefreshStatus?
    ) -> ReadState {
        let approvalsReadFailed = refresh?.failedEndpoints.contains { endpoint in
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("approvals") == .orderedSame
        } ?? false
        if approvalsReadFailed { return approvalCount > 0 ? .stale : .unavailable }
        if approvalCount > 0 { return .available }
        return refresh == nil ? .loading : .empty
    }

    static func outcomeTone(_ outcome: CapabilitiesApprovalInboxResolution) -> String {
        switch outcome {
        case .applied(let approval):
            return approval.decision?.lowercased() == "approved" ? "success" : "warning"
        case .noOpInFlight, .noOpAlreadyResolved:
            return "warning"
        case .unavailable:
            return "failure"
        }
    }
}
