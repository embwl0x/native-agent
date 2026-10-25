import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import SystemOps

// Blueprint: | `TurnPlanning.swift` | `TurnPlanner`, `TurnPlan` and `TurnPlanTraceRecorder`: capability selection and turn-plan trace projection |

public struct TurnPlan: Equatable, Sendable {
    public let id: String
    public let messageCharCount: Int
    public let goalType: String
    public let contextMode: String
    public let recommendedSurface: String
    public let risk: String
    public let requiresApprovalHint: Bool
    public let matchedCapabilityIds: [String]
    public let receiptHints: [String]
    public let createdAt: String

    public init(
        id: String,
        messageCharCount: Int,
        goalType: String,
        contextMode: String,
        recommendedSurface: String,
        risk: String,
        requiresApprovalHint: Bool,
        matchedCapabilityIds: [String],
        receiptHints: [String],
        createdAt: String
    ) {
        self.id = id
        self.messageCharCount = messageCharCount
        self.goalType = goalType
        self.contextMode = contextMode
        self.recommendedSurface = recommendedSurface
        self.risk = risk
        self.requiresApprovalHint = requiresApprovalHint
        self.matchedCapabilityIds = matchedCapabilityIds
        self.receiptHints = receiptHints
        self.createdAt = createdAt
    }

    func tracePayload(runId: String?, surface: String) -> JSONValue {
        var payload: [String: JSONValue] = [
            "schema": .string("turn.plan.v1"),
            "turnPlanId": .string(id),
            "goalType": .string(goalType),
            "contextMode": .string(contextMode),
            "recommendedSurface": .string(recommendedSurface),
            "risk": .string(risk),
            "requiresApprovalHint": .bool(requiresApprovalHint),
            "messageChars": .int(Int64(messageCharCount)),
            "matchedCapabilityIds": .array(matchedCapabilityIds.map { .string($0) }),
            "receiptHints": .array(receiptHints.prefix(6).map { .string($0) }),
            "surface": .string(surface),
        ]
        payload["runId"] = runId.map { .string($0) } ?? .null
        return .object(payload)
    }
}

public actor TurnPlanner {
    private let router: SwiftNativeRouterPlanClient

    public init(
        router: SwiftNativeRouterPlanClient = SwiftNativeRouterPlanClient()
    ) {
        self.router = router
    }

    public func plan(
        message: String
    ) async throws -> TurnPlan {
        let route = try await router.planRoute(message: message)
        return TurnPlan(
            id: route.id,
            messageCharCount: message.count,
            goalType: route.goalType,
            contextMode: route.contextMode,
            recommendedSurface: route.recommendedSurface,
            risk: route.risk,
            requiresApprovalHint: route.requiresApproval,
            matchedCapabilityIds: Self.meaningfulCapabilityIds(from: route.matchedCapabilities),
            receiptHints: route.nextActions,
            createdAt: route.createdAt
        )
    }

    nonisolated static func meaningfulCapabilityIds(from capabilities: [JSONValue]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for capability in capabilities {
            guard case .object(let obj) = capability,
                  case .string(let id)? = obj["id"],
                  !id.isEmpty else {
                continue
            }
            let hasTerm = stringArray(obj["matchedTerms"]).contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let hasRealReason = stringArray(obj["selectionReasons"]).contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "fallback ranking"
            }
            guard hasTerm || hasRealReason else { continue }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    private nonisolated static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            if case .string(let string) = value { return string }
            if case .int(let int) = value { return String(int) }
            return nil
        }
    }
}

enum TurnPlanTraceRecorder {
    static func append(
        _ plan: TurnPlan,
        runId: String?,
        surface: String,
        turnId: String,
        turnTraceBus: TurnTraceBus = .shared,
        now: Date = Date()
    ) {
        let payload = plan.tracePayload(runId: runId, surface: surface)
        TurnTraceBus.fire(TurnTraceEvent(turnId: turnId, ts: now, kind: "turn.plan",
                                       surface: surface, payload: payload), on: turnTraceBus)
    }
}
