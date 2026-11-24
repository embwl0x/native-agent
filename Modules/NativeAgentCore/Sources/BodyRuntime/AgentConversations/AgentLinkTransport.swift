@_exported import ProviderRouting
import Foundation
import PersistenceCore
// Blueprint: | `AgentLinkTransport.swift` | Conversation transport callbacks retain task handles before forwarding live progress. |

extension AgentPeerHTTP {
    public static func send(conversation: AgentConversationContext, _ request: AgentA2AWire.Request, bearerToken: String? = nil,
                            timeout: TimeInterval = 45) async throws -> Response {
        try await send(request, bearerToken: bearerToken, timeout: timeout, liveUpdate: conversationLiveUpdate(conversation: conversation),
            taskOpened: { task in
                guard let target = conversation.liveTarget else { return }
                try AgentConversationStore(dataRoot: target.dataRoot).handle(target, readInput: [
                    "agent": .string(target.agent), "task_id": .string(task), "details": .bool(true)])
            })
    }

    private static func conversationLiveUpdate(conversation: AgentConversationContext) -> LiveUpdateSink? {
        guard let live = conversation.liveTarget else { return nil }
        return { update in
            let hub = AgentConversationLiveHub.shared
            if let text = update.text { await hub.text(live, replace: text) }
            if let note = update.note { await hub.note(live, note) }
            if update.text == nil, update.note == nil { await hub.activity(live) }
        }
    }
}
