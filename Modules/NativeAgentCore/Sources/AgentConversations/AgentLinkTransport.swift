@_exported import AgentLinkTransport
import Foundation

extension AgentPeerHTTP {
    public static func send(_ request: AgentA2AWire.Request, bearerToken: String? = nil,
                            timeout: TimeInterval = 45) async throws -> Response {
        try await send(request, bearerToken: bearerToken, timeout: timeout, liveUpdate: conversationLiveUpdate)
    }

    public static func get(_ url: URL, bearerToken: String? = nil, headers: [String: String] = [:],
                           timeout: TimeInterval = 30) async throws -> Response {
        try await get(url, bearerToken: bearerToken, headers: headers, timeout: timeout,
                      liveUpdate: conversationLiveUpdate)
    }

    private static var conversationLiveUpdate: LiveUpdateHandler? {
        guard let live = AgentConversationLiveContext.target else { return nil }
        return { update in
            let hub = AgentConversationLiveHub.shared
            if let text = update.text { await hub.text(live, replace: text) }
            if let note = update.note { await hub.note(live, note) }
            if update.text == nil, update.note == nil { await hub.activity(live) }
        }
    }
}
