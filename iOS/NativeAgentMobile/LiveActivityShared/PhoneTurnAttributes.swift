import ActivityKit
import Foundation

struct PhoneTurnAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var status: String
        var updatedAt: Date
    }
    let correlationID: String
    let agentName: String
    let startedAt: Date
}
