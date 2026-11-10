import AuthoredCapabilities
import AgentWorkspace
import ChatToolParsing
import ChatToolRuntime
import ChatTurnContracts
import Experiences
import ChatSessionWork
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
// Blueprint: | `ChatOrchestration+StreamingToolLoop.swift` | `SwiftNativeTurnEngine`: `executeContinuationTurnBody` (the stem's loop: delivers the message's facts (text, door, who, verified id, trust, steering, posture), runs the agent's turn part's effects, hands it each event with each result's declared effect (and, for a round's one deed whose call asked for `then_say`, its standing words as `say`), logs at every host-call boundary; the agent's own `app` calls run once as their own dispatch round through the same door and gates, and a turn may act or end before any model call; the turn returns at `reply.end` and `after`, and nothing of the agent's runs after it); before a fresh message’s opening model call, mind/authority practice may supply one gated standing read as `already_looked`; after each tool round the familiarity nerve meets the turn's landed hand-work action ids (or one call repeated 3+ rounds) through `FamiliarLines` (`practice: `), and on a later meeting no active ability's recorded route covers it puts `practice` on the round's last result once a turn, traced as `practice.keep`; `joinedProse`; `provider.roundOutput` counts safe prose and tool calls per parsed round; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams; a `provider_failure` event carries the failure's work state and whether repair is owed; the person's turn is measured as it goes (model rounds, its own calls' tokens, minutes, the longest stretch of one round's calls repeated for `took`): `took` is the after-turn line, and each part called records its rounds |

extension SwiftNativeTurnEngine {
    func executeContinuationTurnBody(
        surface: String = "chat",
        userMessage: String,
        sessionId: String? = nil,
        /// Request-scoped identity keeps ephemeral turns distinct without inventing a transcript session.
        toolSessionId: String? = nil,
        runId: String? = nil,
        llm: any LLMClient,
        tools: any ExpansionToolDispatchClient,
        preBuiltContext: TurnContext,
        progress: ToolProgress? = nil,
        onDelivery: (@Sendable () async -> Void)? = nil,
        cancelFlagPath: URL? = nil,
        /// Asked before every provider call, retries included. Admission errors
        /// stay with their owner; provider recovery cannot override them.
        providerAdmission: (@Sendable () async throws -> Void)? = nil,
        turn: Turn, work: ChatTurnWork, call: LLMCall
    ) async throws -> TurnEngineResult {
        let partRounds = AbilityRounds()
        return try await holding(turn.with(\.userText, userMessage).with(\.abilityRounds, partRounds)) { turn in
        try await holding(work.with(\.senseReads, work.senseReads ?? SenseTurnReads())) { work in
        // Prepared document text and image-only turns need no caption.
        if preBuiltContext.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && preBuiltContext.imageBlocks.isEmpty {
            throw TurnEngineError.emptyMessage
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: toolSessionId ?? sessionId,
            turnId: turn.id
        )
        let turn = turn.with(\.resultRecoveryScope, recoveryScope)
        var cleanFinish = false
        defer {
            if cleanFinish || Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath), let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        let startNs = DispatchTime.now().uptimeNanoseconds
        var dispatchTrace = ContextStageTrace(turn: turn)
        let gathered = preBuiltContext
        // The turn part decides; this loop executes effects. Recovery rebuilds the log and reports in-flight effects as resumed.
        let restarted = turn.resumingCheckpoint.flatMap {
            $0.runId == runId && $0.turnId == turn.id ? $0 : nil
        }
        var part = try await TurnPart(dataRoot: remPinsDataRoot ?? defaultDataRoot(), surface: surface, stop: cancelFlagPath,
                                      context: gathered, log: restarted?.log ?? [], turn: turn, deadlines: work.deadlines)
        defer { part.tellAgent() }
        var inFlight = false
        if part.log.isEmpty {
            // The moment's facts, read-only: the words, who sent them, the door, and the posture over the person's world.
            let posture: String
            do {
                let policy = try await SwiftNativeTrustCenter(dataRoot: remPinsDataRoot ?? defaultDataRoot()).loadTrustPolicyChecked()
                switch PermissionLaw.posture(policy) {
                case .fullMac: posture = "full_mac"
                case .work: posture = "work"
                case .readOnly: posture = "safe"
                }
            } catch { posture = "unreadable: " + error.localizedDescription }
            var message: [String: JSONValue] = [
                "type": .string("message"), "text": .string(gathered.userMessage), "surface": .string(surface),
                "door": .string(turn.arrivalSurface(authorizing: surface)),
                "attachments": .array(gathered.imageBlocks.compactMap {
                    if case .image(_, _, let name, _) = $0 { .string(name ?? "image") } else { nil }
                }),
                "who": .string(turn.originPrincipal),
                "verified": turn.envelope?.verifiedUserId.map(JSONValue.string) ?? .null,
                "trust": .string(turn.peerSteering?.isTainted == true ? "untrusted" : "trusted"),
                "steered_by": .array((turn.peerSteering?.checkpointSources ?? []).map(JSONValue.string)),
                "posture": .string(posture),
            ]
            // A thought of the agent's carries what it attends.
            if let attended = turn.attended { message["attended"] = attended }
            try await part.deliver([.object(message)])
        } else {
            inFlight = try await part.resume()
        }
        // The native opening owns whether this is a thought, including on checkpoint replay.
        let opening = part.log.first?.objectValue?["event"]?.objectValue
        let call = call.with(\.allowsSilentCompletion, call.allowsSilentCompletion
            || (opening?["type"] == .string("message") && opening?["attended"]?.objectValue != nil))
        try Task.checkCancellation()
        // The agent's program may act or end before it ever draws power; the agent's system arrives with its first model.call.
        var resolvedTurnContext = part.system.map { gathered.composing($0, tools: part.offeredTools) } ?? gathered
        dispatchTrace.record(.turnPart, since: startNs)
        Self.fireContextReady(surface: surface, context: resolvedTurnContext, sessionId: sessionId, turn: turn)
        var commitInstructionDelivery = try pendingInstructionDelivery(in: resolvedTurnContext, sessionID: sessionId)
        // Steered messages reach the queue owner as delivered at the same
        // moment instructions do: the round carrying them produced output.
        var steeringOffers: [ChatTurnSteering.Offer] = []
        var replayedArrivals: Set<String> = []
        if restarted != nil, let sessionId {
            replayedArrivals = Set(try part.arrivalIDs().keys)
            await ChatTurnSteering.shared.restoreReadings(replayedArrivals, sessionId: sessionId)
        }
        var agentNow = resolvedTurnContext.agentNow
        var lastBreath: String?
        var breathActs = resolvedTurnContext.recentLifeActs
        var contextDeliveryOwed = true
        var cognitiveContextDelivered = false
        var commitPartsDelivery = resolvedTurnContext.partsDelivery
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
                cognitiveContextDelivered = resolvedTurnContext.cognitiveRuntimeContext
                    .map { Self.deliveredInput(resolvedTurnContext).contains($0) } == true
                await resolvedTurnContext.fluidContextTurn?.recordDelivery()
                await onDelivery?()
                creditDeliveredMemories(resolvedTurnContext)
                await announceDeliveredArrivals(in: resolvedTurnContext, sessionID: sessionId)
            }
            guard let sessionId else { return }
            if !replayedArrivals.isEmpty {
                guard await ChatTurnSteering.shared.markReplayedDelivered(replayedArrivals, sessionId: sessionId) else {
                    throw ChatOrchestrationError.underlying("Couldn't commit replayed arrival delivery; its reading remains owed.")
                }
                replayedArrivals = []
            }
            guard !steeringOffers.isEmpty else { return }
            let offers = steeringOffers
            steeringOffers = []
            guard await ChatTurnSteering.shared.markDelivered(offers, sessionId: sessionId) else {
                throw ChatOrchestrationError.underlying("Couldn't commit steering delivery; the message runs as its own turn.")
            }
        }

        // Offer and read calls using the provider resolved under this turn's
        // bindings: its admitted route or the surface's pick when none is carried.
        let codecStart = DispatchTime.now().uptimeNanoseconds
        let toolCallCodec = try ToolCallCodec.forProvider(
            try await holding(turn.admitting(model: .some(resolvedTurnContext.modelId))) { turn in
                try await holding(turn.admitting(provider: .some(resolvedTurnContext.providerId ?? turn.admission?.provider))) { turn in
                    try await llm.servingProviderID(model: resolvedTurnContext.modelId,call: call.with(\.turn, turn))
                }
            }
        )
        dispatchTrace.record(.toolCodec, since: codecStart)
        /// Seed the opening request again when repair selects a version with different system text or tools.
        func seeded(_ composed: TurnContext) throws -> (ConversationPrefixSeeding.Seed, (prompt: String?, segments: SystemPromptSegments?)) {
            let request = try ConversationPrefixSeeding.request(composed, codec: toolCallCodec, turn: turn)
            return (request.seed, (request.system, request.segments))
        }
        let seedStart = DispatchTime.now().uptimeNanoseconds
        var (prefixSeed, wireSystem) = try seeded(resolvedTurnContext)
        var composed: (system: SystemPromptSegments?, tools: [String]?) = (part.system, part.offeredTools)
        var ctx = prefixSeed.context
        // Hold the provider-name map fixed until a repaired seed changes the offered tools.
        var providerTools = ProviderToolNameMap(ctx.toolSchemas)
        dispatchTrace.record(.prefixSeed, since: seedStart)
        // Capture immutable request values before healing can replace them. Join diagnostics before tool reads, settlement or throwing exits.
        let initialSeed = prefixSeed
        let prefixTelemetry = Task { await Self.preparePrefixTelemetry(initialSeed) }
        let prefixSnapshot = Task { let result = await prefixTelemetry.value; return result.snapshot }
        let prefixSink = work.prefixTelemetry
        prefixSink?.setPending(prefixSnapshot)
        let replacementUserMessageID = turn.rows.replacementUserMessageID
            ?? resolvedTurnContext.historyReplaySpec?.replacementUserMessageID
        var bookkeeping = Task { [remPinsDataRoot] in
            await Self.recordDispatchBookkeeping(seed: initialSeed,
                telemetry: prefixTelemetry, sink: prefixSink, surface: surface, sessionId: sessionId, runId: runId,
                userMessageID: replacementUserMessageID, dataRoot: remPinsDataRoot, turn: turn)
        }
        func settlePartRounds() {
            do {
                let store = AbilityStore(dataRoot: remPinsDataRoot ?? defaultDataRoot())
                for (version, rounds) in try partRounds.take().sorted(by: { ($0.key.id, $0.key.key) < ($1.key.id, $1.key.key) }) {
                    // The rounds ledger owns repair for its own failed writes; one version's failure does not discard its siblings.
                    do { try store.recordRounds(id: version.id, version: version.key, rounds: rounds, turn: turn) }
                    catch { nativeLog("The agent's part %@'s rounds were not recorded: %@", version.id, error.localizedDescription) }
                }
            } catch { nativeLog("This turn's ability rounds were not recorded: %@", error.localizedDescription) }
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
                                        observedBy: "transport.dispatch", flags: ["initialRequest": true], turn: turn)
        }
        var conversation: [LLMMessage] = prefixSeed.messages
        let turnBudget = try ContextBudgetPolicy.resolve(turn: turn, dataRoot: remPinsDataRoot)
        guard let turnWindowTokens = turnBudget.windowTokens else {
            throw ProviderRoutingError.configurationFailed("The admitted model's default window is unavailable.")
        }
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var counters = TurnEngineResult.LoopCounters()
        var previousRoundFailed = false
        // Account for the whole turn's model tokens, part rounds and longest repeated call stretch.
        let spent = OSAllocatedUnfairLock(initialState: LLMCallTraceRecorder.Spend())
        var repeated = (calls: [JSONValue](), call: "", count: 0), longest = (call: "", count: 0)
        // The familiarity nerve fires at most once a turn, and never on a route this turn already met.
        var practiceChecked: Set<String> = [], practiceNoted = false
        func observed(_ result: TurnEngineResult, reason: TurnEngineResult.TerminalReason) -> TurnEngineResult {
            cleanFinish = reason == .replyCompleted || reason == .incomplete
            return result.observingTerminal(reason: reason, counters: counters, cognitiveContextDelivered: cognitiveContextDelivered)
        }
        var visibleText = ""
        // The words she streams read as the kept reply does (`joinedProse`): words that follow a call start a new paragraph.
        var liveLast: Character?
        var liveBreakOwed = false
        func live(_ text: String) async {
            guard !text.isEmpty else { return }
            if liveBreakOwed, let last = liveLast, !last.isNewline, text.first?.isNewline == false { await progress?(.delta("\n\n")) }
            liveBreakOwed = false
            liveLast = text.last
            await progress?(.delta(text))
        }
        defer { turn.observation?.record(counters, dispatches: dispatches, reply: visibleText) }
        var retainedProse = ""
        var workingCommentaryCharacters = 0
        var emittedProviderFirstDelta = false
        var providerCallCount = 0
        var openingAdditionalCharacters = 0
        // Relaunches resume their recorded work; retries keep the one opening read.
        var openingReadOwed = restarted == nil
        var replyTextSettled = false
        var lastMovement: ContinuousClock.Instant?
        var providerFailurePending = part.log.reversed().compactMap { row -> String? in
            guard case .object(let entry) = row, case .object(let event)? = entry["event"],
                  case .string(let type)? = event["type"], ["model", "provider_failure"].contains(type) else { return nil }
            return type
        }.first == "provider_failure"

        if let restarted {
            let rows = work.resumedRows
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
                    throw ChatOrchestrationError.underlying("""
                        The resumed turn's saved tool receipt has no execution-time ranCall identity. Repair the checkpoint's receipt; no tool \
                        binding was inferred.
                        """)
                }
                return TurnEngineResult.ToolDispatchRecord(
                    name: ranCall.tool == "image_generate" && metadata["generatedImages"] != nil ? "image_generate" : name, input: input,
                    ranCall: ranCall, result: result)
            }
            if let route = try Self.practiceRoute(dispatches, repeated: repeated) { practiceChecked.insert(route.signature) }
            // What the agent attached before the restart still goes with the agent's reply, if the fence still lets it.
            for path in restarted.replyChoices ?? [] {
                if case .success(let file) = await SwiftNativeSecurityCenter.fencedAttachment(
                    path, dataRoot: remPinsDataRoot ?? defaultDataRoot(), turn: turn) { turn.replyChoices?.choose(file.path) }
            }
            let replayRows: [ChatMessage]
            if restarted.hiddenInput != nil {
                // Its checkpoint owns the input; only receipts belong in transcript replay.
                replayRows = receipts
            } else if let user = rows.first(where: { $0.role == "user" }) {
                replayRows = [user] + receipts
            } else {
                throw ChatOrchestrationError.underlying("The resumed turn's saved user message is missing; repair its transcript.")
            }
            let replay = SessionHistoryMessages.project(messages: replayRows,
                historyLimit: max(1, receipts.count + 1), budget: turnBudget)
            visibleText = restarted.keptProse
            retainedProse = restarted.keptProse
            workingCommentaryCharacters = min(max(0, restarted.workingCommentaryCharacters), retainedProse.count)
            let resumed = TurnObservation.Kind.restarted(stepsDone: receipts.count,
                unknownStep: restarted.runningStep == nil ? nil : receipts.count + 1,
                started: part.uncertain.map { call in
                    guard case .object(let fields) = call, case .string(let name)? = fields["name"] else { return "a call" }
                    let input = (try? ChatSecretRedactor.redactValue(fields["input"] ?? .object([:])).serialize(pretty: false)) ?? "{}"
                    return name + " " + String(input.prefix(400))
                })
            TurnObservation.apply(resumed, kept: restarted.keptProse, to: &conversation, surface: surface, turn: turn)
            // Reuse the history projection, without inventing provider call IDs.
            let receiptText = replay.messages.dropFirst().flatMap(\.content).compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n\n")
            Self.appendStructuredUserNudge(receiptText, to: &conversation)
            for reading in try part.arrivalReadings() { ConversationPrefixSeeding.appendUser(reading, to: &conversation) }
            if !visibleText.isEmpty { await live(visibleText) }
            if !part.answered.isEmpty { await live(part.answered) }
            if inFlight {
                var event: [String: JSONValue] = ["type": .string("resumed"),
                    "text": .string(TurnObservation.text(resumed)), "steps": .int(Int64(receipts.count))]
                // Saved receipts retain landed effects even when relaunch lost the result event.
                event["effect"] = Self.landedEffect(.object(["receipts": .array(dispatches.map(\.result))])).map(JSONValue.string)
                try await part.deliver([.object(event)])
            }
        }

        func stopCarryingPartial() -> Error {
            TurnEngineError.streamCancelled(
                partial: toolCallCodec.visiblePrefix(in: visibleText),
                underlying: CancellationError())
        }

        /// Persistence and eligibility stay with steering; the turn log retains each reading for relaunch.
        func readArrivals(keeping prose: String = "") async throws -> Bool {
            guard let sessionId, !sessionId.isEmpty else { return false }
            let offers = try await ChatTurnSteering.shared.drain(sessionId: sessionId, cancelFlagPath: cancelFlagPath)
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { throw stopCarryingPartial() }
            steeringOffers += offers
            if !offers.isEmpty, !prose.isEmpty { conversation.append(.assistantText(prose)) }
            for offer in offers {
                try part.readArrival(offer)
                ConversationPrefixSeeding.appendUser(offer.reading, to: &conversation)
            }
            return !offers.isEmpty
        }

        /// The stem applies or records observations; the agent's part decides how to go on.
        func observe(_ kind: TurnObservation.Kind, kept: String = "", applying: Bool = true, unstarted: [ParsedToolCall] = []) async throws {
            if applying { TurnObservation.apply(kind, kept: kept, to: &conversation, surface: surface, turn: turn) }
            else { TurnObservation.record(kind, kept: kept, surface: surface, turn: turn) }
            var text = TurnObservation.text(kind)
            if !unstarted.isEmpty {
                let note = "These proposed calls did not start: " + unstarted.map { $0.name + " (" + $0.id + ")" }.joined(separator: ", ")
                    + ". Read the person's message before deciding what to do next."
                if applying { Self.appendStructuredUserNudge(note, to: &conversation) }
                text += " " + note
                TurnTraceBus.fireFromContext(kind: "turn.proposalSkipped", surface: surface, payload: .object([
                    "reason": .string("person_arrival"), "calls": .array(unstarted.map {
                        .object(["id": .string($0.id), "name": .string($0.name)])
                    }), "effects": .string("none"),
                ]), turn: turn)
            }
            try await part.deliver([.object(["type": .string("observation"), "text": .string(text)])])
        }
        /// Keep rounds in their streamed order; commentary can extend only the leading prefix, never pass an answer.
        func retainProse(_ prose: String, commentary: Bool = false) {
            let extendsCommentary = commentary && workingCommentaryCharacters == retainedProse.count
            retainedProse = Self.joinedProse(retainedProse, prose)
            if extendsCommentary { workingCommentaryCharacters = retainedProse.count }
        }
        /// Every effect boundary checkpoints the turn with its log.
        func capture(startingCalls: Int = 0,turn: Turn,work: ChatTurnWork) async throws {
            await work.checkpoint?.capture(
                prose: retainedProse,
                commentaryCharacters: workingCommentaryCharacters, conversation: conversation, log: part.log,
                startingCalls: startingCalls, turn: turn)
            if !steeringOffers.isEmpty || !replayedArrivals.isEmpty {
                guard work.checkpoint != nil, let root = remPinsDataRoot, let sessionId,
                      let saved = try TurnCheckpoint.read(dataRoot: root, sessionId: sessionId, turnId: turn.id),
                      saved.log == part.log, saved.keptProse == retainedProse else {
                    throw ChatOrchestrationError.underlying(
                        "Joined arrivals were not checkpointed; their doors retain them. Repair the turn checkpoint before continuing.")
                }
                // The reading is durably owned by this checkpoint; another launch must not resume it through its old checkpoint too.
                for (run, id) in try part.arrivalIDs() {
                    if let arrival = try TurnCheckpoint.read(dataRoot: root, sessionId: sessionId, turnId: id) {
                        guard arrival.runId == run else {
                            throw ChatOrchestrationError.underlying("The arrival checkpoint changed identity; repair its ownership before continuing.")
                        }
                        try arrival.remove(dataRoot: root)
                    }
                }
            }
        }
        var round: (calls: [ParsedToolCall], raw: String, codec: TextMarkerCodec?, boundary: LLMToolBoundaryReason?)?

        /// Provider output marks the round emitted, preventing a repeated request.
        func providerFailed(_ error: Error, emitted: Bool, turn: Turn) async throws {
            providerFailurePending = true
            let id = "provider-reply:" + UUID().uuidString
            let provider = ctx.providerId ?? turn.admission?.provider ?? "unresolved"
            let failure = ProviderFailure.repair(error, provider: provider, model: ctx.modelId, surface: surface,
                dataRoot: remPinsDataRoot ?? defaultDataRoot(), id: id, call: call.with(\.turn, turn))
            let next = failure.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
            var calls: [ParsedToolCall] = []
            if case .object(let call)? = next, case .string(let tool)? = call["tool"], case .object(let input)? = call["input"] {
                calls = [ParsedToolCall(id: id, name: tool, input: input)]
            }
            round = (calls, "", nil, nil)
            let reply = ToolResult(ChatToolOutcome.failure(error: failure))
            let remedy = reply.remedy ?? .null
            await progress?(.notice(kind: "provider_failure", text: failure.message))
            do {
                try await part.deliver([.object(["type": .string("provider_failure"), "provider": .string(provider),
                    "model": .string(ctx.modelId), "text": .string(failure.message), "remedy": remedy,
                    "work": .string(emitted || ProviderFailure.report(error)?.work == .ranPartly
                        ? ProviderFailure.WorkState.ranPartly.rawValue : ChatTurnFailure.work(for: error)),
                    "owed": .bool(failure.owner != nil && !failure.personDecides),
                    "calls": .array(calls.map { .object(["id": .string($0.id), "name": .string($0.name), "input": .object($0.input)]) })])])
            } catch { throw TurnEngineError.streamInterrupted(partial: visibleText, underlying: failure) }
        }

        /// A spent per-run output budget is the person's cap: the agent's part reads its
        /// receipt and ends; no further model call can run under it.
        func budgetSpent(emitted: Bool, turn: Turn) async throws {
            let bot = turn.standingBot
            try await providerFailed(ProviderFailure.Diagnostic(cause: .outputLimit, detail: "per-run output token limit spent",
                repair: ToolFailureError(
                    """
                        This run's output token limit\(bot.map { " (\($0.budget.tokens) tokens)" } ?? "") is spent; what was written stays and no \
                        further model call runs in this run.
                        """,
                    effects: .none, owner: bot.map { "helper \($0.name)'s budget" } ?? "this run's caller",
                    tap: bot.map { "Helpers → \($0.name) → Edit → Output tokens per run" }, personDecides: true)),
                emitted: emitted, turn: turn)
        }

        /// The agent's reply ends the turn: the stem returns at reply.end, and nothing of the agent's runs after it.
        func drive(turn: Turn, work: ChatTurnWork, call: LLMCall) async throws -> TurnEngineResult? {
        while true {
            if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) {
                throw stopCarryingPartial()
            }
            // A provider failure or outstanding card leaves completion incomplete; text-only routes must also say the card's copy.
            if part.replied {
                if let stopped = turn.providerRecovery?.stopped {
                    throw TurnEngineError.streamInterrupted(partial: visibleText, underlying: stopped)
                }
                await bookkeeping.value
                let reply = Self.joinedProse(retainedProse, part.answered)
                settlePartRounds()
                let waiting = turn.execution.map { $0.waitingInteraction != nil || $0.waitingForApproval } ?? false
                let completed = await finishReplyTurn(
                    reply: waiting ? ChatTurnExecution.waitingReply(visible: reply, turn: turn) : reply,
                    ctx: ctx, dispatches: dispatches, startNs: startNs,
                    providerCallCount: providerCallCount,
                    userMessage: userMessage, sessionId: sessionId, surface: surface,
                    workingCommentaryCharacters: workingCommentaryCharacters == 0 ? nil : workingCommentaryCharacters,
                    completionState: providerFailurePending || waiting ? .incomplete : .completed,
                    afterTurn: !work.thinking && (providerFailurePending || part.afterTurn),
                    took: counters.toolRoundCount == 0 ? nil : Self.took(rounds: counters.providerRoundCount, tokens: spent.withLock { $0.total },
                        seconds: Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000_000), repeated: longest),
                    turn: turn, work: work)
                return observed(completed, reason: providerFailurePending
                    ? .incomplete : completed.resolvedTerminalReason(dataRoot: remPinsDataRoot))
            }
            guard let effect = try await part.next() else { return nil }
            switch effect["effect"] {
            case .string("reply.stream"):
                if case .string(let text)? = effect["text"], !text.isEmpty {
                    liveBreakOwed = true
                    await live(text)
                    visibleText += text
                    part.sent(text)
                }
                try await capture(turn: turn, work: work)
                continue
            case .string("notebook"):
                // The turn program's notebook: the settings its weigh reads. The effect runs once; a replay matches it by identity.
                if case .object(let set)? = effect["set"], let root = remPinsDataRoot { try AttentionNotebook.write(set, dataRoot: root) }
                try await capture(turn: turn, work: work)
                continue
            case .string("app"):
                await bookkeeping.value
                // One round runs either the calls this model round named or the agent's program's own calls, each exactly once.
                let authored = effect["index"] == nil
                var batch = [effect]
                while part.nextIsApp(authored: authored), let more = try await part.next() { batch.append(more) }
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
                    guard let round else { throw TurnEngineError.turnPartFailed("Its app effects came with no model round to run.") }
                    let indices = try batch.map { item -> Int in
                        guard case .int(let at)? = item["index"], let index = Int(exactly: at), round.calls.indices.contains(index) else {
                            throw TurnEngineError.turnPartFailed("Its app effect names a call outside the current model round.")
                        }
                        return index
                    }
                    ran = (indices.map { round.calls[$0] }, indices, round.raw, round.codec, round.boundary)
                }
                let providerCalls = ran.calls
                counters.toolRoundCount += 1
                try await capture(startingCalls: providerCalls.count,turn: turn,work: work)
                let roundStart = dispatches.count
                try await runToolDispatchRound(
                    providerCalls: providerCalls,
                    iterationRawText: ran.raw,
                    ctx: ctx, surface: surface, sessionId: toolSessionId ?? sessionId,
                    arrivalSessionId: sessionId,
                    tools: tools, progress: progress, conversation: &conversation,
                    dispatches: &dispatches, providerTools: providerTools,
                    cancelFlagPath: cancelFlagPath,
                    markerCodec: ran.codec, toolBoundaryReason: ran.boundary, turn: turn, work: work)
                previousRoundFailed = dispatches.dropFirst(roundStart).contains {
                    ToolLoopTraceObservation.isFailedAttempt($0.result)
                }
                if let reminded = await cameToMind(after: dispatches.dropFirst(roundStart),
                                                   preparedTurn: resolvedTurnContext.fluidContextTurn, turn: turn, held: &cameToMindHeld,
                                                   sessionId: sessionId, surface: surface) {
                    Self.appendStructuredUserNudge(reminded, to: &conversation)
                }
                try partRounds.endRound()
                if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) { throw stopCarryingPartial() }
                // The practice signal rides this round's last result, so the agent's next thought in this turn carries it.
                var practice: JSONValue?
                if !practiceNoted {
                    practice = Self.practiceSignal(dispatches, repeated: repeated, checked: &practiceChecked,
                        dataRoot: remPinsDataRoot ?? defaultDataRoot(), turn: turn)
                    practiceNoted = practice != nil
                }
                // Keep call order and run every non-ignorable call; a waiting receipt reaches the part while its card continues gating the effect.
                var records = dispatches.dropFirst(roundStart).makeIterator()
                try await part.deliver(zip(ran.calls, ran.indices).enumerated().map { item -> JSONValue in
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
                    if ran.calls.count == 1, case .array? = call.input["actions"], case .string? = call.input["then_say"],
                       case .object(let said)? = reply?.payload.objectValue?["then_say"], said["stands"] == .bool(true),
                       case .string(let words)? = said["words"] {
                        event["say"] = .string(words)
                    }
                    return .object(event)
                })
                continue
            case .string("model.call"):
                if let system = part.system, system != composed.system || part.offeredTools != composed.tools {
                    let late = composed.system == nil
                    // Preserve write order: the opening seed cannot overwrite
                    // the healed seed after its request has been prepared.
                    await bookkeeping.value
                    let additional = try ConversationPrefixSeeding.additionalMessages(in: conversation, after: prefixSeed)
                    resolvedTurnContext.toolSchemas = gathered.toolSchemas
                    resolvedTurnContext = resolvedTurnContext.composing(system, tools: part.offeredTools)
                    (prefixSeed, wireSystem) = try seeded(resolvedTurnContext)
                    ctx = prefixSeed.context
                    providerTools = ProviderToolNameMap(ctx.toolSchemas)
                    let healedSeed = prefixSeed
                    let healedTelemetry = Task { await Self.preparePrefixTelemetry(healedSeed) }
                    prefixSink?.setPending(Task { let result = await healedTelemetry.value; return result.snapshot })
                    bookkeeping = Task { [remPinsDataRoot] in
                        await Self.recordDispatchBookkeeping(seed: healedSeed,
                            telemetry: healedTelemetry, sink: prefixSink, surface: surface, sessionId: sessionId,
                            runId: runId, userMessageID: replacementUserMessageID, dataRoot: remPinsDataRoot, turn: turn)
                    }
                    conversation = ConversationPrefixSeeding.Request(seed: prefixSeed,
                        system: wireSystem.prompt, segments: wireSystem.segments,
                        tools: toolCallCodec.requestTools(providerTools.schemas)).appending(additional).messages
                    composed = (.some(system), part.offeredTools)
                    // A system that arrives after the agent's first acts owes its context delivery as an opening one would.
                    if late {
                        commitInstructionDelivery = try pendingInstructionDelivery(in: resolvedTurnContext, sessionID: sessionId)
                        commitPartsDelivery = resolvedTurnContext.partsDelivery
                    }
                }
                if case .string(let note)? = effect["note"], !note.isEmpty { Self.appendStructuredUserNudge(note, to: &conversation) }
                if openingReadOwed {
                    openingReadOwed = false
                    if ctx.toolSchemas.contains(where: { $0.name == "app" }) {
                        let looked = await holding(turn.admitting(model: .some(ctx.modelId))) { turn in
                        await holding(work.with(\.preparedContext, ctx.fluidContextTurn)) { work in
                        await holding(turn.with(\.runtime, .init(
                            model: ctx.modelId, surface: surface, personaID: ctx.personaID,
                            providerID: ctx.providerId ?? turn.admission?.provider))) { turn in
                            await tools.readAhead(surface: surface, session: toolSessionId ?? sessionId, turn: turn, work: work)
                        } } }
                        if let looked {
                            let text = try ChatSecretRedactor.redactValue(looked).serialize(pretty: false)
                            Self.appendStructuredUserNudge(text, to: &conversation)
                        }
                    }
                }
            default:
                // Checkpoint reply-end bookkeeping like any effect.
                try await capture(turn: turn, work: work)
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
            var arrivalCut = false
            var pendingProtocolDelta = ""
            let rawProviderEvents = OSAllocatedUnfairLock<String>(initialState: "")
            let roundBaseVisibleText = visibleText
            liveBreakOwed = true

            // Only prose can survive an incomplete stream; none of its calls ran.
            func keepPartial() async -> String {
                var kept: String
                if arrivalCut {
                    let tail = toolCallCodec.visiblePrefix(in: pendingProtocolDelta)
                    kept = iterEmittedProse + String(tail.dropLast(ToolCallCodec.markerPrefixTailLength(tail)))
                } else {
                    kept = toolBoundaryReason == .fabricatedResult
                        ? iterEmittedProse : toolCallCodec.visiblePrefix(in: iterAccumulated)
                }
                // Words the person cut off read as cut off: the sentence stops visibly before the agent's answer.
                if arrivalCut, let last = kept.last(where: { !$0.isWhitespace }), !".!?…:".contains(last) {
                    kept = String(kept[..<(kept.lastIndex { !$0.isWhitespace }.map { kept.index(after: $0) } ?? kept.endIndex)]) + "…"
                }
                if kept.hasPrefix(iterEmittedProse) {
                    let tail = String(kept.dropFirst(iterEmittedProse.count))
                    if !tail.isEmpty { await live(tail) }
                }
                visibleText = roundBaseVisibleText + kept
                // Words a cut stopped are working, not the answer: they fold above the reply that answers the person.
                retainProse(kept, commentary: arrivalCut)
                streamedCalls.removeAll(keepingCapacity: true)
                pendingProtocolDelta.removeAll(keepingCapacity: true)
                return kept
            }

            do { try await providerAdmission?() }
            catch is CancellationError { throw stopCarryingPartial() }
            providerStream: do {
                // Every step after the first carries what changed in the agent elsewhere since its last one, after its reply too.
                if providerCallCount > 0, let sessionId, !sessionId.isEmpty, let root = remPinsDataRoot, let cursor = agentNow {
                    let at = Date()
                    let peer = try !Self.personContinuityAllowed(root: root, sessionID: sessionId, turn: turn)
                    if !peer || Self.peerContinuityTurn(turn) {
                        let breath = await ChatWorkspaceBinding.breath(turn: turn, invocation: work.invocation, dataRoot: root, scope: sessionId,
                            peer: peer, since: cursor.at, shown: breathActs, at: at)
                        // A read window is new evidence even when it renders alike; only a failed reading's repeat is withheld. Acts are shown once by id.
                        if let text = breath.text, breath.read || text != lastBreath {
                            Self.appendStructuredUserNudge(text, to: &conversation)
                            lastBreath = text
                            breathActs.formUnion(breath.acts)
                        }
                        if breath.read { agentNow = AgentNowCursor(at: at) }
                    }
                }
                _ = try await readArrivals()
                if sessionId != nil, !(work.prefixTelemetry?.marksRequestShapeUnmeasured == true) {
                    let additional = try ConversationPrefixSeeding.additionalMessages(in: conversation, after: prefixSeed)
                    if providerCallCount == 0 {
                        openingAdditionalCharacters = LLMMessage.inputCharacters(additional, system: nil, tools: [])
                    }
                    if let fit = work.fit {
                        await bookkeeping.value
                        let encoded = try toolCallCodec.providerMessages(
                            additional, records: dispatches, schemas: ctx.toolSchemas, turn: turn)
                        let fitted = try await fit(resolvedTurnContext, toolCallCodec, encoded)
                        let changed = fitted.historyContextWindow != resolvedTurnContext.historyContextWindow
                        resolvedTurnContext = fitted
                        (prefixSeed, wireSystem) = try seeded(resolvedTurnContext)
                        ctx = prefixSeed.context
                        providerTools = ProviderToolNameMap(ctx.toolSchemas)
                        conversation = ConversationPrefixSeeding.Request(seed: prefixSeed,
                            system: wireSystem.prompt, segments: wireSystem.segments,
                            tools: toolCallCodec.requestTools(providerTools.schemas)).appending(additional).messages
                        if providerCallCount == 0 || changed {
                            let fittedSeed = prefixSeed
                            let fittedTelemetry = Task { await Self.preparePrefixTelemetry(fittedSeed) }
                            prefixSink?.setPending(Task {
                                let result = await fittedTelemetry.value
                                return result.snapshot
                            })
                            bookkeeping = Task { [remPinsDataRoot] in
                                await Self.recordDispatchBookkeeping(seed: fittedSeed,
                                    telemetry: fittedTelemetry, sink: prefixSink, surface: surface, sessionId: sessionId,
                                    runId: runId, userMessageID: replacementUserMessageID, dataRoot: remPinsDataRoot, turn: turn)
                            }
                        }
                    }
                }
                do {
                    guard let root = remPinsDataRoot else {
                        throw ProviderRoutingError.configurationFailed("The turn's request measurement owner is unavailable.")
                    }
                    let owner = sessionId ?? runId ?? turn.id
                    let measurementRecords = dispatches
                    let measurementContext = ctx
                    let measurementSystem = wireSystem.prompt
                    let measurementTools = toolCallCodec.requestTools(providerTools.schemas) ?? []
                    let measurement: @Sendable ([LLMMessage]) async throws -> SessionContextMeasurement = { messages in
                        let wire = try toolCallCodec.providerMessages(
                            messages, records: measurementRecords, schemas: measurementContext.toolSchemas, turn: turn)
                        let request = try SessionContextRequest(messages: wire,
                            system: measurementSystem, tools: measurementTools,
                            historyCharacters: 0, rowCharacters: [:])
                        return try await SessionContextMeasurement.measure(request, sessionId: owner,
                            model: measurementContext.modelId, providerID: measurementContext.providerId, dataRoot: root,
                            windowTokens: turnWindowTokens, call: call.with(\.turn, turn))
                    }
                    conversation = try await TurnToolResultPointers.fit(conversation, window: turnWindowTokens,
                        dataRoot: root, surface: surface, sessionID: sessionId, turn: turn, measure: measurement)
                    let wire = try toolCallCodec.providerMessages(conversation, records: dispatches, schemas: ctx.toolSchemas, turn: turn)
                    let request = try SessionContextRequest(messages: wire,
                        system: wireSystem.prompt, tools: toolCallCodec.requestTools(providerTools.schemas) ?? [],
                        historyCharacters: 0, rowCharacters: [:])
                    try await SessionContextMeasurement.requireFits(request, sessionId: owner,
                        model: ctx.modelId, providerID: ctx.providerId, dataRoot: root,
                        windowTokens: turnWindowTokens, call: call.with(\.turn, turn))
                }
                // Publish only the fitted opening request actually passed to `streamMessages`, after opening reads and tail fitting.
                if providerCallCount == 0 {
                    let snapshotRequest = ConversationPrefixSeeding.Request(seed: prefixSeed,
                        system: wireSystem.prompt, segments: wireSystem.segments,
                        tools: toolCallCodec.requestTools(providerTools.schemas))
                    let snapshotMessages = try toolCallCodec.providerMessages(
                        conversation, records: dispatches, schemas: ctx.toolSchemas, turn: turn)
                    let publication = remPinsDataRoot.flatMap { root in
                        sessionId.map { ContextFedRecord.begin(sessionId: $0, dataRoot: root) }
                    }
                    let preceding = bookkeeping
                    bookkeeping = Task {
                        await preceding.value
                        await Self.recordWireSnapshot(request: snapshotRequest, messages: snapshotMessages,
                            publication: publication, prefix: prefixSink?.current,
                            surface: surface, sessionId: sessionId, runId: runId, turn: turn)
                    }
                }
                try await capture(turn: turn, work: work)
                providerCallCount += 1
                counters.providerAttemptCount += 1
                counters.providerRoundCount += 1
                if previousRoundFailed { counters.roundsAfterToolFailureCount += 1 }
                previousRoundFailed = false
                // Construction and consumption share the async task-local scope.
                let providerRoute = ctx.providerId ?? turn.admission?.provider
                let serviceTier = ctx.serviceTier ?? turn.admission?.serviceTier
                let purpose: String
                if call.purpose == "other", case .string(let named)? = effect["purpose"] { purpose = named }
                else { purpose = call.purpose }
                let captureEvents: @Sendable (SSEEvent) -> Void = { event in
                    guard providerRoute == "anthropic_oauth_direct" else { return }
                    rawProviderEvents.withLock { raw in
                        if let name = event.event { raw += "event: \(name)\n" }
                        raw += "data: " + event.data.replacingOccurrences(of: "\n", with: "\ndata: ") + "\n\n"
                    }
                }
                let requestPlan: Data?
                // A plan names the saved user row it is rebuilt from; a hidden input has none.
                if call.conversationRequest, !(work.prefixTelemetry?.marksRequestShapeUnmeasured == true),
                   turn.rows.hiddenInput == nil, let runId, sessionId != nil {
                    requestPlan = try ConversationPrefixSeeding.Request(seed: prefixSeed,
                        system: wireSystem.prompt, segments: wireSystem.segments,
                        tools: toolCallCodec.requestTools(providerTools.schemas))
                        .plan(runID: turn.rows.questionRunID ?? runId, userMessageID: replacementUserMessageID,
                            additionalCharacters: openingAdditionalCharacters).encoded
                } else { requestPlan = nil }
                let consumeStream: (Turn, LLMCall) async throws -> Void = { turn, call in
                    try await ProviderStreamContext.$diagnosticEvent.withValue(captureEvents) {
                    try await holding(call.with(\.lifetime.dispatched, requestDispatched)) { call in
                    try await holding(call.with(\.purpose, purpose)) { call in
                    try await holding(call.with(\.requestPlan, requestPlan)) { call in
                    let arrivals = if let sessionId {
                        await ChatTurnSteering.shared.arrivals(sessionId: sessionId)
                    } else { AsyncStream<ChatTurnSteering.Offer> { $0.finish() } }
                    let stream = llm.streamMessages(
                        messages: try toolCallCodec.providerMessages(
                            conversation, records: dispatches, schemas: ctx.toolSchemas, turn: turn),
                        system: wireSystem.prompt,
                        model: ctx.modelId,
                        tools: toolCallCodec.requestTools(providerTools.schemas),
                    call: call.with(\.turn, turn))
                    let merged = TurnRoundEvents(provider: stream, arrivals: arrivals)
                    defer { merged.cancel() }
                    // Every provider byte is movement, ticked at most once a second for every door's card; this door's own words show themselves.
                    func moved(_ input: LLMStreamCallInput?, words: Bool = false) async {
                        let now = ContinuousClock.now
                        if let last = lastMovement, now - last < .seconds(1) { return }
                        lastMovement = now
                        let writing = input.map(TurnCallWriting.init(streaming:))
                        var tick: [String: JSONValue] = [:]
                        if let writing { tick = ["call": .string(writing.call), "bytes": .int(Int64(writing.bytes))] }
                        TurnTraceBus.fireFromContext(kind: "stream.tick", payload: .object(tick), turn: turn)
                        if !words { await progress?(.writing(writing)) }
                    }
                    roundEvents: for try await incoming in merged.stream {
                        try Task.checkCancellation()
                        if ChatCancelFlag.isRaised(cancelFlagPath) { throw CancellationError() }
                        let event: LLMMessageStreamEvent
                        switch incoming {
                        case .arrival(let offer):
                            guard let sessionId,
                                  await ChatTurnSteering.shared.canHear(offer, sessionId: sessionId, run: turn.run) else { continue }
                            if try await part.hear(offer),
                               await ChatTurnSteering.shared.canHear(offer, sessionId: sessionId, run: turn.run) {
                                arrivalCut = true
                                merged.cancel()
                                break roundEvents
                            }
                            continue
                        case .provider(let value): event = value
                        }
                        switch event {
                        case .toolBoundary(let reason):
                            toolBoundaryReason = reason
                        case .replyTextSettled(let settled):
                            if settled {
                                let prose = toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
                                if !prose.isEmpty {
                                    iterEmittedProse += prose
                                    await live(prose)
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
                                        observedBy: "structured_tool_loop.stream", turn: turn)
                                }
                            }
                            iterAccumulated += delta
                            visibleText += delta
                            pendingProtocolDelta += delta
                            let safe = toolCallCodec.releasableProse(holding: &pendingProtocolDelta)
                            if !safe.isEmpty {
                                iterEmittedProse += safe
                                await live(safe)
                                await moved(nil, words: true)
                            } else if !delta.isEmpty {
                                await moved(nil)
                            }
                        case .toolCall(let call):
                            emitted = true
                            try await commitDelivery()
                            await moved(nil)
                            guard let parsed = try toolCallCodec.decode(call) else { continue }
                            streamedCalls.append(parsed)
                        case .keepAlive:
                            await moved(nil)
                        case .callInput(let input):
                            await moved(input)
                        }
                    }
                    try Task.checkCancellation()
                    if ChatCancelFlag.isRaised(cancelFlagPath) { throw CancellationError() }
                    }
                    }
                    }
                    }
                }
                var requestCall = call
                let requestTurn = turn.admitting(model: .some(ctx.modelId), provider: .some(providerRoute),
                    reasoningEffort: .some(ctx.reasoningEffort), serviceTier: .some(serviceTier))
                requestCall.turn = requestTurn
                requestCall.currentUserIndex = prefixSeed.currentUserIndex
                requestCall.systemSegments = wireSystem.segments
                requestCall.session = sessionId
                requestCall.withinTurnReuse = true
                requestCall.prefixMeasurement = work.prefixTelemetry
                requestCall.lifetime.status = { kind, text in
                    await progress?(.notice(kind: kind, text: text))
                }
                requestCall.inspectorThinkingSummarized = InspectorThinkingLane.isEnabledForSurface(surface)
                try await LLMCallTraceRecorder.$spent.withValue(spent) {
                    try await consumeStream(requestTurn, requestCall)
                }
            } catch {
                if Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath) || error is CancellationError {
                    throw stopCarryingPartial()
                }
                if let failure = error as? ToolFailureError,
                   failure.code == "context_window_exceeded" {
                    // A local admission refusal is terminal for this request;
                    // provider-overflow recovery must never truncate around it.
                    throw failure
                }
                if sessionId != nil, !(work.prefixTelemetry?.marksRequestShapeUnmeasured == true),
                   ProviderRecoveryPolicy.isContextOverflow(error) {
                    throw ToolFailureError("""
                        The provider refused this request's context window after fitting: \(error.localizedDescription). Retained history was not \
                        truncated. Repair the model-window/token measurement or reduce the current input before continuing.
                        """,
                        effects: .none, owner: ctx.modelId, code: "context_window_exceeded", status: .refused, recovery: .repair)
                }
                if ProviderFailure.classify(error) == .malformedResponse {
                    let raw = rawProviderEvents.withLock { $0 }
                    if !raw.isEmpty { ProviderOutputDiagnostics.writeDiagnostic(raw, reason: "malformed_stream", dataRoot: remPinsDataRoot, call: call) }
                }
                counters.failedProviderAttemptCount += 1
                // A spent budget's partial is the whole run's ledger, not this round's words.
                if iterAccumulated.isEmpty, case .outputLengthLimit(let partial) = error as? LLMError,
                   turn.tokenBudget?.exhausted != true {
                    iterAccumulated = partial
                }
                if error is ProviderRecovery.Stopped,
                   try toolCallCodec.roundCalls(streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas,
                       recordShims: false, turn: turn).isEmpty {
                    _ = await keepPartial()
                    throw TurnEngineError.streamInterrupted(partial: visibleText, underlying: error)
                }
                // A stream cut preserves complete calls for dispatch and continues after retained prose.
                if ProviderRecoveryPolicy.isRecoverable(error),
                   try !toolCallCodec.roundCalls(streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas, recordShims: false, turn: turn)
                       .isEmpty
                    || !toolCallCodec.visiblePrefix(in: iterAccumulated).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    toolBoundaryReason = .interrupted
                    break providerStream
                }
                let kept = await keepPartial()
                if case .outputLengthLimit = error as? LLMError,
                   turn.tokenBudget?.exhausted == true {
                    try await budgetSpent(emitted: emitted, turn: turn)
                } else if ProviderRecoveryPolicy.isContextOverflow(error) {
                    try await providerFailed(error, emitted: emitted, turn: turn)
                } else if case .outputLengthLimit = error as? LLMError {
                    try await observe(.lengthLimit(chars: kept.count), kept: kept)
                } else {
                    try await providerFailed(error, emitted: emitted, turn: turn)
                }
                continue
            }
            if arrivalCut {
                // A cut dispatches nothing, even a complete proposal. Only visible prose enters the next wire transcript.
                let kept = await keepPartial()
                if !kept.isEmpty { conversation.append(.assistantText(kept)) }
                try await capture(turn: turn, work: work)
                let read = try await readArrivals()
                try await observe(.cut(arrivalRead: read))
                try await capture(turn: turn, work: work)
                TurnTraceBus.fireFromContext(kind: "provider.roundCut", surface: surface, payload: .object([
                    "round": .int(Int64(providerCallCount)), "proseCharacters": .int(Int64(kept.count)),
                    "arrivalRead": .bool(read), "effects": .string("none"),
                ]), turn: turn)
                continue
            }
            providerFailurePending = turn.providerRecovery?.stopped != nil
            let iterProse = ToolCallParser.stripProtocolDebris(iterAccumulated)
            let answerText = iterProse.replacingOccurrences(
                of: #"</?[\p{L}_][\p{L}\p{N}_.:-]*(?:\s[^<>]*)?/?>|<[!?][^>]*>"#, with: "", options: .regularExpression)
            func saveSuspiciousReply() {
                let visible = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard visible.split(whereSeparator: { $0.isWhitespace }).count < 2
                    || (visible.count < 12 && iterProse.contains(where: { "<=>".contains($0) })) else { return }
                let raw = rawProviderEvents.withLock { $0 }
                if !raw.isEmpty { ProviderOutputDiagnostics.writeDiagnostic(raw, reason: "suspicious_reply", dataRoot: remPinsDataRoot, call: call) }
            }
            if !call.allowsSilentCompletion, toolBoundaryReason == nil,
               streamedCalls.isEmpty && !answerText.contains(where: { !$0.isWhitespace }) {
                saveSuspiciousReply()
                visibleText = roundBaseVisibleText
                counters.emptyReplyRoundCount += 1
                try await providerFailed(ProviderFailure.Diagnostic(cause: .malformedResponse,
                    detail: "The provider completed without an answer or a tool call."), emitted: emitted, turn: turn)
                continue
            }
            if call.allowsSilentCompletion, streamedCalls.isEmpty, !answerText.contains(where: { !$0.isWhitespace }) {
                // A silent end is the thought's whole answer: what the model read was delivered, so its offers settle as consumed.
                try await commitDelivery()
            }
            let markerCodec = toolCallCodec == .textMarkers
                ? TextMarkerCodec(schemas: ctx.toolSchemas,
                    turnActiveTools: turn.offeredTools ?? [], catalogNames: Set(ctx.toolsAvailable), turn: turn)
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
                    if let file = try ProviderOutputDiagnostics.writeDiagnostic(iterAccumulated, reason: violation.traceType,
                        dataRoot: remPinsDataRoot, call: call)
                        .get() {
                        diagnostic["path"] = .string(file.path)
                    }
                } catch { diagnostic["file_error"] = .string(error.localizedDescription) }
                TurnTraceBus.fireFromContext(kind: "tool.protocol_violation", surface: surface, payload: .object(diagnostic), turn: turn)
                let kept = await keepPartial()
                try await observe(.malformedCall(why: violation.modelFeedback), kept: kept)
                continue
            }
            let providerCalls = try toolCallCodec.roundCalls(
                streamed: streamedCalls, text: iterAccumulated, schemas: ctx.toolSchemas, turn: turn)
            // Counts only: distinguish a silent tool round from words
            // delivered before tools, without retaining provider text.
            let roundTail = providerCalls.isEmpty
                ? toolCallCodec.visiblePrefix(in: pendingProtocolDelta)
                : (toolBoundaryReason == .fabricatedResult ? "" : toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta))
            let roundProse = (iterEmittedProse + roundTail).trimmingCharacters(in: .whitespacesAndNewlines)
            TurnTraceBus.fireFromContext(kind: "provider.roundOutput", surface: surface, payload: .object([
                "round": .int(Int64(providerCallCount)),
                "proseCharacters": .int(Int64(roundProse.count)),
                "toolCallCount": .int(Int64(providerCalls.count)),
            ]), turn: turn)
            if providerCalls.isEmpty {
                saveSuspiciousReply()
                if let toolBoundaryReason {
                    let kept = await keepPartial()
                    if toolBoundaryReason == .outputLimit, turn.tokenBudget?.exhausted == true {
                        try await budgetSpent(emitted: emitted, turn: turn)
                    } else {
                        try await observe(.boundary(toolBoundaryReason), kept: kept)
                    }
                    continue
                }
                if !pendingProtocolDelta.isEmpty {
                    await live(toolCallCodec.visiblePrefix(in: pendingProtocolDelta))
                }
                // The agent's answer stays in the conversation for whatever the agent's part does next.
                conversation.append(.assistantText(iterProse))
                if try await readArrivals() {
                    // Retain the completed answer before any prose the arrival's next round produces.
                    retainProse(iterProse)
                    try await observe(.arrival)
                    continue
                }
                try await part.deliver([.object(["type": .string("model"), "text": .string(iterProse), "calls": .array([])])])
                continue
            }

            let pendingProse = toolBoundaryReason == .fabricatedResult
                ? "" : toolCallCodec.proseReleasedAtDispatch(pendingProtocolDelta)
            if !pendingProse.isEmpty {
                iterEmittedProse += pendingProse
                await live(pendingProse)
            }
            visibleText = roundBaseVisibleText + iterEmittedProse
            retainProse(iterEmittedProse, commentary: true)
            if let sessionId, ChatTurnSteering.hasPersonWaiting(sessionId), try await readArrivals(keeping: iterEmittedProse) {
                round = nil
                try await observe(.arrival, unstarted: providerCalls)
                continue
            }
            round = (providerCalls, toolCallCodec == .textMarkers ? iterAccumulated : iterEmittedProse, markerCodec, toolBoundaryReason)
            let made = providerCalls.map { JSONValue.object(["name": .string($0.name), "input": .object($0.input)]) }
            repeated = made == repeated.calls ? (made, repeated.call, repeated.count + 1) : (made, providerCalls.map { call in
                if case .string(let action)? = call.input["action"] { action } else { call.name }
            }.joined(separator: ", "), 1)
            if repeated.count > longest.count { longest = (repeated.call, repeated.count) }
            try await part.deliver([.object(["type": .string("model"), "text": .string(iterEmittedProse),
                "calls": .array(providerCalls.enumerated().map {
                    .object(["index": .int(Int64($0.offset)), "id": .string($0.element.id), "name": .string($0.element.name),
                             "input": .object($0.element.input)])
                })])])
        }
        }
        guard let result = try await drive(turn: turn, work: work, call: call) else {
            throw TurnEngineError.turnPartFailed("Its steps ended the turn without a reply.end.")
        }
        await bookkeeping.value
        return result
        } catch {
            await bookkeeping.value
            settlePartRounds()
            throw error
        }
        }
        }
    }

    /// Only landed hand work forms a practice; incidental reads and arguments cannot count. A lone write is just using the tool:
    /// a route needs two steps, or one call made 3+ rounds in a row.
    nonisolated private static func practiceRoute(_ dispatches: [TurnEngineResult.ToolDispatchRecord],
        repeated: (calls: [JSONValue], call: String, count: Int)) throws -> (signature: String, sequence: [JSONValue], hand: Bool, looped: Bool)? {
        func identity(_ name: String, _ input: [String: JSONValue]) -> JSONValue {
            var ids = [JSONValue.string(name)]
            if name == "app", case .string(let action)? = input["action"] { ids.append(.string(action)) }
            return .array(ids)
        }
        // Use each landed action ID in batches and scripts so unrelated `app` calls cannot look like repetition.
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
        let hand = !sequence.isEmpty
        if sequence.isEmpty, repeated.count >= 3, repeated.calls.count == 1,
           let call = repeated.calls.first?.objectValue, let name = call["name"]?.stringValue,
           let input = call["input"]?.objectValue {
            sequence = [identity(name, input)]
        }
        let looped = repeated.count >= 3 && repeated.calls.count == 1
        guard sequence.count >= 2 || (sequence.count == 1 && looped) else { return nil }
        return (try JSONValue.array(sequence).serialize(pretty: false), sequence, hand, looped)
    }

    /// The familiarity nerve: a route met in an earlier turn that no active ability covers yet returns its practice signal for the agent's next
    /// thought in this turn. A first meeting is recorded and stays quiet; a failed read is traced and the turn goes on.
    nonisolated private static func practiceSignal(_ dispatches: [TurnEngineResult.ToolDispatchRecord],
        repeated: (calls: [JSONValue], call: String, count: Int), checked: inout Set<String>, dataRoot: URL, turn: Turn) -> JSONValue? {
        let practice: (signature: String, sequence: [JSONValue], hand: Bool, looped: Bool)
        do {
            guard let route = try practiceRoute(dispatches, repeated: repeated), checked.insert(route.signature).inserted else { return nil }
            practice = route
        } catch {
            TurnTraceBus.fireFromContext(kind: "practice.keep", payload: .object(["failed": .string(error.localizedDescription)]), turn: turn)
            return nil
        }
        let sequence = practice.sequence
        do {
            let first = try !FamiliarLines.firstMet(["practice: " + practice.signature], dataRoot: dataRoot).isEmpty
            var noted = false
            defer {
                TurnTraceBus.fireFromContext(kind: "practice.keep", payload: .object([
                    "practice": .string(practice.signature), "met": .string(first ? "first" : "again"), "noted": .bool(noted),
                ]), turn: turn)
            }
            guard !first else { return nil }
            guard case .array(let abilities) = try AbilityStore(dataRoot: dataRoot).registry(kind: .part) else {
                throw TurnEngineError.turnPartFailed("The ability index did not return rows for practice.")
            }
            for ability in abilities {
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
                    if matched == sequence.count { return nil }
                }
            }
            noted = true
            var signal: [String: JSONValue] = ["route": .string(practice.signature), "hand": .bool(practice.hand)]
            if practice.looped { signal["loop"] = .object(["call": .string(repeated.call), "count": .int(Int64(repeated.count))]) }
            return .object(signal)
        } catch {
            TurnTraceBus.fireFromContext(kind: "practice.keep", payload: .object([
                "practice": .string(practice.signature), "failed": .string(error.localizedDescription)]), turn: turn)
            return nil
        }
    }

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

    /// One blank line separates retained prose and anchors the commentary offset.
    nonisolated static func joinedProse(_ head: String, _ tail: String) -> String {
        let head = String(head[..<(head.lastIndex { !$0.isWhitespace }.map(head.index(after:)) ?? head.startIndex)])
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty || tail.isEmpty ? head + tail : head + "\n\n" + tail
    }
}
