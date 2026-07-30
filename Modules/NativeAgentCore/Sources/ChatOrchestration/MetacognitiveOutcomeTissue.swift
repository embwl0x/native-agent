import Foundation
import PersistenceCore

/// A bounded, payload-free read projection over exact turn receipts.
///
/// This is not a memory, learner, scheduler, prompt source, or control path.
/// It accepts only the completed v1 terminal schema, exact provider receipts,
/// and explicit structured reactions emitted by a canonical owner. Missing
/// evidence remains missing: prose, silence, latency, and recommendations are
/// never promoted into outcome labels.
public struct MetacognitiveTurnOutcomeTissue: Sendable, Equatable {
    public enum ExplicitReactionKind: String, Sendable, Equatable {
        case explicitRetry = "explicit_retry"
    }

    public struct ProviderFact: Sendable, Equatable {
        public let provider: String
        public let model: String
        public let durationMs: Int
        public let observedAt: Date
    }

    public struct TerminalFact: Sendable, Equatable {
        public let modelUsed: String
        public let reasoningEffort: String
        public let turnElapsedMs: Int
        public let contextSource: String
        public let contextSelectedAtomCount: Int
        public let contextPacketCharacters: Int
        public let contextExpandablePointerCount: Int
        public let toolSchemaCount: Int
        public let recalledMemoryCount: Int
        public let toolDispatchCount: Int
        public let successfulToolDispatchCount: Int
        public let failedToolDispatchCount: Int
        public let contextExpansionCount: Int
        public let observedAt: Date
    }

    public struct ExplicitReaction: Sendable, Equatable {
        public let kind: ExplicitReactionKind
        public let reactionTurnId: String
        public let observedAt: Date
    }

    public struct Turn: Sendable, Equatable {
        public let turnId: String
        public let sessionId: String
        public let surface: String?
        public let providerFacts: [ProviderFact]
        /// True only when the turn has at least one provider receipt and every
        /// provider row for that turn passed the closed payload-free schema.
        public let hasCompleteProviderCorrelation: Bool
        public let terminal: TerminalFact
        public let explicitReactions: [ExplicitReaction]
    }

    public let turns: [Turn]
    public let terminalEventCount: Int
    public let rejectedTerminalEventCount: Int
    public let reactionEventCount: Int
    public let rejectedReactionEventCount: Int

    public var explicitRetryEvidenceCount: Int {
        turns.reduce(0) { count, turn in
            count + turn.explicitReactions.filter { $0.kind == .explicitRetry }.count
        }
    }

    /// Pure evaluation over existing trace values. It does not read or write
    /// disk and cannot influence a turn.
    public static func evaluate(events: [TurnTraceEvent]) -> Self {
        let grouped = Dictionary(grouping: events, by: \.turnId)
        var accepted: [String: PartialTurn] = [:]
        var terminalEventCount = 0
        var rejectedTerminalEventCount = 0

        for (turnId, rows) in grouped {
            let terminalRows = rows.filter { $0.kind == "turn.terminal" }
            terminalEventCount += terminalRows.count
            guard terminalRows.count == 1,
                  let terminal = parseTerminal(terminalRows[0]),
                  let normalizedTurnId = OutcomeTraceIdentity.normalized(turnId),
                  let sessionId = normalizedToken(terminalRows[0].sessionId, maximumLength: 128)
            else {
                rejectedTerminalEventCount += terminalRows.count
                continue
            }

            let terminalSurface = normalizedToken(terminalRows[0].surface, maximumLength: 128)

            let providerRows = rows.filter { $0.kind == "llm.call" }
            let providerFacts = providerRows.compactMap { provider -> ProviderFact? in
                guard provider.sessionId == sessionId,
                      provider.ts <= terminal.observedAt,
                      provider.ts >= terminal.observedAt.addingTimeInterval(-24 * 60 * 60)
                else { return nil }
                if let terminalSurface {
                    guard normalizedToken(provider.surface, maximumLength: 128) == terminalSurface else {
                        return nil
                    }
                }
                return parseProvider(provider)
            }
                .sorted(by: providerFactOrder)
            accepted[normalizedTurnId] = PartialTurn(
                turnId: normalizedTurnId,
                sessionId: sessionId,
                surface: terminalSurface,
                providerFacts: providerFacts,
                hasCompleteProviderCorrelation: !providerRows.isEmpty
                    && providerFacts.count == providerRows.count,
                terminal: terminal
            )
        }

        let reactionRows = events.filter { $0.kind == "turn.reaction" }
        var rejectedReactionEventCount = 0
        var reactionsByTarget: [String: [ExplicitReaction]] = [:]
        var seenReactionKeys = Set<String>()
        for row in reactionRows.sorted(by: eventOrder) {
            guard let parsed = parseReaction(row),
                  let target = accepted[parsed.targetTurnId],
                  row.sessionId == target.sessionId,
                  parsed.observedAt >= target.terminal.observedAt
            else {
                rejectedReactionEventCount += 1
                continue
            }
            let key = "\(parsed.targetTurnId)|\(parsed.reactionTurnId)|\(parsed.kind.rawValue)"
            guard seenReactionKeys.insert(key).inserted else { continue }
            reactionsByTarget[parsed.targetTurnId, default: []].append(ExplicitReaction(
                kind: parsed.kind,
                reactionTurnId: parsed.reactionTurnId,
                observedAt: parsed.observedAt
            ))
        }

        let turns = accepted.values.map { partial in
            Turn(
                turnId: partial.turnId,
                sessionId: partial.sessionId,
                surface: partial.surface,
                providerFacts: partial.providerFacts,
                hasCompleteProviderCorrelation: partial.hasCompleteProviderCorrelation,
                terminal: partial.terminal,
                explicitReactions: (reactionsByTarget[partial.turnId] ?? []).sorted {
                    if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                    return $0.reactionTurnId < $1.reactionTurnId
                }
            )
        }.sorted { $0.turnId < $1.turnId }

        return Self(
            turns: turns,
            terminalEventCount: terminalEventCount,
            rejectedTerminalEventCount: rejectedTerminalEventCount,
            reactionEventCount: reactionRows.count,
            rejectedReactionEventCount: rejectedReactionEventCount
        )
    }

    private struct PartialTurn {
        let turnId: String
        let sessionId: String
        let surface: String?
        let providerFacts: [ProviderFact]
        let hasCompleteProviderCorrelation: Bool
        let terminal: TerminalFact
    }

    private struct ParsedReaction {
        let kind: ExplicitReactionKind
        let targetTurnId: String
        let reactionTurnId: String
        let observedAt: Date
    }

    private static func parseTerminal(_ event: TurnTraceEvent) -> TerminalFact? {
        guard case .object(let payload) = event.payload,
              payload["schema"] == .string("metacognition.observed.v1"),
              payload["status"] == .string("completed"),
              let modelUsed = normalizedToken(payload.string("modelUsed"), maximumLength: 256),
              let reasoningEffort = normalizedToken(payload.string("reasoningEffort"), maximumLength: 64),
              let contextSource = normalizedToken(payload.string("contextSource"), maximumLength: 128),
              let turnElapsedMs = nonnegativeInt(payload["turnElapsedMs"], maximum: 24 * 60 * 60 * 1_000),
              let contextSelectedAtomCount = nonnegativeInt(payload["contextSelectedAtomCount"], maximum: 1_000_000),
              let contextPacketCharacters = nonnegativeInt(payload["contextPacketCharacters"], maximum: 100_000_000),
              let contextExpandablePointerCount = nonnegativeInt(payload["contextExpandablePointerCount"], maximum: 1_000_000),
              let toolSchemaCount = nonnegativeInt(payload["toolSchemaCount"], maximum: 1_000_000),
              let recalledMemoryCount = nonnegativeInt(payload["recalledMemoryCount"], maximum: 1_000_000),
              let toolDispatchCount = nonnegativeInt(payload["toolDispatchCount"], maximum: 1_000_000),
              let failedToolDispatchCount = nonnegativeInt(payload["failedToolDispatchCount"], maximum: 1_000_000),
              let contextExpansionCount = nonnegativeInt(payload["contextExpansionCount"], maximum: 1_000_000),
              failedToolDispatchCount <= toolDispatchCount,
              contextExpansionCount <= toolDispatchCount
        else { return nil }
        return TerminalFact(
            modelUsed: modelUsed,
            reasoningEffort: reasoningEffort,
            turnElapsedMs: turnElapsedMs,
            contextSource: contextSource,
            contextSelectedAtomCount: contextSelectedAtomCount,
            contextPacketCharacters: contextPacketCharacters,
            contextExpandablePointerCount: contextExpandablePointerCount,
            toolSchemaCount: toolSchemaCount,
            recalledMemoryCount: recalledMemoryCount,
            toolDispatchCount: toolDispatchCount,
            successfulToolDispatchCount: toolDispatchCount - failedToolDispatchCount,
            failedToolDispatchCount: failedToolDispatchCount,
            contextExpansionCount: contextExpansionCount,
            observedAt: event.ts
        )
    }

    private static func parseProvider(_ event: TurnTraceEvent) -> ProviderFact? {
        guard case .object(let payload) = event.payload,
              let provider = normalizedToken(payload.string("provider"), maximumLength: 128),
              let model = normalizedToken(payload.string("model"), maximumLength: 256),
              let durationMs = nonnegativeInt(payload["durationMs"], maximum: 24 * 60 * 60 * 1_000)
        else { return nil }
        return ProviderFact(
            provider: provider,
            model: model,
            durationMs: durationMs,
            observedAt: event.ts
        )
    }

    private static func parseReaction(_ event: TurnTraceEvent) -> ParsedReaction? {
        guard case .object(let payload) = event.payload,
              payload["schema"] == .string("metacognition.reaction.v1"),
              payload["controlAuthority"] == .bool(false),
              payload["observedBy"] == .string("transcript.regenerate_replacement"),
              payload["reaction"] == .string(ExplicitReactionKind.explicitRetry.rawValue),
              let reactionTurnId = OutcomeTraceIdentity.normalized(event.turnId),
              let targetTurnId = OutcomeTraceIdentity.normalized(payload.string("targetTurnId")),
              reactionTurnId != targetTurnId,
              normalizedToken(event.sessionId, maximumLength: 128) != nil
        else { return nil }
        return ParsedReaction(
            kind: .explicitRetry,
            targetTurnId: targetTurnId,
            reactionTurnId: reactionTurnId,
            observedAt: event.ts
        )
    }

    private static func nonnegativeInt(_ value: JSONValue?, maximum: Int) -> Int? {
        guard case .int(let raw)? = value,
              raw >= 0,
              raw <= Int64(maximum) else { return nil }
        return Int(raw)
    }

    private static func normalizedToken(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed,
              !trimmed.isEmpty,
              trimmed.count <= maximumLength,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func providerFactOrder(_ lhs: ProviderFact, _ rhs: ProviderFact) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
        return lhs.model < rhs.model
    }

    private static func eventOrder(_ lhs: TurnTraceEvent, _ rhs: TurnTraceEvent) -> Bool {
        if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
        return lhs.turnId < rhs.turnId
    }
}

/// Closed validation for the opaque correlation token stored on canonical
/// assistant completions. It intentionally rejects whitespace, paths, prose,
/// and unbounded identifiers.
enum OutcomeTraceIdentity {
    private static let allowed = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._:")
    )

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw == value,
              !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return value
    }
}

/// Deterministic observational calibration over v5 recommendations joined to
/// `MetacognitiveTurnOutcomeTissue`. Only the lazy/none tool decision has an
/// exact matching outcome today. Approval-bound tool posture is not scored by
/// dispatch counts, and explicit retry is reported as a reaction—not treated
/// as causal proof that compute, model, context, or provider choice was wrong.
public struct MetacognitiveOutcomeCalibrationReport: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        public let turnId: String
        public let recommendedComputeLane: String
        public let recommendedToolLane: String
        public let recommendedContextLane: String
        public let recommendedAffordance: String?
        public let hasAuthoritativeTerminal: Bool
        public let hasCompleteProviderCorrelation: Bool
        public let observedProviders: [String]
        public let observedProviderModels: [String]
        public let terminalModelUsed: String?
        public let terminalReasoningEffort: String?
        public let toolDispatchCount: Int?
        public let failedToolDispatchCount: Int?
        public let contextExpansionCount: Int?
        public let explicitRetryEvidenceCount: Int
        public let toolLaneMatchedObservedUse: Bool?
    }

    public struct Cell: Sendable, Equatable {
        public let dimension: String
        public let value: String
        public let rows: Int
        public let authoritativeTerminals: Int
        public let completeProviderCorrelations: Int
        public let scoredToolDecisions: Int
        public let matchedToolDecisions: Int
        public let observedToolDispatches: Int
        public let observedToolFailures: Int
        public let observedContextExpansions: Int
        public let explicitRetryEvidence: Int
    }

    public let turns: [Turn]
    public let cells: [Cell]
    public let rejectedRecommendationCount: Int
    public let rejectedTerminalEventCount: Int
    public let rejectedReactionEventCount: Int

    public var recommendationCount: Int { turns.count }
    public var authoritativeTerminalCount: Int { turns.filter(\.hasAuthoritativeTerminal).count }
    public var completeProviderCorrelationCount: Int {
        turns.filter(\.hasCompleteProviderCorrelation).count
    }
    public var scoredToolDecisionCount: Int {
        turns.compactMap(\.toolLaneMatchedObservedUse).count
    }
    public var matchedToolDecisionCount: Int {
        turns.compactMap(\.toolLaneMatchedObservedUse).filter { $0 }.count
    }
    public var toolLaneAgreementRate: Double? {
        guard scoredToolDecisionCount > 0 else { return nil }
        return Double(matchedToolDecisionCount) / Double(scoredToolDecisionCount)
    }
    public var explicitRetryEvidenceCount: Int {
        turns.reduce(0) { $0 + $1.explicitRetryEvidenceCount }
    }

    public var traceValue: JSONValue {
        .object([
            "schema": .string("metacognition.outcome-calibration.v1"),
            "controlAuthority": .bool(false),
            "payloadFree": .bool(true),
            "recommendations": .int(Int64(recommendationCount)),
            "authoritativeTerminals": .int(Int64(authoritativeTerminalCount)),
            "completeProviderCorrelations": .int(Int64(completeProviderCorrelationCount)),
            "scoredToolDecisions": .int(Int64(scoredToolDecisionCount)),
            "matchedToolDecisions": .int(Int64(matchedToolDecisionCount)),
            "toolLaneAgreement": toolLaneAgreementRate.map(JSONValue.double) ?? .null,
            "explicitRetryEvidence": .int(Int64(explicitRetryEvidenceCount)),
            "rejectedRecommendations": .int(Int64(rejectedRecommendationCount)),
            "rejectedTerminalEvents": .int(Int64(rejectedTerminalEventCount)),
            "rejectedReactionEvents": .int(Int64(rejectedReactionEventCount)),
            "cells": .array(cells.map(\.traceValue)),
            "unscored": .object([
                "compute": .string("no_authoritative_quality_outcome"),
                "context": .string("expansion_proves_use_not_usefulness"),
                "model": .string("observed_not_recommended"),
                "provider": .string("observed_not_selected"),
                "approval": .string("dispatch_does_not_prove_approval_posture"),
                "retry": .string("explicit_reaction_not_causal_quality"),
                "correction": .string("no_canonical_structured_correction_owner"),
                "silence": .string("absence_never_classified"),
            ]),
        ])
    }

    public static func evaluate(events: [TurnTraceEvent]) -> Self {
        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: events)
        let authoritativeByID = Dictionary(uniqueKeysWithValues: tissue.turns.map { ($0.turnId, $0) })
        let grouped = Dictionary(grouping: events.filter { $0.kind == "turn.plan" }, by: \.turnId)
        var turns: [Turn] = []
        var rejectedRecommendationCount = 0

        for (rawTurnId, planRows) in grouped {
            let parsed = planRows.compactMap(parseRecommendation)
            guard planRows.count == 1,
                  parsed.count == 1,
                  let turnId = OutcomeTraceIdentity.normalized(rawTurnId)
            else {
                rejectedRecommendationCount += planRows.count
                continue
            }
            let recommendation = parsed[0]
            let observed = authoritativeByID[turnId]
            let toolMatch: Bool? = {
                guard let observed else { return nil }
                switch recommendation.toolLane {
                case MetacognitiveShadowRecommendation.ToolLane.none.rawValue:
                    return observed.terminal.toolDispatchCount == 0
                case MetacognitiveShadowRecommendation.ToolLane.lazy.rawValue:
                    return observed.terminal.toolDispatchCount > 0
                default:
                    // approval_bound recommends an authority posture, not an
                    // observed dispatch count, so it is deliberately unscored.
                    return nil
                }
            }()
            turns.append(Turn(
                turnId: turnId,
                recommendedComputeLane: recommendation.computeLane,
                recommendedToolLane: recommendation.toolLane,
                recommendedContextLane: recommendation.contextLane,
                recommendedAffordance: recommendation.affordance,
                hasAuthoritativeTerminal: observed != nil,
                hasCompleteProviderCorrelation: observed?.hasCompleteProviderCorrelation == true,
                observedProviders: observed?.providerFacts.map(\.provider) ?? [],
                observedProviderModels: observed?.providerFacts.map(\.model) ?? [],
                terminalModelUsed: observed?.terminal.modelUsed,
                terminalReasoningEffort: observed?.terminal.reasoningEffort,
                toolDispatchCount: observed?.terminal.toolDispatchCount,
                failedToolDispatchCount: observed?.terminal.failedToolDispatchCount,
                contextExpansionCount: observed?.terminal.contextExpansionCount,
                explicitRetryEvidenceCount: observed?.explicitReactions.count ?? 0,
                toolLaneMatchedObservedUse: toolMatch
            ))
        }
        turns.sort { $0.turnId < $1.turnId }

        let dimensions: [(String, (Turn) -> String?)] = [
            ("compute", { $0.recommendedComputeLane }),
            ("tool", { $0.recommendedToolLane }),
            ("context", { $0.recommendedContextLane }),
            ("affordance", { $0.recommendedAffordance }),
            ("model_used", { $0.terminalModelUsed }),
            ("reasoning_effort_used", { $0.terminalReasoningEffort }),
        ]
        var cells: [Cell] = []
        for (dimension, key) in dimensions {
            let groups = Dictionary(grouping: turns.compactMap { turn -> (String, Turn)? in
                guard let value = key(turn) else { return nil }
                return (value, turn)
            }, by: \.0)
            for value in groups.keys.sorted() {
                let group = groups[value, default: []].map(\.1)
                cells.append(Cell(
                    dimension: dimension,
                    value: value,
                    rows: group.count,
                    authoritativeTerminals: group.filter(\.hasAuthoritativeTerminal).count,
                    completeProviderCorrelations: group.filter(\.hasCompleteProviderCorrelation).count,
                    scoredToolDecisions: group.compactMap(\.toolLaneMatchedObservedUse).count,
                    matchedToolDecisions: group.compactMap(\.toolLaneMatchedObservedUse).filter { $0 }.count,
                    observedToolDispatches: saturatingSum(group.compactMap(\.toolDispatchCount)),
                    observedToolFailures: saturatingSum(group.compactMap(\.failedToolDispatchCount)),
                    observedContextExpansions: saturatingSum(group.compactMap(\.contextExpansionCount)),
                    explicitRetryEvidence: group.reduce(0) { $0 + $1.explicitRetryEvidenceCount }
                ))
            }
        }
        let multiValueDimensions: [(String, (Turn) -> [String])] = [
            ("provider_observed", { $0.observedProviders }),
            ("provider_model_observed", { $0.observedProviderModels }),
        ]
        for (dimension, values) in multiValueDimensions {
            let observations = turns.flatMap { turn in
                Set(values(turn)).sorted().map { ($0, turn) }
            }
            let groups = Dictionary(grouping: observations, by: \.0)
            for value in groups.keys.sorted() {
                let group = groups[value, default: []].map(\.1)
                cells.append(Cell(
                    dimension: dimension,
                    value: value,
                    rows: group.count,
                    authoritativeTerminals: group.filter(\.hasAuthoritativeTerminal).count,
                    completeProviderCorrelations: group.filter(\.hasCompleteProviderCorrelation).count,
                    scoredToolDecisions: group.compactMap(\.toolLaneMatchedObservedUse).count,
                    matchedToolDecisions: group.compactMap(\.toolLaneMatchedObservedUse).filter { $0 }.count,
                    observedToolDispatches: saturatingSum(group.compactMap(\.toolDispatchCount)),
                    observedToolFailures: saturatingSum(group.compactMap(\.failedToolDispatchCount)),
                    observedContextExpansions: saturatingSum(group.compactMap(\.contextExpansionCount)),
                    explicitRetryEvidence: group.reduce(0) { $0 + $1.explicitRetryEvidenceCount }
                ))
            }
        }
        cells.sort {
            if $0.dimension != $1.dimension { return $0.dimension < $1.dimension }
            return $0.value < $1.value
        }

        return Self(
            turns: turns,
            cells: cells,
            rejectedRecommendationCount: rejectedRecommendationCount,
            rejectedTerminalEventCount: tissue.rejectedTerminalEventCount,
            rejectedReactionEventCount: tissue.rejectedReactionEventCount
        )
    }

    private struct Recommendation {
        let computeLane: String
        let toolLane: String
        let contextLane: String
        let affordance: String?
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(into: 0) { total, value in
            let (next, overflow) = total.addingReportingOverflow(value)
            total = overflow ? Int.max : next
        }
    }

    private static func parseRecommendation(_ event: TurnTraceEvent) -> Recommendation? {
        guard case .object(let payload) = event.payload,
              case .object(let shadow)? = payload["metacognitiveShadow"],
              shadow["schema"] == .string("metacognition.shadow.v5"),
              shadow["controlAuthority"] == .bool(false),
              let compute = shadow.string("computeLane"),
              let tool = shadow.string("toolLane"),
              let context = shadow.string("contextLane"),
              MetacognitiveShadowRecommendation.ComputeLane(rawValue: compute) != nil,
              MetacognitiveShadowRecommendation.ToolLane(rawValue: tool) != nil,
              MetacognitiveShadowRecommendation.ContextLane(rawValue: context) != nil
        else { return nil }
        let affordance: String? = {
            guard case .object(let governor)? = shadow["governor"],
                  governor["schema"] == .string("metacognition.governor.shadow.v1"),
                  governor["controlAuthority"] == .bool(false),
                  let raw = governor.string("selectedAffordance"),
                  [
                    "respond_now", "deliberate_deeply", "use_tools",
                    "stage_approval", "ask_user", "wait_for_evidence",
                  ].contains(raw)
            else { return nil }
            return raw
        }()
        return Recommendation(
            computeLane: compute,
            toolLane: tool,
            contextLane: context,
            affordance: affordance
        )
    }
}

private extension MetacognitiveOutcomeCalibrationReport.Cell {
    var traceValue: JSONValue {
        .object([
            "dimension": .string(dimension),
            "value": .string(value),
            "rows": .int(Int64(rows)),
            "authoritativeTerminals": .int(Int64(authoritativeTerminals)),
            "completeProviderCorrelations": .int(Int64(completeProviderCorrelations)),
            "scoredToolDecisions": .int(Int64(scoredToolDecisions)),
            "matchedToolDecisions": .int(Int64(matchedToolDecisions)),
            "observedToolDispatches": .int(Int64(observedToolDispatches)),
            "observedToolFailures": .int(Int64(observedToolFailures)),
            "observedContextExpansions": .int(Int64(observedContextExpansions)),
            "explicitRetryEvidence": .int(Int64(explicitRetryEvidence)),
        ])
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}
