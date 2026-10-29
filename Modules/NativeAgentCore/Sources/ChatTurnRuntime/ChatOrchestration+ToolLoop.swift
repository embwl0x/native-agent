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
// Blueprint: | `ChatOrchestration+ToolLoop.swift` | `TurnContext`: `withToolSchemas`; `finishReplyTurn` settles reply.end, including incomplete work; ContextFlow's `.completed` records this loop exit; tool rounds distinguish Stop, control return and failed observation; failed handback waits end the turn without resuming, and the return nudge requires current driver permission |

// MARK: - Tool-dispatch loops

// Context is prepared once. Each iteration parses provider output, dispatches
// through the injected tool client, and returns tool results to the provider.
// Tool errors remain model-visible feedback. The loop itself lives in
// ChatOrchestration+StreamingToolLoop.swift; its dispatch, completion, and
// waiting segments are below.

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
    // Context, completion, dispatch and waiting. Provider calls stay in the
    // loop, which owns live deltas and protocol-buffer cleanup.

    /// Empty replies leave no assistant message. Append the nudge through
    /// the shared prefix owner so it preserves Anthropic role adjacency.
    static func appendStructuredUserNudge(_ text: String, to conversation: inout [LLMMessage]) {
        ConversationPrefixSeeding.appendUserText(text, to: &conversation)
    }

    /// Settles reply.end, including incomplete/waiting work. ContextFlow records
    /// `.completed` for this loop exit; the result's completionState describes work.
    /// Runs after-turn work only when the part requested it.
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
        afterReply: AfterReply? = nil
    ) async -> TurnEngineResult {
        let recalledIds = ctx.resolvedRecalledIds
        await ctx.fluidContextTurn?.recordOutcome(.completed)
        var held = afterReply
        if afterTurn {
            await queueStoppedRuns(dispatches: dispatches, surface: surface)
            held = deferMemoryPromotion(
                userMessage: userMessage,
                assistantMessage: reply,
                toolDispatches: dispatches,
                sessionId: sessionId,
                surface: surface,
                took: took,
                afterReply: held
            )
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
    func queueStoppedRuns(dispatches: [TurnEngineResult.ToolDispatchRecord], surface: String) async {
        guard let root = remPinsDataRoot else { return }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let origin = ChatPersistenceContext.originPrincipal
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        // A part's run still stopped as the turn ends waits for her own turn,
        // the turn's steer with it: its last word this turn is the one that counts.
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
                                                   session: ChatToolSessionContext.verifiedSessionId, origin: origin,
                                                   replyRoute: TurnEnvelope.current(surface: surface).persistedMetadata()), store: store)
            } catch {
                nativeLog("[my-queue] a stopped skill run was not queued: \(error)")
            }
        }
    }

    /// The card a result waits on and what it waits for, when it waits on a person.
    nonisolated static func waitingOn(_ result: JSONValue) -> JSONValue? {
        if let need = InlineInteractionNeed.interaction(in: result), InlineInteractionNeed.blocksTurn(need) {
            return .object(["card": .string(need.id), "on": .string(need.title)])
        }
        guard ChatToolOutcome.isWaitingApproval(result), case .object(let fields) = result else { return nil }
        return .object(["card": fields["approvalId"] ?? fields["approval_id"] ?? .null, "on": .string("the person's approval of this call")])
    }

    /// Post-provider-call round of the structured loop: mint the
    /// assistant message (prose + tool_use blocks, synthesizing collision-free
    /// ids for id-less calls), dispatch the iteration's calls through the shared
    /// core, append the paired tool_result user message, run the no-progress
    /// guard. The loop flushes its
    /// pending prose delta BEFORE calling this.
    func runToolDispatchRound(
        providerCalls: [ParsedToolCall],
        iterationRawText: String,
        ctx: TurnContext,
        surface: String,
        sessionId: String?,
        tools: any ToolDispatchClient,
        progress: TurnEventSink?,
        conversation: inout [LLMMessage],
        dispatches: inout [TurnEngineResult.ToolDispatchRecord],
        providerTools: ProviderToolNameMap,
        cancelFlagPath: URL? = nil,
        /// Set on the marker protocol: the round replays as the model's own
        /// text and its results come back as one text message (8b carrier).
        markerCodec: TextMarkerCodec? = nil,
        toolBoundaryReason: LLMToolBoundaryReason? = nil
    ) async throws {
        // Append the assistant turn that contained the tool calls. Strip any
        // <tool_use> markers from the surfaced text so the assistant text block
        // carries only the model's prose (the structured toolUse blocks below
        // carry the actual tool calls). The marker protocol replays the
        // model's reply as written, cut after its last marker: text past it
        // was written before any result existed.
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

        // Dispatch safe calls concurrently and append one user message of results paired by id in original order.
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
            neutralizingTextResults: markerCodec != nil
        )
        dispatches.append(contentsOf: iterationRecords)
        conversation.append(contentsOf: LocalToolImage.continuation(ToolCallCodec.resultBlocks(toolResultBlocks,
            toolNames: iterationRecords.map(\.name), markerCodec: markerCodec)))
        if let toolBoundaryReason {
            TurnObservation.apply(.boundary(toolBoundaryReason), to: &conversation, surface: surface)
        }
        LocalToolImage.boundConversation(&conversation)
        ChatTurnExecution.current?.keepPixels(LocalToolImage.imageNames(conversation))
        // An app chrome.* call is the Chrome tool it ran, with its args as input.
        if iterationRecords.contains(where: {
            let ran = $0.ranCall.tool
            return Self.driverTakeoverReceipt($0.result) != nil
                || (!MacAttentionSessionStore.shared.currentDriverAllowed
                    && ["act", "go"].contains(ran)
                    && ChatToolOutcome.wasCancelled($0.result))
        }) {
            await progress?(.notice(kind: "mac_handback", text:
                "You took control of the Mac; waiting for you to return control."))
            // Keep the conversation and its delivery route alive while the
            // existing handback event or this run's Stop releases the wait.
            // Observation failure ends the turn; it cannot stand in for either.
            let changes = await MacAttentionSessionStore.shared.driverChanges(waitingForReturn: true)
            let outcome = await withTaskGroup(of: MacControlWaitOutcome.self) { group in
                group.addTask {
                    for await _ in changes {
                        if Self.dispatchCancelSignalled(cancelFlagPath) { return .stopped }
                        if MacAttentionSessionStore.shared.currentDriverAllowed { return .returned }
                    }
                    return Self.dispatchCancelSignalled(cancelFlagPath)
                        ? .stopped : .unavailable("The control-return observation ended.")
                }
                if let flag = cancelFlagPath {
                    group.addTask {
                        let stop = FileChangeEvents(paths: [URL(fileURLWithPath: flag.path)])
                        defer { stop.cancel() }
                        for await _ in stop.stream {
                            if Self.dispatchCancelSignalled(flag) { return .stopped }
                        }
                        return Self.dispatchCancelSignalled(flag)
                            ? .stopped : .unavailable("The Stop-file observation failed.")
                    }
                }
                let result = await group.next() ?? .unavailable("The control-return wait ended without an outcome.")
                group.cancelAll()
                return result
            }
            if Self.dispatchCancelSignalled(cancelFlagPath) { return }
            switch outcome {
            case .stopped: throw CancellationError()
            case .unavailable(let why): throw TurnEngineError.macControlWaitUnavailable(why)
            case .returned: break
            }
            if !MacAttentionSessionStore.shared.currentDriverAllowed {
                throw TurnEngineError.macControlWaitUnavailable("Mac control is still with you.")
            }
            Self.appendStructuredUserNudge("Mac control has returned; continue from the recorded results.", to: &conversation)
        }
        if StandingBotContinuity.isHelperTurn, iterationRecords.contains(where: { ChatToolOutcome.isWaitingApproval($0.result) }) {
            ChatTurnExecution.current?.waitForApproval()
        }
        // A blocking need (a macOS grant, her own question) is the one the turn
        // ends waiting on; the round's results still reach her first.
        if let waiting = iterationRecords.lazy
            .compactMap({ InlineInteractionNeed.interaction(in: $0.result) })
            .first(where: InlineInteractionNeed.blocksTurn) {
            ChatTurnExecution.current?.waitForInteraction(waiting)
        }
    }

    private enum MacControlWaitOutcome: Sendable {
        case returned
        case stopped
        case unavailable(String)
    }

    private static func driverTakeoverReceipt(_ value: JSONValue, depth: Int = 0) -> [String: JSONValue]? {
        guard depth < 5, case .object(let object) = value else { return nil }
        if object["status"] == .string("yielded_to_user")
            || { if case .string(let error)? = object["error"] { error.hasPrefix("human_takeover:") } else { false } }() {
            return object
        }
        for key in ["detail", "output", "result"] {
            if let child = object[key], let receipt = driverTakeoverReceipt(child, depth: depth + 1) {
                return receipt.merging(object.filter { $0.key != key }) { current, _ in current }
            }
        }
        return nil
    }

}
