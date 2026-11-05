import Foundation
import ChatTurnContracts

// Blueprint: | `BridgeLane.swift` | `BridgeLane`: bridge surface spelling and agent-authorship classification, without assigning identity or effect authority |

/// Every agent door carries agent authorship; saved surface spellings grant neither identity nor authority.
public enum BridgeLane {
    // Every bridge caller is an agent process; no route relays human-authored text.
    public static func laneAuthorship(forSender sender: String) -> ChatMessageAuthorship? { .agent }

    /// A lane is named by its sender. Every conversation record names its contact (peer:<id>, bot:<id>, bot-run:<id>; the store refuses one
    /// without), so an empty sender is a malformed record, refused rather than read as an anonymous "bridge" lane.
    public static func bridgeSurfaceName(forSender sender: String) throws -> String {
        let name = sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw UnnamedSender() }
        return name + "-bridge"
    }

    public struct UnnamedSender: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "This reply's conversation names no contact, so its bridge lane is unknown; it was not delivered." }
    }
}
