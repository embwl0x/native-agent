import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Result types

public struct RoutePlanResult: Sendable, Equatable {
    public let id: String
    public let message: String
    public let goalType: String
    public let recommendedSurface: String
    public let contextMode: String
    public let risk: String
    public let requiresApproval: Bool
    public let matchedCapabilities: [JSONValue]
    public let nextActions: [String]
    public let createdAt: String

    public init(
        id: String,
        message: String,
        goalType: String,
        recommendedSurface: String,
        contextMode: String,
        risk: String,
        requiresApproval: Bool,
        matchedCapabilities: [JSONValue],
        nextActions: [String],
        createdAt: String
    ) {
        self.id = id
        self.message = message
        self.goalType = goalType
        self.recommendedSurface = recommendedSurface
        self.contextMode = contextMode
        self.risk = risk
        self.requiresApproval = requiresApproval
        self.matchedCapabilities = matchedCapabilities
        self.nextActions = nextActions
        self.createdAt = createdAt
    }
}

// MARK: - Errors

public enum SystemOpsError: Error, Sendable, Equatable, LocalizedError {
    case missingMessage
    public var errorDescription: String? {
        switch self {
        case .missingMessage: return "Message or objective is required"
        }
    }
}
public struct IntentRoutePlan: Identifiable, Codable, Hashable {
    public var id: String
    public var message: String
    public var goalType: String
    public var recommendedSurface: String?
    public var risk: String
    public var requiresApproval: Bool
    public var matchedCapabilities: [CapabilityRecord]
    public var nextActions: [String]
    public var createdAt: String?

    /// The router's plan, its matched catalog rows read as capabilities.
    public init(_ plan: RoutePlanResult) throws {
        self.init(
            id: plan.id, message: plan.message, goalType: plan.goalType,
            recommendedSurface: plan.recommendedSurface, risk: plan.risk,
            requiresApproval: plan.requiresApproval,
            matchedCapabilities: try plan.matchedCapabilities.map { value in
                guard case .object(let row) = value else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A capability is a JSON object."))
                }
                return try CapabilityRecord(catalogRow: row)
            },
            nextActions: plan.nextActions, createdAt: plan.createdAt
        )
    }

    public init(
        id: String, message: String, goalType: String, recommendedSurface: String?, risk: String,
        requiresApproval: Bool, matchedCapabilities: [CapabilityRecord], nextActions: [String], createdAt: String?
    ) {
        self.id = id; self.message = message; self.goalType = goalType
        self.recommendedSurface = recommendedSurface; self.risk = risk
        self.requiresApproval = requiresApproval; self.matchedCapabilities = matchedCapabilities
        self.nextActions = nextActions; self.createdAt = createdAt
    }
}
