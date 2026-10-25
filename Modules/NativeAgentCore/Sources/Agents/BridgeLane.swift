import Foundation
import ChatTurnContracts

// Blueprint: | `BridgeLane.swift` | `BridgeLane`: bridge surface spelling and agent-authorship classification, without assigning identity or effect authority |

/// Every agent door carries agent authorship. Surface spellings remain readable
/// in saved rows and approvals, without assigning identity or authority.
public enum BridgeLane {
    // Every bridge caller is an agent process; no route relays human-authored text.
    public static func laneAuthorship(forSender sender: String) -> ChatMessageAuthorship? { .agent }

    public static func bridgeSurfaceName(forSender sender: String) -> String {
        let name = sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? "bridge" : name + "-bridge"
    }
}
