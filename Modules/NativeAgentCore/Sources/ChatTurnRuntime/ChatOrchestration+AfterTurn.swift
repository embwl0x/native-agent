import Foundation
import AgentWorkspace
import NativeAgentShared
import NativeAgentCore
import TurnTrace
import CognitiveSubstrate
import Senses
import StandingBots
import MemoryV2
// Blueprint: | `ChatOrchestration+AfterTurn.swift` | `SwiftNativeTurnEngine`; Owed recording before retained interpretation |

extension SwiftNativeTurnEngine {
    // Settlement awaits recording; interpretation runs on a retained serial tail so replies do not wait for it.
    // Sleep joins accepted recordings, and the journal retains unfinished interpretation.
    private struct PendingMemoryPromotion {
        let userMessage: String
        let assistantMessage: String
        let toolDispatches: [TurnEngineResult.ToolDispatchRecord]
        let sessionId: String?
        let surface: String
        let repliedAt: Date?
        let turn: Turn
        let work: ChatTurnWork
        let bus: TurnTraceBus?
    }

    func deferMemoryPromotion(
        userMessage: String,
        assistantMessage: String,
        toolDispatches: [TurnEngineResult.ToolDispatchRecord],
        sessionId: String?,
        surface: String,
        took: String? = nil,
        afterReply held: AfterReply? = nil,
        replied: Bool = true,
        turn: Turn,
    work: ChatTurnWork) -> AfterReply {
        var origin = turn.afterTurnOrigin
        origin?.took = took
        // A thought about a care is judged for that care: its movement is how the thought mattered.
        if sessionId == Happening.stream, !turn.careWakes.isEmpty {
            origin?.careWakes = turn.careWakes
        }
        let pending = PendingMemoryPromotion(
            userMessage: userMessage, assistantMessage: assistantMessage,
            toolDispatches: toolDispatches, sessionId: sessionId, surface: surface,
            repliedAt: replied ? Date() : nil, turn: turn.with(\.afterTurnOrigin, origin), work: work, bus: TurnTraceContext.bus)
        let held = held ?? afterReply {}
        held.beforeStart { await self.recordMemoryPromotion(pending) }
        return held
    }

    private func recordMemoryPromotion(_ pending: PendingMemoryPromotion) async {
        let turn = pending.turn
        let work = pending.work
        // Only trace correlation is rebound; interpretation receives the saved turn and operation.
        await TurnTraceContext.$bus.withValue(pending.bus) {
        await TurnTraceContext.$turnId.withValue(pending.turn.id) {
        await holding(turn.with(\.afterTurnOrigin, pending.turn.afterTurnOrigin)) { turn in
        await holding(work.with(\.senseReads, pending.work.senseReads)) { work in
        await holding(turn.with(\.standingBot, pending.turn.standingBot)) { turn in
            await memoryPromoter?.recordOwedTurn(
                userMessage: pending.userMessage,
                assistantMessage: pending.assistantMessage,
                sessionId: pending.sessionId ?? "swift-turn-engine",
                surface: pending.surface,
                standingAgentName: pending.turn.standingBot?.name,
                repliedAt: pending.repliedAt, turn: turn)
            let previous = deferredMemoryPromotion
            let id = UUID()
            deferredMemoryPromotionID = id
            deferredMemoryPromotion = Task { [self] in
                defer {
                    if deferredMemoryPromotionID == id {
                        deferredMemoryPromotion = nil
                        deferredMemoryPromotionID = nil
                    }
                }
                await previous?.value
                await observeMemoryPromotion(
                    userMessage: pending.userMessage,
                    assistantMessage: pending.assistantMessage,
                    toolDispatches: pending.toolDispatches,
                    sessionId: pending.sessionId,
                    surface: pending.surface,
                 turn: turn,work: work)
            }
        }
        }
        }
        }
        }
    }

    func observeMemoryPromotion(
        userMessage: String,
        assistantMessage: String,
        toolDispatches: [TurnEngineResult.ToolDispatchRecord] = [],
        sessionId: String?,
        surface: String = "chat",
        turn: Turn,
    work: ChatTurnWork) async {
        let startNs = DispatchTime.now().uptimeNanoseconds
        guard let memoryPromoter else {
            ContextStageTrace.emitStage(
                name: .memoryPromotion,
                elapsedMs: Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
                surface: surface,
                counts: [
                    "userMessageChars": Int64(userMessage.count),
                    "assistantMessageChars": Int64(assistantMessage.count),
                    "stagedProposalCount": 0,
                ],
                flags: [
                    "configured": false,
                    "outcomeReported": false,
                ],
                turn: turn
            )
            return
        }
        let observation = await memoryPromoter.observeTurnWithReport(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId ?? "swift-turn-engine",
            surface: surface,
            standingAgentName: turn.standingBot?.name,
            turn: turn, senseReads: work.senseReads)
        ContextStageTrace.emitStage(
            name: .memoryPromotion,
            elapsedMs: Int64((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
            surface: surface,
            counts: [
                "userMessageChars": Int64(userMessage.count),
                "assistantMessageChars": Int64(assistantMessage.count),
                "stagedProposalCount": Int64(observation.proposals.count),
                "extractedCandidateCount": Int64(observation.extraction.candidates.count),
                "semanticCandidateCount": Int64(observation.extraction.semanticCandidateCount),
                "toolDispatchCount": Int64(toolDispatches.count),
                "savedCorrectionCount": Int64(observation.savedCorrectionCount),
                "pendingCorrectionCount": Int64(observation.pendingCorrectionCount),
                "failedCorrectionCount": Int64(observation.failedCorrectionCount),
            ],
            flags: [
                "configured": true,
                "outcomeReported": true,
            ],
            labels: [
                "semanticExtraction": observation.extraction.semanticStatus.rawValue,
                "interpretationFailure": observation.extraction.failure?.interpretationFailure.rawValue ?? "none",
                "failureReason": observation.extraction.failure?.reason.rawValue ?? "none",
                "recoveryAction": observation.extraction.failure?.recovery ?? "none",
                "memoryModel": observation.extraction.failure?.model ?? "unreported",
                "memorySurface": observation.extraction.failure?.surface ?? "unreported",
            ],
            turn: turn
        )
    }
}
