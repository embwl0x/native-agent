import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import SystemOps

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
            let matchedTerms = stringArray(obj["matchedTerms"])
            let selectionReasons = stringArray(obj["selectionReasons"])
            if id.hasPrefix("connector_action:x."),
               !hasExplicitXConnectorEvidence(
                   matchedTerms: matchedTerms,
                   selectionReasons: selectionReasons
               ) {
                continue
            }
            let meaningfulTerms = matchedTerms.filter {
                isMeaningfulMatchedTerm($0, capabilityId: id)
            }
            let hasRealReason = selectionReasons.contains { reason in
                isMeaningfulSelectionReason(reason, capabilityId: id)
            }
            guard !meaningfulTerms.isEmpty || hasRealReason else { continue }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    private nonisolated static func isMeaningfulMatchedTerm(
        _ term: String,
        capabilityId: String
    ) -> Bool {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        // The SystemOps scorer intentionally preserves retired scoring semantics and treats
        // trigger substrings literally. X connector records have a single
        // letter "x" trigger, which matches words like "Codex" and
        // "exercise". For TurnPlan metadata, suppress that trace noise unless
        // a less ambiguous X/Twitter term also matched.
        if capabilityId.hasPrefix("connector_action:x.") && normalized == "x" {
            return false
        }
        if capabilityId.hasPrefix("connector_action:x.") {
            return isExplicitXConnectorTerm(normalized)
        }
        return true
    }

    private nonisolated static func isMeaningfulSelectionReason(
        _ reason: String,
        capabilityId: String
    ) -> Bool {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized != "fallback ranking" else { return false }
        if capabilityId.hasPrefix("connector_action:x.") && normalized == "trigger:x" {
            return false
        }
        if capabilityId.hasPrefix("connector_action:x."),
           normalized.hasPrefix("trigger:") {
            let trigger = String(normalized.dropFirst("trigger:".count))
            return isExplicitXConnectorTerm(trigger)
        }
        return true
    }

    private nonisolated static func isExplicitXConnectorTerm(_ normalized: String) -> Bool {
        normalized == "x.com" ||
            normalized == "twitter" ||
            normalized == "tweet" ||
            normalized == "tweets" ||
            normalized == "retweet" ||
            normalized == "retweets" ||
            normalized == "timeline" ||
            normalized == "timelines" ||
            normalized == "post_tweet" ||
            normalized == "search_recent" ||
            normalized == "user_tweets"
    }

    private nonisolated static func hasExplicitXConnectorEvidence(
        matchedTerms: [String],
        selectionReasons: [String]
    ) -> Bool {
        if matchedTerms.contains(where: {
            isExplicitXConnectorTerm($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }) {
            return true
        }
        return selectionReasons.contains { reason in
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.hasPrefix("trigger:") else { return false }
            let trigger = String(normalized.dropFirst("trigger:".count))
            return isExplicitXConnectorTerm(trigger)
        }
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

extension SwiftNativeTurnEngine {
    nonisolated static func contextByAppendingTurnPlanHint(
        _ context: TurnContext,
        turnPlan: TurnPlan?
    ) -> TurnContext {
        var additions: [String] = []
        // W7/P13 — the cue family splits by what it regulates. Serve/rut/register
        // stay chat-gated (they are about matching a social register). Stance
        // routes through EVERY goal type: narrating your own performance is the
        // same defect on a build turn as on a chat turn, and the chat gate is
        // exactly why the cue never fired on the tic that motivated it.
        // See `NaturalExpressionGuidance.stanceOnly`.
        if let cue = context.naturalExpressionCue, let goalType = turnPlan?.goalType {
            if goalType == "chat" || goalType == "personality" {
                additions.append(cue)
            } else if let stance = NaturalExpressionGuidance.stanceOnly(cue) {
                additions.append(stance)
            }
        }
        // Always consume the request-scoped candidate here, even for a task
        // turn. It must never leak through a later context transform.
        guard !additions.isEmpty || context.naturalExpressionCue != nil else { return context }
        var appended = SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
            context, runtimeContext: additions.joined(separator: "\n\n")
        )
        appended.naturalExpressionCue = nil
        return appended
    }
}
