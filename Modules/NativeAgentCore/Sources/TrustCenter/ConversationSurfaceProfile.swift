import Foundation

// Blueprint: | `ConversationSurfaceProfile.swift` | `ConversationSurfaceProfile`; One security-relevant surface identity. |

/// A surface compared by its one spelling; every named bridge lane is the agent bridge. Domain owners still supply trust evidence.
public struct ConversationSurfaceProfile: Sendable, Equatable, Hashable {
    public let id: String

    public init(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Every bridge lane (BridgeLane.bridgeSurfaceName: "<sender>-bridge", peer:<id>-bridge included) is a peer on the agent bridge, never the
        // local operator, whatever its sender.
        self.id = normalized == "bridge" || normalized.hasSuffix("-bridge") ? Self.agentBridgeID : normalized
    }

    public var isRemote: Bool { Self.remoteSurfaceIDs.contains(id) }

    /// Current named bridge transports classify as peer surfaces. A transport label alone never admits the caller as the local operator.
    public static let agentBridgeID = "agent-bridge"
    public var isAgentBridge: Bool { id == Self.agentBridgeID }
    public var isIOSRemote: Bool { id == "ios" }

    public static let remoteSurfaceIDs: Set<String> = ["telegram", "slack", "ios", agentBridgeID]

}
