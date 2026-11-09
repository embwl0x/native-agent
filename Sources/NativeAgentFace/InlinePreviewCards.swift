import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `InlinePreviewCards.swift` | Approval feedback from the body's durable resolution reply |

enum ApprovalDecisionAction {
    @MainActor static func resolve(id: String, decision: String, appModel: AppModel) async -> String? {
        do {
            let committed = try await appModel.resolveApproval(id: id, decision: decision)
            guard committed.identities.contains(id),
                  case .object(let fields) = committed.value,
                  fields["status"] == .string("resolved"),
                  case .string(let savedDecision)? = fields["decision"],
                  let saved = FaceApprovalDecision(rawValue: savedDecision) else {
                throw PartCallError(code: "approval_unconfirmed", message: "Approval outcome could not be confirmed for this request.")
            }
            let kind: SystemToast.Kind = saved == .approved ? .success : .info
            appModel.systemToasts.push(SystemToast(kind: kind, text: "Approval recorded as " + saved.rawValue))
            return nil
        } catch {
            let message = error.localizedDescription
            appModel.systemToasts.push(error: message)
            return message
        }
    }
}
