import ChatToolParsing
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
// exhaustion segments are below.

// MARK: - Lazy tool filtering

extension TurnContext {
    /// Copy of this context with only `toolSchemas` replaced. The ONE
    /// manual-copy site for the 15 let-only fields — every lazy-filter rebuild
    /// routes through here so a newly added TurnContext field can't be silently
    /// dropped by a hand-inlined 15-field copy (the field-drop trap C3 closes).
    func withToolSchemas(_ newSchemas: [LLMToolSchema]) -> TurnContext {
        TurnContext(
            surface: surface,
            personaID: personaID,
            personaDocs: personaDocs,
            personaFingerprint: personaFingerprint,
            recalled: recalled,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            providerId: providerId,
            serviceTier: serviceTier,
            toolsAvailable: toolsAvailable,
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            toolSchemas: newSchemas,
            systemSegments: systemSegments,
            imageBlocks: imageBlocks,
            fluidContextTurn: fluidContextTurn,
            naturalExpressionCue: naturalExpressionCue,
            historyMessages: historyMessages,
            turnVolatileBlock: turnVolatileBlock,
            historyWindowReceipt: historyWindowReceipt,
            preparationMs: preparationMs
        )
    }
}

// MARK: - Loop

extension SwiftNativeTurnEngine {
    // MARK: - Turn-loop segments
    // Context, completion, dispatch and exhaustion. Provider calls stay in the
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
        workingCommentaryCharacters: Int? = nil
    ) async -> TurnEngineResult {
        // An assistant row is NEVER blank. A completed turn whose reply trims
        // to nothing persisted an empty bubble under the receipts — the
        // "Looked something up · 8 of 12 failed" card with no sentence beside
        // it. Keep this guard at the shared completed-turn boundary too.
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ToolLoopExhaustion.emptyReply(
                dispatchCount: dispatches.count,
                providerRounds: providerCallCount
            )
            : reply
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
            completionState: .completed,
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
                                                   session: ChatToolSessionContext.verifiedSessionId), store: store)
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
                                                   session: ChatToolSessionContext.verifiedSessionId), store: store)
            } catch {
                nativeLog("[my-queue] a promise was not queued: \(error)")
            }
        }
    }

    /// A stopped dispatch round carries its actual cause: takeover, a needed
    /// interaction, or the no-progress guard. Otherwise it continues.
    ///
    /// `madeProgress` is the whole-turn wall-clock budget's extension signal:
    /// true when at least ONE dispatch in the round returned a real result
    /// (`ChatToolOutcome.outputLooksSuccessful` — the same classification that
    /// sets the provider's tool_result `is_error` bit). An all-errored round is
    /// exactly the stuck case the budget exists to kill, so it extends nothing.
    enum ToolDispatchRoundOutcome { case continueLoop(madeProgress: Bool), stopLoop(TurnEngineResult.TerminalReason) }

    /// Post-provider-call round of the structured loop: mint the
    /// assistant message (prose + tool_use blocks, synthesizing collision-free
    /// ids for id-less calls), dispatch the iteration's calls through the shared
    /// core, append the paired tool_result user message, run the no-progress
    /// guard, and — unless a stop was raised — refresh same-turn tool schemas and
    /// age older tool-result bodies (compat-only). The loop flushes its
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
        providerTools: inout ProviderToolNameMap,
        noProgressGuard: inout ToolLoopNoProgressGuard,
        loopRecoveryReply: inout String?,
        cancelFlagPath: URL? = nil,
        /// Set on the marker protocol: the round replays as the model's own
        /// text and its results come back as one text message (8b carrier).
        markerCodec: TextMarkerCodec? = nil,
        toolBoundaryReason: LLMToolBoundaryReason? = nil
    ) async throws -> ToolDispatchRoundOutcome {
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
            if resultIndex > 0 { markerCodec.closeRound(&carrier, boundaryReason: toolBoundaryReason) }
            toolResultBlocks = (carrier.isEmpty ? [] : [.text(carrier)]) + images
        }
        dispatches.append(contentsOf: iterationRecords)
        ChatTurnExecution.current?.keepTools(iterationRecords)
        // An app chrome.* call is the Chrome tool it ran, with its args as input.
        if let stopped = iterationRecords.first(where: {
            let ran = ToolNameAliases.ranTool($0.name, input: $0.input)
            return Self.driverTakeoverReceipt($0.result) != nil
                || (!MacAttentionSessionStore.shared.currentDriverAllowed
                    && ["act", "go"].contains(ran)
                    && ChatToolOutcome.wasCancelled($0.result))
        }) {
            let stoppedName = ToolNameAliases.ranTool(stopped.name, input: stopped.input)
            let stoppedInput = ToolNameAliases.ranInput(stopped.name, input: stopped.input)
            let receipt = Self.driverTakeoverReceipt(stopped.result) ?? [:]
            let place = [stoppedInput["app"], stoppedInput["target"], stoppedInput["url"]]
                .compactMap { if case .string(let value)? = $0 { value } else { nil } }
                .joined(separator: " · ")
            var lines = ["I stopped because you took control of the Mac."]
            if !place.isEmpty { lines.append("Stopped at: " + place + ".") }
            if case .object(let result) = stopped.result, case .string(let text)? = result["text"] {
                lines.append(String(text.prefix(1_600)))
            }
            for (key, label) in [("failed_step", "Stopped at step"), ("steps_completed", "Steps completed"), ("steps_total", "Steps requested"), ("repeat_completed", "Attempts completed"), ("posted_events", "Input events sent"), ("characters_sent", "Characters sent"), ("requested_events_emitted", "Gesture events sent"), ("recovery_events_emitted", "Held inputs released"), ("gesture", "Gesture"), ("outcome", "Outcome")] {
                if let value = receipt[key], value != .null {
                    if let data = try? value.serializedData(pretty: false), let text = String(data: data, encoding: .utf8) {
                        lines.append(label + ": " + text)
                    }
                }
            }
            if stoppedName.contains("chrome") {
                let tab: Int64? = if case .int(let value)? = receipt["tabId"] ?? stoppedInput["tab_id"] { value } else { nil }
                if let page = ChromePageMirror.page(tab: tab, session: sessionId) {
                    lines.append("Chrome page: " + page.title + " · " + page.url)
                    let node = receipt["nodeId"] ?? receipt["targetNodeId"] ?? stoppedInput["node_id"]
                    if (receipt["snapshotId"] ?? stoppedInput["snapshot_id"]) == .string(page.snapshotID),
                       case .string(let id)? = node, let target = page.rows.first(where: { $0.node == id }) {
                        lines.append("Chrome target: " + target.label)
                    }
                }
                lines.append("Chrome action: " + stoppedName.replacingOccurrences(of: "browser.chrome_", with: ""))
            }
            let handback = String(lines.joined(separator: "\n").prefix(2_200))
                + "\nInput already sent may have changed the app; unfinished work remains unverified. Under Full Mac I'll pick it up when you ask; otherwise I'll wait until you return Mac control with Let agent use Mac."
            loopRecoveryReply = handback
            await progress?(.notice(kind: "mac_handback", text: handback))
            return .stopLoop(.humanTakeover)
        }
        if StandingBotContinuity.isHelperTurn, iterationRecords.contains(where: { ChatToolOutcome.isWaitingApproval($0.result) }) {
            ChatTurnExecution.current?.waitForApproval()
        }
        // Setup and permission cards leave this item skipped while the turn
        // finishes its other work. Only a question needed by the turn parks it.
        if let waiting = iterationRecords.lazy
            .compactMap({ InlineInteractionNeed.interaction(in: $0.result) })
            .first(where: InlineInteractionNeed.blocksTurn) {
            ChatTurnExecution.current?.waitForInteraction(waiting)
            return .stopLoop(.interactionRequired)
        }
        // Whole-turn budget extension signal (see ToolDispatchRoundOutcome).
        // User, 2026-09-06: an approval FILED is not a tool that ran, so it does
        // not re-earn the surface window. A model stuck re-asking for the same
        // CONFIRM renewed the budget every round and rode the turn to the
        // iteration cap.
        let madeProgress = iterationRecords.contains {
            ChatToolOutcome.outputLooksSuccessful($0.result)
                && !ChatToolOutcome.isWaitingOnPerson($0.result)
                && !ChatToolOutcome.neverRan($0.result)
        }
        switch noProgressGuard.observe(iterationRecords) {
        case .none:
            break
        case .warn(let feedback, let visible):
            // 2026-09-13 (first-failure pass): the model-directed correction
            // used to go straight into the visible progress stream, so the
            // reader was handed the agent's repair work ("change the
            // arguments", "use a narrower query"). Only an evidenced blocker
            // they can actually resolve surfaces now; the correction still
            // rides into the conversation below, where it belongs.
            if let visible {
                await progress?(.notice(kind: "tool_loop_recovery", text: visible))
            }
            // 2026-07-21 audit fix: the WARN text is model-directed
            // guidance ("change the arguments, use a narrower query or a
            // different tool...") but only the USER ever saw it — the
            // model repeated identical rounds 9-15 with zero corrective
            // signal until the hard stop (whose feedback IS appended).
            // Feed it into the conversation like the stop branch does.
            toolResultBlocks.append(.text(feedback))
        case .stop(let feedback, let visible):
            toolResultBlocks.append(.text(feedback))
            // The final answer is the person-facing half: what stopped and what
            // survived, never an inference about the agent's arguments.
            loopRecoveryReply = visible
        }
        conversation.append(contentsOf: LocalToolImage.continuation(toolResultBlocks))
        LocalToolImage.boundConversation(&conversation)
        if loopRecoveryReply != nil { return .stopLoop(.noProgress) }
        return .continueLoop(madeProgress: madeProgress)
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

    /// Shared exhaustion tail for a loop that ran out of iterations without a
    /// final reply: pick the best-effort reply (loop-recovery stop > protocol-
    /// violation terminal > exhaustion fallback when there's no usable prose or
    /// the last raw was only a structured tool call > the stripped fallback
    /// text), record the abandoned outcome, run memory promotion, and build the
    /// result. A streamed tool-call round also counts as "only a structured
    /// tool call", so that extra signal is a parameter.
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

    func finishExhaustedTurn(
        ctx: TurnContext,
        lastRawResponse: String,
        lastProtocolViolation: ToolCallProtocolViolation?,
        loopRecoveryReply: String?,
        iterationLimit: Int,
        wallClockElapsedSeconds: Int?,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String,
        additionalStructuredToolCallSignal: Bool,
        /// Prose the user ALREADY WATCHED RENDER this turn, marker-stripped.
        /// User, 2026-09-06: a streaming turn that hit the whole-turn budget in
        /// the reconnect ladder took the generic exhaustion reply whenever an
        /// earlier round had tool calls, and the client persisted THAT as the
        /// reply — so displayed paragraphs vanished on reload.
        visiblePartial: String,
        codec: ToolCallCodec = .native
    ) async -> TurnEngineResult {
        let fallbackText = ToolCallParser.stripToolUseMarkers(lastRawResponse).trimmingCharacters(in: .whitespacesAndNewlines)
        let recalledIds = ctx.resolvedRecalledIds
        let rawWasOnlyStructuredToolCall = additionalStructuredToolCallSignal
            || !ToolCallParser.parse(lastRawResponse, parseInvoke: codec == .textMarkers).isEmpty
        // What the user saw stays: the terminal line explains the stop, but it
        // never REPLACES prose that already rendered.
        //
        // User, 2026-09-06: this used to apply on the exhaustion branch alone, so
        // a turn that ended on the no-progress guard or on a protocol violation
        // persisted the canned line by itself and the paragraphs the user had
        // just watched render vanished on reload.
        let shown = visiblePartial.trimmingCharacters(in: .whitespacesAndNewlines)
        func keepingVisible(_ terminal: String) -> String {
            shown.isEmpty ? terminal : shown + "\n\n" + terminal
        }
        let final: String
        if let loopRecoveryReply {
            final = keepingVisible(loopRecoveryReply)
        } else if let lastProtocolViolation {
            final = keepingVisible(lastProtocolViolation.terminalReply)
        } else if fallbackText.isEmpty || rawWasOnlyStructuredToolCall {
            final = keepingVisible(ToolLoopExhaustion.fallbackReply(
                iterationLimit: iterationLimit,
                dispatchCount: dispatches.count,
                providerRounds: providerCallCount,
                wallClockElapsedSeconds: wallClockElapsedSeconds
            ))
        } else {
            final = fallbackText
        }
        await ctx.fluidContextTurn?.recordRetry()
        await ctx.fluidContextTurn?.recordOutcome(.abandoned)
        let promotionTicket = deferMemoryPromotion(
            userMessage: userMessage,
            assistantMessage: final,
            toolDispatches: dispatches,
            sessionId: sessionId,
            surface: surface
        )
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Int((endNs &- startNs) / 1_000_000)
        return TurnEngineResult(
            reply: final,
            modelUsed: ctx.modelId,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            rawLLMResponse: lastRawResponse,
            providerCallCount: providerCallCount,
            completionState: .incomplete,
            memoryPromotionTicket: promotionTicket
        )
    }

    /// A provider output budget is a terminal incomplete answer, with no retry
    /// or dispatch of the unfinished round's tool plan.
    func finishLengthLimitedTurn(
        ctx: TurnContext,
        partial: String,
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        providerCallCount: Int,
        userMessage: String,
        sessionId: String?,
        surface: String,
        codec: ToolCallCodec = .native
    ) async -> TurnEngineResult {
        // 2026-09-23: keep the prose before any repetition loop, and say why.
        let (kept, notice) = RunawayOutputDetector.cutoffReply(partial)
        let prefix = codec.visiblePrefix(in: ToolCallParser.stripToolUseMarkers(kept))
        let prose = LLMCallContext.turnTokenBudget != nil ? prefix : prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        await ctx.fluidContextTurn?.recordOutcome(.abandoned)
        let reply = LLMCallContext.turnTokenBudget != nil ? prose : (prose.isEmpty ? notice : prose + "\n\n" + notice)
        let promotionTicket = deferMemoryPromotion(
            userMessage: userMessage, assistantMessage: reply, toolDispatches: dispatches,
            sessionId: sessionId, surface: surface
        )
        return TurnEngineResult(
            reply: reply,
            modelUsed: ctx.modelId,
            recalledIds: ctx.resolvedRecalledIds,
            toolDispatches: dispatches,
            elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
            rawLLMResponse: partial,
            providerCallCount: providerCallCount,
            completionState: .incomplete,
            memoryPromotionTicket: promotionTicket
        )
    }
}
