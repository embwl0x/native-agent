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
// Blueprint: | `TurnStem+ModelRound.swift` | `ModelRound`; `SwiftNativeTurnEngine`: `modelRound` (one model round: its request, its stream, a failed stream's recovery, and the settled round); `provider.roundOutput` counts safe prose and tool calls per parsed round; round-scoped OAuth provider-event capture through the existing cutoff writer for suspicious cleaned replies and malformed streams |

/// One model round's own state, from its request to its settlement.
final class ModelRound: ModelRoundKernel.Stream {
    var iterEmittedProse = ""
    var streamedCalls: [ParsedToolCall] = []
    /// The provider yielded text or a call this round; set as it arrives, before any cleanup.
    var emitted = false
    var toolBoundaryReason: LLMToolBoundaryReason?
    var arrivalCut = false
    var closeClass: String?
    var closeOutcome: String?
    /// The turn already said something visible, to anyone, and the round before this one landed every call with nothing waiting: an empty answer here is the turn ending.
    var spokeAndLanded = false

    final class ProviderEvents: Sendable {
        let raw = Mutex("")
    }
    let providerEvents = ProviderEvents()
    let roundBaseVisibleText: String

    init(roundBaseVisibleText: String) {
        self.roundBaseVisibleText = roundBaseVisibleText
    }

    func allowsSilence(_ call: LLMCall) -> Bool { call.allowsSilentCompletion || closeClass != nil || spokeAndLanded }
}

extension SwiftNativeTurnEngine {
    /// One round's words after the earlier rounds', with the paragraph break the live stream shows between them.
    static func paragraphJoined(_ base: String, _ next: String) -> String {
        guard let last = base.last, !last.isNewline, let first = next.first, !first.isNewline else { return base + next }
        return base + "\n\n" + next
    }

    func modelRound(_ stem: TurnStem, _ effect: [String: JSONValue], closeClass: String?) async throws {
        if Task.isCancelled || ChatCancelFlag.isRaised(stem.cancelFlagPath) { throw stem.stopCarryingPartial() }
        if stem.voice.replyTextSettled {
            stem.voice.replyTextSettled = false
            await stem.progress?(.replyTextSettled(false))
        }
        let round = ModelRound(roundBaseVisibleText: stem.voice.visibleText)
        round.closeClass = closeClass
        round.spokeAndLanded = effect["purpose"] == .string("tool_round") && stem.voice.visibleText.contains(where: { !$0.isWhitespace })
            && !stem.tally.previousRoundFailed
            && stem.turn.execution?.waitingForApproval != true && stem.turn.execution?.waitingInteraction == nil
        stem.voice.liveBreakOwed = true
        stem.voice.liveInAuthoredReply = false

        do {
            try await runModelRound(stem, round, effect)
        } catch {
            await recordCloseOutcome(stem, round)
            throw error
        }
        await recordCloseOutcome(stem, round)
    }

    private func runModelRound(_ stem: TurnStem, _ round: ModelRound, _ effect: [String: JSONValue]) async throws {
        do { try await stem.providerAdmission?() }
        catch is CancellationError { throw stem.stopCarryingPartial() }
        do {
            let wire = try await prepareRequest(stem, round)
            try await streamRound(stem, round, effect, wire: wire)
        } catch {
            guard try await roundFailed(stem, round, error) else { return }
        }
        try await settleRound(stem, round)
    }

    private func recordCloseOutcome(_ stem: TurnStem, _ round: ModelRound) async {
        guard let subject = round.closeClass, let root = stem.dataRoot else { return }
        let spoken = round.iterEmittedProse.contains { !$0.isWhitespace }
        guard let outcome = round.closeOutcome ?? (spoken ? "yielded" : nil) else { return }
        let turnID = stem.turn.id
        await ExperienceStore.record(root, turnID) { store in
            let row = try JSONValue.object(["outcome": .string(outcome)]).serializedData(pretty: false)
            try await store.note([.init(source: "mind", at: Date(), subject: subject,
                kind: "close", row: row, once: "close|" + turnID)], durable: true)
        }.value
    }

    // Only prose can survive an incomplete stream; none of its calls ran.
    private func keepPartial(_ stem: TurnStem, _ round: ModelRound) async -> String {
        var kept: String
        if round.arrivalCut {
            let tail = stem.toolCallCodec.visiblePrefix(in: round.pendingProtocolDelta)
            kept = round.iterEmittedProse + String(tail.dropLast(ToolCallCodec.markerPrefixTailLength(tail)))
        } else {
            kept = round.toolBoundaryReason == .fabricatedResult
                ? round.iterEmittedProse : round.visiblePartial(stem.toolCallCodec)
        }
        // Words the person cut off read as cut off: the sentence stops visibly before the agent's answer.
        if round.arrivalCut, let last = kept.last(where: { !$0.isWhitespace }), !".!?…:".contains(last) {
            kept = String(kept[..<(kept.lastIndex { !$0.isWhitespace }.map { kept.index(after: $0) } ?? kept.endIndex)]) + "…"
        }
        if kept.hasPrefix(round.iterEmittedProse) {
            let tail = String(kept.dropFirst(round.iterEmittedProse.count))
            if !tail.isEmpty {
                await live(stem, tail)
                round.iterEmittedProse += tail
            }
        }
        stem.voice.visibleText = Self.paragraphJoined(round.roundBaseVisibleText, kept)
        // Words a cut stopped are working, not the answer: they fold above the reply that answers the person.
        stem.voice.retainProse(kept, commentary: round.arrivalCut)
        round.streamedCalls.removeAll(keepingCapacity: true)
        round.pendingProtocolDelta.removeAll(keepingCapacity: true)
        return kept
    }

    private func prepareRequest(_ stem: TurnStem, _ round: ModelRound) async throws -> [LLMMessage] {
        // Every step after the first carries what changed in the agent elsewhere since its last one, after its reply too.
        if stem.tally.providerCallCount > 0, let sessionId = stem.sessionId, !sessionId.isEmpty, let root = remPinsDataRoot, let cursor = stem.owed.agentNow {
            let at = Date()
            let peer = !stem.turn.steeringStamp().isEmpty
            if try peer || Self.personContinuityAllowed(root: root, sessionID: sessionId, turn: stem.turn) {
                let breath = await ChatWorkspaceBinding.breath(turn: stem.turn, dataRoot: root, scope: sessionId,
                    peer: peer, since: cursor.at, shown: stem.owed.breathActs, at: at)
                // A read window is new evidence even when it renders alike; only a failed reading's repeat is withheld. Acts are shown once by id.
                if let text = breath.text, breath.read || text != stem.owed.lastBreath {
                    Self.appendStructuredUserNudge(text, to: &stem.wire.conversation)
                    stem.owed.lastBreath = text
                    stem.owed.breathActs.formUnion(breath.acts)
                }
                if breath.read { stem.owed.agentNow = AgentNowCursor(at: at) }
            }
        }
        if try await readArrivals(stem) { round.closeClass = nil }
        if stem.sessionId != nil, !(stem.work.prefixTelemetry?.marksRequestShapeUnmeasured == true) {
            let additional = try ConversationPrefixSeeding.additionalMessages(in: stem.wire.conversation, after: stem.wire.prefixSeed)
            if stem.tally.providerCallCount == 0 {
                stem.tally.openingAdditionalCharacters = LLMMessage.inputCharacters(additional, system: nil, tools: [])
            }
            if let fit = stem.work.fit {
                await stem.wire.bookkeeping.value
                let encoded = try stem.toolCallCodec.providerMessages(
                    additional, records: stem.tally.dispatches, schemas: stem.wire.ctx.toolSchemas, turn: stem.turn)
                let fitted = try await fit(stem.wire.resolvedTurnContext, stem.toolCallCodec, encoded)
                let changed = fitted.historyContextWindow != stem.wire.resolvedTurnContext.historyContextWindow
                stem.wire.resolvedTurnContext = fitted
                if changed {
                    try stem.wire.reseed(keeping: additional, afterToolRound: stem.tally.counters.toolRoundCount > 0, turn: stem.turn,
                        codec: stem.toolCallCodec, prefixSink: stem.prefixSink, surface: stem.surface, sessionId: stem.sessionId,
                        runId: stem.runId, replacementUserMessageID: stem.replacementUserMessageID, dataRoot: stem.dataRoot)
                }
            }
        }
        let fittedWire: [LLMMessage]
        do {
            guard let root = remPinsDataRoot else {
                throw ProviderRoutingError.configurationFailed("The turn's request measurement owner is unavailable.")
            }
            let owner = stem.sessionId ?? stem.runId ?? stem.turn.id
            let fitted = try await ModelRoundKernel.fitAndMeasure(stem.wire.conversation, codec: stem.toolCallCodec,
                records: stem.tally.dispatches, context: stem.wire.ctx, system: stem.wire.wireSystem.prompt,
                tools: stem.toolCallCodec.requestTools(stem.wire.providerTools.schemas), window: stem.turnWindowTokens,
                root: root, surface: stem.surface, session: stem.sessionId, owner: owner, turn: stem.turn,
                call: stem.call.with(\.turn, stem.turn))
            stem.wire.conversation = fitted.conversation
            fittedWire = fitted.wire
        }
        // Publish only the fitted opening request actually passed to `streamMessages`, after opening reads and tail fitting.
        if stem.tally.providerCallCount == 0 {
            let snapshotRequest = try ConversationPrefixSeeding.Request(seed: stem.wire.prefixSeed,
                system: stem.wire.wireSystem.prompt, segments: stem.wire.wireSystem.segments,
                tools: stem.toolCallCodec.requestTools(stem.wire.providerTools.schemas))
            let publication = remPinsDataRoot.flatMap { root in
                stem.sessionId.map { ContextFedRecord.begin(sessionId: $0, dataRoot: root) }
            }
            let prefixSink = stem.prefixSink, surface = stem.surface, sessionId = stem.sessionId, runId = stem.runId, turn = stem.turn
            let preceding = stem.wire.bookkeeping
            stem.wire.bookkeeping = Task {
                await preceding.value
                await Self.recordWireSnapshot(request: snapshotRequest, messages: fittedWire,
                    publication: publication, prefix: prefixSink?.current,
                    surface: surface, sessionId: sessionId, runId: runId, turn: turn)
            }
        }
        try await capture(stem, turn: stem.turn, work: stem.work)
        stem.tally.providerCallCount += 1
        stem.tally.counters.providerAttemptCount += 1
        stem.tally.counters.providerRoundCount += 1
        if stem.tally.previousRoundFailed { stem.tally.counters.roundsAfterToolFailureCount += 1 }
        stem.tally.previousRoundFailed = false
        return fittedWire
    }

    private func streamRound(_ stem: TurnStem, _ round: ModelRound, _ effect: [String: JSONValue], wire: [LLMMessage]) async throws {
        // Construction and consumption share the async task-local scope.
        let providerRoute = stem.wire.ctx.providerId ?? stem.turn.admission?.provider
        let serviceTier = stem.wire.ctx.serviceTier ?? stem.turn.admission?.serviceTier
        let purpose: String
        if stem.call.purpose == "other", case .string(let named)? = effect["purpose"] { purpose = named }
        else { purpose = stem.call.purpose }
        let events = round.providerEvents
        let captureEvents: @Sendable (SSEEvent) -> Void = { event in
            guard providerRoute == "anthropic_oauth_direct" else { return }
            events.raw.withLock { raw in
                if let name = event.event { raw += "event: \(name)\n" }
                raw += "data: " + event.data.replacingOccurrences(of: "\n", with: "\ndata: ") + "\n\n"
            }
        }
        let requestPlan: Data?
        // A plan names the saved user row it is rebuilt from; a hidden input has none.
        if stem.call.conversationRequest, !(stem.work.prefixTelemetry?.marksRequestShapeUnmeasured == true),
           stem.turn.rows.hiddenInput == nil, let runId = stem.runId, stem.sessionId != nil {
            requestPlan = try ConversationPrefixSeeding.Request(seed: stem.wire.prefixSeed,
                system: stem.wire.wireSystem.prompt, segments: stem.wire.wireSystem.segments,
                tools: stem.toolCallCodec.requestTools(stem.wire.providerTools.schemas))
                .plan(runID: stem.turn.rows.questionRunID ?? runId, userMessageID: stem.replacementUserMessageID,
                    additionalCharacters: stem.tally.openingAdditionalCharacters).encoded
        } else { requestPlan = nil }
        let consumeStream: (Turn, LLMCall) async throws -> Void = { [self] turn, call in
            try await ProviderStreamContext.$diagnosticEvent.withValue(captureEvents) {
            try await holding(call.with(\.lifetime.dispatched, stem.requestDispatched)) { call in
            try await holding(call.with(\.purpose, purpose)) { call in
            try await holding(call.with(\.requestPlan, requestPlan)) { call in
            let arrivals = if let sessionId = stem.sessionId {
                await ChatTurnSteering.shared.arrivals(sessionId: sessionId)
            } else { AsyncStream<ChatTurnSteering.Offer> { $0.finish() } }
            round.arrivalCut = try await ModelRoundKernel.streamRound(llm: stem.llm,
                messages: wire, system: stem.wire.wireSystem.prompt,
                model: stem.wire.ctx.modelId, tools: stem.toolCallCodec.requestTools(stem.wire.providerTools.schemas),
                call: call.with(\.turn, turn), codec: stem.toolCallCodec, round: round, stop: stem.cancelFlagPath,
                hearing: (arrivals, { offer in
                    guard let sessionId = stem.sessionId,
                          await ChatTurnSteering.shared.canHear(offer, sessionId: sessionId, run: turn.run),
                          try await stem.part.hear(offer) else { return false }
                    return await ChatTurnSteering.shared.canHear(offer, sessionId: sessionId, run: turn.run)
                })) { event, safe in
                switch event {
                case .toolBoundary(let reason):
                    round.toolBoundaryReason = reason
                case .replyTextSettled(let settled):
                    if settled {
                        let prose = stem.toolCallCodec.proseReleasedAtDispatch(round.pendingProtocolDelta)
                        if !prose.isEmpty {
                            round.iterEmittedProse += prose
                            await live(stem, prose)
                        }
                        round.pendingProtocolDelta.removeAll(keepingCapacity: true)
                    }
                    stem.voice.replyTextSettled = settled
                    await stem.progress?(.replyTextSettled(settled))
                case .textDelta(let delta):
                    if !delta.isEmpty {
                        round.emitted = true
                        try await commitDelivery(stem)
                        if !stem.voice.emittedProviderFirstDelta {
                            stem.voice.emittedProviderFirstDelta = true
                            TurnLifecycleTelemetry.emit(
                                .providerFirstDelta, surface: stem.surface, sessionId: stem.sessionId,
                                observedBy: "structured_tool_loop.stream", turn: turn)
                        }
                    }
                    // A new round's words start a new paragraph, as the live stream shows them, so a stopped reply saves them apart.
                    if round.iterAccumulated.utf8.count == delta.utf8.count { stem.voice.visibleText = Self.paragraphJoined(round.roundBaseVisibleText, delta) }
                    else { stem.voice.visibleText += delta }
                    if !safe.isEmpty {
                        round.iterEmittedProse += safe
                        await live(stem, safe)
                        await moved(stem, nil, words: true, turn: turn)
                    } else if !delta.isEmpty {
                        // Held text is a call being written as words: the card names it and counts it, as a native call's input does.
                        // Read at most once a second, when a tick is due.
                        let due = stem.voice.lastMovement.map { ContinuousClock.now - $0 >= .seconds(1) } ?? true
                        let written = due ? ToolCallParser.callBeingWritten(in: round.pendingProtocolDelta) : nil
                        await moved(stem, written.map { LLMStreamCallInput(name: $0.name, input: $0.input.utf8) }, turn: turn)
                    }
                case .toolCall(let call):
                    round.emitted = true
                    try await commitDelivery(stem)
                    await moved(stem, nil, turn: turn)
                    guard let parsed = try stem.toolCallCodec.decode(call) else { return }
                    round.streamedCalls.append(parsed)
                case .keepAlive:
                    await moved(stem, nil, turn: turn)
                case .callInput(let input):
                    await moved(stem, input, turn: turn)
                }
            }
            }
            }
            }
            }
        }
        var requestCall = stem.call
        let requestTurn = stem.turn.admitting(model: .some(stem.wire.ctx.modelId), provider: .some(providerRoute),
            reasoningEffort: .some(stem.wire.ctx.reasoningEffort), serviceTier: .some(serviceTier))
        requestCall.allowsSilentCompletion = round.allowsSilence(requestCall)
        requestCall.turn = requestTurn
        requestCall.currentUserIndex = try stem.wire.prefixSeed.currentUserIndex
        requestCall.systemSegments = stem.wire.wireSystem.segments
        requestCall.session = stem.sessionId
        requestCall.withinTurnReuse = true
        requestCall.prefixMeasurement = stem.work.prefixTelemetry
        let progress = stem.progress
        requestCall.lifetime.status = { kind, text in
            await progress?(.notice(kind: kind, text: text))
        }
        requestCall.inspectorThinkingSummarized = InspectorThinkingLane.isEnabledForSurface(stem.surface)
        try await LLMCallTraceRecorder.$spent.withValue(stem.tally.spent) {
            try await consumeStream(requestTurn, requestCall)
        }
    }

    /// A failed stream either stops the turn (throws), goes on to settle what it kept (true), or ends this round (false).
    private func roundFailed(_ stem: TurnStem, _ round: ModelRound, _ error: Error) async throws -> Bool {
        if Task.isCancelled || ChatCancelFlag.isRaised(stem.cancelFlagPath) || error is CancellationError {
            throw stem.stopCarryingPartial()
        }
        if let failure = error as? ToolFailureError,
           failure.code == "context_window_exceeded" {
            // A local admission refusal is terminal for this request;
            // provider-overflow recovery must never truncate around it.
            throw failure
        }
        if stem.sessionId != nil, !(stem.work.prefixTelemetry?.marksRequestShapeUnmeasured == true),
           ProviderRecoveryPolicy.isContextOverflow(error) {
            throw ToolFailureError("""
                The provider refused this request's context window after fitting: \(error.localizedDescription). Retained history was not \
                truncated. Repair the model-window/token measurement or reduce the current input before continuing.
                """,
                effects: .none, owner: stem.wire.ctx.modelId, code: "context_window_exceeded", status: .refused, recovery: .repair)
        }
        if ProviderFailure.classify(error) == .malformedResponse {
            let raw = round.providerEvents.raw.withLock { $0 }
            if !raw.isEmpty { ProviderOutputDiagnostics.writeDiagnostic(raw, reason: "malformed_stream", dataRoot: remPinsDataRoot, call: stem.call) }
        }
        stem.tally.counters.failedProviderAttemptCount += 1
        // A spent budget's partial is the whole run's ledger, not this round's words.
        if round.iterAccumulated.isEmpty, case .outputLengthLimit(let partial) = error as? LLMError,
           stem.turn.tokenBudget?.exhausted != true {
            round.iterAccumulated = partial
        }
        if error is ProviderRecovery.Stopped,
           try stem.toolCallCodec.roundCalls(streamed: round.streamedCalls, text: round.iterAccumulated, schemas: stem.wire.ctx.toolSchemas,
               recordShims: false, turn: stem.turn).isEmpty {
            _ = await keepPartial(stem, round)
            throw TurnEngineError.streamInterrupted(partial: stem.voice.visibleText, underlying: error)
        }
        // A stream cut preserves complete calls for dispatch and continues after retained prose.
        if ProviderRecoveryPolicy.isRecoverable(error),
           try !stem.toolCallCodec.roundCalls(streamed: round.streamedCalls, text: round.iterAccumulated, schemas: stem.wire.ctx.toolSchemas, recordShims: false, turn: stem.turn)
               .isEmpty
            || !round.visiblePartial(stem.toolCallCodec).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            round.toolBoundaryReason = .interrupted
            return true
        }
        let kept = await keepPartial(stem, round)
        if case .outputLengthLimit = error as? LLMError,
           stem.turn.tokenBudget?.exhausted == true {
            try await budgetSpent(stem, emitted: round.emitted, turn: stem.turn)
        } else if ProviderRecoveryPolicy.isContextOverflow(error) {
            try await providerFailed(stem, error, emitted: round.emitted, turn: stem.turn)
        } else if case .outputLengthLimit = error as? LLMError {
            try await observe(stem, .lengthLimit(chars: kept.count), kept: kept)
        } else {
            try await providerFailed(stem, error, emitted: round.emitted, turn: stem.turn)
        }
        return false
    }

    private func settleRound(_ stem: TurnStem, _ round: ModelRound) async throws {
        if round.arrivalCut {
            // A cut dispatches nothing, even a complete proposal.
            let kept = await keepPartial(stem, round)
            stem.wire.keep(prose: kept)
            try await capture(stem, turn: stem.turn, work: stem.work)
            let read = try await readArrivals(stem)
            try await observe(stem, .cut(arrivalRead: read))
            try await capture(stem, turn: stem.turn, work: stem.work)
            TurnTraceBus.fireFromContext(kind: "provider.roundCut", surface: stem.surface, payload: .object([
                "round": .int(Int64(stem.tally.providerCallCount)), "proseCharacters": .int(Int64(kept.count)),
                "arrivalRead": .bool(read), "effects": .string("none"),
            ]), turn: stem.turn)
            return
        }
        stem.tally.providerFailurePending = stem.turn.providerRecovery?.stopped != nil
        let iterProse = ToolCallParser.stripProtocolDebris(round.iterAccumulated)
        func saveSuspiciousReply() {
            let visible = iterProse.trimmingCharacters(in: .whitespacesAndNewlines)
            guard visible.split(whereSeparator: { $0.isWhitespace }).count < 2
                || (visible.count < 12 && iterProse.contains(where: { "<=>".contains($0) })) else { return }
            let raw = round.providerEvents.raw.withLock { $0 }
            if !raw.isEmpty { ProviderOutputDiagnostics.writeDiagnostic(raw, reason: "suspicious_reply", dataRoot: remPinsDataRoot, call: stem.call) }
        }
        let allowsSilence = round.allowsSilence(stem.call)
        if !allowsSilence, round.toolBoundaryReason == nil,
           round.streamedCalls.isEmpty && !iterProse.contains(where: { !$0.isWhitespace }) {
            saveSuspiciousReply()
            stem.voice.visibleText = round.roundBaseVisibleText
            stem.tally.counters.emptyReplyRoundCount += 1
            try await providerFailed(stem, ProviderFailure.Diagnostic(cause: .malformedResponse,
                detail: "The provider completed without an answer or a tool call."), emitted: round.emitted, turn: stem.turn)
            return
        }
        if allowsSilence, round.streamedCalls.isEmpty, !iterProse.contains(where: { !$0.isWhitespace }) {
            try await commitDelivery(stem)
        }
        let markerCodec = stem.toolCallCodec == .textMarkers
            ? TextMarkerCodec(schemas: stem.wire.ctx.toolSchemas,
                turnActiveTools: stem.turn.offeredTools ?? [], catalogNames: Set(stem.wire.ctx.toolsAvailable), turn: stem.turn)
            : nil
        let violation: ToolCallProtocolViolation?
        if let markerCodec {
            violation = markerCodec.malformedCall(in: iterProse)
        } else {
            violation = ToolCallParser.formattedToolCallViolation(in: iterProse, toolNames: Set(stem.wire.ctx.toolsAvailable))
        }
        if let violation {
            stem.tally.counters.protocolViolationRoundCount += 1
            let rejectedBytes = Data(round.iterAccumulated.utf8)
            var diagnostic: [String: JSONValue] = [
                "type": .string(violation.traceType),
                "byteSize": .int(Int64(rejectedBytes.count)),
                "sha256": .string(SHA256Hex.of(rejectedBytes)),
            ]
            do {
                if let file = try ProviderOutputDiagnostics.writeDiagnostic(round.iterAccumulated, reason: violation.traceType,
                    dataRoot: remPinsDataRoot, call: stem.call)
                    .get() {
                    diagnostic["path"] = .string(file.path)
                }
            } catch { diagnostic["file_error"] = .string(error.localizedDescription) }
            TurnTraceBus.fireFromContext(kind: "tool.protocol_violation", surface: stem.surface, payload: .object(diagnostic), turn: stem.turn)
            let kept = await keepPartial(stem, round)
            try await observe(stem, .malformedCall(why: violation.modelFeedback), kept: kept)
            return
        }
        let providerCalls = try stem.toolCallCodec.roundCalls(
            streamed: round.streamedCalls, text: round.iterAccumulated, schemas: stem.wire.ctx.toolSchemas, turn: stem.turn)
        // Counts only: distinguish a silent tool round from words
        // delivered before tools, without retaining provider text.
        let roundTail = providerCalls.isEmpty
            ? stem.toolCallCodec.visiblePrefix(in: round.pendingProtocolDelta)
            : (round.toolBoundaryReason == .fabricatedResult ? "" : stem.toolCallCodec.proseReleasedAtDispatch(round.pendingProtocolDelta))
        let roundProse = (round.iterEmittedProse + roundTail).trimmingCharacters(in: .whitespacesAndNewlines)
        TurnTraceBus.fireFromContext(kind: "provider.roundOutput", surface: stem.surface, payload: .object([
            "round": .int(Int64(stem.tally.providerCallCount)),
            "proseCharacters": .int(Int64(roundProse.count)),
            "toolCallCount": .int(Int64(providerCalls.count)),
        ]), turn: stem.turn)
        if !providerCalls.isEmpty || !roundProse.isEmpty { round.closeOutcome = "yielded" }
        else if round.toolBoundaryReason == nil { round.closeOutcome = "empty" }
        if providerCalls.isEmpty {
            saveSuspiciousReply()
            if let toolBoundaryReason = round.toolBoundaryReason {
                let kept = await keepPartial(stem, round)
                if toolBoundaryReason == .outputLimit, stem.turn.tokenBudget?.exhausted == true {
                    try await budgetSpent(stem, emitted: round.emitted, turn: stem.turn)
                } else {
                    try await observe(stem, .boundary(toolBoundaryReason), kept: kept)
                }
                return
            }
            if !round.pendingProtocolDelta.isEmpty {
                await live(stem, stem.toolCallCodec.visiblePrefix(in: round.pendingProtocolDelta))
            }
            // The agent's answer stays in the conversation for whatever the agent's part does next.
            stem.wire.keep(prose: iterProse)
            if try await readArrivals(stem) {
                // Retain the completed answer before any prose the arrival's next round produces.
                stem.voice.retainProse(iterProse)
                try await observe(stem, .arrival)
                return
            }
            var event: [String: JSONValue] = ["type": .string("model"), "text": .string(iterProse), "calls": .array([])]
            event["reflect"] = await reflectionReading(stem, closing: iterProse)
            try await stem.part.deliver([.object(event)])
            return
        }

        let pendingProse = round.toolBoundaryReason == .fabricatedResult
            ? "" : stem.toolCallCodec.proseReleasedAtDispatch(round.pendingProtocolDelta)
        if !pendingProse.isEmpty {
            round.iterEmittedProse += pendingProse
            await live(stem, pendingProse)
        }
        stem.voice.visibleText = Self.paragraphJoined(round.roundBaseVisibleText, round.iterEmittedProse)
        stem.voice.retainProse(round.iterEmittedProse, commentary: true)
        if let sessionId = stem.sessionId, ChatTurnSteering.hasPersonWaiting(sessionId), try await readArrivals(stem, keeping: round.iterEmittedProse) {
            stem.tally.round = nil
            try await observe(stem, .arrival, unstarted: providerCalls)
            return
        }
        stem.tally.round = (providerCalls, stem.toolCallCodec == .textMarkers ? round.iterAccumulated : round.iterEmittedProse, markerCodec, round.toolBoundaryReason)
        let made = providerCalls.map { JSONValue.object(["name": .string($0.name), "input": .object($0.input)]) }
        stem.tally.repeated = made == stem.tally.repeated.calls ? (made, stem.tally.repeated.call, stem.tally.repeated.count + 1) : (made, providerCalls.map { call in
            if case .string(let action)? = call.input["action"] { action } else { call.name }
        }.joined(separator: ", "), 1)
        if stem.tally.repeated.count > stem.tally.longest.count { stem.tally.longest = (stem.tally.repeated.call, stem.tally.repeated.count) }
        try await stem.part.deliver([.object(["type": .string("model"), "text": .string(round.iterEmittedProse),
            "calls": .array(providerCalls.enumerated().map {
                .object(["index": .int(Int64($0.offset)), "id": .string($0.element.id), "name": .string($0.element.name),
                         "input": .object($0.element.input)])
            })])])
    }

    /// Every provider byte is movement, ticked at most once a second for every door's card; this door's own words show themselves.
    func moved(_ stem: TurnStem, _ input: LLMStreamCallInput?, words: Bool = false, turn: Turn) async {
        let now = ContinuousClock.now
        if let last = stem.voice.lastMovement, now - last < .seconds(1) { return }
        stem.voice.lastMovement = now
        let writing = input.map(TurnCallWriting.init(streaming:))
        var tick: [String: JSONValue] = [:]
        if let writing { tick = ["call": .string(writing.call), "bytes": .int(Int64(writing.bytes))] }
        TurnTraceBus.fireFromContext(kind: "stream.tick", payload: .object(tick), turn: turn)
        if !words { await stem.progress?(.writing(writing)) }
    }
}
