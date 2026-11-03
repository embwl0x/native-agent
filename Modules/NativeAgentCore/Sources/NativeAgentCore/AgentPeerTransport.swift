// Blueprint: | `AgentPeerTransport.swift` | Canonical contact transport vocabulary shared by contact storage and checked security effect profiling |
public enum AgentPeerTransport: String, Codable, Sendable {
    case a2a
    case nativeAgent
    case desktop
    /// An agent host ON THIS MAC that this app set itself up inside: that
    /// host's own MCP configuration now carries one entry running
    /// `nativeagent-link mcp` with this connection's key in it. The host CALLS
    /// IN, so the endpoint is an identity (`mcp://<host row id>`), never an
    /// address to send to.
    case mcpHost
    case acp
    case grokBot
    /// A chat app on this Mac driven through its window (`app://<bundle id>`):
    /// the message is typed into the agent's own thread there and its answer
    /// read back in the same call. The thread's title is the conversation_id.
    case desktopChat
}
