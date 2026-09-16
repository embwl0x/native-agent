import Foundation

/// Canonical classification for a conversation/action origin.
///
/// Surface identity is security-relevant: remote callers must not become local
/// merely because one subsystem forgot an alias. This type owns normalization
/// and the remote/mobile sets; domain-specific trust evidence still belongs to
/// TrustCenter and the signed origin stores.
public struct ConversationSurfaceProfile: Sendable, Equatable, Hashable {
    public let id: String

    public init(_ rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        self.id = Self.aliases[normalized] ?? normalized
    }

    public var isRemote: Bool { Self.remoteSurfaceIDs.contains(id) }

    /// The inbound agent-to-agent bridge lane (`/agent/mcp`, `/a2a`,
    /// `/agent/message`). A REMOTE PEER IS NEVER THE PERSON: this surface is
    /// its own id precisely so a peer turn can never be mistaken for the
    /// operator's own "chat". Claude's own bridge lane keeps `claude-bridge`.
    public static let agentBridgeID = "agent-bridge"
    public var isAgentBridge: Bool { id == Self.agentBridgeID }
    public var isIOSRemote: Bool { Self.iosRemoteSurfaceIDs.contains(id) }

    public static let remoteSurfaceIDs: Set<String> = [
        "telegram", "slack", "ios", "icloud", "iphone", "ipad", "mobile", "remote", "watch",
        agentBridgeID,
    ]

    public static let iosRemoteSurfaceIDs: Set<String> = [
        "ios", "icloud", "iphone", "ipad", "mobile", "watch",
    ]

    private static let aliases: [String: String] = [
        "i-phone": "iphone",
        "i-pad": "ipad",
        "agentbridge": agentBridgeID,
        "agent bridge": agentBridgeID,
    ]
}
