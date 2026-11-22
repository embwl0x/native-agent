import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import ChatToolRuntime
import ChatTurnContracts
import Experiences
import ChatSessionWork
import ToolRegistry
import Foundation
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
// Blueprint: | `TurnStem+Effects.swift` | `SwiftNativeTurnEngine`: `drive` (the stem's loop: runs the agent's turn part's effects, hands it each event with each result's declared effect (and, for a round's one deed whose call asked for `then_say`, its standing words as `say`), logs at every host-call boundary; the agent's own `app` calls run once as their own dispatch round through the same door and gates, and a turn may act or end before any model call; the turn returns at `reply.end` and `after`, and nothing of the agent's runs after it); after each tool round the familiarity nerve meets the turn's landed hand-work action ids (or one call repeated 3+ rounds) through `FamiliarLines` (`practice: `), and on a later meeting puts `practice` on the round's last result once a turn (naming an active ability whose recorded route covers it, to run or repair), traced as `practice.keep`; a `provider_failure` event carries the failure's work state and whether repair is owed |

extension SwiftNativeTurnEngine {
    /// The agent's reply ends the turn: the stem returns at reply.end, and nothing of the agent's runs after it.
    func drive(_ stem: TurnStem) async throws -> TurnEngineResult? {
        while true {
            if Task.isCancelled || ChatCancelFlag.isRaised(stem.cancelFlagPath) {
                throw stem.stopCarryingPartial()
            }
            // A provider failure or outstanding card leaves completion incomplete; text-only routes must also say the card's copy.
            if stem.part.replied { return try await finishReply(stem) }
            guard let effect = try await stem.part.next() else { return nil }
            switch effect["effect"] {
            case .string("reply.stream"):
                if case .string(let text)? = effect["text"], !text.isEmpty {
                    if !stem.voice.liveInAuthoredReply { stem.voice.liveBreakOwed = true }
                    stem.voice.liveInAuthoredReply = true
                    await live(stem, text)
                    stem.voice.visibleText += text
                    stem.part.sent(text)
                }
                try await capture(stem, turn: stem.turn, work: stem.work)
                continue
            case .string("notebook"):
                // The turn program's notebook: the settings its weigh reads. The effect runs once; a replay matches it by identity.
                if case .object(let set)? = effect["set"], let root = remPinsDataRoot { try await AttentionNotebook.write(set, dataRoot: root) }
                try await capture(stem, turn: stem.turn, work: stem.work)
                continue
            case .string("app"):
                try await runAppEffects(stem, effect)
                continue
            case .string("model.call"):
                try await prepareModelCall(stem, effect)
            default:
                // Checkpoint reply-end bookkeeping like any effect.
                try await capture(stem, turn: stem.turn, work: stem.work)
                continue
            }
            try await modelRound(stem, effect)
        }
    }

    private func finishReply(_ stem: TurnStem) async throws -> TurnEngineResult {
        if let stopped = stem.turn.providerRecovery?.stopped {
            throw TurnEngineError.streamInterrupted(partial: stem.voice.visibleText, underlying: stopped)
        }
        await stem.wire.bookkeeping.value
        let reply = Self.joinedProse(stem.voice.retainedProse, stem.part.answered)
        let waiting = stem.turn.execution.map { $0.waitingInteraction != nil || $0.waitingForApproval } ?? false
        let completed = await finishReplyTurn(
            reply: waiting ? ChatTurnExecution.waitingReply(visible: reply, turn: stem.turn) : reply,
            ctx: stem.wire.ctx, dispatches: stem.tally.dispatches, startNs: stem.startNs,
            providerCallCount: stem.tally.providerCallCount,
            userMessage: stem.userMessage, sessionId: stem.sessionId, surface: stem.surface,
            workingCommentaryCharacters: stem.voice.workingCommentaryCharacters == 0 ? nil : stem.voice.workingCommentaryCharacters,
            completionState: stem.tally.providerFailurePending || waiting ? .incomplete : .completed,
            afterTurn: !stem.work.thinking && (stem.tally.providerFailurePending || stem.part.afterTurn),
            took: stem.tally.counters.toolRoundCount == 0 ? nil : Self.took(rounds: stem.tally.counters.providerRoundCount, tokens: stem.tally.spent.withLock { $0.total },
                seconds: Int((DispatchTime.now().uptimeNanoseconds &- stem.startNs) / 1_000_000_000), repeated: stem.tally.longest),
            turn: stem.turn, work: stem.work)
        return stem.observed(completed, reason: stem.tally.providerFailurePending
            ? .incomplete : completed.resolvedTerminalReason(dataRoot: remPinsDataRoot))
    }

    private func runAppEffects(_ stem: TurnStem, _ effect: [String: JSONValue]) async throws {
        await stem.wire.bookkeeping.value
        // One round runs either the calls this model round named or the agent's program's own calls, each exactly once.
        let authored = effect["index"] == nil
        var batch = [effect]
        while stem.part.nextIsApp(authored: authored), let more = try await stem.part.next() { batch.append(more) }
        let ran: (calls: [ParsedToolCall], indices: [Int?], raw: String, codec: TextMarkerCodec?, boundary: LLMToolBoundaryReason?)
        if authored {
            let calls = try batch.map { item -> ParsedToolCall in
                guard case .object(let call)? = item["call"], case .string(let id)? = call["id"],
                      case .object(let input)? = call["input"] else {
                    throw TurnEngineError.turnPartFailed("Its own app effect reached the stem without its identity and input.")
                }
                return ParsedToolCall(id: id, name: "app", input: input)
            }
            ran = (calls, [Int?](repeating: nil, count: calls.count), "", nil, nil)
        } else {
            guard let round = stem.tally.round else { throw TurnEngineError.turnPartFailed("Its app effects came with no model round to run.") }
            let indices = try batch.map { item -> Int in
                guard case .int(let at)? = item["index"], let index = Int(exactly: at), round.calls.indices.contains(index) else {
                    throw TurnEngineError.turnPartFailed("Its app effect names a call outside the current model round.")
                }
                return index
            }
            ran = (indices.map { round.calls[$0] }, indices, round.raw, round.codec, round.boundary)
        }
        let providerCalls = ran.calls
        stem.tally.counters.toolRoundCount += 1
        try await capture(stem, startingCalls: providerCalls.count,turn: stem.turn,work: stem.work)
        let roundStart = stem.tally.dispatches.count
        try await runToolDispatchRound(
            providerCalls: providerCalls,
            iterationRawText: ran.raw,
            ctx: stem.wire.ctx, surface: stem.surface, sessionId: stem.toolSessionId ?? stem.sessionId,
            arrivalSessionId: stem.sessionId,
            tools: stem.tools, progress: stem.progress, conversation: &stem.wire.conversation,
            dispatches: &stem.tally.dispatches, providerTools: stem.wire.providerTools,
            cancelFlagPath: stem.cancelFlagPath,
            markerCodec: ran.codec, toolBoundaryReason: ran.boundary, turn: stem.turn, work: stem.work)
        stem.tally.previousRoundFailed = stem.tally.dispatches.dropFirst(roundStart).contains {
            ToolLoopTraceObservation.isFailedAttempt($0.result)
        }
        if let reminded = await cameToMind(after: stem.tally.dispatches.dropFirst(roundStart),
                                           preparedTurn: stem.wire.resolvedTurnContext.fluidContextTurn, turn: stem.turn, held: &stem.owed.cameToMindHeld,
                                           owed: &stem.owed.familiarOwed,
                                           sessionId: stem.sessionId, surface: stem.surface) {
            Self.appendStructuredUserNudge(reminded, to: &stem.wire.conversation)
        }
        try stem.partRounds.endRound()
        if Task.isCancelled || ChatCancelFlag.isRaised(stem.cancelFlagPath) { throw stem.stopCarryingPartial() }
        // The practice signal rides this round's last result, so the agent's next thought in this turn carries it.
        var practice: JSONValue?
        if !stem.tally.practiceNoted {
            practice = Self.practiceSignal(stem.tally.dispatches, repeated: stem.tally.repeated, checked: &stem.tally.practiceChecked,
                dataRoot: remPinsDataRoot ?? defaultDataRoot(), turn: stem.turn)
            stem.tally.practiceNoted = practice != nil
        }
        // Keep call order and run every non-ignorable call; a waiting receipt reaches the part while its card continues gating the effect.
        var records = stem.tally.dispatches.dropFirst(roundStart).makeIterator()
        try await stem.part.deliver(zip(ran.calls, ran.indices).enumerated().map { item -> JSONValue in
            let (call, index) = item.element
            let record = ToolCallParser.isIgnorableToolName(call.name) ? nil : records.next()
            let reply = record.map { ToolResult($0.result) }
            var event: [String: JSONValue] = ["type": .string("result"), "id": .string(call.id),
                "name": .string(call.name), "ok": .bool(reply.map {
                    ChatToolOutcome.outputLooksSuccessful($0.payload, verdict: $0.outcome)
                } ?? false)]
            event["index"] = index.map { JSONValue.int(Int64($0)) }
            event["waiting"] = record.flatMap { Self.waitingOn($0.result) }
            event["effect"] = record.flatMap { Self.landedEffect($0.result) }.map(JSONValue.string)
            if item.offset == ran.calls.count - 1 { event["practice"] = practice }
            // A deed alone in its round, whose own call asked for closing words, carries them when they stand; an answer cannot supply them.
            if ran.calls.count == 1, ToolNameAliases.canonical(call.name) == "app", case .string? = call.input["then_say"],
               call.input["actions"]?.arrayValue != nil || (!JSONValue.trimmedScalarTextOrEmpty(call.input["action"]).isEmpty && (call.input["expect"] ?? .null) != .null),
               case .object(let said)? = reply?.payload.objectValue?["then_say"], said["stands"] == .bool(true),
               case .string(let words)? = said["words"] {
                event["say"] = .string(words)
            }
            return .object(event)
        })
    }

    private func prepareModelCall(_ stem: TurnStem, _ effect: [String: JSONValue]) async throws {
        if let system = stem.part.system, system != stem.wire.composed.system || stem.part.offeredTools != stem.wire.composed.tools {
            let late = stem.wire.composed.system == nil
            // Preserve write order: the opening seed cannot overwrite
            // the healed seed after its request has been prepared.
            await stem.wire.bookkeeping.value
            let additional = try ConversationPrefixSeeding.additionalMessages(in: stem.wire.conversation, after: stem.wire.prefixSeed)
            stem.wire.resolvedTurnContext.toolSchemas = stem.gathered.toolSchemas
            stem.wire.resolvedTurnContext = stem.wire.resolvedTurnContext.composing(system, tools: stem.part.offeredTools)
            try stem.wire.reseed(keeping: additional, recording: true, turn: stem.turn,
                codec: stem.toolCallCodec, prefixSink: stem.prefixSink, surface: stem.surface, sessionId: stem.sessionId,
                runId: stem.runId, replacementUserMessageID: stem.replacementUserMessageID, dataRoot: stem.dataRoot)
            stem.wire.composed = (.some(system), stem.part.offeredTools)
            // A system that arrives after the agent's first acts owes its context delivery as an opening one would.
            if late {
                stem.owed.commitInstructionDelivery = try pendingInstructionDelivery(in: stem.wire.resolvedTurnContext, sessionID: stem.sessionId)
                stem.owed.commitPartsDelivery = stem.wire.resolvedTurnContext.partsDelivery
            }
        }
        if stem.toolCallCodec == .textMarkers, stem.wire.wireSystem.segments == nil {
            throw ProviderRoutingError.configurationFailed(
                "The text-marker request requires coherent system segments; its offered tool contract was not assembled.")
        }
        if case .string(let note)? = effect["note"], !note.isEmpty { Self.appendStructuredUserNudge(note, to: &stem.wire.conversation) }
    }

    func live(_ stem: TurnStem, _ text: String) async {
        guard !text.isEmpty else { return }
        if stem.voice.liveBreakOwed, let last = stem.voice.liveLast, !last.isNewline, text.first?.isNewline == false { await stem.progress?(.delta("\n\n")) }
        stem.voice.liveBreakOwed = false
        stem.voice.liveLast = text.last
        await stem.progress?(.delta(text))
    }

    /// Persistence and eligibility stay with steering; the turn log retains each reading for relaunch.
    func readArrivals(_ stem: TurnStem, keeping prose: String = "") async throws -> Bool {
        guard let sessionId = stem.sessionId, !sessionId.isEmpty else { return false }
        let offers = try await ChatTurnSteering.shared.drain(sessionId: sessionId, cancelFlagPath: stem.cancelFlagPath)
        if Task.isCancelled || ChatCancelFlag.isRaised(stem.cancelFlagPath) { throw stem.stopCarryingPartial() }
        stem.owed.steeringOffers += offers
        if !offers.isEmpty, !prose.isEmpty { stem.wire.conversation.append(.assistantText(prose)) }
        for offer in offers {
            try stem.part.readArrival(offer)
            ConversationPrefixSeeding.appendUser(offer.reading, to: &stem.wire.conversation)
        }
        return !offers.isEmpty
    }

    /// The stem applies or records observations; the agent's part decides how to go on.
    func observe(_ stem: TurnStem, _ kind: TurnObservation.Kind, kept: String = "", unstarted: [ParsedToolCall] = []) async throws {
        TurnObservation.apply(kind, kept: kept, to: &stem.wire.conversation, surface: stem.surface, turn: stem.turn)
        var text = TurnObservation.text(kind)
        if !unstarted.isEmpty {
            let note = "These proposed calls did not start: " + unstarted.map { $0.name + " (" + $0.id + ")" }.joined(separator: ", ")
                + ". Read the person's message before deciding what to do next."
            Self.appendStructuredUserNudge(note, to: &stem.wire.conversation)
            text += " " + note
            TurnTraceBus.fireFromContext(kind: "turn.proposalSkipped", surface: stem.surface, payload: .object([
                "reason": .string("person_arrival"), "calls": .array(unstarted.map {
                    .object(["id": .string($0.id), "name": .string($0.name)])
                }), "effects": .string("none"),
            ]), turn: stem.turn)
        }
        try await stem.part.deliver([.object(["type": .string("observation"), "text": .string(text)])])
    }

    /// Every effect boundary checkpoints the turn with its log.
    func capture(_ stem: TurnStem, startingCalls: Int = 0,turn: Turn,work: ChatTurnWork) async throws {
        await work.checkpoint?.capture(
            prose: stem.voice.retainedProse,
            commentaryCharacters: stem.voice.workingCommentaryCharacters, log: stem.part.log,
            startingCalls: startingCalls, turn: turn)
        if !stem.owed.steeringOffers.isEmpty || !stem.owed.replayedArrivals.isEmpty {
            guard work.checkpoint != nil, let root = remPinsDataRoot, let sessionId = stem.sessionId,
                  let saved = try TurnCheckpoint.read(dataRoot: root, sessionId: sessionId, turnId: turn.id),
                  saved.log == stem.part.log, saved.keptProse == stem.voice.retainedProse else {
                throw ChatOrchestrationError.underlying(
                    "Joined arrivals were not checkpointed; their doors retain them. Repair the turn checkpoint before continuing.")
            }
            // The reading is durably owned by this checkpoint; another launch must not resume it through its old checkpoint too.
            for (run, id) in try stem.part.arrivalIDs() {
                if let arrival = try TurnCheckpoint.read(dataRoot: root, sessionId: sessionId, turnId: id) {
                    guard arrival.runId == run else {
                        throw ChatOrchestrationError.underlying("The arrival checkpoint changed identity; repair its ownership before continuing.")
                    }
                    try arrival.remove(dataRoot: root)
                }
            }
        }
    }

    /// Provider output marks the round emitted, preventing a repeated request.
    func providerFailed(_ stem: TurnStem, _ error: Error, emitted: Bool, turn: Turn) async throws {
        stem.tally.providerFailurePending = true
        let id = "provider-reply:" + UUID().uuidString
        let provider = stem.wire.ctx.providerId ?? turn.admission?.provider ?? "unresolved"
        let failure = ProviderFailure.repair(error, provider: provider, model: stem.wire.ctx.modelId, surface: stem.surface,
            dataRoot: remPinsDataRoot ?? defaultDataRoot(), id: id, call: stem.call.with(\.turn, turn))
        let next = failure.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        var calls: [ParsedToolCall] = []
        if case .object(let call)? = next, case .string(let tool)? = call["tool"], case .object(let input)? = call["input"] {
            calls = [ParsedToolCall(id: id, name: tool, input: input)]
        }
        stem.tally.round = (calls, "", nil, nil)
        let reply = ToolResult(ChatToolOutcome.failure(error: failure))
        let remedy = reply.remedy ?? .null
        await stem.progress?(.notice(kind: "provider_failure", text: failure.message))
        do {
            try await stem.part.deliver([.object(["type": .string("provider_failure"), "provider": .string(provider),
                "model": .string(stem.wire.ctx.modelId), "text": .string(failure.message), "remedy": remedy,
                "work": .string(emitted || ProviderFailure.report(error)?.work == .ranPartly
                    ? ProviderFailure.WorkState.ranPartly.rawValue : ChatTurnFailure.work(for: error)),
                "owed": .bool(failure.owner != nil && !failure.personDecides),
                "calls": .array(calls.map { .object(["id": .string($0.id), "name": .string($0.name), "input": .object($0.input)]) })])])
        } catch { throw TurnEngineError.streamInterrupted(partial: stem.voice.visibleText, underlying: failure) }
    }

    /// A spent per-run output budget is the person's cap: the agent's part reads its
    /// receipt and ends; no further model call can run under it.
    func budgetSpent(_ stem: TurnStem, emitted: Bool, turn: Turn) async throws {
        let bot = turn.standingBot
        try await providerFailed(stem, ProviderFailure.Diagnostic(cause: .outputLimit, detail: "per-run output token limit spent",
            repair: ToolFailureError(
                """
                    This run's output token limit\(bot.map { " (\($0.budget.tokens) tokens)" } ?? "") is spent; what was written stays and no \
                    further model call runs in this run.
                    """,
                effects: .none, owner: bot.map { "helper \($0.name)'s budget" } ?? "this run's caller",
                tap: bot.map { "Helpers → \($0.name) → Edit → Output tokens per run" }, personDecides: true)),
            emitted: emitted, turn: turn)
    }
}
