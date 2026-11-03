import Foundation

// Blueprint: | `PhoneSenseEvent.swift` | Coordinate-free phone observations and per-organ setup evidence, shared labels and validation; motion preserves activity flags, confidence and activity time |
public struct PhoneSenseEvent: Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable, Hashable, CaseIterable {
        case places, motion, focus, charging, battery, headphones, network, music, photos
        public var title: String {
            switch self {
            case .places: "Places"
            case .motion: "Motion"
            case .focus: "Focus"
            case .charging: "Sleep clues"
            case .battery: "Battery"
            case .headphones: "Headphones"
            case .network: "Connection"
            case .music: "Apple Music"
            case .photos: "Photos today"
            }
        }
    }
    public struct Setup: Codable, Sendable, Equatable {
        /// Nil means local preference storage could not be read, never off.
        public let enabled: Bool?
        public let required: String
        public let permission: String
        public let missing: [String]
        public let detail: String
        public init(enabled: Bool?, required: String, permission: String, missing: [String], detail: String = "") {
            self.enabled = enabled; self.required = required; self.permission = permission
            self.missing = missing; self.detail = detail
        }
        var isValid: Bool {
            required.count <= 160 && permission.count <= 160 && detail.count <= 240
                && missing.count <= 8 && missing.allSatisfy { $0.count <= 240 }
        }
        public var line: String {
            "app \(enabled.map { $0 ? "on" : "off" } ?? "unreadable"); \(required): \(permission)"
                + (detail.isEmpty ? "" : "; \(detail)")
                + (missing.isEmpty ? "; setup complete at this observation" : "; missing: " + missing.joined(separator: ", "))
        }
    }
    public static let messageKind = "phone_sense_event"
    public let id: String
    public let source: Source
    public let value: String
    public let timestamp: Date
    /// Phone-local night at observation, never the Mac's timezone.
    public let localNight: Bool?
    public let setup: Setup?
    public let confidence: String?
    public let activityStartedAt: Date?
    /// Bounded summary only: song title/artist or a count's phone-local day/scope.
    public let summary: String?

    public init(id: String = UUID().uuidString, source: Source, value: String, timestamp: Date = Date(), localNight: Bool? = nil,
                setup: Setup? = nil, confidence: String? = nil, activityStartedAt: Date? = nil, summary: String? = nil) {
        self.id = id; self.source = source; self.value = value
        self.timestamp = timestamp; self.localNight = localNight
        self.setup = setup; self.confidence = confidence; self.activityStartedAt = activityStartedAt; self.summary = summary
    }
    public var isSetup: Bool { value == "setup" }
    /// Low-confidence activity remains visible, but cannot establish absence or sleep.
    public var supportsPresenceInference: Bool {
        (confidence == nil && activityStartedAt == nil) || confidence == "medium" || confidence == "high"
    }
    public var isMovement: Bool {
        source == .motion && !isSetup && supportsPresenceInference
            && !value.split(separator: "+").contains("unknown")
            && value.split(separator: "+").contains { ["walking", "running", "cycling", "driving"].contains(String($0)) }
    }
    public var isValid: Bool {
        let values: Set<String> = switch source {
        case .places: []
        case .motion: ["stationary", "walking", "running", "cycling", "driving", "unknown", "disabled"]
        case .focus: ["on", "off", "unknown", "disabled"]
        case .charging: ["charging", "unplugged", "unknown", "disabled"]
        case .battery: Set((0...100).map(String.init) + ["unknown", "disabled"])
        case .headphones: ["headphones_route", "bluetooth_route", "other_route", "unknown", "disabled"]
        case .network: ["wifi", "cellular", "wired", "other", "unavailable", "unknown", "disabled"]
        case .music: ["playing", "paused", "stopped", "interrupted", "seeking", "unknown", "disabled"]
        case .photos: []
        }
        let flags = value.split(separator: "+").map(String.init)
        let validValue = isSetup ? setup?.isValid == true
            : source == .motion ? !flags.isEmpty && flags.count <= 6 && Set(flags).count == flags.count && flags.allSatisfy(values.contains)
                && (flags.count == 1 || !flags.contains("disabled"))
            : source == .photos ? ["unknown", "disabled"].contains(value) || (Int(value).map { $0 >= 0 && String($0) == value } ?? false)
            : values.contains(value)
        return UUID(uuidString: id) != nil && validValue && value.count <= 100
            && timestamp.timeIntervalSince1970.isFinite && timestamp.timeIntervalSinceNow <= 60
            && (source == .charging || localNight == nil)
            && (isSetup || setup == nil) && (summary?.count ?? 0) <= 300
            && (confidence == nil || (source == .motion && ["low", "medium", "high"].contains(confidence!)))
            && (activityStartedAt.map { source == .motion && $0.timeIntervalSince1970.isFinite && $0 <= timestamp } ?? true)
    }
}
