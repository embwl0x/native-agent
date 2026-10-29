import Foundation
import NativeAgentShared
import NativeAgentCore
import TurnTrace
import CognitiveSubstrate
import Senses
import StandingBots
import MemoryV2
// Blueprint: | `ChatOrchestration+AfterTurn.swift` | `SwiftNativeTurnEngine`: owed memory recording and serialized retained interpretation; predecessor tasks settle before current-handle cleanup |

extension SwiftNativeTurnEngine {
    // Settlement awaits the owed recording; only interpretation rides the
    // retained, serialized tail. Replies do not wait on interpretation and no
    // surface needs to drain it. Sleep joins accepted recordings; the journal
    // owns every unfinished interpretation (docs/STOP.md).
    private struct PendingMemoryPromotion {
        let userMessage: String
        let assistantMessage: String
        let toolDispatches: [TurnEngineResult.ToolDispatchRecord]
        let sessionId: String?
        let surface: String
        let origin: AfterTurnOrigin?
        let standingBot: BotDefinition?
        let senseReads: SenseTurnReads?
        /// The captured parent trace is rebound for recording and interpretation.
        let turnId: String?
        let bus: TurnTraceBus?
    }

    /// Capture recording on the turn's own answer-settlement handle.
    func deferMemoryPromotion(
        userMessage: String,
        assistantMessage: String,
        toolDispatches: [TurnEngineResult.ToolDispatchRecord],
        sessionId: String?,
        surface: String,
        took: String? = nil,
        afterReply held: AfterReply? = nil
    ) -> AfterReply {
        var origin = AfterTurnSource.origin
        origin?.took = took
        let pending = PendingMemoryPromotion(
            userMessage: userMessage, assistantMessage: assistantMessage,
            toolDispatches: toolDispatches, sessionId: sessionId, surface: surface,
            origin: origin, standingBot: StandingBotContinuity.currentBot,
            senseReads: SenseTurnReads.current, turnId: TurnTraceContext.turnId, bus: TurnTraceContext.bus)
        let held = held ?? afterReply {}
        held.beforeStart { await self.recordMemoryPromotion(pending) }
        return held
    }

    /// Await owed recording; interpretation alone waits on the serialized tail.
    private func recordMemoryPromotion(_ pending: PendingMemoryPromotion) async {
        // Rebind before recording and creating the interpretation task, which
        // inherits these task locals from its settled parent turn.
        await TurnTraceContext.$bus.withValue(pending.bus) {
        await TurnTraceContext.$turnId.withValue(pending.turnId) {
        await AfterTurnSource.$origin.withValue(pending.origin) {
        await SenseTurnReads.$current.withValue(pending.senseReads) {
        await StandingBotContinuity.$currentBot.withValue(pending.standingBot) {
            await memoryPromoter?.recordOwedTurn(
                userMessage: pending.userMessage,
                assistantMessage: pending.assistantMessage,
                sessionId: pending.sessionId ?? "swift-turn-engine",
                surface: pending.surface,
                standingAgentName: pending.standingBot?.name,
                turnId: pending.turnId
            )
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
                    surface: pending.surface
                )
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
        surface: String = "chat"
    ) async {
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
                ]
            )
            return
        }
        let observation = await memoryPromoter.observeTurnWithReport(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            sessionId: sessionId ?? "swift-turn-engine",
            surface: surface,
            standingAgentName: StandingBotContinuity.currentBot?.name,
            turnId: TurnTraceContext.turnId
        )
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
                "surpriseObservedTurns": Int64(observation.surprise?.agreement.turns ?? 0),
                "surpriseWouldDefer": Int64(observation.surprise?.agreement.wouldDefer ?? 0),
                "surpriseChangedOnPrediction": Int64(observation.surprise?.agreement.changedOnPrediction ?? 0),
                "surpriseIncompletePredictions": Int64(observation.surprise?.agreement.incompletePredictions ?? 0),
                "surpriseTries": Int64(observation.surprise?.check.tries ?? 0),
                "surpriseHits": Int64(observation.surprise?.check.hits ?? 0),
            ],
            flags: [
                "configured": true,
                "outcomeReported": true,
                "surpriseLedgerReadable": observation.surprise?.agreement.ledgerReadable ?? false,
                "surpriseStanding": observation.surprise?.check.standing == true,
                "surpriseDeferred": observation.surprise?.deferred == true,
            ],
            labels: [
                "semanticExtraction": observation.extraction.semanticStatus.rawValue,
                "interpretationFailure": observation.extraction.failure?.interpretationFailure.rawValue ?? "none",
                "surpriseVerdict": observation.surprise?.check.verdict.rawValue ?? "unreported",
                "surpriseEvidence": observation.surprise?.check.reason ?? "unreported",
                "surpriseAgent": observation.surprise?.check.scope?.agent ?? "unreported",
                "surpriseDetector": String(observation.surprise?.check.scope?.detector ?? 0),
                "surpriseRule": observation.surprise?.check.rule ?? "none",
                "surpriseLowerBound": String(observation.surprise?.check.lowerBound ?? 0),
                "surpriseCostBar": String(observation.surprise?.check.costBar ?? 1),
                "failureReason": observation.extraction.failure?.reason.rawValue ?? "none",
                "recoveryAction": observation.extraction.failure?.recovery ?? "none",
                "memoryModel": observation.extraction.failure?.model ?? "unreported",
                "memorySurface": observation.extraction.failure?.surface ?? "unreported",
            ]
        )
    }
}
