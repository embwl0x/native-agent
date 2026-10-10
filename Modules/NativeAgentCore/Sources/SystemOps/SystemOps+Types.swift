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

    public func toJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "message": .string(message),
            "goalType": .string(goalType),
            "recommendedSurface": .string(recommendedSurface),
            "contextMode": .string(contextMode),
            "risk": .string(risk),
            "requiresApproval": .bool(requiresApproval),
            "matchedCapabilities": .array(matchedCapabilities),
            "nextActions": .array(nextActions.map { .string($0) }),
            "createdAt": .string(createdAt),
        ])
    }

    public init(from json: JSONValue) throws {
        guard case .object(let obj) = json else {
            throw SystemOpsError.malformedResponse("RoutePlanResult: not an object")
        }
        func str(_ k: String) throws -> String {
            if case .string(let s) = obj[k] ?? .null { return s }
            throw SystemOpsError.malformedResponse("RoutePlanResult: missing string '\(k)'")
        }
        func boolean(_ k: String) -> Bool {
            if case .bool(let b) = obj[k] ?? .null { return b }
            return false
        }
        var caps: [JSONValue] = []
        if case .array(let arr) = obj["matchedCapabilities"] ?? .null { caps = arr }
        var actions: [String] = []
        if case .array(let arr) = obj["nextActions"] ?? .null {
            actions = arr.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
        }
        self.init(
            id: try str("id"),
            message: try str("message"),
            goalType: try str("goalType"),
            recommendedSurface: try str("recommendedSurface"),
            contextMode: try str("contextMode"),
            risk: try str("risk"),
            requiresApproval: boolean("requiresApproval"),
            matchedCapabilities: caps,
            nextActions: actions,
            createdAt: try str("createdAt")
        )
    }
}

// MARK: - Errors

public enum SystemOpsError: Error, Sendable, Equatable, LocalizedError {
    case missingMessage
    case missingLabel
    case subprocessFailed(String)
    case stashNotFound(String)
    case stashPopFailed(String)
    case transport(String)
    case malformedResponse(String)
    case notFlippable(String)
    public var errorDescription: String? {
        switch self {
        case .missingMessage: return "Message or objective is required"
        case .missingLabel: return "missing stash label"
        case .subprocessFailed(let s): return s
        case .stashNotFound(let label):
            return "stash with label '\(label)' not found in git stash list"
        case .stashPopFailed(let s): return s
        case .transport(let s): return "transport error: \(s)"
        case .malformedResponse(let s): return "malformed response: \(s)"
        case .notFlippable(let s): return s
        }
    }
}

// MARK: - Protocols

public protocol RouterPlanClient: Sendable {
    func planRoute(message: String) async throws -> RoutePlanResult
}
