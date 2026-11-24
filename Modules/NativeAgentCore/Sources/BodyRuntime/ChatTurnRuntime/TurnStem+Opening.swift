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
// Blueprint: | `TurnStem+Opening.swift` | `SwiftNativeTurnEngine`: `openPart`, `openStem`, `replayRestart`, `commitDelivery` (the stem's opening: delivers the message's facts (text, door, who, verified id, trust, steering, posture), or resumes a checkpointed log and replays its saved receipts) |

extension SwiftNativeTurnEngine {
    /// Delivers the moment's message to a fresh part, or resumes a checkpointed one; true when an effect was in flight.
    func openPart(_ part: inout TurnPart, gathered: TurnContext, surface: String, turn: Turn) async throws -> Bool {
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
                "trust": .string(turn.peerSteering?.isTainted(dataRoot: turn.dataRoot) == true ? "untrusted" : "trusted"),
                "steered_by": .array((turn.peerSteering?.checkpointSources ?? []).map(JSONValue.string)),
                "posture": .string(posture),
            ]
            // A thought of the agent's carries what it attends.
            if let attended = turn.attended { message["attended"] = attended }
            try await part.deliver([.object(message)])
        } else {
            inFlight = try await part.resume()
        }
        return inFlight
    }

    /// Everything the turn's stages share, built once; a throwing exit joins the bookkeeping it started.
    func openStem(part: TurnPart, dispatchTrace: inout ContextStageTrace, surface: String, userMessage: String,
                  sessionId: String?, toolSessionId: String?, runId: String?, llm: any LLMClient, tools: any ToolDispatchClient,
                  gathered: TurnContext, progress: ToolProgress?, onDelivery: (@Sendable () async -> Void)?, cancelFlagPath: URL?,
                  providerAdmission: (@Sendable () async throws -> Void)?, startNs: UInt64, restarted: TurnCheckpoint?,
                  turn: Turn, work: ChatTurnWork, call: LLMCall, partRounds: AbilityRounds) async throws -> TurnStem {
        // The native opening owns whether this is a thought, including on checkpoint replay.
        let opening = part.log.first?.objectValue?["event"]?.objectValue
        let call = call.with(\.allowsSilentCompletion, call.allowsSilentCompletion
            || (opening?["type"] == .string("message") && opening?["attended"]?.objectValue != nil))
        try Task.checkCancellation()
        dispatchTrace.record(.turnPart, since: startNs)
        var replayedArrivals: Set<String> = []
        if restarted != nil, let sessionId {
            replayedArrivals = Set(try part.arrivalIDs().keys)
            await ChatTurnSteering.shared.restoreReadings(replayedArrivals, sessionId: sessionId)
        }
        let codecStart = DispatchTime.now().uptimeNanoseconds
        let toolCallCodec = try ToolCallCodec.forProvider(
            try await holding(turn.admitting(model: .some(gathered.modelId))) { turn in
                try await holding(turn.admitting(provider: .some(gathered.providerId ?? turn.admission?.provider))) { turn in
                    try await llm.servingProviderID(model: gathered.modelId,call: call.with(\.turn, turn))
                }
            }
        )
        dispatchTrace.record(.toolCodec, since: codecStart)
        let preparedDispatchTrace = dispatchTrace
        let remainderStart = DispatchTime.now().uptimeNanoseconds
        // Dispatch is route/adapter admission, before HTTP body assembly. The
        // ProviderWire event separately names the URLSession send boundary.
        let requestStarted = Atomic(false)
        let requestDispatched: @Sendable () -> Void = {
            guard !requestStarted.exchange(true, ordering: .acquiringAndReleasing) else { return }
            var trace = preparedDispatchTrace
            trace.record(.dispatchRemainder, since: remainderStart)
            trace.emit(kind: "turn.dispatch.summary", surface: surface)
            TurnLifecycleTelemetry.emit(.providerRequestStarted, surface: surface, sessionId: sessionId,
                                        observedBy: "transport.dispatch", flags: ["initialRequest": true], turn: turn)
        }
        let turnBudget = try ContextBudgetPolicy.resolve(turn: turn, dataRoot: remPinsDataRoot)
        guard let turnWindowTokens = turnBudget.windowTokens else {
            throw ProviderRoutingError.configurationFailed("The admitted model's default window is unavailable.")
        }
        let providerFailurePending = part.log.reversed().compactMap { row -> String? in
            guard case .object(let entry) = row, case .object(let event)? = entry["event"],
                  case .string(let type)? = event["type"], ["model", "provider_failure"].contains(type) else { return nil }
            return type
        }.first == "provider_failure"
        return TurnStem(surface: surface, userMessage: userMessage, sessionId: sessionId, toolSessionId: toolSessionId, runId: runId,
            llm: llm, tools: tools, progress: progress, onDelivery: onDelivery, cancelFlagPath: cancelFlagPath,
            providerAdmission: providerAdmission, startNs: startNs, turn: turn, work: work, call: call,
            partRounds: partRounds, toolCallCodec: toolCallCodec, turnBudget: turnBudget, turnWindowTokens: turnWindowTokens,
            prefixSink: work.prefixTelemetry, requestDispatched: requestDispatched,
            dataRoot: remPinsDataRoot, part: part,
            wire: TurnStem.Wire(opening: gathered),
            owed: TurnStem.Owed(commitInstructionDelivery: nil, commitPartsDelivery: nil,
                replayedArrivals: replayedArrivals, agentNow: nil, breathActs: []),
            voice: TurnStem.Voice(), tally: TurnStem.Tally(providerFailurePending: providerFailurePending))
    }

    func replayRestart(_ stem: TurnStem, _ restarted: TurnCheckpoint, inFlight: Bool) async throws {
        let rows = stem.work.resumedRows
        let receipts = rows.filter { SessionHistoryPromptRenderer.renderable($0)?.isTool == true }
        stem.tally.dispatches = try receipts.map { row in
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
        if let route = try Self.practiceRoute(stem.tally.dispatches, repeated: stem.tally.repeated) { stem.tally.practiceChecked.insert(route.signature) }
        // What the agent attached before the restart still goes with the agent's reply, if the fence still lets it.
        for path in restarted.replyChoices ?? [] {
            if case .success(let file) = await SwiftNativeSecurityCenter.fencedAttachment(
                path, dataRoot: remPinsDataRoot ?? defaultDataRoot(), turn: stem.turn) { stem.turn.replyChoices?.choose(file.path) }
        }
        let replayRows: [HistoryChatMessage]
        if restarted.hiddenInput != nil {
            // Its checkpoint owns the input; only receipts belong in transcript replay.
            replayRows = receipts
        } else if let user = rows.first(where: { $0.role == "user" }) {
            replayRows = [user] + receipts
        } else {
            throw ChatOrchestrationError.underlying("The resumed turn's saved user message is missing; repair its transcript.")
        }
        let replay = SessionHistoryMessages.project(messages: replayRows,
            historyLimit: max(1, receipts.count + 1), budget: stem.turnBudget)
        stem.voice.visibleText = restarted.keptProse
        stem.voice.retainedProse = restarted.keptProse
        stem.voice.workingCommentaryCharacters = min(max(0, restarted.workingCommentaryCharacters), stem.voice.retainedProse.count)
        // A call whose receipt reached the transcript after its result missed the part's log landed: it is done, not uncertain.
        // Receipts past the logged results are matched in order by call and input; one that cannot be matched stays uncertain.
        let logged = stem.part.log.reduce(0) { count, row in
            guard case .object(let entry) = row, case .object(let event)? = entry["event"], event["type"] == .string("result"),
                  case .string(let name)? = event["name"], !ToolCallParser.isIgnorableToolName(name) else { return count }
            return count + 1
        }
        // The receipt keeps the door's form (`app {action, args}`), the part its call's (`action {args}`): compare them as one.
        func shape(_ name: String, _ input: [String: JSONValue]) -> JSONValue {
            let input = input.filter { !$0.key.hasPrefix("__") }
            if name == "app", case .string(let action)? = input["action"], input.keys.allSatisfy({ ["action", "args"].contains($0) }) {
                return .object(["name": .string(action), "input": input["args"] ?? .object([:])])
            }
            return .object(["name": .string(name), "input": .object(input)])
        }
        var landed = stem.tally.dispatches.dropFirst(logged).map { shape($0.name, $0.input) }
        let uncertain = stem.part.uncertain.filter { call in
            guard case .object(let fields) = call, case .string(let name)? = fields["name"], case .object(let input)? = fields["input"],
                  let at = landed.firstIndex(of: shape(name, input)) else { return true }
            landed.remove(at: at)
            return false
        }
        let runningLanded = !stem.part.uncertain.isEmpty && uncertain.isEmpty
        let resumed = TurnObservation.Kind.restarted(stepsDone: receipts.count,
            unknownStep: restarted.runningStep == nil || runningLanded ? nil : receipts.count + 1,
            started: uncertain.map { call in
                guard case .object(let fields) = call, case .string(let name)? = fields["name"] else { return "a call" }
                let input = (try? ChatSecretRedactor.redactValue(fields["input"] ?? .object([:])).serialize(pretty: false)) ?? "{}"
                return name + " " + String(input.prefix(400))
            })
        TurnObservation.apply(resumed, kept: restarted.keptProse, to: &stem.wire.conversation, surface: stem.surface, turn: stem.turn)
        // Reuse the history projection, without inventing provider call IDs.
        let receiptText = replay.messages.dropFirst().flatMap(\.content).compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n\n")
        Self.appendStructuredUserNudge(receiptText, to: &stem.wire.conversation)
        for reading in try stem.part.arrivalReadings() { ConversationPrefixSeeding.appendUser(reading, to: &stem.wire.conversation) }
        if !stem.voice.visibleText.isEmpty { await live(stem, stem.voice.visibleText) }
        if !stem.part.answered.isEmpty { await live(stem, stem.part.answered) }
        if !stem.owed.replayedArrivals.isEmpty { stem.voice.spoken = false }
        if inFlight {
            var event: [String: JSONValue] = ["type": .string("resumed"),
                "text": .string(TurnObservation.text(resumed)), "steps": .int(Int64(receipts.count))]
            // Saved receipts retain landed effects even when relaunch lost the result event.
            event["effect"] = Self.landedEffect(.object(["receipts": .array(stem.tally.dispatches.map(\.result))])).map(JSONValue.string)
            try await stem.part.deliver([.object(event)])
        }
    }

    func commitDelivery(_ stem: TurnStem) async throws {
        if !stem.owed.familiarOwed.isEmpty, let root = remPinsDataRoot {
            let lines = stem.owed.familiarOwed
            stem.owed.familiarOwed = []
            do { try FamiliarLines.firstMet(lines, dataRoot: root) }
            catch { _ = familiarityFailure(error, root: root, turn: stem.turn) }
        }
        if stem.tally.providerCallCount > 0 {
            if let acknowledge = stem.owed.commitPartsDelivery {
                stem.owed.commitPartsDelivery = nil
                acknowledge(Self.deliveredInput(stem.wire.resolvedTurnContext))
            }
            try await stem.owed.commitInstructionDelivery?()
            stem.owed.commitInstructionDelivery = nil
            if stem.owed.contextDeliveryOwed {
                stem.owed.contextDeliveryOwed = false
                stem.owed.cognitiveContextDelivered = stem.wire.resolvedTurnContext.cognitiveRuntimeContext
                    .map { Self.deliveredInput(stem.wire.resolvedTurnContext).contains($0) } == true
                await stem.wire.resolvedTurnContext.fluidContextTurn?.recordDelivery()
                await stem.onDelivery?()
                creditDeliveredMemories(stem.wire.resolvedTurnContext)
                await announceDeliveredArrivals(in: stem.wire.resolvedTurnContext, sessionID: stem.sessionId)
            }
        }
        guard let sessionId = stem.sessionId else { return }
        if !stem.owed.replayedArrivals.isEmpty {
            guard await ChatTurnSteering.shared.markReplayedDelivered(stem.owed.replayedArrivals, sessionId: sessionId) else {
                throw ChatOrchestrationError.underlying("Couldn't commit replayed arrival delivery; its reading remains owed.")
            }
            stem.owed.replayedArrivals = []
        }
        guard !stem.owed.steeringOffers.isEmpty else { return }
        let offers = stem.owed.steeringOffers
        stem.owed.steeringOffers = []
        guard await ChatTurnSteering.shared.markDelivered(offers, sessionId: sessionId) else {
            throw ChatOrchestrationError.underlying("Couldn't commit steering delivery; the message runs as its own turn.")
        }
    }
}
