import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import WorkflowOrchestration

struct PrivacyCategory: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var path: String
    var contains: String
    var exportable: Bool
}

struct PrivacyMap: Codable, Hashable {
    var dataRoot: String
    var categories: [PrivacyCategory]
    var generatedAt: String
}

struct SupportDiagnostics: Codable, Hashable {
    var app: String
    var version: String
    var doctorStatus: String?
    var generatedAt: String
}

struct CapabilityCounts: Codable, Hashable {
    var total: Int
    var active: Int
    var review: Int
    var autoloaded: Int
    var byKind: [String: Int]?
}

struct CapabilitySummaryResponse: Codable, Hashable {
    var records: [CapabilityRecord]
    var summary: CapabilityCounts
    var createdAt: String?
}

struct CapabilityRecord: Identifiable, Codable, Hashable {
    var id: String
    var sourceId: String?
    var name: String?
    var kind: String
    var status: String?
    var description: String?
    var triggers: [String]?
    var permissions: [String]?
    var riskClass: String?
    var autoload: Bool?
    var useCount: Int?
    var lastUsedAt: String?
    var updatedAt: String?
}

struct CapabilityFoundrySummary: Codable, Hashable {
    var status: String
    var principle: String?
    var hotPathContract: CapabilityFoundryHotPath?
    var summary: CapabilityFoundryCounts
    var lanes: [CapabilityFoundryLane]
    var reviewQueue: [CapabilityFoundryArtifact]
    var recentArtifacts: [CapabilityFoundryArtifact]
    var readouts: [CapabilityFoundryReadout]
    var createdAt: String?
}

struct CapabilityFoundryHotPath: Codable, Hashable {
    var chatInjection: String?
    var bodiesLoaded: String?
    var pluginPolicy: String?
    var reviewRequiredFor: [String]?
    var riskyPermissionsPresent: [String]?
}

struct CapabilityFoundryCounts: Codable, Hashable {
    var total: Int
    var active: Int
    var review: Int
    var autoCreated: Int
    var byKind: [String: Int]?
}

struct CapabilityFoundryLane: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: String
    var count: Int
    var reviewCount: Int
    var endpoint: String?
    var policyGate: String?
    var hotPath: String?
}

struct CapabilityFoundryArtifact: Identifiable, Codable, Hashable {
    var id: String
    var kind: String
    var name: String
    var status: String
    var description: String?
    var riskClass: String?
    var autoCreated: Bool?
    var sourceRunId: String?
    var updatedAt: String?
}

struct CapabilityFoundryReadout: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: String
    var surface: String?
}

struct IntentRoutePlan: Identifiable, Codable, Hashable {
    var id: String
    var message: String
    var goalType: String
    var recommendedSurface: String?
    var risk: String
    var requiresApproval: Bool
    var matchedCapabilities: [CapabilityRecord]
    var nextActions: [String]
    var createdAt: String?
}

struct WorkflowStep: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var kind: String?
    var status: String?
    var requiresApproval: Bool?
    var detail: String?
}

struct WorkflowRecord: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var description: String?
    var status: String?
    var trigger: String?
    var steps: [WorkflowStep]
    var createdAt: String?
    var updatedAt: String?

    var executionAvailability: WorkflowExecutionAvailability {
        WorkflowExecutionPreflight.evaluate(
            status: status,
            stepKinds: steps.map(\.kind)
        )
    }
}

struct WorkflowRun: Identifiable, Codable, Hashable {
    var id: String
    var workflowId: String
    var workflowName: String?
    var objective: String?
    var status: String
    var mode: String?
    var engineVersion: String?
    var steps: [WorkflowStep]
    var createdAt: String?
    var completedAt: String?
    var currentStepIndex: Int?
    var approvalId: String?
}

// ApprovalRequest moved to NativeAgentShared.
