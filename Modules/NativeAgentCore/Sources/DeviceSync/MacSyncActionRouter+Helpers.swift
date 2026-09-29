import Foundation

extension MacSyncActionRouter {
    func helpersAction(_ action: String, payload: [String: String]) async throws -> [String: String] {
        switch action {
        case "get_agent_thread", "send_agent_message":
            return try await sync.host.agentThreadAction(action: action, payload: payload)
        default:
            return try await sync.host.helperAction(action: action, payload: payload)
        }
    }
}
