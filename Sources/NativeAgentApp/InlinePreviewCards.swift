// The one approve/deny path the inline approval buttons share.

import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore

/// The ONE approve/deny path. Resolve, toast, refresh the approvals list and
/// the health card — in that order, with the same toast vocabulary — so every
/// surface that offers the buttons (Today's "Waiting for you" card) produces
/// an identical outcome. Returns the error text to show beside the buttons,
/// or nil when the decision landed.
enum ApprovalDecisionAction {
    static func resolve(
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
            var failure: String?
            await MainActor.run {
                ApprovalDecisionToastPresentation.publish(toast, to: appModel.systemToasts)
                if toast.kind == .error { failure = toast.text }
            }
            // Refresh the approvals list + health card so the row disappears
            // once the decision lands.
            if let refreshed = try? await appModel.engine.approvals.list() {
                await MainActor.run { appModel.engine.approvals.records = refreshed }
            }
            await appModel.loadHealthCard()
            return failure
        } catch {
            let toast = ApprovalDecisionToastPresentation.unavailable(error)
            await MainActor.run {
                ApprovalDecisionToastPresentation.publish(toast, to: appModel.systemToasts)
            }
            return toast.text
        }
    }
}
