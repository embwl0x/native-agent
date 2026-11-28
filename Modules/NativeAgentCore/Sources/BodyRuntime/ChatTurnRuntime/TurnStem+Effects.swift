import SenseCore
import MacNerves
import MindCore
import DeskCore
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Synchronization
import NativeAgentShared
// Blueprint: | `TurnStem+Effects.swift` | `SwiftNativeTurnEngine`: `drive` (the stem's loop: runs the agent's turn part's effects, hands it each event with each result's declared effect (and, for a round's one deed whose call asked for `then_say`, its standing words as `say`), logs at every host-call boundary; the agent's own `app` calls run once as their own dispatch round through the same door and gates, and a turn may act or end before any model call; the turn returns at `reply.end` and `after`, and nothing of the agent's runs after it); after each tool round the familiarity nerve meets the turn's landed hand-work action ids (or one call repeated 3+ rounds) through `FamiliarLines` (`practice: `), and on a later meeting puts `practice` on the round's last result once a turn, traced as `practice.keep`; a `provider_failure` event carries the failure's work state and whether repair is owed |

extension SwiftNativeTurnEngine {
    /// The agent's reply ends the turn: the stem returns at reply.end, and nothing of the agent's runs after it.
    func drive(_ stem: TurnStem) async throws -> TurnEngineResult? {
        while true {
            if Task.isCancelled || ChatCancelFlag.isRaised(stem.cancelFlagPath) {
                throw stem.stopCarryingPartial()
            }
            // A provider failure or outstanding card leaves completion incomplete; text-only routes must also say the card's copy.
            if stem.part.replied { return try await finishReply(stem) }
            guard let (effect, event) = try await stem.part.next(turn: stem.turn) else { return nil }
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
                if effect["effect"] == .string("reply.end"), let close = event["close"]?.objectValue,
                   close["quiet"] == .bool(true), let subject = close["class"] {
                    TurnTraceBus.fireFromContext(kind: "turn.quietClose", surface: stem.surface,
                        payload: .object(["class": subject, "reason": .string("close record stands")]), turn: stem.turn)
                }
                try await capture(stem, turn: stem.turn, work: stem.work)
                continue
            }
            let subject = effect["purpose"] == .string("tool_round") ? event["close"]?.objectValue?["class"]?.stringValue : nil
            try await modelRound(stem, effect, closeClass: subject)
        }
    }

    private func finishReply(_ stem: TurnStem) async throws -> TurnEngineResult {
        if let stopped = stem.turn.providerRecovery?.stopped {
            throw TurnEngineError.streamInterrupted(partial: stem.voice.visibleText, underlying: stopped)
        }
        await stem.wire.bookkeeping.value
        if stem.tally.providerCallCount == 0 { try await commitDelivery(stem) }
        let reply = Self.joinedProse(stem.voice.retainedProse, stem.part.answered)
        let waiting = stem.turn.execution.map { $0.waitingInteraction != nil || $0.waitingForApproval } ?? false
        let after = !stem.work.thinking && (stem.tally.providerFailurePending || stem.part.afterTurn)
        let quietClass = after || stem.work.thinking ? nil : stem.part.quietReflection
        if after || quietClass != nil {
            await queueStoppedRuns(dispatches: stem.tally.dispatches, surface: stem.surface, turn: stem.turn)
        }
        let replyContext: TurnContext
        if !stem.wire.cortexPrepared, let reading = stem.part.context.reading {
            replyContext = try reading.get().context
        } else {
            replyContext = stem.wire.ctx
        }
        let completed = await finishReplyTurn(
            reply: waiting ? ChatTurnExecution.waitingReply(visible: reply, turn: stem.turn) : reply,
            ctx: replyContext, dispatches: stem.tally.dispatches, startNs: stem.startNs,
            providerCallCount: stem.tally.providerCallCount,
            userMessage: stem.userMessage, sessionId: stem.sessionId, surface: stem.surface,
            workingCommentaryCharacters: stem.voice.workingCommentaryCharacters == 0 ? nil : stem.voice.workingCommentaryCharacters,
            completionState: stem.tally.providerFailurePending || waiting ? .incomplete : .completed,
            afterTurn: after,
            took: stem.tally.counters.toolRoundCount == 0 ? nil : Self.took(rounds: stem.tally.counters.providerRoundCount, tokens: stem.tally.spent.withLock { $0.total },
                seconds: Int((DispatchTime.now().uptimeNanoseconds &- stem.startNs) / 1_000_000_000), repeated: stem.tally.longest),
            turn: stem.turn, work: stem.work)
        var result = stem.observed(completed, reason: stem.tally.providerFailurePending
            ? .incomplete : completed.resolvedTerminalReason(dataRoot: remPinsDataRoot))
        if result.terminalReason == .replyCompleted { result.quietReflection = quietClass }
        return result
    }

    func reflectionReading(_ stem: TurnStem, closing words: String) async -> JSONValue? {
        let turn = stem.turn
        let reply = Self.joinedProse(stem.voice.retainedProse, stem.part.answered + words)
        let execution = turn.execution
        let interrupted = stem.part.log.contains { row in
            let event = row.objectValue?["event"]?.objectValue
            return row.objectValue?["arrival"] != nil || event?["type"] == .string("observation")
                || event?["type"] == .string("provider_failure") || event?["ok"] == .bool(false)
        }
        // A thought woken by evidence crossing one of her stances may be a change of mind: never routine.
        let crossedWake = turn.attended?.objectValue?["happenings"]?.arrayValue?.contains { happening in
            if let crossed = happening.objectValue?["crossed"], crossed != .null { return true }
            return false
        } == true
        // A moment that acted is never routine: what its acts did is the reflection's to judge.
        let routine = !stem.work.thinking && !crossedWake && stem.tally.dispatches.isEmpty && execution?.hasFiledPromise == false && execution?.waitingForApproval == false
            && execution?.waitingInteraction == nil && !stem.tally.providerFailurePending && turn.resumingCheckpoint == nil
            && stem.tally.counters.failedProviderAttemptCount == 0 && !interrupted && turn.peerSteering?.checkpointSources.isEmpty != false
        return await memoryPromoter?.reflectionReading(user: stem.userMessage, reply: reply, session: stem.sessionId,
            surface: stem.surface, standingAgent: turn.standingBot?.name, turn: turn, routine: routine)
    }

    private func runAppEffects(_ stem: TurnStem, _ effect: [String: JSONValue]) async throws {
        await stem.wire.bookkeeping.value
        // One round runs either the calls this model round named or the agent's program's own calls, each exactly once.
        let authored = effect["index"] == nil
        var batch = [effect]
        while stem.part.nextIsApp(authored: authored), let more = try await stem.part.next(turn: stem.turn) { batch.append(more.effect) }
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
        if authored && !stem.wire.cortexPrepared {
            let gathered = try await stem.dispatchContext()
            let context = stem.part.system.map { gathered.composing($0, tools: stem.part.offeredTools) } ?? gathered
            stem.wire.ctx = context
            stem.wire.resolvedTurnContext = context
            stem.wire.providerTools = ProviderToolNameMap(context.toolSchemas)
        }
        let providerCalls = ran.calls
        stem.tally.counters.toolRoundCount += 1
        try await capture(stem, startingCalls: providerCalls.count,turn: stem.turn,work: stem.work)
        let roundStart = stem.tally.dispatches.count
        let deliveredCleanly = try await runToolDispatchRound(
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
        let round = stem.tally.dispatches.dropFirst(roundStart)
        var records = round.makeIterator()
        let execution = stem.turn.execution
        let canEnd = stem.voice.spoken && deliveredCleanly && round.count == ran.calls.count
            && ran.calls.allSatisfy { ($0.input["then_say"] ?? .null) == .null }
            && ran.boundary == nil && !stem.tally.providerFailurePending
            && execution?.waitingForApproval != true && execution?.waitingInteraction == nil
            && ChatGeneratedImageArtifacts.attachments(from: stem.tally.dispatches, chosen: stem.turn.replyChoices?.paths ?? [],
                                                       dataRoot: stem.part.dataRoot).isEmpty
        let subject = canEnd ? closingClass(round, stem: stem) : nil
        var events = zip(ran.calls, ran.indices).enumerated().map { item -> JSONValue in
            let (call, index) = item.element
            let record = ToolCallParser.isIgnorableToolName(call.name) ? nil : records.next()
            let reply = record.map { ToolResult($0.result) }
            var event: [String: JSONValue] = ["type": .string("result"), "id": .string(call.id),
                "name": .string(call.name), "ok": .bool(reply.map {
                    ChatToolOutcome.outputLooksSuccessful($0.payload, verdict: $0.outcome)
                } ?? false)]
            event["spoken"] = .bool(stem.voice.spoken)
            event["clean"] = .bool(subject != nil)
            event["index"] = index.map { JSONValue.int(Int64($0)) }
            event["waiting"] = record.flatMap { Self.waitingOn($0.result) }
            event["effect"] = record.flatMap { Self.landedEffect($0.result) }.map(JSONValue.string)
            if item.offset == ran.calls.count - 1 { event["practice"] = practice }
            // A deed alone in its round, whose own call asked for closing words, carries them when they stand; an answer cannot supply them.
            if ran.calls.count == 1, ToolNameAliases.canonical(call.name) == "app", case .string? = call.input["then_say"],
               call.input["actions"]?.arrayValue != nil || (!JSONValue.trimmedScalarTextOrEmpty(call.input["action"]).isEmpty && call.input["expect"] != nil),
               case .object(let said)? = reply?.payload.objectValue?["then_say"], said["stands"] == .bool(true),
               case .string(let words)? = said["words"] {
                event["say"] = .string(words)
            }
            return .object(event)
        }
        if let last = events.indices.last, case .object(var event) = events[last] {
            if case .string(let words)? = event["say"] {
                event["reflect"] = await reflectionReading(stem, closing: words)
            }
            if let root = stem.dataRoot, let subject {
                do {
                    event["close"] = try await AdaptiveMemoryPromoter.emptyRoundReading(dataRoot: root, kind: "close",
                        subject: subject, cMiss: 2, maySkip: true)
                } catch {
                    nativeLog("Turn: close record unavailable for %@: %@", subject, error.localizedDescription)
                }
            }
            if !stem.owed.replayedArrivals.isEmpty || !stem.owed.steeringOffers.isEmpty
                || stem.sessionId.map(ChatTurnSteering.hasPersonWaiting) == true {
                event["clean"] = .bool(false)
                event["close"] = nil
            }
            events[last] = .object(event)
        }
        try await stem.part.deliver(events, turn: stem.turn)
    }

    private func closingClass(_ round: ArraySlice<ToolDispatchRecord>, stem: TurnStem) -> String? {
        var actions = Set<String>()
        for record in round {
            let input = ToolNameAliases.doorCall(record.name, record.input)
            let action = record.name == "app" ? input["action"]?.stringValue : ToolNameAliases.appAction(record.name, input: input)
            guard let id = action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let binding = try? AppActionBinding.binding(id, turn: stem.turn),
                  binding.toolClass == .write, binding.reach == .agent, !binding.irreversible, !binding.voice,
                  // A folded action is judged by its host tool's own declaration here (shell reaches the person), without changing what Trust reads.
                  !binding.folded || AppActionBinding.declaredSchema(binding.tool).map({ ($0.toolClass ?? .write) == .write && $0.reach == .agent }) == true,
                  !binding.readOnly(args: input["args"]?.objectValue ?? input),
                  input["preview"] != .bool(true),
                  !ToolNameAliases.appDeedKeys.contains(where: { (input[$0] ?? .null) != .null }),
                  !Self.receiptContains(record.result, where: Self.requiresReadback) else { return nil }
            actions.insert(id)
        }
        guard !actions.isEmpty, !stem.tally.dispatches.contains(where: Self.mayHaveFiledForPerson),
              stem.turn.execution?.toolRecords.contains(where: Self.mayHaveFiledForPerson) != true else { return nil }
        return actions.sorted().joined(separator: "+")
    }

    private static func requiresReadback(_ value: JSONValue) -> Bool {
        let reply = ToolResult(value)
        guard reply.outcome == .succeeded, !reply.isOpen, !ChatToolOutcome.neverRan(value),
              !ChatToolOutcome.effectsUnknown(value), reply.effects != .partial else { return true }
        guard let fields = value.objectValue else { return false }
        return (fields["effects"] != nil && reply.effects == nil) || fields["needs_me"] != nil
            || fields["handed_back"] != nil || fields["continuation"]?.stringValue != nil || fields["then_say"] != nil
            || fields["attachments"]?.arrayValue?.isEmpty == false || fields["partial"] == .bool(true)
            || fields["read_only"] == .bool(true) || fields["irreversible"] == .bool(true)
    }

    private static func mayHaveFiledForPerson(_ record: ToolDispatchRecord) -> Bool {
        receiptContains(record.result) { value in
            guard let fields = value.objectValue else { return false }
            if let raised = fields["side_effects"]?.objectValue?["notes_raised"], raised != .array([]) { return true }
            return ChatToolOutcome.isWaitingOnPerson(value) || InlineInteractionNeed.isWaiting(value)
                || fields["card_id"]?.stringValue != nil || fields["permission_card"]?.objectValue?["status"] == .string("up")
                || fields["needCards"]?.arrayValue?.contains { $0.objectValue?["status"] == .string("filed") } == true
                || fields["full_result_in_transcript"] == .bool(false)
                || (fields["status"] == .string("unknown") && fields["effects"] == .string("unknown"))
        }
    }

    private static func receiptContains(_ value: JSONValue, where matches: (JSONValue) -> Bool) -> Bool {
        if matches(value) { return true }
        guard let fields = value.objectValue else { return false }
        for key in ["result", "returned", "stopped", "next_result"] {
            if let child = fields[key], child.objectValue != nil, receiptContains(child, where: matches) { return true }
        }
        for key in ["receipts", "calls"] {
            if let rows = fields[key]?.arrayValue, rows.contains(where: { receiptContains($0, where: matches) }) { return true }
        }
        return false
    }

    private func prepareModelCall(_ stem: TurnStem, _ effect: [String: JSONValue]) async throws {
        if let system = stem.part.system, !stem.wire.cortexPrepared || system != stem.wire.composed.system || stem.part.offeredTools != stem.wire.composed.tools {
            let first = !stem.wire.cortexPrepared
            await stem.wire.bookkeeping.value
            let gathered = try await stem.dispatchContext()
            let additional: [LLMMessage]
            if first {
                additional = stem.wire.conversation
                stem.wire.resolvedTurnContext = gathered
                stem.owed.agentNow = gathered.agentNow
                stem.owed.breathActs = gathered.recentLifeActs
            } else {
                additional = try ConversationPrefixSeeding.additionalMessages(in: stem.wire.conversation, after: stem.wire.prefixSeed)
            }
            stem.wire.resolvedTurnContext.toolSchemas = gathered.toolSchemas
            stem.wire.resolvedTurnContext = stem.wire.resolvedTurnContext.composing(system, tools: stem.part.offeredTools)
            if first { Self.fireContextReady(surface: stem.surface, context: stem.wire.resolvedTurnContext, sessionId: stem.sessionId, turn: stem.turn) }
            try stem.wire.reseed(keeping: additional, afterToolRound: stem.tally.counters.toolRoundCount > 0, turn: stem.turn,
                codec: stem.toolCallCodec, prefixSink: stem.prefixSink, surface: stem.surface, sessionId: stem.sessionId,
                runId: stem.runId, replacementUserMessageID: stem.replacementUserMessageID, dataRoot: stem.dataRoot)
            stem.wire.composed = (.some(system), stem.part.offeredTools)
            // A system that arrives after the agent's first acts owes its context delivery as an opening one would.
            if first || stem.owed.contextDeliveryOwed {
                stem.owed.commitInstructionDelivery = try pendingInstructionDelivery(in: stem.wire.resolvedTurnContext, sessionID: stem.sessionId,
                                                                                    openingBody: stem.part.openingBody)
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
        if stem.progress != nil, stem.turn.originPrincipal == "person", text.contains(where: { !$0.isWhitespace }) {
            stem.voice.spoken = true
        }
    }

    /// Persistence and eligibility stay with steering; the turn log retains each reading for relaunch.
    func readArrivals(_ stem: TurnStem, keeping prose: String = "") async throws -> [ChatTurnSteering.Offer] {
        guard let sessionId = stem.sessionId, !sessionId.isEmpty else { return [] }
        let offers = try await ChatTurnSteering.shared.drain(sessionId: sessionId, cancelFlagPath: stem.cancelFlagPath)
        if Task.isCancelled || ChatCancelFlag.isRaised(stem.cancelFlagPath) { throw stem.stopCarryingPartial() }
        if !offers.isEmpty { stem.voice.spoken = false }
        stem.owed.steeringOffers += offers
        if !offers.isEmpty { stem.wire.keep(prose: prose) }
        for offer in offers {
            try stem.part.readArrival(offer)
            ConversationPrefixSeeding.appendUser(offer.reading, to: &stem.wire.conversation)
        }
        return offers
    }

    /// The stem applies or records observations; the agent's part decides how to go on.
    func observe(_ stem: TurnStem, _ kind: TurnObservation.Kind, kept: String = "",
                 unstarted: (calls: [ParsedToolCall], arrival: ChatTurnSteering.WaitingArrival)? = nil) async throws {
        TurnObservation.apply(kind, kept: kept, to: &stem.wire.conversation, surface: stem.surface, turn: stem.turn)
        var text = TurnObservation.text(kind)
        if let unstarted, !unstarted.calls.isEmpty {
            let note = "These proposed calls did not start: " + unstarted.calls.map { $0.name + " (" + $0.id + ")" }.joined(separator: ", ")
                + ". Read the \(unstarted.arrival.subject) before deciding what to do next."
            Self.appendStructuredUserNudge(note, to: &stem.wire.conversation)
            text += " " + note
            TurnTraceBus.fireFromContext(kind: "turn.proposalSkipped", surface: stem.surface, payload: .object([
                "reason": .string("person_arrival"), "calls": .array(unstarted.calls.map {
                    .object(["id": .string($0.id), "name": .string($0.name)])
                }), "effects": .string("none"),
            ]), turn: stem.turn)
            if stem.surface == "chat" {
                for call in unstarted.calls {
                    await stem.progress?(.unstartedStep(id: call.id, name: ToolNameAliases.shown(call.name, input: .object(call.input)).name,
                        disposition: .withdrawnBeforeStart))
                }
            }
        }
        try await stem.part.deliver([.object(["type": .string("observation"), "text": .string(text)])], turn: stem.turn)
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
                "calls": .array(calls.map { .object(["id": .string($0.id), "name": .string($0.name), "input": .object($0.input)]) })])], turn: turn)
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
