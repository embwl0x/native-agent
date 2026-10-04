import Foundation

/// A display-only projection; the extension never opens the resident stores.
@available(macOS 27, *)
struct NativeAgentWidgetSnapshot: Codable, Equatable {
    static let kind = "NativeAgentStatus"
    static let filename = "status.json"

    let name: String
    let status: String
    let waitingCount: Int?
    let updatedAt: Date
    var activityExpiresAt: Date? = nil

    func status(at date: Date) -> String {
        if let activityExpiresAt, date >= activityExpiresAt { return "Activity unconfirmed — last movement is stale" }
        if activityExpiresAt == nil,
           status.hasPrefix("Working on ") || ["Thinking…", "Replying…", "Here"].contains(status) {
            return "Activity unknown"
        }
        return status
    }

    static func fileURL() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NativeAgentMacAppGroupID") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return container.appendingPathComponent(filename)
    }

    static func read() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL()))
    }
}
