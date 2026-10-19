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

    /// Saved bridge spellings remain readable as peer surfaces. A transport
    /// label alone never admits the caller as the local operator.
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
        "claude-bridge": agentBridgeID,
        "codex-bridge": agentBridgeID,
        "omp-bridge": agentBridgeID,
        "bridge": agentBridgeID,
    ]
}
