import Foundation
import ChatTurnRuntime
import NativeAgentCore
// Blueprint: | `MacSyncActionRouter+Helpers.swift` | `MacSyncActionRouter`: `helpersAction` |

extension MacSyncActionRouter {
    func helpersAction(_ action: InboxAction) async throws -> [String: String] {
        let payload = action.payload
        switch action.action {
        case "get_agent_thread", "send_agent_message":
            // dispatch admitted this signed action from a paired phone; it starts its own act.
            let request = TurnRequest(message: payload["text"] ?? "", sessionID: payload["session_id"],
                surface: "ios", envelope: TurnEnvelope(surface: "ios", commandSignatureVerified: true),
                verifiedSessionID: payload["session_id"], pinnedRunID: action.msgId)
            return try await sync.host.agentThreadAction(action: action.action, payload: payload, turn: request.turn())
        default:
            return try await sync.host.helperAction(action: action.action, payload: payload)
        }
    }
}
