import Foundation
// Blueprint: | `RuntimeSummaryModels.swift` | `KernelGuardrail`, `AutonomyKernelSummary`; Policy-only summaries |

public struct KernelGuardrail: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public init(id: String, title: String, status: String) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct AutonomyKernelSummary: Codable, Hashable, Sendable {
    public var status: String
    public var mode: String?
    public var enabled: Bool?
    public var disabledReason: String?
    public var guardrails: [KernelGuardrail]
    public init(status: String, mode: String? = nil, enabled: Bool? = nil,
        disabledReason: String? = nil, guardrails: [KernelGuardrail]) {
        self.status = status
        self.mode = mode
        self.enabled = enabled
        self.disabledReason = disabledReason
        self.guardrails = guardrails
    }
}
