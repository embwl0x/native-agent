import AuthoredCapabilities
import ChatToolParsing
import ChatTurnContracts
import Experiences
import ChatSessionWork
import Desk
import ToolRegistry
import Foundation
import CryptoKit
import Dispatcher
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import MemoryV2
import ProviderRouting
import MacIntegration
import Context
import Senses
import TrustCenter
import os
import NativeAgentShared
// Blueprint: | `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: runs their turn part's effects, hands it each event with each result's declared effect, logs at every host-call boundary; the turn returns at `reply.end` and `after`, and effects after them run privately on the same turn id, never streamed, saved to the conversation or checkpointed), `joinedProse`; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed; the person's turn is measured as it goes (model rounds, its own calls' tokens, minutes, the longest stretch of one round's calls repeated, on the closing `model` event as `repeated`): `took` is the after-turn line, and each part called records its rounds |

extension SwiftNativeTurnEngine {
    /// The structured tool loop builds the tool conversation and forwards
    /// provider text deltas and tool-call events through optional progress.
    func executeContinuationTurnBody(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        /// Request-scoped tool identity for ephemeral turns without a
        /// chat transcript or provider session.
        toolSessionId: String? = nil,
        runId: String? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient,
        preBuiltContext: TurnContext,
        progress: TurnEventSink? = nil,
        onDelivery: (@Sendable () async -> Void)? = nil,
        cancelFlagPath: URL? = nil,
        /// Asked before every provider call, retries included. Admission errors
        /// stay with their owner; provider recovery cannot override them.
        providerAdmission: (@Sendable () async throws -> Void)? = nil
    ) async throws -> TurnEngineResult {
        return try await ChatToolSessionContext.$userText.withValue(userMessage) {
        try await SenseTurnReads.$current.withValue(SenseTurnReads.current ?? SenseTurnReads()) {
        // Fold the Workshop surface once so the whole loop threads one vocabulary.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        // Nothing her part does after the person's reply reaches the person (`drive`).
        var progress = progress
        // Prepared document text and image-only turns need no caption.
        if preBuiltContext.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && preBuiltContext.imageBlocks.isEmpty {
            throw TurnEngineError.emptyMessage
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: toolSessionId ?? sessionId,
            turnId: TurnTraceContext.turnId
        )
        var cleanFinish = false
        defer {
            if cleanFinish || Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath), let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let gathered = preBuiltContext
        // Her turn part runs the turn's decisions; this loop runs its effects.
        // The message goes in first; a turn resumed after a relaunch rebuilds
        // from its log, and hears `resumed` when an effect was in flight.
        let restarted = TurnCheckpointScope.resuming.flatMap {
            $0.runId == runId && $0.turnId == TurnTraceContext.turnId ? $0 : nil
        }
        var part = try await TurnPart(dataRoot: remPinsDataRoot ?? defaultDataRoot(), surface: surface, stop: cancelFlagPath,
                                      context: gathered, log: restarted?.log ?? [])
        defer { part.tellHer() }
        var inFlight = false
        if part.log.isEmpty {
            try await part.deliver([.object([
                "type": .string("message"), "text": .string(gathered.userMessage), "surface": .string(surface),
                "attachments": .array(gathered.imageBlocks.compactMap {
                    if case .image(_, _, let name, _) = $0 { .string(name ?? "image") } else { nil }
                }),
                "who": .string(ChatPersistenceContext.originPrincipal),
                "trust": .string(PeerDataTaint.current?.isTainted == true ? "untrusted" : "trusted"),
            ])])
        } else {
            inFlight = try await part.resume()
        }
        try Task.checkCancellation()
        guard let system = part.system else {
            throw TurnEngineError.turnPartFailed("Its log opened with no model.call naming the system.")
        }
        let resolvedTurnContext = gathered.composing(system, tools: part.offeredTools)
        let traceSessionId = Self.fireContextSnapshotEvent(
            surface: surface, context: resolvedTurnContext, sessionId: sessionId, runId: runId)
        // The request milestone belongs to the dispatch it names: the transport
        // calls this once routing is validated and the adapter chosen, and the
        // turn's first such call is its request start.
        let requestStarted = OSAllocatedUnfairLock(initialState: false)
        let requestDispatched: @Sendable () -> Void = {
            guard requestStarted.withLock({ started in defer { started = true }; return !started }) else { return }
            TurnLifecycleTelemetry.emit(.providerRequestStarted, surface: surface, sessionId: traceSessionId,
                                        observedBy: "transport.dispatch", flags: ["initialRequest": true])
        }
        Self.fireAssemblyStageEvent(surface: surface, context: resolvedTurnContext)
        var commitInstructionDelivery = pendingInstructionDelivery(in: resolvedTurnContext, sessionID: sessionId)
        // Steered messages reach the queue owner as delivered at the same
        // moment instructions do: the round carrying them produced output.
        var steeringOffers: [ChatTurnSteering.Offer] = []
        var arrivedItems: [ResidentWake.Item] = []
        var contextDeliveryOwed = true
        // Memories a moment brought to mind this turn (what she read, while working).
        var cameToMindHeld: Set<ContextAtomID> = []
        func commitDelivery() async throws {
            commitInstructionDelivery?()
            commitInstructionDelivery = nil
            if contextDeliveryOwed {
                contextDeliveryOwed = false
                await resolvedTurnContext.fluidContextTurn?.recordDelivery()
                await onDelivery?()
                creditDeliveredMemories(resolvedTurnContext)
                await announceDeliveredArrivals(in: resolvedTurnContext, sessionID: sessionId)
            }
            if let root = remPinsDataRoot, !arrivedItems.isEmpty {
                guard ResidentWake.shared.accept(dataRoot: root, items: arrivedItems) else {
                    throw ChatOrchestrationError.underlying("Arrival acceptance could not be saved; it remains owed.")
                }
                arrivedItems = []
            }
            guard let sessionId, !steeringOffers.isEmpty else { return }
            let offers = steeringOffers
            steeringOffers = []
            guard await ChatTurnSteering.shared.markDelivered(offers, sessionId: sessionId) else {
                throw ChatOrchestrationError.underlying("Couldn't commit steering delivery; the message stays queued.")
            }
        }

        // Offer and read calls using the provider resolved under this turn's
        // bindings: its admitted route or the surface's pick when none is carried.
        let toolCallCodec = ToolCallCodec.forProvider(
            await LLMCallContext.$admittedModel.withValue(resolvedTurnContext.modelId) {
                await LLMCallContext.$providerId.withValue(resolvedTurnContext.providerId ?? LLMCallContext.providerId) {
                    await llm.servingProviderID(model: resolvedTurnContext.modelId, surface: surface)
                }
            }
        )
        /// The request her part's opening model.call names, seeded as the turn's
        /// prefix; seeded again when a heal brings a version that names another.
        func seeded(_ composed: TurnContext) -> (ConversationPrefixSeeding.Seed, (prompt: String?, segments: SystemPromptSegments?)) {
            let seed = ConversationPrefixSeeding.seed(
                composed,
                // The marker catalog's session-loaded run rides the volatile block
                // on v2, so a mid-session tool_load cannot move the cached prefix.
                textToolCatalogAppendix: toolCallCodec == .textMarkers
                    ? TextMarkerCodec.volatileCatalogAppendix(for: composed)
                    : nil
            )
            let ctx = seed.context
            guard toolCallCodec == .textMarkers else { return (seed, (ctx.systemPrompt, ctx.systemSegments)) }
            let layout = TextMarkerCodec.systemLayout(baseSystem: ctx.systemPrompt, segments: ctx.systemSegments, context: ctx)
            return (seed, (layout.system, layout.segments))
        }
        var (prefixSeed, wireSystem) = seeded(resolvedTurnContext)
        var composed = (system: system, tools: part.offeredTools)
        var ctx = prefixSeed.context
        // The provider-name map is built from the array and then held still
        // until a heal names other tools.
        var providerTools = ProviderToolNameMap(ctx.toolSchemas)
        if let sessionId, !sessionId.isEmpty, let runId, !runId.isEmpty {
            // Keeping the sent block is what lets the next request extend this
            // one; a failed save never fails her turn (the next turn finds the
            // paragraphs absent from its history and sends them in full).
            await prefixSeed.sentContext.persist(sessionID: sessionId, runID: runId,
                userMessageID: ChatPersistenceContext.replacementUserMessageID, dataRoot: remPinsDataRoot)
        }
        ConversationPrefixTelemetry.sink?.set(ConversationPrefixSeeding.telemetry(
            prefixSeed,
            toolSchemaFingerprint: Self.toolSchemaFingerprint(ctx.toolSchemas)
        ))
        var conversation: [LLMMessage] = prefixSeed.messages
        // What happened since her last turn primes this one: her own turns hear what it brought to mind.
        if let root = remPinsDataRoot, let sessionId, !SessionConversation.isHelper(sessionId, dataRoot: root),
           PeerDataTaint.current?.isTainted != true, [nil, "self"].contains(ChatToolSessionContext.envelope?.agent) {
            let moments = PrimedMoments.take(dataRoot: root)
            if !moments.isEmpty, let primed = await primedSinceLastTurn(
                moments, turn: resolvedTurnContext.fluidContextTurn, held: &cameToMindHeld,
                sessionId: sessionId, surface: surface) {
                Self.appendStructuredUserNudge(primed, to: &conversation)
            }
        }
        // Resolve the model window once per turn; compaction preserves the seed through compactionTurnStart.
        let turnWindowTokens = ContextBudgetPolicy.windowTokens(
            forModel: ctx.modelId,
            providerID: ctx.providerId ?? LLMCallContext.providerId,
            dataRoot: remPinsDataRoot
        )
        var compactionTurnStart = prefixSeed.messages.count - 1
        let compactionClient = llm
        // Working notes use the independent Memory and mind tuple, resolved
        // only when this turn compacts, with its own turn choice set aside.
        let compactionSurface = ChatCompactionDistiller.distillSurface
        let distillWorkingNotes: IntraTurnContextCompaction.Distill = { [weak self] rendered in
            guard let self else { return .failure(ToolFailureError("The turn engine ended before its notes were written.", effects: .none)) }
            var named = (provider: "unresolved", model: "")
            do {
                let route = try await ProviderTurnChoice.$current.withValue(nil) {
                    try await self.router.checkedRouteAdmission(for: compactionSurface)
                }
                named = (route.providerId ?? named.provider, route.modelId)
                return .success(try await ProviderTurnChoice.$current.withValue(nil) {
                    try await route.withModelContext {
                        try await compactionClient.complete(
                            prompt: rendered,
                            system: IntraTurnContextCompaction.workingNotesSystem,
                            model: route.modelId,
                            surface: compactionSurface, purpose: "compaction", tools: nil
                        )
                    }
                })
            } catch {
                // No notes is the compaction's receipt, carried into her turn: a
                // route that is wrong owes its repair, once, here.
                try Task.checkCancellation()
                return .failure(ProviderFailure.repair(error, provider: named.provider, model: named.model, surface: compactionSurface,
                    dataRoot: self.remPinsDataRoot ?? defaultDataRoot(), id: "working-notes:" + UUID().uuidString))
            }
        }
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var counters = TurnEngineResult.LoopCounters()
        var previousRoundFailed = false
        // What the person's turn takes, measured as it goes: its model rounds'
        // tokens, the rounds each of her parts was called in, and the longest
        // stretch of one round's calls made again round after round.
        let spent = OSAllocatedUnfairLock(initialState: 0)
        var partRounds: [String: Int] = [:]
        var repeated = (calls: [JSONValue](), call: "", count: 0), longest = (call: "", count: 0)
        func observed(_ result: TurnEngineResult, reason: TurnEngineResult.TerminalReason) -> TurnEngineResult {
            cleanFinish = reason == .replyCompleted || reason == .incomplete
            return result.observingTerminal(reason: reason, counters: counters)
        }
        var visibleText = ""
        defer { ToolLoopTraceObservation.current?.record(counters, dispatches: dispatches, reply: visibleText) }
        var turnInterstitialProse = ""
        var retainedAnswerProse = ""
        var emittedProviderFirstDelta = false
        var providerCallCount = 0
        var replyTextSettled = false
        var providerFailurePending = part.log.reversed().compactMap { row -> String? in
            guard case .object(let entry) = row, case .object(let event)? = entry["event"],
                  case .string(let type)? = event["type"], ["model", "provider_failure"].contains(type) else { return nil }
            return type
        }.first == "provider_failure"

        if let restarted {
            let rows = TurnCheckpointScope.resumedRows
            let receipts = rows.filter { SessionHistoryPromptRenderer.renderable($0)?.isTool == true }
            dispatches = receipts.map { row in
                var metadata: [String: JSONValue] = [:]
                if case .object(let fields)? = row.extras, case .object(let saved)? = fields["metadata"] { metadata = saved }
                let name = if case .string(let saved)? = metadata["toolName"] { saved } else { "unknown" }
                // A receipt that cannot be read stays a step whose outcome is unknown.
                var result: JSONValue = .object(["status": .string("unknown"), "effects": .string("unknown"),
                    "reason": .string("Its saved receipt could not be read after the restart; check its effect before repeating it.")])
                if case .string(let raw)? = metadata["resultBody"] ?? metadata["resultSummary"],
                   let saved = try? JSONValue.parse(Data(raw.utf8)) { result = saved }
                if let images = metadata["generatedImages"], case .object(var fields) = result {
                    fields["generatedImages"] = images
                    result = .object(fields)
                }
                if let landed = metadata["landedEffect"], case .object(var fields) = result {
                    fields["landedEffect"] = landed
                    result = .object(fields)
                }
                let input: [String: JSONValue]
                if case .string(let raw)? = metadata["inputJSON"],
                   case .object(let saved)? = try? JSONValue.parse(Data(raw.utf8)) { input = saved }
                else { input = [:] }
                let ranCall: (tool: String, input: [String: JSONValue])
                if case .object(let saved)? = metadata["ranCall"],
                   case .string(let tool)? = saved["tool"], case .object(let args)? = saved["input"] {
                    ranCall = (tool, args)
                } else {
                    // Legacy receipts only prove their saved name/input, never a current binding.
                    ranCall = (metadata["generatedImages"] == nil ? name : "image_generate", input)
                }
                return TurnEngineResult.ToolDispatchRecord(
                    name: ranCall.tool == "image_generate" && metadata["generatedImages"] != nil ? "image_generate" : name, input: input,
                    ranCall: ranCall, result: result)
            }
            // What she attached before the restart still goes with her reply, if the fence still lets it.
            for path in restarted.replyChoices ?? [] {
                if case .success(let file) = await SwiftNativeSecurityCenter.fencedAttachment(
                    path, dataRoot: remPinsDataRoot ?? defaultDataRoot()) { ReplyChoices.current?.choose(file.path) }
            }
            guard let user = rows.first(where: { $0.role == "user" }) else {
                throw ChatOrchestrationError.underlying("The resumed turn's saved user message is missing; repair its transcript.")
            }
            let replay = SessionHistoryMessages.project(messages: [user] + receipts,
                historyLimit: max(1, receipts.count + 1), windowTokens: turnWindowTokens)
            visibleText = restarted.keptProse
            // Held in joined shape, as a live one is, so its count is the offset.
            let commentaryCharacters = max(0, restarted.workingCommentaryCharacters)
            turnInterstitialProse = Self.joinedProse(String(restarted.keptProse.prefix(commentaryCharacters)), "")
            retainedAnswerProse = String(restarted.keptProse.dropFirst(commentaryCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !restarted.workingNotes.isEmpty { conversation.append(.assistantText(restarted.workingNotes)) }
            let resumed = TurnObservation.Kind.restarted(stepsDone: receipts.count,
                unknownStep: restarted.runningStep == nil ? nil : receipts.count + 1,
                started: part.uncertain.map { call in
                    guard case .object(let fields) = call, case .string(let name)? = fields["name"] else { return "a call" }
                    let input = (try? ChatSecretRedactor.redactValue(fields["input"] ?? .object([:])).serialize(pretty: false)) ?? "{}"
                    return name + " " + String(input.prefix(IntraTurnContextCompaction.renderToolInputChars))
                })
            TurnObservation.apply(resumed, kept: restarted.keptProse, to: &conversation, surface: surface)
            // Reuse the history projection, without inventing provider call IDs.
            let receiptText = replay.messages.dropFirst().flatMap(\.content).compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n\n")
            Self.appendStructuredUserNudge(receiptText, to: &conversation)
            if !visibleText.isEmpty { await progress?(.delta(visibleText)) }
            if !part.answered.isEmpty { await progress?(.delta(part.answered)) }
            if inFlight {
                var event: [String: JSONValue] = ["type": .string("resumed"),
                    "text": .string(TurnObservation.text(resumed)), "steps": .int(Int64(receipts.count))]
                // What her saved receipts landed, read as one list: a write whose result event the
                // relaunch lost still counts as done by hand.
                event["effect"] = Self.landedEffect(.object(["receipts": .array(dispatches.map(\.result))])).map(JSONValue.string)
                try await part.deliver([.object(event)])
            }
        }

        func stopCarryingPartial() -> Error {
            TurnEngineError.streamCancelled(
                partial: toolCallCodec.visiblePrefix(in: visibleText),
                underlying: CancellationError())
        }

        /// The stem applies or records observations; her part decides how to go on.
        func observe(_ kind: TurnObservation.Kind, kept: String = "", applying: Bool = true) async throws {
            if applying { TurnObservation.apply(kind, kept: kept, to: &conversation, surface: surface) }
            else { TurnObservation.record(kind, kept: kept, surface: surface) }
            try await part.deliver([.object(["type": .string("observation"), "text": .string(TurnObservation.text(kind))])])
        }
        /// Every effect boundary checkpoints the turn with its log.
        func capture(startingCalls: Int = 0) async throws {
            await TurnCheckpointScope.current?.capture(
                prose: Self.joinedProse(turnInterstitialProse, retainedAnswerProse),
                commentaryCharacters: turnInterstitialProse.count, conversation: conversation, log: part.log,
                startingCalls: startingCalls)
        }
        /// The model round whose calls the next app effects dispatch.
        var round: (calls: [ParsedToolCall], raw: String, codec: TextMarkerCodec?, boundary: LLMToolBoundaryReason?)?

        /// `emitted`: the provider yielded output this round, so asking again would repeat it.
        func providerFailed(_ error: Error, emitted: Bool) async throws {
            providerFailurePending = true
            let id = "provider-reply:" + UUID().uuidString
            let provider = ctx.providerId ?? LLMCallContext.providerId ?? "unresolved"
            let failure = ProviderFailure.repair(error, provider: provider, model: ctx.modelId, surface: surface,
                dataRoot: remPinsDataRoot ?? defaultDataRoot(), id: id)
            let next = failure.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
            var calls: [ParsedToolCall] = []
            if case .object(let call)? = next, case .string(let tool)? = call["tool"], case .object(let input)? = call["input"] {
                calls = [ParsedToolCall(id: id, name: tool, input: input)]
            }
            round = (calls, "", nil, nil)
            let remedy: JSONValue = if case .object(let shaped) = ChatToolOutcome.failure(error: failure) { shaped["remedy"] ?? .null } else { .null }
            await progress?(.notice(kind: "provider_failure", text: failure.message))
            do {
                try await part.deliver([.object(["type": .string("provider_failure"), "provider": .string(provider),
                    "model": .string(ctx.modelId), "text": .string(failure.message), "remedy": remedy,
                    "work": .string(emitted || ProviderFailure.report(error)?.work == .ranPartly
                        ? ProviderFailure.WorkState.ranPartly.rawValue : ChatTurnFailure.work(for: error)),
                    "owed": .bool(failure.owner != nil && !failure.personDecides),
                    "retry_now": .bool(ProviderWire.redialDelay(ProviderFailure.classify(error),
                        attempt: (error as? ProviderFailure.Diagnostic)?.tries ?? 1) != nil),
                    "tries": .int(Int64((error as? ProviderFailure.Diagnostic)?.tries ?? 1)),
                    "calls": .array(calls.map { .object(["id": .string($0.id), "name": .string($0.name), "input": .object($0.input)]) })])])
            } catch { throw TurnEngineError.streamInterrupted(partial: visibleText, underlying: failure) }
        }

        /// A spent per-run output budget is the person's cap: her part reads its
        /// receipt and ends; no further model call can run under it.
        func budgetSpent(emitted: Bool) async throws {
            let bot = StandingBotContinuity.currentBot
            try await providerFailed(ProviderFailure.Diagnostic(cause: .outputLimit, detail: "per-run output token limit spent",
                repair: ToolFailureError(
                    "This run's output token limit\(bot.map { " (\($0.budget.tokens) tokens)" } ?? "") is spent; what was written stays and no further model call runs in this run.",
                    effects: .none, owner: bot.map { "helper \($0.name)'s budget" } ?? "this run's caller",
                    tap: bot.map { "Helpers → \($0.name) → Edit → Output tokens per run" }, personDecides: true)),
                emitted: emitted)
        }

        /// The person's turn, delivered when it ends; set, the loop runs her part's private work.
        var replied: TurnEngineResult?
        /// The loop. Her reply ends; she doesn't: run again after the person
        /// has it, it runs what her part returned after reply.end, privately,
        /// on the same turn id, through the same gates, with nothing streamed,
        /// saved to the conversation or checkpointed.
        func drive() async throws -> TurnEngineResult? {
        while true {
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                throw stopCarryingPartial()
            }
            // The one exit: her part ended the turn. Ending on a provider failure,
            // or with a card still waiting on the person, leaves it incomplete; a
            // door that cannot draw the card also hears it said.
            if replied == nil, part.replied {
                let reply = Self.joinedProse(turnInterstitialProse, Self.joinedProse(retainedAnswerProse, part.answered))
                let store = AbilityStore(dataRoot: remPinsDataRoot ?? defaultDataRoot())
                for (id, rounds) in partRounds.sorted(by: { $0.key < $1.key }) {
                    // recordRounds owes the ledger's repair itself.
                    do { try store.recordRounds(id: id, rounds: rounds) }
                    catch { nativeLog("Her part %@'s rounds were not recorded: %@", id, error.localizedDescription) }
                }
                let waiting = ChatTurnExecution.current.map { $0.waitingInteraction != nil || $0.waitingForApproval } ?? false
                var held: AfterReply?
                if part.continues, !PartToolThinkingContext.active {
                let allowance = LLMCallContext.turnTokenBudget.map { TurnTokenBudget(tokens: $0.available) }
                let keeping = (turn: TurnTraceContext.turnId ?? "unknown", at: Date())
                held = afterReply {
                    await AbilityStore.$keeping.withValue(keeping) {
                    await TurnCheckpointScope.$current.withValue(nil) {
                    await DeskContinuationScope.$current.withValue(nil) {
                    await ChatTurnExecution.$current.withValue(nil) {
                    await LLMCallContext.$toolCapabilityNote.withValue(nil) {
                    await LLMCallContext.$turnTokenBudget.withValue(allowance) {
                    await ReplyChoices.$current.withValue(nil) {
                        do { _ = try await drive() } catch {
                            TurnTraceBus.fireFromContext(kind: "turn.after_reply", surface: surface, payload: .object([
                                "status": .string("failed"), "reason": .string(error.localizedDescription)]))
                        }
                    }
                    }
                    }
                    }
                    }
                    }
                    }
                    part.tellHer()
                    if let recoveryScope { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
                }
                }
                let completed = await finishReplyTurn(
                    reply: waiting ? ChatTurnExecution.waitingReply(visible: reply) : reply,
                    ctx: ctx, dispatches: dispatches, startNs: startNs,
                    providerCallCount: providerCallCount,
                    userMessage: userMessage, sessionId: sessionId, surface: surface,
                    workingCommentaryCharacters: turnInterstitialProse.isEmpty ? nil : turnInterstitialProse.count,
                    completionState: providerFailurePending || waiting ? .incomplete : .completed,
                    afterTurn: !PartToolThinkingContext.active && (providerFailurePending || part.afterTurn),
                    took: counters.toolRoundCount == 0 ? nil : Self.took(rounds: counters.providerRoundCount, tokens: spent.withLock { $0 },
                        seconds: Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000_000), repeated: longest),
                    afterReply: held)
                let result = observed(completed, reason: providerFailurePending
                    ? .incomplete : completed.resolvedTerminalReason(dataRoot: remPinsDataRoot))
                if held != nil {
                    replied = result
                    replied?.afterReply = nil
                    progress = nil
                }
                return result
            }
            guard let effect = try await part.next() else { return replied }
            switch effect["effect"] {
            case .string("reply.stream"):
                if case .string(let text)? = effect["text"], !text.isEmpty {
                    await progress?(.delta(text))
                    visibleText += text
                    part.sent(text)
                }
                try await capture()
                continue
            case .string("app"):
                // The part names calls of this model round; they run verbatim.
                var batch = [effect]
                while part.nextIsApp, let more = try await part.next() { batch.append(more) }
                guard var updatedRound = round else { throw TurnEngineError.turnPartFailed("Its app effects came with no model round to run.") }
                for item in batch {
                    if case .object(let call)? = item["call"], call["tool"] == .string("app"),
                       case .string(let id)? = call["id"], case .object(let input)? = call["input"] {
                        updatedRound.calls.append(ParsedToolCall(id: id, name: "app", input: input))
                    }
                }
                round = updatedRound
                let round = updatedRound
                let indices = try batch.compactMap { item -> Int? in
                    guard case .int(let at)? = item["index"] else { return nil }
                    guard let index = Int(exactly: at), round.calls.indices.contains(index) else {
                        throw TurnEngineError.turnPartFailed("Its app effect names a call outside the current model round.")
                    }
                    return index
                }
                let providerCalls = indices.map { round.calls[$0] }
                counters.toolRoundCount += 1
                try await capture(startingCalls: providerCalls.count)
                let roundStart = dispatches.count
                try await runToolDispatchRound(
                    providerCalls: providerCalls,
                    iterationRawText: round.raw,
                    ctx: ctx, surface: surface, sessionId: toolSessionId ?? sessionId,
                    tools: tools, progress: progress, conversation: &conversation,
                    dispatches: &dispatches, providerTools: providerTools,
                    cancelFlagPath: cancelFlagPath,
                    markerCodec: round.codec, toolBoundaryReason: round.boundary)
                previousRoundFailed = dispatches.dropFirst(roundStart).contains {
                    ToolLoopTraceObservation.isFailedAttempt($0.result)
                }
                // What she just read can bring something to mind, as her message did.
                if let reminded = await cameToMind(after: dispatches.dropFirst(roundStart),
                                                   turn: resolvedTurnContext.fluidContextTurn, held: &cameToMindHeld,
                                                   sessionId: sessionId, surface: surface) {
                    Self.appendStructuredUserNudge(reminded, to: &conversation)
                }
                if replied == nil {
                    for id in Set(dispatches.dropFirst(roundStart).compactMap({ record -> String? in
                        // The model's own call names the part; its ran call is the folded tool.
                        if let id = ToolNameAliases.authoredTool(record.ranCall.tool) { return id }
                        guard record.name == "app", case .string(let action)? = record.input["action"] else { return nil }
                        return ToolNameAliases.authoredTool(action)
                    })) { partRounds[id, default: 0] += 1 }
                }
                if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { throw stopCarryingPartial() }
                // dispatchIterationCalls keeps call order and runs every call but an ignorable one.
                // A result waiting on a person is a receipt like any other: her part
                // reads it with the card it waits on, and the card still gates the effect.
                var records = dispatches.dropFirst(roundStart).makeIterator()
                try await part.deliver(indices.map { index in
                    let call = round.calls[index]
                    let record = ToolCallParser.isIgnorableToolName(call.name) ? nil : records.next()
                    var event: [String: JSONValue] = ["type": .string("result"), "index": .int(Int64(index)), "id": .string(call.id),
                        "name": .string(call.name), "ok": .bool(record.map { ChatToolOutcome.outputLooksSuccessful($0.result) } ?? false)]
                    event["waiting"] = record.flatMap { Self.waitingOn($0.result) }
                    event["effect"] = record.flatMap { Self.landedEffect($0.result) }.map(JSONValue.string)
                    return .object(event)
                })
                continue
            case .string("model.call"):
                // A heal brought a version that names another system or tools.
                if let system = part.system, system != composed.system || part.offeredTools != composed.tools {
                    let seededCount = prefixSeed.messages.count
                    (prefixSeed, wireSystem) = seeded(gathered.composing(system, tools: part.offeredTools))
                    ctx = prefixSeed.context
                    if let sessionId, !sessionId.isEmpty, let runId, !runId.isEmpty {
                        await prefixSeed.sentContext.persist(sessionID: sessionId, runID: runId,
                            userMessageID: ChatPersistenceContext.replacementUserMessageID, dataRoot: remPinsDataRoot)
                    }
                    providerTools = ProviderToolNameMap(ctx.toolSchemas)
                    conversation = prefixSeed.messages + conversation.dropFirst(seededCount)
                    compactionTurnStart = prefixSeed.messages.count - 1
                    composed = (system, part.offeredTools)
                }
                // Words of her own the part adds to the conversation before this call.
                if case .string(let note)? = effect["note"], !note.isEmpty { Self.appendStructuredUserNudge(note, to: &conversation) }
            default:
                // reply.end and after: the part's own bookkeeping, checkpointed like any effect.
                try await capture()
                continue
            }
            if replyTextSettled {
                replyTextSettled = false
                await progress?(.replyTextSettled(false))
            }
            let pressure = try await IntraTurnContextCompaction.compactProactivelyIfNeeded(
                conversation: &conversation,
                turnStartIndex: compactionTurnStart,
                windowTokens: turnWindowTokens,
                distill: distillWorkingNotes,
                surface: surface,
                progress: progress
            )
            if let failure = pressure?.failure {
                TurnObservation.apply(.notesUnwritten(why: failure.message), to: &conversation, surface: surface)
            }
            try await capture()
            var iterAccumulated = ""
            var iterEmittedProse = ""
            var streamedCalls: [ParsedToolCall] = []
            /// The provider yielded text or a call this round; set as it arrives, before any cleanup.
            var emitted = false
            var toolBoundaryReason: LLMToolBoundaryReason?
            var pendingProtocolDelta = ""
            let rawProviderEvents = OSAllocatedUnfairLock<String>(initialState: "")
            let roundBaseVisibleText = visibleText

            // Only prose can survive an incomplete stream; none of its calls ran.
            func keepPartial() async -> String {
                let kept = toolBoundaryReason == .fabricatedResult
                    ? iterEmittedProse : toolCallCodec.visiblePrefix(in: iterAccumulated)
                if kept.hasPrefix(iterEmittedProse) {
                    let tail = String(kept.dropFirst(iterEmittedProse.count))
                    if !tail.isEmpty { await progress?(.delta(tail)) }
                }
                visibleText = roundBaseVisibleText + kept
                retainedAnswerProse = Self.joinedProse(retainedAnswerProse, kept)
                streamedCalls.removeAll(keepingCapacity: true)
                pendingProtocolDelta.removeAll(keepingCapacity: true)
                return kept
            }

            do { try await providerAdmission?() }
            catch is CancellationError { throw stopCarryingPartial() }
            providerStream: do {
                if let sessionId, !sessionId.isEmpty, replied == nil {
                    let offers = await ChatTurnSteering.shared.drain(
                        sessionId: sessionId, cancelFlagPath: cancelFlagPath)
                    if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                        throw CancellationError()
                    }
                    steeringOffers += offers
                    for offer in offers {
                        Self.appendStructuredUserNudge(
                            ChatTurnSteering.deliveryText(offer.text), to: &conversation)
                    }
                    if let root = remPinsDataRoot, !SessionConversation.isHelper(sessionId, dataRoot: root), PeerDataTaint.current?.isTainted != true,
                       [nil, "self"].contains(ChatToolSessionContext.envelope?.agent),
                       let arrived = ResidentWake.shared.take(dataRoot: root) {
                        arrivedItems += arrived.items
                        Self.appendStructuredUserNudge(arrived.text, to: &conversation)
                    }
                }
                providerCallCount += 1
                counters.providerAttemptCount += 1
                counters.providerRoundCount += 1
                if previousRoundFailed { counters.roundsAfterToolFailureCount += 1 }
                previousRoundFailed = false
                // Construction and consumption share the async task-local scope.
                let providerRoute = ctx.providerId ?? LLMCallContext.providerId
                let serviceTier = ctx.serviceTier ?? LLMCallContext.serviceTier
                let purpose: String
                if LLMCallContext.purpose == "other", case .string(let named)? = effect["purpose"] { purpose = named }
                else { purpose = LLMCallContext.purpose }
                let captureEvents: @Sendable (SSEEvent) -> Void = { event in
                    guard providerRoute == "anthropic_oauth_direct" else { return }
                    rawProviderEvents.withLock { raw in
                        if let name = event.event { raw += "event: \(name)\n" }
                        raw += "data: " + event.data.replacingOccurrences(of: "\n", with: "\ndata: ") + "\n\n"
                    }
                }
                let consumeStream: () async throws -> Void = {
                    try await ProviderStreamContext.$diagnosticEvent.withValue(captureEvents) {
                    try await ProviderStreamContext.$dispatched.withValue(requestDispatched) {
                    try await LLMCallContext.$purpose.withValue(purpose) {
                    let stream = llm.streamMessages(
                        messages: conversation,
                        system: wireSystem.prompt,
                        model: ctx.modelId,
                        surface: surface,
                        tools: toolCallCodec.requestTools(providerTools.schemas)
                    )
                    streaming: for try await event in stream {
                        try Task.checkCancellation()
                        if ChatCancelFlag.isRaised(cancelFlagPath) { throw CancellationError() }
                        // A Steer waits: cut here, keep what was said, and the next
                        // round reads the person's words (the drain below).
                        if let sessionId, !sessionId.isEmpty, replied == nil, ChatTurnSteering.hasPending(sessionId) {
                            toolBoundaryReason = .steered
                            break streaming
                        }
                        switch event {
                        case .toolBoundary(let reason):
                            toolBoundaryReason = reason
                        case .replyTextSettled(let settled):
                            if settled {
                                let prose = toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
                                if !prose.isEmpty {
                                    iterEmittedProse += prose
                                    await progress?(.delta(prose))
                                }
                                pendingProtocolDelta.removeAll(keepingCapacity: true)
                            }
                            replyTextSettled = settled
                            await progress?(.replyTextSettled(settled))
                        case .textDelta(let delta):
                            if !delta.isEmpty {
                                emitted = true
                                try await commitDelivery()
                                if !emittedProviderFirstDelta {
                                    emittedProviderFirstDelta = true
                                    TurnLifecycleTelemetry.emit(
                                        .providerFirstDelta, surface: surface, sessionId: sessionId,
                                        observedBy: "structured_tool_loop.stream")
                                }
                            }
                            iterAccumulated += delta
                            visibleText += delta
                            pendingProtocolDelta += delta
                            let safe = toolCallCodec.releasableProse(holding: &pendingProtocolDelta)
                            if !safe.isEmpty {
                                iterEmittedProse += safe
                                await progress?(.delta(safe))
                            }
                        case .toolCall(let call):
                            emitted = true
                            try await commitDelivery()
                            guard let parsed = try toolCallCodec.decode(call) else { continue }
                            streamedCalls.append(parsed)
                        case .keepAlive:
                            break
                        }
                    }
                    try Task.checkCancellation()
                    if ChatCancelFlag.isRaised(cancelFlagPath) { throw CancellationError() }
                    }
                    }
                    }
                }
                try await ConversationPrefixBoundary.$currentUserIndex.withValue(prefixSeed.currentUserIndex) {
                try await LLMCallContext.$admittedModel.withValue(ctx.modelId) {
                try await LLMCallContext.$providerId.withValue(providerRoute) {
                try await LLMCallContext.$serviceTier.withValue(serviceTier) {
                try await LLMCallContext.$systemSegments.withValue(wireSystem.segments) {
                try await LLMCallContext.$sessionId.withValue(sessionId) {
                try await LLMCallContext.$reasoningEffort.withValue(ctx.reasoningEffort) {
                try await LLMCallTraceRecorder.$spent.withValue(spent) {
                try await AnthropicOAuthTransport.MessagesCacheHint.$withinTurnReuse.withValue(true) {
                try await InspectorThinkingLane.$summarizedThinking
                    .withValue(InspectorThinkingLane.isEnabledForSurface(surface)) {
                    try await consumeStream()
                }
                }
                }
                }
                }
                }
                }
                }
                }
                }
            } catch {
                if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) || error is CancellationError {
                    throw stopCarryingPartial()
                }
                if ProviderFailure.classify(error) == .malformedResponse {
                    let raw = rawProviderEvents.withLock { $0 }
                    if !raw.isEmpty { RunawayOutputDetector.writeDiagnostic(raw, reason: "malformed_stream") }
                }
                counters.failedProviderAttemptCount += 1
                // A spent budget's partial is the whole run's ledger, not this round's words.
                if iterAccumulated.isEmpty, case .outputLengthLimit(let partial) = error as? LLMError,
                   LLMCallContext.turnTokenBudget?.exhausted != true {
                    iterAccumulated = partial
                }
                // A cut after her words or calls is the round's boundary: complete
                // calls run, and she continues after what she said.
                if ProviderRecoveryPolicy.isRecoverable(error) || ProviderFailure.classify(error) == .malformedResponse,
                   !toolCallCodec.roundCalls(streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas, recordShims: false).isEmpty
                    || !toolCallCodec.visiblePrefix(in: iterAccumulated).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    toolBoundaryReason = .interrupted
                    break providerStream
                }
                let kept = await keepPartial()
                if case .outputLengthLimit = error as? LLMError,
                   LLMCallContext.turnTokenBudget?.exhausted == true {
                    try await budgetSpent(emitted: emitted)
                } else if ProviderRecoveryPolicy.isContextOverflow(error) {
                    let receipt = try await IntraTurnContextCompaction.compact(
                        conversation: &conversation, turnStartIndex: compactionTurnStart,
                        windowTokens: turnWindowTokens, pressure: .overflow, distill: distillWorkingNotes)
                    if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { throw stopCarryingPartial() }
                    counters.contextOverflowRecoveryCount += 1
                    TurnTraceBus.fireFromContext(
                        kind: TurnLifecycleMilestone.contextIntraTurnCompaction.rawValue,
                        surface: surface, payload: IntraTurnContextCompaction.tracePayload(
                            receipt, trigger: "overflow"))
                    // Nothing left to trim: the refusal itself, or why no notes could
                    // be written, is her part's next input.
                    if receipt.mode == "none" {
                        try await providerFailed(receipt.failure.map {
                            ProviderFailure.Diagnostic(cause: .contextTooLong, detail: $0.message, repair: $0)
                        } ?? error, emitted: emitted)
                    } else {
                        if let failure = receipt.failure {
                            TurnObservation.apply(.notesUnwritten(why: failure.message), to: &conversation, surface: surface)
                        }
                        try await observe(.contextFull, kept: kept)
                        await progress?(.notice(kind: IntraTurnContextCompaction.noticeKind,
                            text: IntraTurnContextCompaction.noticeText))
                    }
                } else if case .outputLengthLimit = error as? LLMError {
                    try await observe(.lengthLimit(chars: kept.count), kept: kept)
                } else {
                    try await providerFailed(error, emitted: emitted)
                }
                continue
            }
            providerFailurePending = false
            let iterProse = ToolCallParser.stripProtocolDebris(iterAccumulated)
            let answerText = iterProse.replacingOccurrences(
                of: #"</?[\p{L}_][\p{L}\p{N}_.:-]*(?:\s[^<>]*)?/?>|<[!?][^>]*>"#, with: "", options: .regularExpression)
            func saveSuspiciousReply() {
                let visible = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard visible.split(whereSeparator: { $0.isWhitespace }).count < 2
                    || (visible.count < 12 && iterProse.contains(where: { "<=>".contains($0) })) else { return }
                let raw = rawProviderEvents.withLock { $0 }
                if !raw.isEmpty { RunawayOutputDetector.writeDiagnostic(raw, reason: "suspicious_reply") }
            }
            if toolBoundaryReason == nil, streamedCalls.isEmpty && !answerText.contains(where: { !$0.isWhitespace }) {
                saveSuspiciousReply()
                visibleText = roundBaseVisibleText
                counters.emptyReplyRoundCount += 1
                try await providerFailed(ProviderFailure.Diagnostic(cause: .malformedResponse,
                    detail: "The provider completed without an answer or a tool call."), emitted: emitted)
                continue
            }
            let markerCodec = toolCallCodec == .textMarkers
                ? TextMarkerCodec(schemas: ctx.toolSchemas,
                    turnActiveTools: LLMCallContext.turnActiveTools ?? [], catalogNames: Set(ctx.toolsAvailable))
                : nil
            var violation: ToolCallProtocolViolation?
            if let markerCodec {
                violation = markerCodec.malformedCall(in: iterProse)
            } else {
                violation = ToolCallParser.formattedToolCallViolation(in: iterProse, toolNames: Set(ctx.toolsAvailable))
            }
            if violation?.traceType == "malformedToolUseMarker", markerCodec != nil, streamedCalls.isEmpty,
               let repaired = ToolCallParser.repairMalformedRegion(
                in: iterAccumulated, toolNames: Set(ctx.toolSchemas.map(\.name))) {
                iterAccumulated = repaired
                violation = nil
            }
            if let violation {
                counters.protocolViolationRoundCount += 1
                let rejectedBytes = Data(iterAccumulated.utf8)
                var diagnostic: [String: JSONValue] = [
                    "type": .string(violation.traceType),
                    "byteSize": .int(Int64(rejectedBytes.count)),
                    "sha256": .string(SHA256.hash(data: rejectedBytes).map { String(format: "%02x", $0) }.joined()),
                ]
                do {
                    diagnostic["path"] = .string(try RunawayOutputDetector.writeDiagnostic(iterAccumulated, reason: violation.traceType).get().path)
                } catch { diagnostic["file_error"] = .string(error.localizedDescription) }
                TurnTraceBus.fireFromContext(kind: "tool.protocol_violation", surface: surface, payload: .object(diagnostic))
                let kept = await keepPartial()
                try await observe(.malformedCall(why: violation.modelFeedback), kept: kept)
                continue
            }
            let providerCalls = toolCallCodec.roundCalls(
                streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas)
            if providerCalls.isEmpty {
                saveSuspiciousReply()
                if let toolBoundaryReason {
                    let kept = await keepPartial()
                    if toolBoundaryReason == .outputLimit, LLMCallContext.turnTokenBudget?.exhausted == true {
                        try await budgetSpent(emitted: emitted)
                    } else {
                        try await observe(.boundary(toolBoundaryReason), kept: kept)
                    }
                    continue
                }
                if !pendingProtocolDelta.isEmpty {
                    await progress?(.delta(toolCallCodec.visiblePrefix(in: pendingProtocolDelta)))
                }
                // Her answer stays in the conversation for whatever her part does next.
                conversation.append(.assistantText(iterProse))
                // The longest stretch rides the closing event, so her part can read the loop.
                var closing: [String: JSONValue] = ["type": .string("model"), "text": .string(iterProse), "calls": .array([])]
                if replied == nil, longest.count > 1 {
                    closing["repeated"] = .object(["call": .string(longest.call), "count": .int(Int64(longest.count))])
                }
                try await part.deliver([.object(closing)])
                continue
            }

            let pendingProse = toolBoundaryReason == .fabricatedResult
                ? "" : toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
            if !pendingProse.isEmpty {
                iterEmittedProse += pendingProse
                await progress?(.delta(pendingProse))
            }
            visibleText = roundBaseVisibleText + iterEmittedProse
            turnInterstitialProse = Self.joinedProse(turnInterstitialProse, iterEmittedProse)
            round = (providerCalls, toolCallCodec == .textMarkers ? iterAccumulated : iterEmittedProse, markerCodec, toolBoundaryReason)
            if replied == nil {
                let made = providerCalls.map { JSONValue.object(["name": .string($0.name), "input": .object($0.input)]) }
                repeated = made == repeated.calls ? (made, repeated.call, repeated.count + 1) : (made, providerCalls.map { call in
                    if case .string(let action)? = call.input["action"] { action } else { call.name }
                }.joined(separator: ", "), 1)
                if repeated.count > longest.count { longest = (repeated.call, repeated.count) }
            }
            try await part.deliver([.object(["type": .string("model"), "text": .string(iterEmittedProse),
                "calls": .array(providerCalls.enumerated().map {
                    .object(["index": .int(Int64($0.offset)), "id": .string($0.element.id), "name": .string($0.element.name),
                             "input": .object($0.element.input)])
                })])])
        }
        }
        guard let result = try await drive() else {
            throw TurnEngineError.turnPartFailed("Its steps ended the turn without a reply.end.")
        }
        return result
        }
        }
    }

    /// What a turn took, in one plain line for her after-turn mind.
    nonisolated static func took(rounds: Int, tokens: Int, seconds: Int, repeated: (call: String, count: Int)) -> String {
        let amount = tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
            : tokens >= 1_000 ? "\(tokens / 1_000)k" : "\(tokens)"
        var line = "This took \(rounds) round\(rounds == 1 ? "" : "s")" + (tokens > 0 ? ", \(amount) tokens" : "")
            + (seconds < 90 ? ", \(seconds) seconds" : ", \(Int((Double(seconds) / 60).rounded())) minutes")
        if repeated.count > 1 { line += "; \(repeated.count) rounds in a row called \(repeated.call)" }
        return line + "."
    }

    /// Trim seam and trailing whitespace; one blank line separates prose and anchors the commentary offset.
    nonisolated static func joinedProse(_ head: String, _ tail: String) -> String {
        let head = String(head[..<(head.lastIndex { !$0.isWhitespace }.map(head.index(after:)) ?? head.startIndex)])
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty || tail.isEmpty ? head + tail : head + "\n\n" + tail
    }
}
