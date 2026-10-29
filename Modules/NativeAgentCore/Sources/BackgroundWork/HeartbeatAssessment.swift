import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import WorkshopExecution
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatAssessment.swift` | Heartbeat assessment, notice and action values consumed by the existing work and loop owners |
public struct HeartbeatNoticeAction: Sendable, Equatable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}
public struct HeartbeatAssessment: Sendable, Equatable {
    public let deterministicOK: Bool
    public let conditionId: String
    public let fallbackAlert: String
    public let actions: [HeartbeatNoticeAction]

    public init(
        deterministicOK: Bool,
        conditionId: String,
        fallbackAlert: String,
        actions: [HeartbeatNoticeAction] = []
    ) {
        self.deterministicOK = deterministicOK
        self.conditionId = conditionId
        self.fallbackAlert = fallbackAlert
        self.actions = actions
    }
    public static func clean() -> HeartbeatAssessment {
        HeartbeatAssessment(
            deterministicOK: true,
            conditionId: "ok",
            fallbackAlert: ""
        )
    }
}
public struct HeartbeatNotice: Sendable, Equatable {
    public let conditionId: String
    public let body: String
    public let actions: [HeartbeatNoticeAction]

    public init(conditionId: String, body: String, actions: [HeartbeatNoticeAction] = []) {
        self.conditionId = conditionId
        self.body = body
        self.actions = actions
    }
}
