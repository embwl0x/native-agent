import Foundation
@testable import NativeAgentEvaluation
import Testing
@testable import ChatOrchestration
import PersistenceCore

@Suite("Metacognitive outcome tissue")
struct MetacognitiveOutcomeTissueTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("correlates exact terminal provider tool context and retry facts")
    func exactCorrelation() throws {
        let events = [
            plan(turn: "turn-a", tool: "lazy", affordance: "use_tools"),
            provider(turn: "turn-a", at: 1),
            terminal(turn: "turn-a", at: 2, tools: 2, failures: 1, expansions: 1),
            TurnTraceEvent(
                turnId: "turn-b",
                ts: at(3),
                kind: "turn.reaction",
                sessionId: "session-1",
                surface: "chat",
                payload: .object([
                    "schema": .string("metacognition.reaction.v1"),
                    "controlAuthority": .bool(false),
                    "reaction": .string("explicit_retry"),
                    "targetTurnId": .string("turn-a"),
                    "observedBy": .string("transcript.regenerate_replacement"),
                ])
            ),
        ]

        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: events)
        let turn = try #require(tissue.turns.first)
        #expect(tissue.turns.count == 1)
        #expect(tissue.rejectedTerminalEventCount == 0)
        #expect(tissue.rejectedReactionEventCount == 0)
        #expect(tissue.explicitRetryEvidenceCount == 1)
        #expect(turn.hasCompleteProviderCorrelation)
        #expect(turn.providerFacts.map(\.provider) == ["openai"])
        #expect(turn.providerFacts.map(\.model) == ["gpt-5.6"])
        #expect(turn.terminal.modelUsed == "gpt-5.6")
        #expect(turn.terminal.reasoningEffort == "high")
        #expect(turn.terminal.contextSource == "fluid_context")
        #expect(turn.terminal.toolDispatchCount == 2)
        #expect(turn.terminal.successfulToolDispatchCount == 1)
        #expect(turn.terminal.failedToolDispatchCount == 1)
        #expect(turn.terminal.contextExpansionCount == 1)
        #expect(turn.explicitReactions.map(\.reactionTurnId) == ["turn-b"])

        let report = MetacognitiveOutcomeCalibrationReport.evaluate(events: events)
        #expect(report.recommendationCount == 1)
        #expect(report.authoritativeTerminalCount == 1)
        #expect(report.completeProviderCorrelationCount == 1)
        #expect(report.scoredToolDecisionCount == 1)
        #expect(report.matchedToolDecisionCount == 1)
        #expect(report.toolLaneAgreementRate == 1)
        #expect(report.explicitRetryEvidenceCount == 1)
        #expect(report.cells.contains {
            $0.dimension == "provider_observed" && $0.value == "openai" && $0.rows == 1
        })
        #expect(report.cells.contains {
            $0.dimension == "provider_model_observed" && $0.value == "gpt-5.6" && $0.rows == 1
        })
        #expect(
            report.traceValue
                == MetacognitiveOutcomeCalibrationReport.evaluate(events: Array(events.reversed())).traceValue
        )
        guard case .object(let value) = report.traceValue else {
            Issue.record("expected object report")
            return
        }
        #expect(value["controlAuthority"] == .bool(false))
        #expect(value["payloadFree"] == .bool(true))
    }

    @Test("rejects malformed terminal and cannot reconstruct an outcome from prose or loose rows")
    func terminalFailsClosed() {
        let invalid = TurnTraceEvent(
            turnId: "turn-invalid",
            ts: at(2),
            kind: "turn.terminal",
            sessionId: "session-1",
            surface: "chat",
            payload: .object([
                "schema": .string("metacognition.observed.v1"),
                "status": .string("completed"),
                "modelUsed": .string("gpt-5.6"),
                "reasoningEffort": .string("high"),
                "turnElapsedMs": .int(10),
                "contextSource": .string("fluid_context"),
                "contextSelectedAtomCount": .int(1),
                "contextPacketCharacters": .int(20),
                "contextExpandablePointerCount": .int(0),
                "toolSchemaCount": .int(2),
                "recalledMemoryCount": .int(0),
                "toolDispatchCount": .int(1),
                "failedToolDispatchCount": .int(2),
                "contextExpansionCount": .int(0),
            ])
        )
        let prose = TurnTraceEvent(
            turnId: "turn-invalid",
            ts: at(3),
            kind: "assistant.message",
            payload: .object(["content": .string("I succeeded; the user loved it")])
        )
        let looseTool = TurnTraceEvent(
            turnId: "turn-invalid",
            ts: at(4),
            kind: "tool.dispatch",
            payload: .object(["phase": .string("end"), "status": .string("ok")])
        )
        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: [invalid, prose, looseTool])
        #expect(tissue.turns.isEmpty)
        #expect(tissue.terminalEventCount == 1)
        #expect(tissue.rejectedTerminalEventCount == 1)
    }

    @Test("missing provider detail remains incomplete while the terminal stays authoritative")
    func providerDetailFailsClosed() throws {
        let incompleteProvider = TurnTraceEvent(
            turnId: "turn-a",
            ts: at(1),
            kind: "llm.call",
            payload: .object([
                "provider": .string("openai"),
                "model": .string("gpt-5.6"),
            ])
        )
        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: [
            incompleteProvider,
            terminal(turn: "turn-a", at: 2),
        ])
        let turn = try #require(tissue.turns.first)
        #expect(turn.providerFacts.isEmpty)
        #expect(turn.hasCompleteProviderCorrelation == false)
        #expect(turn.terminal.toolDispatchCount == 0)
    }

    @Test("reaction evidence requires exact owner target chronology and session")
    func reactionProvenanceFailsClosed() throws {
        let target = terminal(turn: "turn-a", at: 5)
        let wrongSession = reaction(
            current: "turn-b", target: "turn-a", at: 6, session: "other"
        )
        let beforeTarget = reaction(
            current: "turn-c", target: "turn-a", at: 4, session: "session-1"
        )
        let wrongOwner = TurnTraceEvent(
            turnId: "turn-d",
            ts: at(7),
            kind: "turn.reaction",
            sessionId: "session-1",
            payload: .object([
                "schema": .string("metacognition.reaction.v1"),
                "controlAuthority": .bool(false),
                "reaction": .string("explicit_retry"),
                "targetTurnId": .string("turn-a"),
                "observedBy": .string("assistant_prose_classifier"),
            ])
        )
        let valid = reaction(
            current: "turn-e", target: "turn-a", at: 8, session: "session-1"
        )
        let duplicate = reaction(
            current: "turn-e", target: "turn-a", at: 9, session: "session-1"
        )

        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: [
            target, wrongSession, beforeTarget, wrongOwner, valid, duplicate,
        ])
        let turn = try #require(tissue.turns.first)
        #expect(tissue.reactionEventCount == 5)
        #expect(tissue.rejectedReactionEventCount == 3)
        #expect(turn.explicitReactions.count == 1)
        #expect(turn.explicitReactions.first?.reactionTurnId == "turn-e")
    }

    @Test("approval posture and explicit retry remain unscored quality dimensions")
    func noQualityTheater() throws {
        let events = [
            plan(turn: "turn-a", tool: "approval_bound", affordance: "stage_approval"),
            provider(turn: "turn-a", at: 1),
            terminal(turn: "turn-a", at: 2, tools: 1),
            reaction(current: "turn-b", target: "turn-a", at: 3, session: "session-1"),
        ]
        let report = MetacognitiveOutcomeCalibrationReport.evaluate(events: events)
        let turn = try #require(report.turns.first)
        #expect(turn.toolLaneMatchedObservedUse == nil)
        #expect(report.scoredToolDecisionCount == 0)
        #expect(report.toolLaneAgreementRate == nil)
        #expect(report.explicitRetryEvidenceCount == 1)
        guard case .object(let value) = report.traceValue,
              case .object(let unscored)? = value["unscored"] else {
            Issue.record("missing unscored contract")
            return
        }
        #expect(unscored["approval"] == .string("dispatch_does_not_prove_approval_posture"))
        #expect(unscored["retry"] == .string("explicit_reaction_not_causal_quality"))
        #expect(unscored["correction"] == .string("no_canonical_structured_correction_owner"))
        #expect(unscored["silence"] == .string("absence_never_classified"))
    }

    @Test("duplicate or unknown recommendation shapes are excluded deterministically")
    func recommendationEpochFailsClosed() {
        let valid = plan(turn: "turn-a", tool: "none", affordance: "respond_now")
        let duplicate = plan(turn: "turn-a", tool: "none", affordance: "respond_now")
        let legacy = TurnTraceEvent(
            turnId: "legacy",
            kind: "turn.plan",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v4"),
                    "controlAuthority": .bool(false),
                    "computeLane": .string("frontier_standard"),
                    "toolLane": .string("none"),
                    "contextLane": .string("minimal"),
                ]),
            ])
        )
        let report = MetacognitiveOutcomeCalibrationReport.evaluate(events: [valid, duplicate, legacy])
        #expect(report.turns.isEmpty)
        #expect(report.rejectedRecommendationCount == 3)
        #expect(report.cells.isEmpty)
    }

    @Test("hostile numeric rows and mismatched provider chronology fail closed")
    func hostileRowsFailClosed() throws {
        var oversized = terminal(turn: "too-large", at: 2)
        oversized = TurnTraceEvent(
            turnId: oversized.turnId,
            ts: oversized.ts,
            kind: oversized.kind,
            sessionId: oversized.sessionId,
            surface: oversized.surface,
            payload: .object([
                "schema": .string("metacognition.observed.v1"),
                "status": .string("completed"),
                "modelUsed": .string("gpt-5.6"),
                "reasoningEffort": .string("high"),
                "turnElapsedMs": .int(Int64.max),
                "contextSource": .string("fluid_context"),
                "contextSelectedAtomCount": .int(1),
                "contextPacketCharacters": .int(20),
                "contextExpandablePointerCount": .int(0),
                "toolSchemaCount": .int(0),
                "recalledMemoryCount": .int(0),
                "toolDispatchCount": .int(0),
                "failedToolDispatchCount": .int(0),
                "contextExpansionCount": .int(0),
            ])
        )
        let futureProvider = TurnTraceEvent(
            turnId: "turn-a",
            ts: at(3),
            kind: "llm.call",
            sessionId: "session-1",
            surface: "telegram",
            payload: .object([
                "provider": .string("openai"),
                "model": .string("gpt-5.6"),
                "durationMs": .int(500),
            ])
        )
        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: [
            oversized,
            futureProvider,
            terminal(turn: "turn-a", at: 2),
        ])

        #expect(tissue.rejectedTerminalEventCount == 1)
        let accepted = try #require(tissue.turns.first { $0.turnId == "turn-a" })
        #expect(accepted.providerFacts.isEmpty)
        #expect(accepted.hasCompleteProviderCorrelation == false)
    }

    @Test("provider correlation requires the terminal surface when one is authoritative")
    func missingProviderSurfaceFailsClosed() throws {
        let missingSurface = TurnTraceEvent(
            turnId: "turn-a",
            ts: at(1),
            kind: "llm.call",
            sessionId: "session-1",
            surface: nil,
            payload: .object([
                "provider": .string("openai"),
                "model": .string("gpt-5.6"),
                "durationMs": .int(500),
            ])
        )
        let tissue = MetacognitiveTurnOutcomeTissue.evaluate(events: [
            missingSurface,
            terminal(turn: "turn-a", at: 2),
        ])
        let accepted = try #require(tissue.turns.first)
        #expect(accepted.providerFacts.isEmpty)
        #expect(accepted.hasCompleteProviderCorrelation == false)
    }

    private func plan(
        turn: String,
        tool: String,
        affordance: String
    ) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: turn,
            ts: at(0),
            kind: "turn.plan",
            sessionId: "session-1",
            surface: "chat",
            payload: .object([
                "metacognitiveShadow": .object([
                    "schema": .string("metacognition.shadow.v5"),
                    "controlAuthority": .bool(false),
                    "computeLane": .string("frontier_standard"),
                    "toolLane": .string(tool),
                    "contextLane": .string("planned"),
                    "governor": .object([
                        "schema": .string("metacognition.governor.shadow.v1"),
                        "controlAuthority": .bool(false),
                        "selectedAffordance": .string(affordance),
                    ]),
                ]),
            ])
        )
    }

    private func provider(turn: String, at seconds: TimeInterval) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: turn,
            ts: at(seconds),
            kind: "llm.call",
            sessionId: "session-1",
            surface: "chat",
            payload: .object([
                "provider": .string("openai"),
                "model": .string("gpt-5.6"),
                "durationMs": .int(500),
            ])
        )
    }

    private func terminal(
        turn: String,
        at seconds: TimeInterval,
        tools: Int = 0,
        failures: Int = 0,
        expansions: Int = 0
    ) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: turn,
            ts: at(seconds),
            kind: "turn.terminal",
            sessionId: "session-1",
            surface: "chat",
            payload: .object([
                "schema": .string("metacognition.observed.v1"),
                "status": .string("completed"),
                "modelUsed": .string("gpt-5.6"),
                "reasoningEffort": .string("high"),
                "turnElapsedMs": .int(760),
                "contextSource": .string("fluid_context"),
                "contextSelectedAtomCount": .int(6),
                "contextPacketCharacters": .int(2_048),
                "contextExpandablePointerCount": .int(2),
                "toolSchemaCount": .int(12),
                "recalledMemoryCount": .int(3),
                "toolDispatchCount": .int(Int64(tools)),
                "failedToolDispatchCount": .int(Int64(failures)),
                "contextExpansionCount": .int(Int64(expansions)),
            ])
        )
    }

    private func reaction(
        current: String,
        target: String,
        at seconds: TimeInterval,
        session: String
    ) -> TurnTraceEvent {
        TurnTraceEvent(
            turnId: current,
            ts: at(seconds),
            kind: "turn.reaction",
            sessionId: session,
            surface: "chat",
            payload: .object([
                "schema": .string("metacognition.reaction.v1"),
                "controlAuthority": .bool(false),
                "reaction": .string("explicit_retry"),
                "targetTurnId": .string(target),
                "observedBy": .string("transcript.regenerate_replacement"),
            ])
        )
    }

    private func at(_ offset: TimeInterval) -> Date {
        base.addingTimeInterval(offset)
    }
}
