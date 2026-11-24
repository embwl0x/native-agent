import Foundation
import NativeAgentShared
// Blueprint: | `AppModel+SkillsIntegrations.swift` | Doctor and Inbox acts; the body owns their effects |

@MainActor
extension AppModel {
    func inboxAction(_ id: String, action: String) async throws {
        _ = try await committedFaceAct(.inboxAction(id: id, action: action, value: nil))
    }
}
