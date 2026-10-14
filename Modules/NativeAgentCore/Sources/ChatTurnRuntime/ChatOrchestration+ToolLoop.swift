import ChatToolParsing
import ChatToolRuntime
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

    /// Shared pre-loop context resolution. Prefer a caller-provided context
    /// (e.g. one already threaded with session history); otherwise build a fresh
    /// per-turn context AND lazy-filter ctx.toolSchemas so the
    /// no-preBuiltContext path can't expose the full eager catalog. Then fire
    /// the context-snapshot event.
    func resolveToolLoopContext(
        surface: String,
        userMessage: String,
        sessionId: String?,
        runId: String?,
        preBuiltContext: TurnContext?
    ) async throws -> TurnContext {
        if let preBuiltContext {
            // This is the production structured-chat shape. Its context already
            // contains the chosen persona, threaded history/session digest, and
            // cognitive capsule, and has already received its turn-scoped lazy
            // tool filter. Rebuilding here would silently discard those inputs.
            Self.fireContextSnapshotEvent(
                surface: surface,
                context: preBuiltContext,
                sessionId: sessionId,
                runId: runId
            )
            return preBuiltContext
        }
        let rawCtx = try await buildTurnContext(
            surface: surface,
            userMessage: userMessage,
            personaOverride: nil,
            imageBlocks: [],
            sessionID: sessionId,
            offeredToolNames: SwiftToolDispatcher.normalModelToolNames(activeTools: LLMCallContext.turnActiveTools ?? [])
        )
        // The one lazy filter: always-on core plus this turn's own scope.
        let ctx = SwiftNativeChatOrchestrationClient.applyLazyToolFilter(
            to: rawCtx,
            activeTools: LLMCallContext.turnActiveTools ?? []
        ) ?? rawCtx
        Self.fireContextSnapshotEvent(
            surface: surface,
            context: ctx,
            sessionId: sessionId,
            runId: runId
        )
        return ctx
    }

    /// Shared terminal for a loop iteration that produced a final reply (no
    /// executable tool calls): record the completed outcome, run the realtime
    /// memory-promotion side channel (production chat goes through this loop, so
    /// without it AdaptiveMemoryPromoter never sees the user/assistant pair), and
    /// build the TurnEngineResult. `rawLLMResponse` is the turn's accumulated
    /// raw output.
    func finishCompletedTurn(
        reply: String,
        ctx: TurnContext,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        rawLLMResponse: String,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String,
        workingCommentaryCharacters: Int? = nil,
        completionState: TurnEngineResult.CompletionState = .completed
    ) async -> TurnEngineResult {
        let recalledIds = ctx.resolvedRecalledIds
        await ctx.fluidContextTurn?.recordOutcome(.completed)
        await queuePromises(in: reply, dispatches: dispatches, surface: surface)
        Self.noticeRepeatedWork(dispatches: dispatches, surface: surface, root: remPinsDataRoot, sessionId: sessionId)
        // NOT run here (Astra audit 2, finding 4, 2026-09-11): this used to hold
        // the TurnEngineResult — and therefore the caller's assistant-row persist
        // and output milestone — for the whole promotion, 8-10 s on live bridge
        // turns. This only CAPTURES the promotion's inputs; the caller's
        // `startDeferredMemoryPromotion(ticket:)` starts it once the assistant
        // row is durable, so the work is deferred behind the append, not dropped.
        // The ticket rides home on the result: it is what makes the start
        // per-turn instead of "whatever this actor last captured" (Astra comb 3
        // review, finding 1, 2026-09-12).
        let promotionTicket = deferMemoryPromotion(
            userMessage: userMessage,
            assistantMessage: reply,
            toolDispatches: dispatches,
            sessionId: sessionId,
            surface: surface
        )
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: reply,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            rawLLMResponse: rawLLMResponse,
            providerCallCount: providerCallCount,
            completionState: completionState,
            memoryPromotionTicket: promotionTicket,
            workingCommentaryCharacters: workingCommentaryCharacters
        )
    }

    /// Wave 2 #7: work her reply promises for a later turn goes to MY QUEUE,
    /// in her words, tagged inferred with the sentence it came from
    /// (`ToolCallParser.crossTurnDeferrals`). Only on the doors people and
    /// peers talk to her through, and not when she queued a step herself this
    /// turn. "Once you approve" follows the card this turn filed, if it filed
    /// one. The turn's steer rides along (`PeerDataTaint.carried`). Inferred
    /// steps untouched for a week expire here (`MyQueue.expireInferred`).
    func queuePromises(in reply: String, dispatches: [TurnEngineResult.ToolDispatchRecord], surface: String) async {
        let doors: Set<String> = ["chat", "mac", "telegram", "slack", "ios", "iphone", "mobile", "icloud", "mac_ios",
                                  "ios_icloud", "agent-bridge", "claude-bridge", "codex-bridge"]
        guard let root = remPinsDataRoot else { return }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let origin = ChatPersistenceContext.originPrincipal
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        // A skill run still stopped as the turn ends waits for her own turn,
        // the turn's steer with it: its last word this turn is the one that counts.
        var stopped: [String: String] = [:]
        for dispatch in dispatches where dispatch.name == "app"
            && [.string("skill.run"), .string("skill.resume")].contains(dispatch.input["action"]) {
            guard case .object(let receipt) = dispatch.result else { continue }
            if case .object(let resume)? = receipt["resume"], case .string(let run)? = resume["run_id"],
               case .string(let skill)? = receipt["skill"] {
                let held = if case .array(let items)? = resume["held"] {
                    items.compactMap { if case .string(let id) = $0 { id } else { nil } }
                } else { [String]() }
                let question = if case .string(let text)? = resume["question"] { text } else { "" }
                stopped[run] = MyQueue.skillRunWords(skill: skill, run: run, question: question, held: held)
            } else if case .object(let args)? = dispatch.input["args"], case .string(let run)? = args["run_id"] {
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
        guard doors.contains(surface.lowercased()),
              !dispatches.contains(where: { $0.name == "app" && $0.input["action"] == .string("queue.add") }) else { return }
        do { try await MyQueue.expireInferred(store: store) } catch { nativeLog("[my-queue] expiry failed: \(error)") }
        let promises = ToolCallParser.crossTurnDeferrals(reply)
        guard !promises.isEmpty else { return }
        let card = dispatches.last { ChatToolOutcome.isWaitingApproval($0.result) }.flatMap { dispatch -> String? in
            guard case .object(let object) = dispatch.result,
                  case .string(let id)? = object["approvalId"] ?? object["approval_id"] else { return nil }
            return id
        }
        for promise in promises {
            let after = promise.when == "after_card" ? card : nil
            let when = promise.when == "after_card" && after == nil ? "next_turn" : promise.when
            do {
                _ = try await MyQueue.add(DeskStep(words: promise.sentence, when: when, card: after, source: promise.sentence,
                                                   peers: steer.sources, elevated: steer.elevated,
                                                   session: ChatToolSessionContext.verifiedSessionId, origin: origin,
                                                   replyRoute: TurnEnvelope.current(surface: surface).persistedMetadata()), store: store)
            } catch {
                nativeLog("[my-queue] a promise was not queued: \(error)")
            }
        }
    }

    /// A dispatch round continues or waits for the person.
    enum ToolDispatchRoundOutcome { case continueLoop, waiting(TurnEngineResult.TerminalReason) }

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
        progress: ChatOrchestrationProgressHandler?,
        conversation: inout [LLMMessage],
        dispatches: inout [TurnEngineResult.ToolDispatchRecord],
        providerTools: ProviderToolNameMap,
        noProgressGuard: inout ToolLoopNoProgressGuard,
        cancelFlagPath: URL? = nil,
        /// Set on the marker protocol: the round replays as the model's own
        /// text and its results come back as one text message (8b carrier).
        markerCodec: TextMarkerCodec? = nil,
        toolBoundaryReason: LLMToolBoundaryReason? = nil
    ) async -> ToolDispatchRoundOutcome {
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
        // If the parser didn't recover an id (legacy marker), mint a stable one
        // keyed on round base + call index + name so the provider has SOMETHING
        // to round-trip. The index matters: two id-less calls to the SAME tool in
        // one round must not collide (audit 2026-06-09). pairedIds keeps the
        // result side echoing the exact assistant-side id by position.
        let roundBase = dispatches.count
        var pairedIds: [String] = []
        for (idx, call) in providerCalls.enumerated() {
            let argsJSON: Data = {
                if let v = try? JSONValue.object(call.input).serializedData(pretty: false) {
                    return v
                }
                return Data("{}".utf8)
            }()
            let id = call.id.isEmpty
                ? "toolu_synth_\(roundBase + idx)_\(call.name)"
                : call.id
            pairedIds.append(id)
            if markerCodec == nil {
                assistantBlocks.append(.toolUse(id: id, name: call.name, inputJSON: argsJSON))
            }
        }
        conversation.append(LLMMessage(role: .assistant, content: assistantBlocks))

        // Dispatch the iteration's calls (parallel-safe runs concurrent, cap 4,
        // everything else serial in order — U1 step 6) and append the results as
        // ONE user message of tool_result blocks paired by id in original order.
        var (toolResultBlocks, iterationRecords) = await dispatchIterationCalls(
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
        if let markerCodec {
            // The round's results as the marker protocol returns them: one
            // text carrier in call order, closed once, pixels after it.
            var carrier = ""
            var images: [LLMContentBlock] = []
            var resultIndex = 0
            for block in toolResultBlocks {
                guard case .toolResult(_, let content, let isError) = block else {
                    images.append(block)
                    continue
                }
                markerCodec.appendResult(
                    index: resultIndex,
                    toolName: iterationRecords[resultIndex].name,
                    ok: !isError,
                    content: content,
                    to: &carrier
                )
                resultIndex += 1
            }
            if resultIndex > 0 { markerCodec.closeRound(&carrier) }
            toolResultBlocks = (carrier.isEmpty ? [] : [.text(carrier)]) + images
        }
        dispatches.append(contentsOf: iterationRecords)
        ChatTurnExecution.current?.keepTools(iterationRecords)
        conversation.append(contentsOf: LocalToolImage.continuation(toolResultBlocks))
        if let toolBoundaryReason {
            TurnObservation.apply(.boundary(toolBoundaryReason), to: &conversation, surface: surface)
        }
        LocalToolImage.boundConversation(&conversation)
        // An app chrome.* call is the Chrome tool it ran, with its args as input.
        if iterationRecords.contains(where: {
            let ran = ToolNameAliases.ranTool($0.name, input: $0.input)
            return Self.driverTakeoverReceipt($0.result) != nil
                || (!MacAttentionSessionStore.shared.currentDriverAllowed
                    && ["act", "go"].contains(ran)
                    && ChatToolOutcome.wasCancelled($0.result))
        }) {
            await progress?(.notice(kind: "mac_handback", text:
                "You took control of the Mac; waiting for you to return control."))
            // Keep the conversation and its delivery route alive while the
            // existing handback event or this run's Stop releases the wait.
            let changes = await MacAttentionSessionStore.shared.driverChanges(waitingForReturn: true)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in changes {
                        if Self.dispatchCancelSignalled(cancelFlagPath)
                            || MacAttentionSessionStore.shared.currentDriverAllowed { return }
                    }
                }
                if let flag = cancelFlagPath {
                    group.addTask {
                        let stop = FileChangeEvents(paths: [URL(fileURLWithPath: flag.path)])
                        defer { stop.cancel() }
                        for await _ in stop.stream {
                            if Self.dispatchCancelSignalled(flag) { return }
                        }
                    }
                }
                _ = await group.next()
                group.cancelAll()
            }
            if Self.dispatchCancelSignalled(cancelFlagPath) { return .continueLoop }
            Self.appendStructuredUserNudge("Mac control has returned; continue from the recorded results.", to: &conversation)
        }
        if StandingBotContinuity.isHelperTurn, iterationRecords.contains(where: { ChatToolOutcome.isWaitingApproval($0.result) }) {
            ChatTurnExecution.current?.waitForApproval()
        }
        // Automation waits for the owner's system grant; other setup lets
        // the turn finish its remaining work.
        if let waiting = iterationRecords.lazy
            .compactMap({ InlineInteractionNeed.interaction(in: $0.result) })
            .first(where: InlineInteractionNeed.blocksTurn) {
            ChatTurnExecution.current?.waitForInteraction(waiting)
            return .waiting(.interactionRequired)
        }
        switch noProgressGuard.observe(iterationRecords) {
        case .none:
            break
        case .warn(let feedback, let visible):
            if let visible {
                await progress?(.notice(kind: "tool_loop_recovery", text: visible))
            }
            Self.appendStructuredUserNudge(feedback, to: &conversation)
        case .wait(let count):
            let question = "I've done the same thing \(count) times in a row without getting further — keep going, or change course?"
            let input: [String: JSONValue] = [
                "kind": .string("choose"), "title": .string(question),
                "why": .string(question),
                "decline_consequence": .string("I'll wait for your direction before carrying on."),
                "options": .array([
                    .object(["id": .string("keep_going"), "label": .string("Keep going")]),
                    .object(["id": .string("change_course"), "label": .string("Change course")]),
                ]),
            ]
            // The existing receipt path stamps and persists the same-turn continuation.
            let need = InlineInteraction(kind: .choose, target: "", title: question,
                why: question, primaryActionLabel: "Choose",
                declineConsequence: "I'll wait for your direction before carrying on.",
                cardProse: question, options: [
                    .init(id: "keep_going", label: "Keep going"),
                    .init(id: "change_course", label: "Change course"),
                ])
            let result = InlineInteractionNeed.envelope(need)
            ChatTurnExecution.current?.waitForInteraction(need)
            let record = TurnEngineResult.ToolDispatchRecord(name: InlineInteractionWire.toolName,
                input: input, result: result)
            dispatches.append(record)
            ChatTurnExecution.current?.keepTools([record])
            await progress?(.toolUse(name: record.name, input: .object(input)))
            await progress?(.toolResult(name: record.name, output: result))
            return .waiting(.interactionRequired)
        }
        return .continueLoop
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

    /// The turn's OWN terminal for "waiting on you".
    ///
    /// A raised need is not exhaustion, not a protocol violation, and not a
    /// cancellation, and it must not borrow any of their endings: the generic
    /// "I ran out of iterations" line would sit above the card contradicting
    /// it, and `.abandoned` would tell the context ledger that the selection
    /// failed when what actually happened is that the work reached a person.
    ///
    /// So: keep exactly the prose the person already watched render, add
    /// nothing, and record the turn as a deliberate stop. The card beneath it
    /// is the rest of the message, and resolving it resumes the request.
    func waitingOnInteractionResult(
        ctx: TurnContext,
        visible: String,
        lastRawResponse: String,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int
    ) -> TurnEngineResult {
        Task { [weak turn = ctx.fluidContextTurn] in
            await turn?.recordOutcome(.completed)
        }
        return TurnSettle.waitingOnCard(
            visible: visible,
            modelUsed: ctx.modelId,
            recalledIds: ctx.resolvedRecalledIds,
            dispatches: dispatches,
            startNs: startNs,
            rawLLMResponse: lastRawResponse,
            providerCallCount: providerCallCount
        )
    }

}
