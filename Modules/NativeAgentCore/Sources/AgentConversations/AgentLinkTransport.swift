@_exported import AgentLinkTransport
import Foundation
// Blueprint: | `AgentLinkTransport.swift` | Re-exports `AgentLinkTransport` |

extension AgentPeerHTTP {
    public static func send(_ request: AgentA2AWire.Request, bearerToken: String? = nil,
                            timeout: TimeInterval = 45) async throws -> Response {
        try await send(request, bearerToken: bearerToken, timeout: timeout, liveUpdate: conversationLiveUpdate)
    }

    private static var conversationLiveUpdate: LiveUpdateSink? {
        guard let live = AgentConversationLiveContext.target else { return nil }
        return { update in
            let hub = AgentConversationLiveHub.shared
            if let text = update.text { await hub.text(live, replace: text) }
            if let note = update.note { await hub.note(live, note) }
            if update.text == nil, update.note == nil { await hub.activity(live) }
        }
    }
}
