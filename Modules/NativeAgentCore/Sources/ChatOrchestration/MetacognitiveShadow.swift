import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore

/// A deterministic, zero-authority estimate of how much machinery a turn
/// appears to deserve. It is recorded beside the real turn plan for later
/// comparison with provider/tool/outcome traces; it never changes the prompt,
/// model, context packet, tool catalog, approval path, or loop budget.
public struct MetacognitiveShadowRecommendation: Sendable, Equatable {
    public enum ComputeLane: String, Sendable {
        case askUser = "ask_user"
        case frontierStandard = "frontier_standard"
        case frontierDeep = "frontier_deep"
    }

    public enum ToolLane: String, Sendable {
        case none
        case lazy
        case approvalBound = "approval_bound"
    }

    public enum ContextLane: String, Sendable {
        case minimal
        case planned
        case expanded
    }

    public let computeLane: ComputeLane
    public let toolLane: ToolLane
    public let contextLane: ContextLane
    public let feasibleAffordances: [String]
    public let reasonCodes: [String]
    public let governor: MetacognitiveGovernorShadow

    public var traceValue: JSONValue {
        .object([
            // v5 begins the terminal-counted, hermetic epoch. Earlier versions
            // either lacked authoritative terminal counts or were emitted by
            // SwiftPM's `swiftpm-testing-helper`, whose process name did not
            // satisfy the first XCTest detector. History stays readable but is
            // never calibration evidence.
            "schema": .string("metacognition.shadow.v5"),
            "controlAuthority": .bool(false),
            "computeLane": .string(computeLane.rawValue),
            "toolLane": .string(toolLane.rawValue),
            "contextLane": .string(contextLane.rawValue),
            "feasibleAffordances": .array(feasibleAffordances.map(JSONValue.string)),
            "reasonCodes": .array(reasonCodes.map(JSONValue.string)),
            "governor": governor.traceValue,
        ])
    }
}

public enum MetacognitiveShadowEvaluator {
    public static func recommend(
        plan: TurnPlan,
        posture: OrganismBehaviorPosture?
    ) -> MetacognitiveShadowRecommendation {
        var reasons: [String] = []
        let compute: MetacognitiveShadowRecommendation.ComputeLane
        if plan.requiresApprovalHint && !plan.policySnapshot.approvalAvailable {
            compute = .askUser
            reasons.append("approval_unavailable")
        } else if plan.risk == "high" || plan.contextMode == "research" {
            compute = .frontierDeep
            reasons.append(plan.risk == "high" ? "high_risk" : "research_depth")
        } else {
            compute = .frontierStandard
            reasons.append("bounded_interactive_turn")
        }

        let tools: MetacognitiveShadowRecommendation.ToolLane
        if plan.requiresApprovalHint {
            tools = .approvalBound
            reasons.append("approval_boundary")
        } else if !plan.preloadGroupNames.isEmpty || !plan.matchedCapabilityIds.isEmpty {
            tools = .lazy
            reasons.append("capability_evidence")
        } else {
            tools = .none
            reasons.append("no_tool_evidence")
        }

        let context: MetacognitiveShadowRecommendation.ContextLane
        if plan.goalType == "chat" && plan.contextMode == "minimal" {
            context = .minimal
            reasons.append("minimal_chat")
        } else if plan.contextMode == "research" || plan.contextMode == "memory" {
            context = .expanded
            reasons.append("specialized_context")
        } else {
            context = .planned
            reasons.append("planned_context")
        }

        if let posture, posture.enabled {
            reasons.append("organism_\(posture.loopBudget.rawValue)")
            if posture.toolStrategy == .lightweightOnly {
                reasons.append("lightweight_posture")
            } else if posture.toolStrategy == .pauseForApproval {
                reasons.append("approval_posture")
            }
        }

        var affordances = ["respond"]
        if tools != .none { affordances.append("use_tools") }
        if compute == .askUser || plan.requiresApprovalHint { affordances.append("ask_user") }
        if plan.goalType != "chat" { affordances.append("wait_for_evidence") }

        let governor = MetacognitiveGovernorShadowEvaluator.evaluate(
            plan: plan,
            posture: posture,
            computeLane: compute,
            toolLane: tools
        )
        return MetacognitiveShadowRecommendation(
            computeLane: compute,
            toolLane: tools,
            contextLane: context,
            feasibleAffordances: affordances,
            reasonCodes: Array(Set(reasons)).sorted(),
            governor: governor
        )
    }
}

public struct MetacognitiveShadowEvaluation: Sendable, Equatable {
    public enum EvidenceStatus: String, Sendable, Equatable {
        case noRecommendations = "no_recommendations"
        case correlationIncomplete = "correlation_incomplete"
        case evaluable
    }

    public struct Turn: Sendable, Equatable {
        public let turnId: String
        public let observedAt: Date
        public let surface: String?
        public let recommendedComputeLane: String
        public let recommendedToolLane: String
        public let recommendedContextLane: String
        /// The highest-value feasible move from the nested governor shadow.
        /// This remains observational: it never replaces the TurnPlan or
        /// acquires action, model, context, or approval authority.
        public let recommendedAffordance: String?
        public let providerCallCount: Int
        /// Exact provider/model identifiers from persisted `llm.call` receipts.
        /// Empty means the detail was absent; it is never reconstructed from
        /// the requested model or the recommendation.
        public let observedProviders: [String]
        public let observedModels: [String]
        /// Sum of provider-reported call durations only when every correlated
        /// call supplied a duration. Missing detail stays nil.
        public let providerDurationMs: Int?
        /// Exact completed-turn observations written from TurnEngineResult and
        /// the provider-bound TurnContext. Old/partial terminal rows remain nil.
        public let terminalModelUsed: String?
        public let terminalReasoningEffort: String?
        public let turnElapsedMs: Int?
        public let contextSource: String?
        public let contextSelectedAtomCount: Int?
        public let contextPacketCharacters: Int?
        public let contextExpandablePointerCount: Int?
        public let toolSchemaCount: Int?
        public let recalledMemoryCount: Int?
        public let toolDispatchCount: Int
        public let failedToolDispatchCount: Int
        public let contextExpansionCount: Int
        /// Evaluation requires both a provider receipt and the authoritative
        /// terminal turn row containing final tool counts. Individual trace
        /// rows are drop-tolerant and cannot prove that no tool ran.
        public let hasCorrelatedProviderOutcome: Bool
        /// All v1 terminal/provider observation fields needed for an offline
        /// compute/context/model/latency row are present. This is coverage, not
        /// a claim that the recommendation was good.
        public let hasCompleteObservedMeasurements: Bool
        public let toolLaneMatchedObservedUse: Bool
    }

    public struct IntegerMetricSummary: Sendable, Equatable {
        public let count: Int
        public let minimum: Int?
        public let maximum: Int?
        public let mean: Double?

        public init(_ values: [Int]) {
            count = values.count
            minimum = values.min()
            maximum = values.max()
            mean = values.isEmpty
                ? nil
                : values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        }
    }

    public let turns: [Turn]
    public let legacyExcludedRecommendationCount: Int

    public var correlatedTurnCount: Int {
        turns.filter(\.hasCorrelatedProviderOutcome).count
    }

    public var incompleteCorrelationCount: Int {
        turns.count - correlatedTurnCount
    }

    public var correlationCoverageRate: Double {
        guard !turns.isEmpty else { return 0 }
        return Double(correlatedTurnCount) / Double(turns.count)
    }

    public var completeObservedMeasurementCount: Int {
        turns.filter(\.hasCompleteObservedMeasurements).count
    }

    public var observedMeasurementCoverageRate: Double {
        guard !turns.isEmpty else { return 0 }
        return Double(completeObservedMeasurementCount) / Double(turns.count)
    }

    public var providerCounts: [String: Int] {
        Dictionary(grouping: turns.flatMap(\.observedProviders), by: { $0 }).mapValues(\.count)
    }

    public var modelCounts: [String: Int] {
        Dictionary(grouping: turns.compactMap(\.terminalModelUsed), by: { $0 }).mapValues(\.count)
    }

    public var providerModelCounts: [String: Int] {
        Dictionary(grouping: turns.flatMap(\.observedModels), by: { $0 }).mapValues(\.count)
    }

    public var reasoningEffortCounts: [String: Int] {
        Dictionary(grouping: turns.compactMap(\.terminalReasoningEffort), by: { $0 }).mapValues(\.count)
    }

    public var contextSourceCounts: [String: Int] {
        Dictionary(grouping: turns.compactMap(\.contextSource), by: { $0 }).mapValues(\.count)
    }

    public var affordanceCounts: [String: Int] {
        Dictionary(grouping: turns.compactMap(\.recommendedAffordance), by: { $0 }).mapValues(\.count)
    }

    public var turnLatency: IntegerMetricSummary {
        IntegerMetricSummary(turns.compactMap(\.turnElapsedMs))
    }

    public var providerLatency: IntegerMetricSummary {
        IntegerMetricSummary(turns.compactMap(\.providerDurationMs))
    }

    public var contextPacketCharacters: IntegerMetricSummary {
        IntegerMetricSummary(turns.compactMap(\.contextPacketCharacters))
    }

    public var contextSelectedAtoms: IntegerMetricSummary {
        IntegerMetricSummary(turns.compactMap(\.contextSelectedAtomCount))
    }

    public var evidenceStatus: EvidenceStatus {
        guard !turns.isEmpty else { return .noRecommendations }
        return incompleteCorrelationCount == 0 ? .evaluable : .correlationIncomplete
    }

    public var firstRecommendationAt: Date? {
        turns.map(\.observedAt).min()
    }

    public var lastRecommendationAt: Date? {
        turns.map(\.observedAt).max()
    }

    public var surfaceCounts: [String: Int] {
        Dictionary(grouping: turns, by: { $0.surface ?? "unknown" })
            .mapValues(\.count)
    }

    /// Agreement is calculated only over turns with an honestly correlated
    /// provider outcome. `0` with zero correlated turns means "not measured",
    /// and callers must inspect `correlatedTurnCount`/`evidenceStatus` before
    /// presenting it as a quality score.
    public var toolLaneAgreementRate: Double {
        let correlated = turns.filter(\.hasCorrelatedProviderOutcome)
        guard !correlated.isEmpty else { return 0 }
        return Double(correlated.filter(\.toolLaneMatchedObservedUse).count) / Double(correlated.count)
    }

    /// Pure evaluation over existing payload-free turn traces. It creates no
    /// model, dataset, file, prompt context, or control signal.
    public static func evaluate(events: [TurnTraceEvent]) -> MetacognitiveShadowEvaluation {
        let planEvents = events.filter { $0.kind == "turn.plan" }
        let legacyExcludedRecommendationCount = planEvents.filter { event in
            guard case .object(let payload) = event.payload,
                  case .object(let shadow)? = payload["metacognitiveShadow"],
                  case .string(let schema)? = shadow["schema"] else { return false }
            return schema.hasPrefix("metacognition.shadow.")
                && schema != "metacognition.shadow.v5"
        }.count
        let grouped = Dictionary(grouping: events, by: \.turnId)
        var turns: [Turn] = []
        for (turnId, unsortedRows) in grouped {
            let rows = unsortedRows.sorted { $0.ts < $1.ts }
            guard let plan = rows.first(where: { $0.kind == "turn.plan" }),
                  case .object(let planPayload) = plan.payload,
                  case .object(let shadow)? = planPayload["metacognitiveShadow"],
                  case .string("metacognition.shadow.v5")? = shadow["schema"],
                  case .string(let computeLane)? = shadow["computeLane"],
                  case .string(let toolLane)? = shadow["toolLane"],
                  case .string(let contextLane)? = shadow["contextLane"] else { continue }
            let recommendedAffordance: String? = {
                guard case .object(let governor)? = shadow["governor"],
                      case .string("metacognition.governor.shadow.v1")? = governor["schema"],
                      governor["controlAuthority"] == .bool(false),
                      case .string(let value)? = governor["selectedAffordance"] else { return nil }
                return nonEmptyString(value)
            }()
            let toolEnds = rows.filter { row in
                guard row.kind == "tool.dispatch", case .object(let payload) = row.payload else { return false }
                return payload["phase"] == .string("end")
            }
            let failed = toolEnds.filter { row in
                guard case .object(let payload) = row.payload else { return false }
                return payload["status"] == .string("failed")
            }.count
            let expansions = toolEnds.filter { row in
                guard case .object(let payload) = row.payload else { return false }
                return payload["name"] == .string("context_expand")
            }.count
            let providerRows = rows.filter { $0.kind == "llm.call" }
            let providerCalls = providerRows.count
            let observedProviders = providerRows.compactMap { row -> String? in
                guard case .object(let payload) = row.payload,
                      case .string(let value)? = payload["provider"] else { return nil }
                return nonEmptyString(value)
            }
            let observedModels = providerRows.compactMap { row -> String? in
                guard case .object(let payload) = row.payload,
                      case .string(let value)? = payload["model"] else { return nil }
                return nonEmptyString(value)
            }
            let providerDurations = providerRows.compactMap { row -> Int? in
                guard case .object(let payload) = row.payload,
                      case .int(let value)? = payload["durationMs"],
                      value >= 0 else { return nil }
                return Int(value)
            }
            let providerDurationMs = providerCalls > 0 && providerDurations.count == providerCalls
                ? providerDurations.reduce(0, +)
                : nil
            let terminal = rows.last(where: { row in
                guard row.kind == "turn.terminal", case .object(let payload) = row.payload else { return false }
                return payload["status"] == .string("completed")
            })
            let terminalPayload: [String: JSONValue]? = {
                guard let terminal, case .object(let payload) = terminal.payload else { return nil }
                return payload
            }()
            let terminalToolCount: Int? = terminalPayload.flatMap { payload in
                guard case .int(let value)? = payload["toolDispatchCount"] else { return nil }
                return Int(value)
            }
            let terminalFailedCount: Int = terminalPayload.flatMap { payload in
                guard case .int(let value)? = payload["failedToolDispatchCount"] else { return nil }
                return Int(value)
            } ?? failed
            let terminalExpansionCount: Int = terminalPayload.flatMap { payload in
                guard case .int(let value)? = payload["contextExpansionCount"] else { return nil }
                return Int(value)
            } ?? expansions
            let terminalSchema: String? = terminalPayload.flatMap { payload in
                guard case .string(let value)? = payload["schema"] else { return nil }
                return value
            }
            let terminalModelUsed: String? = terminalPayload.flatMap { payload in
                guard case .string(let value)? = payload["modelUsed"] else { return nil }
                return nonEmptyString(value)
            }
            let terminalReasoningEffort: String? = terminalPayload.flatMap { payload in
                guard case .string(let value)? = payload["reasoningEffort"] else { return nil }
                return nonEmptyString(value)
            }
            let turnElapsedMs = intValue("turnElapsedMs", in: terminalPayload)
            let contextSource: String? = terminalPayload.flatMap { payload in
                guard case .string(let value)? = payload["contextSource"] else { return nil }
                return nonEmptyString(value)
            }
            let contextSelectedAtomCount = intValue("contextSelectedAtomCount", in: terminalPayload)
            let contextPacketCharacters = intValue("contextPacketCharacters", in: terminalPayload)
            let contextExpandablePointerCount = intValue("contextExpandablePointerCount", in: terminalPayload)
            let toolSchemaCount = intValue("toolSchemaCount", in: terminalPayload)
            let recalledMemoryCount = intValue("recalledMemoryCount", in: terminalPayload)
            let hasCorrelatedProviderOutcome = providerCalls > 0 && terminalToolCount != nil
            let hasCompleteObservedMeasurements = hasCorrelatedProviderOutcome
                && terminalSchema == "metacognition.observed.v1"
                && observedProviders.count == providerCalls
                && observedModels.count == providerCalls
                && providerDurationMs != nil
                && terminalModelUsed != nil
                && terminalReasoningEffort != nil
                && turnElapsedMs != nil
                && contextSource != nil
                && contextSelectedAtomCount != nil
                && contextPacketCharacters != nil
                && contextExpandablePointerCount != nil
                && toolSchemaCount != nil
                && recalledMemoryCount != nil
            let observedTools = (terminalToolCount ?? 0) > 0
            let recommendedTools = toolLane != MetacognitiveShadowRecommendation.ToolLane.none.rawValue
            turns.append(Turn(
                turnId: turnId,
                observedAt: plan.ts,
                surface: plan.surface,
                recommendedComputeLane: computeLane,
                recommendedToolLane: toolLane,
                recommendedContextLane: contextLane,
                recommendedAffordance: recommendedAffordance,
                providerCallCount: providerCalls,
                observedProviders: observedProviders,
                observedModels: observedModels,
                providerDurationMs: providerDurationMs,
                terminalModelUsed: terminalModelUsed,
                terminalReasoningEffort: terminalReasoningEffort,
                turnElapsedMs: turnElapsedMs,
                contextSource: contextSource,
                contextSelectedAtomCount: contextSelectedAtomCount,
                contextPacketCharacters: contextPacketCharacters,
                contextExpandablePointerCount: contextExpandablePointerCount,
                toolSchemaCount: toolSchemaCount,
                recalledMemoryCount: recalledMemoryCount,
                toolDispatchCount: terminalToolCount ?? toolEnds.count,
                failedToolDispatchCount: terminalFailedCount,
                contextExpansionCount: terminalExpansionCount,
                hasCorrelatedProviderOutcome: hasCorrelatedProviderOutcome,
                hasCompleteObservedMeasurements: hasCompleteObservedMeasurements,
                toolLaneMatchedObservedUse: hasCorrelatedProviderOutcome && recommendedTools == observedTools
            ))
        }
        return MetacognitiveShadowEvaluation(
            turns: turns.sorted { $0.turnId < $1.turnId },
            legacyExcludedRecommendationCount: legacyExcludedRecommendationCount
        )
    }

    private static func intValue(
        _ key: String,
        in payload: [String: JSONValue]?
    ) -> Int? {
        guard let payload,
              case .int(let value)? = payload[key],
              value >= 0 else { return nil }
        return Int(value)
    }

    private static func nonEmptyString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Structured chat can run beneath an outer streaming task that already owns
/// the turn trace identity. Reusing that ambient identity is required so the
/// plan recommendation, provider call, tool dispatches, and outcome remain one
/// calibratable story. Direct non-streaming callers still mint one identity.
enum StructuredTurnTraceIdentity {
    static func currentOrMint() -> String {
        TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
    }
}
