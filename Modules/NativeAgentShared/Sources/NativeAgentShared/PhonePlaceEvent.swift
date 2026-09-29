import Foundation

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

/// Bounded, atomic source history; the Mac bridge is its sole writer.
public enum PhonePlaceHistory {
    public static func url(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("mobile/place-events.json") }
    public static func read(_ dataRoot: URL) throws -> [PhonePlaceEvent] {
        let file = url(dataRoot)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([PhonePlaceEvent].self, from: Data(contentsOf: file))
    }
    public static func record(_ event: PhonePlaceEvent, dataRoot: URL) throws {
        var events = try read(dataRoot)
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        events = Array(events.sorted { $0.timestamp < $1.timestamp }.suffix(64))
        let file = url(dataRoot)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: file, options: .atomic)
    }
}
