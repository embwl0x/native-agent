import Foundation
import NativeAgentShared
// Blueprint: | `InboxCardActions.swift` | Native Inbox commands cross to the body's transaction owner |

@MainActor enum InboxCardActions {
    static func perform(_ id: String, action: String, appModel: AppModel) async throws -> CommittedResult {
        try await appModel.committedFaceAct(.inboxAction(id: id, action: action, value: nil))
    }
}
