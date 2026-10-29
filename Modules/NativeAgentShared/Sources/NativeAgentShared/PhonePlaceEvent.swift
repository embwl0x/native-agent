import Foundation

// Blueprint: | `PhonePlaceEvent.swift` | `PhonePlaceEvent`: authenticated cross-device place observations |

/// Source observations, carried only inside an authenticated BridgeMessage.
public struct PhonePlaceEvent: Codable, Sendable, Identifiable {
    public enum Transition: String, Codable, Sendable { case arrived, left }
    public static let messageKind = "phone_place_event"
    public let id: String
    public let placeID: String
    public let name: String
    public let transition: Transition
    public let timestamp: Date

    public init(id: String, placeID: String, name: String, transition: Transition, timestamp: Date) {
        self.id = id; self.placeID = placeID; self.name = name
        self.transition = transition; self.timestamp = timestamp
    }

    public var isValid: Bool {
        UUID(uuidString: placeID) != nil && !name.isEmpty && name.count <= 60
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !id.isEmpty && id.count <= 160 && timestamp.timeIntervalSinceNow <= 60
    }
}
