
import SwiftUI
import ApprovalInbox
import Context
import EngineRuntime
import NativeAgentShared
import NativeAgentCore

// Blueprint: | `InlinePreviewCards.swift` | Inline approval resolve, durable-decision toasts and resolution messages retained by chat and Trust |

/// Share resolve → toast → approvals/health refresh ordering so every approval surface exposes the same outcome.
enum ApprovalDecisionAction {
    @MainActor static func resolve(
        id: String,
        decision: String,
        appModel: AppModel
    ) async -> String? {
        do {
            let resolvedApproval = try await appModel.resolveApproval(id: id, decision: decision)
            let toast = ApprovalDecisionToastPresentation.toast(
                for: resolvedApproval,
                requestedID: id
            )
            ApprovalDecisionToastPresentation.publish(toast, to: appModel.systemToasts)
            await appModel.engine.approvals.refresh()
            await appModel.loadHealthCard()
            return toast.kind == .error ? toast.text : nil
        } catch {
            let toast = ApprovalDecisionToastPresentation.unavailable(error)
            ApprovalDecisionToastPresentation.publish(toast, to: appModel.systemToasts)
            return toast.text
        }
    }
}

/// The durable decision supplies the toast; a requested decision alone proves no outcome.
enum ApprovalDecisionToastPresentation {
    struct Toast: Equatable, Sendable {
        let kind: SystemToast.Kind
        let text: String
    }

    static func toast(for resolvedApproval: ApprovalRecord, requestedID: String) -> Toast {
        guard !requestedID.isEmpty, resolvedApproval.id == requestedID else {
            return .init(kind: .error, text: "Approval outcome could not be confirmed for this request.")
        }
        guard resolvedApproval.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "resolved" else {
            return .init(kind: .error, text: "Approval outcome could not be confirmed.")
        }
        switch resolvedApproval.decision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved": return .init(kind: .success, text: "Approval recorded as approved")
        case "denied": return .init(kind: .info, text: "Approval recorded as denied")
        case "canceled": return .init(kind: .info, text: "Approval recorded as canceled")
        default: return .init(kind: .error, text: "Approval outcome could not be confirmed.")
        }
    }

    static func unavailable(_ error: any Error) -> Toast {
        .init(kind: .error, text: UserFacingError.message(error, action: "update that approval"))
    }

    @MainActor static func publish(_ toast: Toast, to center: SystemToastCenter) {
        center.push(SystemToast(kind: toast.kind, text: toast.text))
    }
}

extension ApprovalsFacade.Resolution {
    var visibleMessage: String {
        switch self {
        case .applied(let approval): return "Approval recorded as \(approval.decision ?? approval.status)."
        case .noOpInFlight: return "This approval is already being decided on another screen."
        case .noOpAlreadyResolved: return "This approval was already decided; no second action was run."
        case .unavailable(let detail): return "Approval update failed: \(detail)"
        }
    }
}
