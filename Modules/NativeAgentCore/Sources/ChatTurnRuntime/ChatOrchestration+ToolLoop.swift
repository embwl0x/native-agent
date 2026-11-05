import ChatToolParsing
import ChatToolRuntime
import ChatSessionWork
import NativeAgentShared
import Foundation
import Dispatcher
import NativeAgentCore
import PersistenceCore
import MemoryV2
import ProviderRouting
import MacIntegration
import Context
import MacControl
import AgentWorkspace
import ToolRegistry
import Desk
import TrustCenter
import TurnTrace
// Blueprint: | `ChatOrchestration+ToolLoop.swift` | `TurnContext`; `withToolSchemas`; `finishReplyTurn`; `.completed` |

// MARK: - Tool-dispatch loops

// Context is prepared once; both protocols share one streaming loop so dispatch and completion behavior cannot drift.

// MARK: - Lazy tool filtering

extension TurnContext {
    func withToolSchemas(_ newSchemas: [LLMToolSchema]) -> TurnContext {
        var copy = self
        copy.toolSchemas = newSchemas
        return copy
    }
}

// MARK: - Loop

extension SwiftNativeTurnEngine {
    // MARK: - Turn-loop segments

    /// Empty replies leave no assistant message. Append the nudge through
    /// the shared prefix owner so it preserves Anthropic role adjacency.
    static func appendStructuredUserNudge(_ text: String, to conversation: inout [LLMMessage]) {
        ConversationPrefixSeeding.appendUserText(text, to: &conversation)
    }

    /// Reply-end settlement records the loop exit separately from work completion; private after-turn work requires the part's request.
    func finishReplyTurn(
        reply: String,
        ctx: TurnContext,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String,
        workingCommentaryCharacters: Int? = nil,
        completionState: TurnEngineResult.CompletionState = .completed,
        afterTurn: Bool = true,
        took: String? = nil,
        afterReply: AfterReply? = nil,
        turn: Turn, work: ChatTurnWork
    ) async -> TurnEngineResult {
        let recalledIds = ctx.resolvedRecalledIds
        await ctx.fluidContextTurn?.recordOutcome(.completed)
        var held = afterReply
        if afterTurn {
            await queueStoppedRuns(dispatches: dispatches, surface: surface, turn: turn)
            held = deferMemoryPromotion(
                userMessage: userMessage,
                assistantMessage: reply,
                toolDispatches: dispatches,
                sessionId: sessionId,
                surface: surface,
                took: took,
                afterReply: held,
             turn: turn,work: work)
        }
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: reply,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            providerCallCount: providerCallCount,
            completionState: completionState,
            afterReply: held,
            workingCommentaryCharacters: workingCommentaryCharacters
        )
    }

    /// Typed stopped-run receipts retain their continuation and origin.
    /// Reply prose never creates work; explicit commitments use queue.add.
    func queueStoppedRuns(dispatches: [TurnEngineResult.ToolDispatchRecord], surface: String, turn: Turn) async {
        guard let root = remPinsDataRoot else { return }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let origin = turn.originPrincipal
        let steer = PeerDataTaint.carried(turn: turn, peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: turn.envelope?.verifiedUserId)
        // Retain the part's latest stopped-run state and steering so its continuation waits for its own turn.
        var stopped: [String: String] = [:]
        for dispatch in dispatches where dispatch.name == "app" {
            guard case .string(let action)? = dispatch.input["action"],
                  action.hasPrefix("authored.") || ["ability.resume", "skill.run", "skill.resume"].contains(action),
                  case .object(let outer) = dispatch.result else { continue }
            // A part's own action answers inside the door's receipt; a resume answers as itself.
            let receipt: [String: JSONValue] = if case .object(let inner)? = outer["result"], outer["resume"] == nil { inner } else { outer }
            if case .object(let resume)? = receipt["resume"], case .string(let run)? = resume["run_id"],
               case .string(let skill)? = receipt["name"] {
                let held = if case .array(let items)? = resume["held"] {
                    items.compactMap { if case .string(let id) = $0 { id } else { nil } }
                } else { [String]() }
                let question = if case .string(let text)? = resume["question"] { text } else { "" }
                stopped[run] = MyQueue.skillRunWords(skill: skill, run: run, question: question, held: held)
            } else if dispatch.input["preview"] != .bool(true), case .object(let args)? = dispatch.input["args"], case .string(let run)? = args["run_id"] {
                stopped.removeValue(forKey: run)
            }
        }
        for words in stopped.values.sorted() {
            do {
                _ = try await MyQueue.add(DeskStep(words: words, when: "own_turn", peers: steer.sources, elevated: steer.elevated,
                                                   session: turn.verifiedSessionID, origin: origin,
                                                   replyRoute: TurnEnvelope.current(turn: turn, surface: surface).persistedMetadata()), store: store)
            } catch {
                nativeLog("[my-queue] a stopped skill run was not queued: \(error)")
            }
        }
    }

    nonisolated static func waitingOn(_ result: JSONValue) -> JSONValue? {
        if let need = InlineInteractionNeed.interaction(in: result), InlineInteractionNeed.blocksTurn(need) {
            return .object(["card": .string(need.id), "on": .string(need.title)])
        }
        guard ChatToolOutcome.isWaitingApproval(result), case .object(let fields) = result else { return nil }
        return .object(["card": fields["approvalId"] ?? fields["approval_id"] ?? .null, "on": .string("the person's approval of this call")])
    }

    /// Flush pending prose before dispatching calls; synthesize unique missing IDs and preserve result pairing.
    func runToolDispatchRound(
        providerCalls: [ParsedToolCall],
        iterationRawText: String,
        ctx: TurnContext,
        surface: String,
        sessionId: String?,
        tools: any ToolDispatchClient,
        progress: ToolProgress?,
        conversation: inout [LLMMessage],
        dispatches: inout [TurnEngineResult.ToolDispatchRecord],
        providerTools: ProviderToolNameMap,
        cancelFlagPath: URL? = nil,
        /// The marker protocol replays the model's own text and returns results in one text message.
        markerCodec: TextMarkerCodec? = nil,
        toolBoundaryReason: LLMToolBoundaryReason? = nil,
        turn: Turn, work: ChatTurnWork
    ) async throws {
        // Structured replies strip textual call markers because tool-use blocks carry the calls.
        // Marker replies cut after the last marker: later prose was written before any result existed.
        let prose = ToolCallParser.stripToolUseMarkers(iterationRawText).trimmingCharacters(in: .whitespacesAndNewlines)
        var assistantBlocks: [LLMContentBlock] = []
        if let markerCodec {
            assistantBlocks.append(.text(markerCodec.throughLastMarker(iterationRawText)))
        } else if !prose.isEmpty {
            assistantBlocks.append(.text(prose))
        }
        // Missing ids use round base, call index and name; pairedIds echoes each unique id by position.
        let roundBase = dispatches.count
        let pairedIds = providerCalls.enumerated().map { idx, call in
            call.id.isEmpty
                ? "toolu_synth_\(roundBase + idx)_\(call.name)"
                : call.id
        }
        conversation.append(try ToolCallCodec.assistantMessage(prose: assistantBlocks, calls: providerCalls,
            pairedIDs: pairedIds, markerCodec: markerCodec))

        let (toolResultBlocks, iterationRecords) = await dispatchIterationCalls(
            providerCalls: providerCalls,
            pairedIds: pairedIds,
            providerTools: providerTools,
            priorDispatches: dispatches,
            modelId: ctx.modelId,
            surface: surface,
            sessionId: sessionId,
            personaID: ctx.personaID,
            fluidContextTurn: ctx.fluidContextTurn,
            tools: tools,
            progress: progress,
            cancelFlagPath: cancelFlagPath,
            neutralizingTextResults: markerCodec != nil,
         turn: turn, work: work)
        dispatches.append(contentsOf: iterationRecords)
        conversation.append(contentsOf: LocalToolImage.continuation(toolResultBlocks))
        if let toolBoundaryReason {
            TurnObservation.apply(.boundary(toolBoundaryReason), to: &conversation, surface: surface, turn: turn)
        }
        LocalToolImage.boundConversation(&conversation)
        turn.execution?.keepPixels(LocalToolImage.imageNames(conversation))
        // A takeover answers this call. The recorded refusal reaches the agent's next
        // model round immediately; whether to wait, answer or stop is the agent's call.
        if StandingBotContinuity.isHelperTurn(turn: turn), iterationRecords.contains(where: { ChatToolOutcome.isWaitingApproval($0.result) }) {
            turn.execution?.waitForApproval()
        }
        // A blocking need (a macOS grant, the agent's own question) is the one the turn
        // ends waiting on; the round's results still reach the agent first.
        if let waiting = iterationRecords.lazy
            .compactMap({ InlineInteractionNeed.interaction(in: $0.result) })
            .first(where: InlineInteractionNeed.blocksTurn) {
            turn.execution?.waitForInteraction(waiting)
        }
    }

}
