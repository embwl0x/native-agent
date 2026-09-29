import Foundation

public struct KernelGuardrail: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String
    public var status: String
    public init(id: String, title: String, status: String) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct ApprovalClass: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String
    public var requiresApproval: Bool
    public init(id: String, title: String, requiresApproval: Bool) {
        self.id = id
        self.title = title
        self.requiresApproval = requiresApproval
    }
}

public struct AutonomyKernelSummary: Codable, Hashable {
    public var status: String
    public var mode: String?
    public var enabled: Bool?
    public var processEnabled: Bool?
    public var trustEnabled: Bool?
    public var disabledReason: String?
    public var guardrails: [KernelGuardrail]
    public var approvalClasses: [ApprovalClass]
    public var runningImprovements: Int?
    public var createdAt: String?
    public init(status: String, mode: String? = nil, enabled: Bool? = nil, processEnabled: Bool? = nil, trustEnabled: Bool? = nil, disabledReason: String? = nil, guardrails: [KernelGuardrail], approvalClasses: [ApprovalClass], runningImprovements: Int? = nil, createdAt: String? = nil) {
        self.status = status
        self.mode = mode
        self.enabled = enabled
        self.processEnabled = processEnabled
        self.trustEnabled = trustEnabled
        self.disabledReason = disabledReason
        self.guardrails = guardrails
        self.approvalClasses = approvalClasses
        self.runningImprovements = runningImprovements
        self.createdAt = createdAt
    }
}

public struct PersonalOSSpace: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var count: Int
    public var kind: String?
    public init(id: String, name: String, count: Int, kind: String? = nil) {
        self.id = id
        self.name = name
        self.count = count
        self.kind = kind
    }
}

public struct PersonalOSSummary: Codable, Hashable {
    public var spaces: [PersonalOSSpace]
    public var createdAt: String?
    public init(spaces: [PersonalOSSpace], createdAt: String? = nil) {
        self.spaces = spaces
        self.createdAt = createdAt
    }
}
