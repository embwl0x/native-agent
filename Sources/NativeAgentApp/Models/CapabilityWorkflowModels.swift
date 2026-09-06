import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

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

/// Mounted Intent Router state. A successful plan with no matching
/// capabilities is useful evidence; it must never look like the router did
/// not run or that it failed before producing a plan.
enum IntentRoutePresentation: Equatable {
    case idle
    case planning
    case plan(IntentRoutePlan)
    case failed(String)

    enum CapabilityMatchState: Equatable {
        case matches([CapabilityRecord])
        case noMatches
    }

    var capabilityMatchState: CapabilityMatchState? {
        guard case let .plan(plan) = self else { return nil }
        return plan.matchedCapabilities.isEmpty
            ? .noMatches
            : .matches(plan.matchedCapabilities)
    }

    var isPlanning: Bool {
        if case .planning = self { return true }
        return false
    }

    static func boundedFailure(_ error: Error) -> String {
        let normalized = error.localizedDescription
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "The router did not return an error description." }
        return normalized.count > 240 ? String(normalized.prefix(240)) + "…" : normalized
    }
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
}

// 2026-09-01: `WorkflowRun` and its run-control projection were retired with
// the workflow run engine (User authorized). The registry record above is what
// the Capabilities panel still reads.

// ApprovalRequest moved to NativeAgentShared.
