// Blueprint: | `AgentPeerTransport.swift` | Canonical contact transport vocabulary shared by contact storage and checked security effect profiling |
public enum AgentPeerTransport: String, Codable, Sendable {
    case a2a
    case nativeAgent
    case desktop
    /// The configured local host calls in through nativeagent-link mcp; its mcp:// endpoint is an identity, never an outbound address.
    case mcpHost
    case acp
    case grokBot
    /// Window-driven chat uses the thread title as conversation identity so readback stays with the thread that received the message.
    case desktopChat
}
