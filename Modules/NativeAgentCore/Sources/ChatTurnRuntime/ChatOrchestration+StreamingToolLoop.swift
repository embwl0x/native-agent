import AuthoredCapabilities
import AgentWorkspace
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
// Blueprint: | `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: runs their turn part's effects, hands it each event with each result's declared effect, logs at every host-call boundary; the turn returns at `reply.end` and `after`, and effects after them run privately on the same turn id, never streamed, saved to the conversation or checkpointed); before a fresh message’s opening model call, mind/authority practice may supply one gated standing read as `already_looked`; the first private keep records only landed hand-work action ids (or one call repeated 3+ rounds) through `FamiliarLines` (`practice: `), opens on a later meeting unless an active ability's recorded route covers it, traces `practice.keep`, and lets later rounds finish that keep; `joinedProse`; `provider.roundOutput` counts safe prose and tool calls per parsed person-facing round; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed; the person's turn is measured as it goes (model rounds, its own calls' tokens, minutes, the longest stretch of one round's calls repeated for `took`, and the longest single-call stretch on the closing `model` event as `repeated`): `took` is the after-turn line, and each part called records its rounds |

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
        guard surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "missions" else {
            throw ToolFailureError("The routing surface is workshop. Correct the caller's surface before starting its turn.", effects: .none, recovery: .correctArguments)
        }
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
        var dispatchTrace = ContextStageTrace()
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
        var resolvedTurnContext = gathered.composing(system, tools: part.offeredTools)
        dispatchTrace.record(.turnPart, since: startNs)
        Self.fireContextReady(surface: surface, context: resolvedTurnContext, sessionId: sessionId)
        var commitInstructionDelivery = try pendingInstructionDelivery(in: resolvedTurnContext, sessionID: sessionId)
        // Steered messages reach the queue owner as delivered at the same
        // moment instructions do: the round carrying them produced output.
        var steeringOffers: [ChatTurnSteering.Offer] = []
        var arrivedItems: [ResidentWake.Item] = []
        var contextDeliveryOwed = true
        var commitPartsDelivery = resolvedTurnContext.partsDelivery
        // Memories a moment brought to mind this turn (what she read, while working).
        var cameToMindHeld: Set<ContextAtomID> = []
        func commitDelivery() async throws {
            if let acknowledge = commitPartsDelivery {
                commitPartsDelivery = nil
                acknowledge(Self.deliveredInput(resolvedTurnContext))
            }
            try commitInstructionDelivery?()
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
        let codecStart = DispatchTime.now().uptimeNanoseconds
        let toolCallCodec = try ToolCallCodec.forProvider(
            try await LLMCallContext.$admittedModel.withValue(resolvedTurnContext.modelId) {
                try await LLMCallContext.$providerId.withValue(resolvedTurnContext.providerId ?? LLMCallContext.providerId) {
                    try await llm.servingProviderID(model: resolvedTurnContext.modelId, surface: surface)
                }
            }
        )
        dispatchTrace.record(.toolCodec, since: codecStart)
        /// The request her part's opening model.call names, seeded as the turn's
        /// prefix; seeded again when a heal brings a version that names another.
        func seeded(_ composed: TurnContext) throws -> (ConversationPrefixSeeding.Seed, (prompt: String?, segments: SystemPromptSegments?)) {
            let request = try ConversationPrefixSeeding.request(composed, codec: toolCallCodec)
            return (request.seed, (request.system, request.segments))
        }
        let seedStart = DispatchTime.now().uptimeNanoseconds
        var (prefixSeed, wireSystem) = try seeded(resolvedTurnContext)
        var composed = (system: system, tools: part.offeredTools)
        var ctx = prefixSeed.context
        // The provider-name map is built from the array and then held still
        // until a heal names other tools.
        var providerTools = ProviderToolNameMap(ctx.toolSchemas)
        dispatchTrace.record(.prefixSeed, since: seedStart)
        // Capture immutable request values: later healing may replace the seed.
        // None of these diagnostics or the optional replay write builds the wire
        // request. Join before tool reads, reply settlement, or any throwing exit.
        let initialSeed = prefixSeed
        let prefixTelemetry = Task { await Self.preparePrefixTelemetry(initialSeed) }
        let prefixSnapshot = Task { let result = await prefixTelemetry.value; return result.snapshot }
        let prefixSink = ConversationPrefixTelemetry.sink
        prefixSink?.setPending(prefixSnapshot)
        let replacementUserMessageID = ChatPersistenceContext.replacementUserMessageID
            ?? resolvedTurnContext.historyReplaySpec?.replacementUserMessageID
        var bookkeeping = Task { [remPinsDataRoot] in
            await Self.recordDispatchBookkeeping(seed: initialSeed,
                telemetry: prefixTelemetry, sink: prefixSink, surface: surface, sessionId: sessionId, runId: runId,
                userMessageID: replacementUserMessageID, dataRoot: remPinsDataRoot)
        }
        do {
        dispatchTrace.setFlag("bookkeepingParallel", true)
        let preparedDispatchTrace = dispatchTrace
        let remainderStart = DispatchTime.now().uptimeNanoseconds
        // Dispatch is route/adapter admission, before HTTP body assembly. The
        // ProviderWire event separately names the URLSession send boundary.
        let requestStarted = OSAllocatedUnfairLock(initialState: false)
        let requestDispatched: @Sendable () -> Void = {
            guard requestStarted.withLock({ started in defer { started = true }; return !started }) else { return }
            var trace = preparedDispatchTrace
            trace.record(.dispatchRemainder, since: remainderStart)
            trace.emit(kind: "turn.dispatch.summary", surface: surface)
            TurnLifecycleTelemetry.emit(.providerRequestStarted, surface: surface, sessionId: sessionId,
                                        observedBy: "transport.dispatch", flags: ["initialRequest": true])
        }
        var conversation: [LLMMessage] = prefixSeed.messages
        // What happened since her last turn primes this one: her own turns hear what it brought to mind.
        if let root = remPinsDataRoot, let sessionId, try !SessionConversation.checkedIsHelper(sessionId, dataRoot: root),
           PeerDataTaint.current?.isTainted != true, [nil, "self"].contains(ChatToolSessionContext.envelope?.agent) {
            let moments = try PrimedMoments.take(dataRoot: root)
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
        let spent = OSAllocatedUnfairLock(initialState: LLMCallTraceRecorder.Spend())
        var partRounds: [String: Int] = [:]
        var repeated = (calls: [JSONValue](), call: "", count: 0), longest = (call: "", count: 0)
        var loopPractice = (calls: [JSONValue](), call: "", count: 0)
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
        var openingAdditionalCharacters = 0
        // Relaunches resume their recorded work; retries keep the one opening read.
        var openingReadOwed = restarted == nil
        var replyTextSettled = false
        var providerFailurePending = part.log.reversed().compactMap { row -> String? in
            guard case .object(let entry) = row, case .object(let event)? = entry["event"],
                  case .string(let type)? = event["type"], ["model", "provider_failure"].contains(type) else { return nil }
            return type
        }.first == "provider_failure"

        if let restarted {
            let rows = TurnCheckpointScope.resumedRows
            let receipts = rows.filter { SessionHistoryPromptRenderer.renderable($0)?.isTool == true }
            dispatches = try receipts.map { row in
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
                    throw ChatOrchestrationError.underlying("The resumed turn's saved tool receipt has no execution-time ranCall identity. Repair the checkpoint's receipt; no tool binding was inferred.")
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
            let replay = try SessionHistoryMessages.project(messages: [user] + receipts,
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
        var keepStarted = false
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
                await bookkeeping.value
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
                    took: counters.toolRoundCount == 0 ? nil : Self.took(rounds: counters.providerRoundCount, tokens: spent.withLock { $0.total },
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
                await bookkeeping.value
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
                if replied != nil, effect["purpose"] == .string("keep"), !keepStarted {
                    guard try Self.practiceShouldKeep(dispatches, repeated: loopPractice, dataRoot: remPinsDataRoot ?? defaultDataRoot()) else { return replied }
                    keepStarted = true
                }
                // A heal brought a version that names another system or tools.
                if let system = part.system, system != composed.system || part.offeredTools != composed.tools {
                    // Preserve write order: the opening seed cannot overwrite
                    // the healed seed after its request has been prepared.
                    await bookkeeping.value
                    let seededCount = prefixSeed.messages.count
                    resolvedTurnContext = gathered.composing(system, tools: part.offeredTools)
                    (prefixSeed, wireSystem) = try seeded(resolvedTurnContext)
                    ctx = prefixSeed.context
                    providerTools = ProviderToolNameMap(ctx.toolSchemas)
                    let healedSeed = prefixSeed
                    let healedTelemetry = Task { await Self.preparePrefixTelemetry(healedSeed) }
                    prefixSink?.setPending(Task { let result = await healedTelemetry.value; return result.snapshot })
                    bookkeeping = Task { [remPinsDataRoot] in
                        await Self.recordDispatchBookkeeping(seed: healedSeed,
                            telemetry: healedTelemetry, sink: prefixSink, surface: surface, sessionId: sessionId,
                            runId: runId, userMessageID: replacementUserMessageID, dataRoot: remPinsDataRoot)
                    }
                    conversation = prefixSeed.messages + conversation.dropFirst(seededCount)
                    compactionTurnStart = prefixSeed.messages.count - 1
                    composed = (system, part.offeredTools)
                }
                // Words of her own the part adds to the conversation before this call.
                if case .string(let note)? = effect["note"], !note.isEmpty { Self.appendStructuredUserNudge(note, to: &conversation) }
                if openingReadOwed {
                    openingReadOwed = false
                    if ctx.toolSchemas.contains(where: { $0.name == "app" }), let expansion = tools as? ExpansionDispatcher {
                        let looked = await LLMCallContext.$admittedModel.withValue(ctx.modelId) {
                        await FluidContextToolScope.$current.withValue(ctx.fluidContextTurn) {
                        await ChatTurnRuntimeContext.$current.withValue(.init(
                            model: ctx.modelId, surface: surface, personaID: ctx.personaID,
                            providerID: ctx.providerId ?? LLMCallContext.providerId)) {
                            await expansion.readAhead(surface: surface, session: toolSessionId ?? sessionId)
                        } } }
                        if let looked {
                            // The same {call,result} already_looked entry a tool result carries.
                            let text = try ChatSecretRedactor.redactValue(looked).serialize(pretty: false)
                            Self.appendStructuredUserNudge(text, to: &conversation)
                        }
                    }
                }
            default:
                // reply.end and after: the part's own bookkeeping, checkpointed like any effect.
                try await capture()
                continue
            }
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { throw stopCarryingPartial() }
            if replyTextSettled {
                replyTextSettled = false
                await progress?(.replyTextSettled(false))
            }
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
                    if let root = remPinsDataRoot, try !SessionConversation.checkedIsHelper(sessionId, dataRoot: root), PeerDataTaint.current?.isTainted != true,
                       [nil, "self"].contains(ChatToolSessionContext.envelope?.agent),
                       let arrived = ResidentWake.shared.take(dataRoot: root) {
                        arrivedItems += arrived.items
                        Self.appendStructuredUserNudge(arrived.text, to: &conversation)
                    }
                }
                if providerCallCount == 0, sessionId != nil,
                   !ConversationPrefixTelemetry.requestShapeUnmeasured {
                    // This is the actual opening request, including text that
                    // arrived after seeding. Slice its appended blocks here,
                    // never rows from a second transcript reconstruction.
                    let index = prefixSeed.currentUserIndex
                    guard conversation.indices.contains(index), prefixSeed.messages.indices.contains(index),
                          conversation[index].content.count >= prefixSeed.messages[index].content.count else {
                        throw ProviderRoutingError.configurationFailed("The opening request no longer contains its built user block.")
                    }
                    let added = Array(conversation[index].content.dropFirst(prefixSeed.messages[index].content.count))
                    var additional: [LLMMessage] = added.isEmpty ? [] : [LLMMessage(role: .user, content: added)]
                    additional.append(contentsOf: conversation.dropFirst(index + 1))
                    openingAdditionalCharacters = LLMMessage.inputCharacters(additional, system: nil, tools: [])
                    if let fit = SessionRequestFit.current {
                        await bookkeeping.value
                        resolvedTurnContext = try await fit(resolvedTurnContext, toolCallCodec, additional)
                        (prefixSeed, wireSystem) = try seeded(resolvedTurnContext)
                        ctx = prefixSeed.context
                        providerTools = ProviderToolNameMap(ctx.toolSchemas)
                        conversation = ConversationPrefixSeeding.Request(seed: prefixSeed,
                            system: wireSystem.prompt, segments: wireSystem.segments,
                            tools: toolCallCodec.requestTools(providerTools.schemas)).appending(additional).messages
                        compactionTurnStart = prefixSeed.messages.count - 1
                        let fittedSeed = prefixSeed
                        let fittedTelemetry = Task { await Self.preparePrefixTelemetry(fittedSeed) }
                        prefixSink?.setPending(Task {
                            let result = await fittedTelemetry.value
                            return result.snapshot
                        })
                        bookkeeping = Task { [remPinsDataRoot] in
                            await Self.recordDispatchBookkeeping(seed: fittedSeed,
                                telemetry: fittedTelemetry, sink: prefixSink, surface: surface, sessionId: sessionId,
                                runId: runId, userMessageID: replacementUserMessageID, dataRoot: remPinsDataRoot)
                        }
                    }
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
                if let sessionId, !ConversationPrefixTelemetry.requestShapeUnmeasured {
                    guard let root = remPinsDataRoot else {
                        throw ProviderRoutingError.configurationFailed("The conversation's data root is unavailable; its request cannot be checked before sending.")
                    }
                    let request = try SessionContextRequest(messages: conversation,
                        system: wireSystem.prompt, tools: toolCallCodec.requestTools(providerTools.schemas) ?? [],
                        historyCharacters: 0, rowCharacters: [:])
                    try await SessionContextMeasurement.requireFits(request, sessionId: sessionId,
                        model: ctx.modelId, providerID: ctx.providerId, dataRoot: root,
                        windowTokens: turnWindowTokens)
                }
                // Capture only after fit, opening reads and compaction have
                // produced the exact first request passed to streamMessages.
                // The accepted publication is reserved here, before its task.
                if providerCallCount == 0 {
                    let snapshotRequest = ConversationPrefixSeeding.Request(seed: prefixSeed,
                        system: wireSystem.prompt, segments: wireSystem.segments,
                        tools: toolCallCodec.requestTools(providerTools.schemas))
                    let snapshotMessages = conversation
                    let publication = remPinsDataRoot.flatMap { root in
                        sessionId.map { ContextFedRecord.begin(sessionId: $0, dataRoot: root) }
                    }
                    let preceding = bookkeeping
                    bookkeeping = Task {
                        await preceding.value
                        await Self.recordWireSnapshot(request: snapshotRequest, messages: snapshotMessages,
                            publication: publication, surface: surface, sessionId: sessionId, runId: runId)
                    }
                }
                try await capture()
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
                let requestPlan: Data?
                if LLMCallContext.conversationRequest, !ConversationPrefixTelemetry.requestShapeUnmeasured,
                   let runId, sessionId != nil {
                    requestPlan = try ConversationPrefixSeeding.Request(seed: prefixSeed,
                        system: wireSystem.prompt, segments: wireSystem.segments,
                        tools: toolCallCodec.requestTools(providerTools.schemas))
                        .plan(runID: runId, userMessageID: replacementUserMessageID,
                            additionalCharacters: openingAdditionalCharacters).encoded
                } else { requestPlan = nil }
                let consumeStream: () async throws -> Void = {
                    try await ProviderStreamContext.$diagnosticEvent.withValue(captureEvents) {
                    try await ProviderStreamContext.$dispatched.withValue(requestDispatched) {
                    try await LLMCallContext.$purpose.withValue(purpose) {
                    try await LLMCallContext.$sessionRequestPlan.withValue(requestPlan) {
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
                if let failure = error as? ToolFailureError,
                   failure.code == "context_window_exceeded" || failure.code == "recollection_unavailable" {
                    // A local admission refusal is terminal for this request;
                    // provider-overflow recovery must never truncate around it.
                    throw failure
                }
                if sessionId != nil, !ConversationPrefixTelemetry.requestShapeUnmeasured,
                   ProviderRecoveryPolicy.isContextOverflow(error) {
                    throw ToolFailureError("The provider refused this request's context window after fitting: \(error.localizedDescription). Retained history was not truncated. Repair the model-window/token measurement or reduce the current input before continuing.",
                        effects: .none, owner: ctx.modelId, code: "context_window_exceeded", status: .refused, recovery: .repair)
                }
                if ProviderFailure.classify(error) == .malformedResponse {
                    let raw = rawProviderEvents.withLock { $0 }
                    if !raw.isEmpty { RunawayOutputDetector.writeDiagnostic(raw, reason: "malformed_stream", dataRoot: remPinsDataRoot) }
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
                   try !toolCallCodec.roundCalls(streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas, recordShims: false).isEmpty
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
                if !raw.isEmpty { RunawayOutputDetector.writeDiagnostic(raw, reason: "suspicious_reply", dataRoot: remPinsDataRoot) }
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
            let violation: ToolCallProtocolViolation?
            if let markerCodec {
                violation = markerCodec.malformedCall(in: iterProse)
            } else {
                violation = ToolCallParser.formattedToolCallViolation(in: iterProse, toolNames: Set(ctx.toolsAvailable))
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
                    if let file = try RunawayOutputDetector.writeDiagnostic(iterAccumulated, reason: violation.traceType, dataRoot: remPinsDataRoot).get() {
                        diagnostic["path"] = .string(file.path)
                    }
                } catch { diagnostic["file_error"] = .string(error.localizedDescription) }
                TurnTraceBus.fireFromContext(kind: "tool.protocol_violation", surface: surface, payload: .object(diagnostic))
                let kept = await keepPartial()
                try await observe(.malformedCall(why: violation.modelFeedback), kept: kept)
                continue
            }
            let providerCalls = try toolCallCodec.roundCalls(
                streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas)
            if replied == nil {
                // Counts only: distinguish a silent tool round from words
                // delivered before tools, without retaining provider text.
                let tail = providerCalls.isEmpty
                    ? toolCallCodec.visiblePrefix(in: pendingProtocolDelta)
                    : (toolBoundaryReason == .fabricatedResult ? "" : toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta))
                let prose = (iterEmittedProse + tail).trimmingCharacters(in: .whitespacesAndNewlines)
                TurnTraceBus.fireFromContext(kind: "provider.roundOutput", surface: surface, payload: .object([
                    "round": .int(Int64(providerCallCount)),
                    "proseCharacters": .int(Int64(prose.count)),
                    "toolCallCount": .int(Int64(providerCalls.count)),
                ]))
            }
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
                // A single call's longest stretch offers a loop practice to her part.
                var closing: [String: JSONValue] = ["type": .string("model"), "text": .string(iterProse), "calls": .array([])]
                if replied == nil, loopPractice.count > 1 {
                    closing["repeated"] = .object(["call": .string(loopPractice.call), "count": .int(Int64(loopPractice.count))])
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
                if made.count == 1, repeated.count > loopPractice.count { loopPractice = repeated }
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
        await bookkeeping.value
        return result
        } catch {
            await bookkeeping.value
            throw error
        }
        }
        }
    }

    /// Meet only the hand work that offered this keep, never incidental reads,
    /// arguments or the keep's later work. First meeting records it; a later
    /// meeting opens the keep unless an active ability's recorded route covers it.
    nonisolated private static func practiceShouldKeep(_ dispatches: [TurnEngineResult.ToolDispatchRecord],
                                                       repeated: (calls: [JSONValue], call: String, count: Int), dataRoot: URL) throws -> Bool {
        func identity(_ name: String, _ input: [String: JSONValue]) -> JSONValue {
            var ids = [JSONValue.string(name)]
            if name == "app", case .string(let action)? = input["action"] { ids.append(.string(action)) }
            return .array(ids)
        }
        // A batch or a script is its landed steps, each by its own action id,
        // never one opaque "app" (two unrelated batches are not a repeat).
        func steps(_ record: TurnEngineResult.ToolDispatchRecord) -> [JSONValue] {
            if record.name != "app" || record.input["action"]?.stringValue?.isEmpty == false {
                return [identity(record.name, record.input)]
            }
            let fields = record.result.objectValue ?? [:]
            let rows = fields["receipts"]?.arrayValue ?? fields["calls"]?.arrayValue ?? []
            return rows.compactMap { row -> JSONValue? in
                guard let step = row.objectValue,
                      Self.landedEffect(row).map({ ["write", "irreversible"].contains($0) }) == true,
                      let id = step["action"]?.stringValue ?? step["call"]?.stringValue, !id.isEmpty,
                      ToolNameAliases.authoredTool(id) == nil else { return nil }
                return .array([.string("app"), .string(id)])
            }
        }
        var sequence = dispatches.filter { record in
            let action = record.name == "app" ? record.input["action"]?.stringValue ?? "" : ""
            guard ToolNameAliases.authoredTool(record.ranCall.tool) == nil,
                  ToolNameAliases.authoredTool(action) == nil else { return false }
            return Self.landedEffect(record.result).map { ["write", "irreversible"].contains($0) } ?? false
        }.flatMap(steps)
        if sequence.isEmpty, repeated.count >= 3, repeated.calls.count == 1,
           let call = repeated.calls.first?.objectValue, let name = call["name"]?.stringValue,
           let input = call["input"]?.objectValue {
            sequence = [identity(name, input)]
        }
        // An ability is worth keeping when it would replace more than one call:
        // a lone write, however often she makes it, is just using the tool.
        let looped = sequence.count == 1 && repeated.count >= 3 && repeated.calls.count == 1
        guard sequence.count >= 2 || looped else { return false }
        let signature = try JSONValue.array(sequence).serialize(pretty: false)
        let first = try !FamiliarLines.firstMet(["practice: " + signature], dataRoot: dataRoot).isEmpty
        var kept = false
        defer {
            TurnTraceBus.fireFromContext(kind: "practice.keep", payload: .object([
                "practice": .string(signature), "met": .string(first ? "first" : "again"), "kept": .bool(kept),
            ]))
        }
        guard !first else { return false }
        guard case .array(let abilities) = try AbilityStore(dataRoot: dataRoot).registry(kind: .part) else {
            throw TurnEngineError.turnPartFailed("The ability index did not return rows for practice.")
        }
        var hasAbility = false
        abilityRoutes: for ability in abilities {
            guard let row = ability.objectValue, row["status"] == .string("active") else { continue }
            let use = row["learned"]?.objectValue?["use"]?.objectValue
            let operations = use?["operations"]?.objectValue?.values.map { $0 } ?? []
            let learned = operations.compactMap { $0.objectValue?["scope"]?.objectValue?["calls"]?.arrayValue }
            let validated = (row["validation_evidence"]?.objectValue?["runs"]?.arrayValue ?? [])
                .compactMap { $0.objectValue?["calls"]?.arrayValue }
            for calls in learned + validated {
                let route = calls.map { call -> JSONValue in
                    guard let label = call.objectValue?["call"]?.stringValue else { return .null }
                    // Read/find labels carry their arguments; only the app
                    // door's identity belongs in a practice signature.
                    if label.hasPrefix("read ") || label.hasPrefix("find ") { return .array([.string("app")]) }
                    return .array([.string("app"), .string(label)])
                }
                // The practice omits reads; a recorded route may include them.
                // Match its hand work in order, including repeated action ids.
                var matched = 0
                for call in route where matched < sequence.count {
                    if call == sequence[matched] { matched += 1 }
                }
                if matched == sequence.count { hasAbility = true; break abilityRoutes }
            }
        }
        kept = !hasAbility
        return kept
    }

    /// What a turn took, in one plain line for her after-turn mind.
    nonisolated static func took(rounds: Int, tokens: Int?, seconds: Int, repeated: (call: String, count: Int)) -> String {
        let amount: String
        if let tokens {
            amount = tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
                : tokens >= 1_000 ? "\(tokens / 1_000)k" : "\(tokens)"
        } else { amount = "unavailable" }
        var line = "This took \(rounds) round\(rounds == 1 ? "" : "s")" + (tokens == nil ? ", token usage unavailable" : ", \(amount) tokens")
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
