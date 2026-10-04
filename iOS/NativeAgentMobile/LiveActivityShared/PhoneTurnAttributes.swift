import ActivityKit
import Foundation
import NativeAgentShared

struct PhoneTurnAttributes: ActivityAttributes, Sendable {
    typealias ContentState = MobileWorkActivity.ContentState
    let workID: String
    let pairingFingerprint: String
    let sessionID: String?
    let agentName: String
    let startedAt: Date
}
