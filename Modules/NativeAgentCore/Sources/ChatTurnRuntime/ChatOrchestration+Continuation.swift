import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Transcripts
import TurnTrace
import ProviderRouting

public enum TurnCheckpointScope {
    @TaskLocal public static var resuming: TurnCheckpoint?
    @TaskLocal static var current: TurnCheckpointWriter?
    @TaskLocal static var resumedRows: [ChatMessage] = []
}

/// Serialized with receipts so a checkpoint never claims an unrecorded effect finished.
actor TurnCheckpointWriter {
    private var record: TurnCheckpoint
    private let dataRoot: URL
    private var pendingCalls = 0

    init(record: TurnCheckpoint, dataRoot: URL) {
        self.record = record
        self.dataRoot = dataRoot
        pendingCalls = record.runningStep == nil ? 0 : 1
    }

    func capture(prose: String, commentaryCharacters: Int, conversation: [LLMMessage],
                 startingCalls: Int = 0, nextIteration: Bool = false) throws {
        if nextIteration { record.iteration += 1 }
        record.keptProse = prose
        record.workingCommentaryCharacters = commentaryCharacters
        record.workingNotes = conversation.flatMap(\.content).compactMap { block -> String? in
            guard case .text(let text) = block,
                  text.hasPrefix(IntraTurnContextCompaction.priorNoteMarker) else { return nil }
            return text
        }.joined(separator: "\n")
        pendingCalls += startingCalls
        record.runningStep = pendingCalls > 0 ? record.dispatchCount + 1 : nil
        record.peerSources = PeerDataTaint.current?.checkpointSources ?? record.peerSources
        try record.write(dataRoot: dataRoot)
    }

    func receiptWritten() throws {
        record.dispatchCount += 1
        pendingCalls = max(0, pendingCalls - 1)
        record.runningStep = pendingCalls > 0 ? record.dispatchCount + 1 : nil
        record.peerSources = PeerDataTaint.current?.checkpointSources ?? record.peerSources
        try record.write(dataRoot: dataRoot)
    }
}

extension SwiftNativeChatOrchestrationClient {
    func settleTurnCheckpoint(_ terminal: TurnTraceEvent, sessionId: String, runId: String) async throws {
        var checkpoints = try TurnCheckpoint.forSession(dataRoot: dataRoot, sessionId: sessionId)
            .filter { $0.runId == runId }
        for index in checkpoints.indices {
            if TurnCheckpointScope.resuming?.runId == runId,
               case .object(let payload) = terminal.payload, payload["status"] == .string("completed"),
               checkpoints[index].hasRedeliveryOwner {
                // Persist ownership before the terminal so a kill at either write remains resumable.
                checkpoints[index].deliveryPending = true
                try checkpoints[index].write(dataRoot: dataRoot)
            } else { checkpoints[index].deliveryPending = false }
        }
        try await turnTraceBus.deliverDurably(terminal)
        for checkpoint in checkpoints {
            if !checkpoint.deliveryPending { try checkpoint.remove(dataRoot: dataRoot) }
            if let scope = ProviderToolResultRecoveryStore.Scope(sessionId: sessionId, turnId: checkpoint.turnId) {
                await ProviderToolResultRecoveryStore.shared.remove(scope: scope)
            }
        }
    }

    public func resumeTurn(_ checkpoint: TurnCheckpoint, request: TurnRequest,
                           progress: ChatOrchestrationProgressHandler? = nil) async throws -> ChatResponse {
        let history = try await history.messagesWithStats(forSessionId: checkpoint.sessionId, strictEvidence: true)
        guard history.stats.malformedRowCount == 0, history.stats.invalidShapeRowCount == 0 else {
            throw ChatOrchestrationError.underlying("Repair this turn's transcript before resuming it.")
        }
        let rows = history.messages.filter { SessionHistoryPromptRenderer.renderable($0)?.runId == checkpoint.runId }
        for answer in rows.reversed() where answer.role == "assistant" {
            guard case .object(let fields)? = answer.extras, case .object(let metadata)? = fields["metadata"],
                  metadata["turnTraceId"] == .string(checkpoint.turnId), metadata["completionState"] != nil,
                  let raw = metadata["outcomeObservation"], let outcome = ResponseOutcomeObservationV2(jsonValue: raw),
                  outcome.turnID == checkpoint.turnId, outcome.sessionID == checkpoint.sessionId,
                  fields["id"] == .string(outcome.messageID),
                  let model = outcome.providerModel, case .string(let status)? = metadata["terminalState"],
                  let state = TurnEngineResult.TerminalState(rawValue: status) else { continue }
            var response = ChatResponse(runId: checkpoint.runId, model: model, reasoningEffort: outcome.reasoningEffort,
                output: answer.content, sessionId: checkpoint.sessionId,
                attachments: try CodexCompletionTranscriptEvidence.decodeAttachments(metadata["attachments"]), terminalState: state)
            if case .int(let count)? = metadata["workingCommentaryChars"] { response.workingCommentaryCharacters = Int(count) }
            if state != .completed {
                response.runtimeStatus = state == .waiting ? "waiting on you" : state == .failed ? "failed" : "interrupted"
            }
            let reason: TurnEngineResult.TerminalReason = state == .completed ? .replyCompleted
                : state == .waiting ? .interactionRequired : state == .failed ? .executionFailed : .incomplete
            try await TurnCheckpointScope.$resuming.withValue(checkpoint) {
            try await settleTurnCheckpoint(TurnTraceEvent(turnId: checkpoint.turnId, kind: "turn.terminal",
                sessionId: checkpoint.sessionId, surface: checkpoint.surface, payload: .object([
                    "schema": .string("metacognition.observed.v1"), "status": .string(status),
                    "terminalReason": .string(reason.rawValue), "observedBy": .string("checkpoint_recovery")])),
                sessionId: checkpoint.sessionId, runId: checkpoint.runId)
            }
            return response
        }
        guard let user = rows.first(where: { $0.role == "user" }) else {
            throw ChatOrchestrationError.underlying("The resumed turn's saved user message is missing; repair its transcript.")
        }
        var request = request
        guard case .object(let fields)? = user.extras, case .object(let metadata)? = fields["metadata"] else {
            throw ChatOrchestrationError.underlying("The resumed turn's input metadata is missing; repair its transcript.")
        }
        if case .string(let persona)? = metadata["persona"] { request.persona = persona }
        request.attachments = try CodexCompletionTranscriptEvidence.decodeAttachments(metadata["attachments"])
        for index in request.attachments.indices {
            guard let path = request.attachments[index].path else {
                throw ChatOrchestrationError.underlying("The resumed turn's attachment has no saved file; restore it before resuming.")
            }
            request.attachments[index].base64 = try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
        }
        var record = checkpoint
        record.dispatchCount = rows.filter { SessionHistoryPromptRenderer.renderable($0)?.isTool == true }.count
        let sources = rows.flatMap { row -> [String] in
            guard case .object(let fields)? = row.extras, case .object(let metadata)? = fields["metadata"],
                  case .array(let saved)? = metadata["untrusted_sources"] else { return [] }
            return saved.compactMap { if case .string(let source) = $0 { return source }; return nil }
        }
        let taint = PeerDataTaint(restoring: (record.peerSources ?? []) + sources
            + (PeerDataTaint.current?.checkpointSources ?? []))
        return try await PeerDataTaint.$current.withValue(taint) {
        for row in rows {
            SwiftToolDispatcher.consumePersistedHistoryEvidence(row.extras ?? .null)
        }
        record.peerSources = taint.checkpointSources
        return try await TurnTraceContext.$turnId.withValue(record.turnId) {
        try await TurnCheckpointScope.$resuming.withValue(record) {
        try await TurnCheckpointScope.$resumedRows.withValue(rows) {
            if let bot = StandingBotContinuity.currentBot {
                return try await request.bind {
                    try await chat(message: request.message, sessionId: checkpoint.sessionId,
                        choice: ProviderTurnChoice.current, tokenLimit: bot.budget.tokens, surface: request.surface,
                        fileAccess: request.fileAccess, suppressUserAppend: true, mechanicalRow: .botReceipt,
                        progress: progress)
                }
            }
            return try await request.chat(on: self, progress: progress)
        }
        }
        }
        }
    }
}

extension SwiftNativeTurnEngine {
    public func executeTurnWithStreamingToolLoop(
        surface: String = "chat", userMessage: String, sessionId: String? = nil,
        toolSessionId: String? = nil, runId: String? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient, preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil,
        cancelFlagPath: URL? = nil, providerAdmission: (@Sendable () async throws -> Void)? = nil,
        fileAccess: String = "auto", capabilityProfile: String? = nil
    ) async throws -> TurnEngineResult {
        let saved: DeskContinuation?
        if remPinsDataRoot != nil, let runId, !runId.isEmpty {
            let envelope = TurnEnvelope.current(surface: surface)
            let metadata: [String: JSONValue]
            if case .object(let object) = envelope.persistedMetadata() { metadata = object }
            else { throw DeskContinuationError.unavailable }
            let route = ChatToolSessionContext.replyRoute ?? envelope.deliveryRoute
            var reply: [String: JSONValue] = ["surface": .string(route?.surface ?? surface)]
            for (key, value) in [("destinationId", route?.destinationId), ("threadId", route?.threadId),
                                 ("sourceKey", route?.sourceKey), ("replyTo", route?.replyTo),
                                 ("correlationId", route?.correlationId)] {
                if let value { reply[key] = .string(value) }
            }
            saved = DeskContinuation(runID: runId, sessionID: sessionId, surface: surface,
                    envelope: metadata, replyRoute: reply, remainingWork: userMessage, fileAccess: fileAccess,
                    peerSources: PeerDataTaint.current?.checkpointSources, capabilityProfile: capabilityProfile,
                    commandSignatureVerified: envelope.commandSignatureVerified, declaredRemote: envelope.declaredRemote,
                    helperDefinition: try StandingBotContinuity.currentBot.map { try JSONValue.fromEncodable($0) })
        } else { saved = nil }
        let journal: DeskContinuationTurn?
        if let current = DeskContinuationScope.current { journal = current }
        else if let root = remPinsDataRoot, let saved {
            journal = DeskContinuationTurn(store: SwiftNativeDeskStore(dataRoot: root), record: saved)
        } else { journal = nil }
        let ownsJournal = await journal?.snapshot().runID == runId
        let checkpoint: TurnCheckpointWriter?
        if let root = remPinsDataRoot, let saved, let sessionId, let turnId = TurnTraceContext.turnId {
            let restarted = TurnCheckpointScope.resuming.flatMap { $0.runId == runId && $0.turnId == turnId ? $0 : nil }
            let record = restarted ?? TurnCheckpoint(runId: saved.runID,
                turnId: turnId, sessionId: sessionId, surface: surface, userMessage: userMessage,
                envelope: saved.envelope, replyRoute: saved.replyRoute, fileAccess: saved.fileAccess,
                capabilityProfile: saved.capabilityProfile, peerSources: saved.peerSources,
                commandSignatureVerified: saved.commandSignatureVerified, declaredRemote: saved.declaredRemote,
                helperDefinition: saved.helperDefinition)
            checkpoint = TurnCheckpointWriter(record: record, dataRoot: root)
        } else { checkpoint = nil }
        return try await TurnCheckpointScope.$current.withValue(checkpoint) {
        return try await DeskContinuationScope.$current.withValue(journal) {
            do {
                let result = try await executeContinuationTurnBody(
                    surface: surface, userMessage: userMessage, sessionId: sessionId,
                    toolSessionId: toolSessionId, runId: runId,
                    llm: llm, tools: tools,
                    preBuiltContext: preBuiltContext, progress: progress,
                    cancelFlagPath: cancelFlagPath, providerAdmission: providerAdmission)
                let reason = result.terminalReason ?? .incomplete
                let state: DeskContinuation.State
                switch reason {
                case .replyCompleted: state = .complete
                case .cancelled: state = .canceled
                default: state = .blocked
                }
                // A successor publishes completion only together with its full
                // ChatResponse, including attachments, in the client owner.
                let checkpoint = await journal?.snapshot()
                let completingSuccessor = state == .complete && (checkpoint?.resumeCount ?? 0) > 0
                    && checkpoint?.pending.isEmpty == true
                if ownsJournal && !completingSuccessor {
                    try await journal?.finish(state: state, reply: result.reply, reason: reason.rawValue,
                        peerSources: PeerDataTaint.current?.checkpointSources)
                }
                return result
            } catch {
                let canceled = Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath)
                if ownsJournal {
                    try await journal?.finish(state: canceled ? .canceled : .ready, reply: "",
                        reason: canceled ? "canceled" : "turn_interrupted",
                        peerSources: PeerDataTaint.current?.checkpointSources)
                }
                throw error
            }
        }
        }
    }
}
