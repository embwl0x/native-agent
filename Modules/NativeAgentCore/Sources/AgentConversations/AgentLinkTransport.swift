@_exported import AgentLinkTransport
import Foundation
// Blueprint: | `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |

extension AgentPeerHTTP {
    public static func send(conversation: AgentConversationContext, _ request: AgentA2AWire.Request, bearerToken: String? = nil,
                            timeout: TimeInterval = 45) async throws -> Response {
        try await send(request, bearerToken: bearerToken, timeout: timeout, liveUpdate: conversationLiveUpdate(conversation: conversation))
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
