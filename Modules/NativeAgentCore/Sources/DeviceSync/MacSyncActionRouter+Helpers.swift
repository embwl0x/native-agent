import Foundation
import ChatTurnRuntime
import NativeAgentCore
// Blueprint: | `MacSyncActionRouter+Helpers.swift` | `MacSyncActionRouter`: `helpersAction` |

extension MacSyncActionRouter {
    func helpersAction(_ action: InboxAction) async throws -> [String: String] {
        // Dispatch admitted this signed action from a paired phone: its client is the verified device the person's act names.
        try await sync.host.agentThreadAction(action: action.action, payload: action.payload, device: action.clientId)
    }
}
