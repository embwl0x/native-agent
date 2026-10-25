import Foundation
// Blueprint: | `NativeAgentWidgetSnapshot.swift` | Shared widget wire and stale-activity interpretation; compiled directly into the widget extension |

/// A display-only projection; the extension never opens the resident stores.
@available(macOS 27, *)
public struct NativeAgentWidgetSnapshot: Codable, Equatable, Sendable {
    public static let kind = "NativeAgentStatus"
    public static let filename = "status.json"

    public let name: String
    public let status: String
    public let waitingCount: Int?
    public let updatedAt: Date
    public var activityExpiresAt: Date? = nil

    public func status(at date: Date) -> String {
        if let activityExpiresAt, date >= activityExpiresAt { return "Activity unconfirmed — last movement is stale" }
        if activityExpiresAt == nil,
           status.hasPrefix("Working on ") || ["Thinking…", "Replying…", "Here"].contains(status) {
            return "Activity unknown"
        }
        return status
    }

    public static func fileURL() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NativeAgentMacAppGroupID") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return container.appendingPathComponent(filename)
    }

    public static func read() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL()))
    }
}
