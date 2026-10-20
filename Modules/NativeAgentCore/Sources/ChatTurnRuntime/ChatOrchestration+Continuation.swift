import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Experiences
import Transcripts
import TurnTrace
import ProviderRouting
import Experiences

public enum TurnCheckpointScope {
    @TaskLocal public static var resuming: TurnCheckpoint?
    @TaskLocal static var current: TurnCheckpointWriter?
    @TaskLocal static var resumedRows: [ChatMessage] = []
}

/// Serialized with receipts so a checkpoint never claims an unrecorded effect finished.
/// A write that fails is the turn's receipt, never its end: it owes repair for
/// that session's checkpoints and the turn goes on; the next write that lands settles it.
actor TurnCheckpointWriter {
    private var record: TurnCheckpoint
    private let dataRoot: URL
    private var pendingCalls = 0
    private var owesSettle = true

    init(record: TurnCheckpoint, dataRoot: URL) {
        self.record = record
        self.dataRoot = dataRoot
        pendingCalls = record.runningStep == nil ? 0 : 1
    }

    func capture(prose: String, commentaryCharacters: Int, conversation: [LLMMessage], log: [JSONValue],
                 startingCalls: Int = 0) {
        record.log = log
        record.keptProse = prose
        record.workingCommentaryCharacters = commentaryCharacters
        record.workingNotes = conversation.flatMap(\.content).compactMap { block -> String? in
            guard case .text(let text) = block,
                  text.hasPrefix(IntraTurnContextCompaction.priorNoteMarker) else { return nil }
            return text
        }.joined(separator: "\n")
        pendingCalls += startingCalls
        record.runningStep = pendingCalls > 0 ? 1 : nil
        record.peerSources = PeerDataTaint.current?.checkpointSources ?? record.peerSources
        persist()
    }

    func receiptWritten() {
        pendingCalls = max(0, pendingCalls - 1)
        record.runningStep = pendingCalls > 0 ? 1 : nil
        record.peerSources = PeerDataTaint.current?.checkpointSources ?? record.peerSources
        persist()
    }

    private func persist() {
        if Self.persist(record, dataRoot: dataRoot) != nil { owesSettle = true; return }
        if owesSettle {
            RepairOwed.settle(dataRoot, operation: Self.operation(record),
                              evidence: .init(source: "chat/session_state", id: record.turnId))
            owesSettle = false
        }
    }

    private static func operation(_ record: TurnCheckpoint) -> String { "turn.checkpoint:" + record.sessionId }

    /// The one write of a turn's checkpoint. A failure owes repair naming the
    /// checkpoint and its cause, and returns those words for the turn to read.
    static func persist(_ record: TurnCheckpoint, dataRoot: URL) -> String? {
        do {
            try record.write(dataRoot: dataRoot)
            return nil
        } catch {
            let owner = "chat/session_state/\(record.sessionId)/turn-\(record.turnId).json"
            let words = "This turn's checkpoint was not written to \(owner): \(error.localizedDescription). "
                + "The turn runs; a relaunch before it finishes will not resume it."
            RepairOwed.owe(dataRoot, id: "turn-checkpoint:" + record.turnId, kind: .run,
                operation: operation(record), owner: owner, words: words)
            return words
        }
    }
}

extension SwiftNativeChatOrchestrationClient {
    public static func retainRequestedResult(dataRoot: URL, sessionId: String, runId: String, deliveryId: String) async throws {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId else { throw CocoaError(.fileReadInvalidFileName) }
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let read = try await persistence.readJSONLReporting(path)
            guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
                  read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var rows = read.rows
            guard let index = rows.lastIndex(where: { row in
                guard case .object(let fields) = row, fields["role"] == .string("assistant"),
                      case .object(let metadata)? = fields["metadata"] else { return false }
                return fields["runId"] == .string(runId) || metadata["answerFor"] == .string(deliveryId)
            }), case .object(var fields) = rows[index], case .object(var metadata)? = fields["metadata"],
                case .string(let savedRun)? = fields["runId"] else { throw CocoaError(.fileReadCorruptFile) }
            guard metadata["resultDelivery"] == nil else { return }
            metadata["resultDelivery"] = .object(["eventId": .string(deliveryId), "state": .string("pending"),
                "sessionId": .string(sessionId), "runId": .string(savedRun)])
            fields["metadata"] = .object(metadata)
            rows[index] = .object(fields)
            let text = try rows.map { try $0.serialize(pretty: false) }.joined(separator: "\n") + "\n"
            try await persistence.writeDataAtomicDurable(Data(text.utf8), to: path)
        }
    }

    /// The reply's door answered for it in the route journal's words:
    /// `completed` (the destination holds it) or `sent_unconfirmed` (the door
    /// gave up resending). The phone's `accepted_by_transport` is transport
    /// evidence only; no obligation is declared there to settle.
    /// The answer's `deliver:<surface>` settles before the checkpoint that owns
    /// its redelivery retires: a relaunch between them confirms again through
    /// the door's own ledger, which never resends. A write that fails is logged
    /// and never holds the checkpoint.
    public static func settleReplyCheckpoint(dataRoot: URL, sessionId: String, runId: String, verdict: String) async throws {
        for checkpoint in try replyCheckpoints(dataRoot: dataRoot, sessionId: sessionId, runId: runId).matching
            where checkpoint.deliveryPending {
            if let key = checkpoint.owedDelivery(status: "completed")?.key {
                let settle: ExperienceStore.Change? = switch verdict {
                case "completed": .obligation(key: key, phase: .accepted)
                case "sent_unconfirmed": .letGo(key: key, reason: .abandoned)
                default: nil
                }
                if let settle {
                    let answer = Experience.answer(run: runId)
                    await ExperienceStore.record(dataRoot, answer) { try await $0.append([settle], to: answer) }.value
                }
            }
            try checkpoint.remove(dataRoot: dataRoot)
        }
    }

    /// A damaged file may be this run's: its answer stays owed.
    public static func hasReplyCheckpoint(dataRoot: URL, sessionId: String, runId: String) throws -> Bool {
        let found = try replyCheckpoints(dataRoot: dataRoot, sessionId: sessionId, runId: runId)
        return !found.matching.isEmpty || !found.damaged.isEmpty
    }

    /// A checkpoint the launch recovery can read, and so resumes; a damaged one
    /// stays owed (`hasReplyCheckpoint`) but schedules nothing.
    public static func hasResumableReplyCheckpoint(dataRoot: URL, sessionId: String, runId: String) throws -> Bool {
        try !replyCheckpoints(dataRoot: dataRoot, sessionId: sessionId, runId: runId).matching.isEmpty
    }

    public static func removeReplyCheckpoint(dataRoot: URL, sessionId: String, runId: String) throws {
        for checkpoint in try replyCheckpoints(dataRoot: dataRoot, sessionId: sessionId, runId: runId).matching {
            try checkpoint.remove(dataRoot: dataRoot)
        }
    }

    /// This run's checkpoints, each file read on its own. A damaged file may be
    /// this run's, so it is kept and named, never settled or removed.
    static func replyCheckpoints(dataRoot: URL, sessionId: String, runId: String) throws
        -> (matching: [TurnCheckpoint], damaged: [String]) {
        var found: (matching: [TurnCheckpoint], damaged: [String]) = ([], [])
        for turnId in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: sessionId) {
            do {
                if let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId),
                   checkpoint.runId == runId { found.matching.append(checkpoint) }
            } catch {
                found.damaged.append(turnId)
                nativeLog("Turn checkpoint %@ is unreadable and may be run %@; its answer stays owed: %@",
                          turnId, runId, error.localizedDescription)
            }
        }
        return found
    }

    public static func savedReply(dataRoot: URL, sessionId: String, runId: String, turnId: String? = nil) async throws -> ChatResponse? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        let persistence = SwiftNativePersistenceCore()
        let read = try await persistence.withFileLock(path) { try await persistence.readJSONLReporting(path) }
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
              read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rows = read.rows
        for row in rows.reversed() {
            guard case .object(let fields) = row, fields["role"] == .string("assistant"),
                  fields["runId"] == .string(runId), fields["sessionId"] == .string(sessionId),
                  case .object(let metadata)? = fields["metadata"],
                  case .string(let content)? = fields["content"] else { continue }
            // Explicit authorship binds the answer to the appended row's own identity.
            if turnId == nil, !runId.isEmpty, fields["id"] == .string(runId), metadata["answerFor"] == .string(runId) {
                return ChatResponse(runId: runId, model: "explicit-assistant-reply", output: content, sessionId: sessionId,
                    attachments: try CodexCompletionTranscriptEvidence.decodeAttachments(metadata["attachments"]), terminalState: .completed)
            }
            guard metadata["completionState"] != nil,
                  let raw = metadata["outcomeObservation"], let outcome = ResponseOutcomeObservationV2(jsonValue: raw),
                  outcome.sessionID == sessionId, fields["id"] == .string(outcome.messageID),
                  metadata["turnTraceId"] == .string(outcome.turnID),
                  turnId == nil || outcome.turnID == turnId,
                  let model = outcome.providerModel, case .string(let status)? = metadata["terminalState"],
                  let state = TurnEngineResult.TerminalState(rawValue: status) else { continue }
            var response = ChatResponse(runId: runId, model: model, reasoningEffort: outcome.reasoningEffort,
                output: content, sessionId: sessionId,
                attachments: try CodexCompletionTranscriptEvidence.decodeAttachments(metadata["attachments"]), terminalState: state)
            if case .int(let count)? = metadata["workingCommentaryChars"] { response.workingCommentaryCharacters = Int(count) }
            if state != .completed {
                response.runtimeStatus = state == .waiting ? "waiting on you" : state == .failed ? "failed" : "interrupted"
            }
            let answerRef = Self.transcriptRef(sessionId, outcome.messageID)
            let heardID = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])?.answerExperienceID ?? outcome.turnID
            // The same birth the turn wrote, so a lost one is restored and a kept one stands.
            Self.recordAnswer(id: Experience.answer(run: runId), heardID: heardID, evidence: answerRef, state: state,
                              dataRoot: dataRoot) { [attachments = response.attachments ?? []] in
                var answer = Experience(id: Experience.answer(run: runId), kind: .answer, cause: [heardID],
                    evidence: [answerRef], face: Self.face(content, attachments), addressedTo: ["conversation:" + sessionId])
                let checkpoint = try? TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: outcome.turnID)
                if let owed = checkpoint?.owedDelivery(status: state.rawValue) {
                    answer.addressedTo.append(owed.to)
                    answer.owes[owed.key] = .init(to: owed.to)
                }
                return answer
            }
            return response
        }
        return nil
    }

    func settleTurnCheckpoint(_ terminal: TurnTraceEvent, sessionId: String, runId: String) async throws {
        // This turn's own checkpoint, read alone: a damaged sibling never holds it.
        var checkpoints = try [TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: terminal.turnId)]
            .compactMap { $0 }.filter { $0.runId == runId }
        for index in checkpoints.indices {
            if case .object(let payload) = terminal.payload,
               payload["status"] == .string("completed") || payload["status"] == .string("waiting"),
               checkpoints[index].hasRedeliveryOwner {
                // Persist ownership before the terminal so a kill at either write remains resumable.
                checkpoints[index].deliveryPending = true
                try checkpoints[index].write(dataRoot: dataRoot)
            } else { checkpoints[index].deliveryPending = false }
        }
        if case .object(let payload) = terminal.payload,
           payload["status"] == .string("completed") || payload["status"] == .string("waiting") {
            do { try await AbandonedTurnReconciliationHook.retainMirror(dataRoot: dataRoot, sessionId: sessionId, runId: runId) }
            catch { nativeLog("Reply mirror remains owed: %@", error.localizedDescription) }
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
        if let response = try await Self.savedReply(dataRoot: dataRoot, sessionId: checkpoint.sessionId,
                                                    runId: checkpoint.runId, turnId: checkpoint.turnId) {
            let state = response.terminalState ?? .completed
            let reason: TurnEngineResult.TerminalReason = state == .completed ? .replyCompleted
                : state == .waiting ? .interactionRequired : state == .failed ? .executionFailed : .incomplete
            try await TurnCheckpointScope.$resuming.withValue(checkpoint) {
            try await settleTurnCheckpoint(TurnTraceEvent(turnId: checkpoint.turnId, kind: "turn.terminal",
                sessionId: checkpoint.sessionId, surface: checkpoint.surface, payload: .object([
                    "schema": .string("metacognition.observed.v1"), "status": .string(state.rawValue),
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
        request.origin = try metadata["origin"].map {
            try JSONDecoder().decode(ChatMessageOrigin.self, from: $0.serializedData(pretty: false))
        }
        request.attachments = try CodexCompletionTranscriptEvidence.savedAttachments(metadata["attachments"])
        var record = checkpoint
        let sources = rows.flatMap { row -> [String] in
            guard case .object(let fields)? = row.extras, case .object(let metadata)? = fields["metadata"],
                  case .array(let saved)? = metadata["untrusted_sources"] else { return [] }
            return saved.compactMap { if case .string(let source) = $0 { return source }; return nil }
        }
        let taint = PeerDataTaint(restoring: (record.peerSources ?? []) + sources
            + (PeerDataTaint.current?.checkpointSources ?? []),
            elevated: PeerDataTaint.current?.elevatedSources ?? [])
        try await DeskContinuationScope.current?.resume()
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
    /// What an accepted turn owes its door, from the bindings it runs under.
    nonisolated static func continuation(runId: String?, sessionId: String?, surface: String, userMessage: String,
                                         fileAccess: String, capabilityProfile: String?) throws -> DeskContinuation? {
        guard let runId, !runId.isEmpty else { return nil }
        let envelope = TurnEnvelope.current(surface: surface)
        guard case .object(let metadata) = envelope.persistedMetadata() else { throw DeskContinuationError.unavailable }
        let route = ChatToolSessionContext.replyRoute ?? envelope.deliveryRoute
        var reply: [String: JSONValue] = ["surface": .string(route?.surface ?? surface)]
        for (key, value) in [("destinationId", route?.destinationId), ("threadId", route?.threadId),
                             ("sourceKey", route?.sourceKey), ("replyTo", route?.replyTo),
                             ("correlationId", route?.correlationId), ("requesterUserId", route?.requesterUserId)] {
            if let value { reply[key] = .string(value) }
        }
        return DeskContinuation(runID: runId, sessionID: sessionId, surface: surface,
                envelope: metadata, replyRoute: reply, remainingWork: userMessage, fileAccess: fileAccess,
                peerSources: PeerDataTaint.current?.checkpointSources, capabilityProfile: capabilityProfile,
                commandSignatureVerified: envelope.commandSignatureVerified, declaredRemote: envelope.declaredRemote,
                helperDefinition: try StandingBotContinuity.currentBot.map { try JSONValue.fromEncodable($0) })
    }

    /// Stop is the turn's one cancel link: the run's raised flag cancels its
    /// work at once, wherever it waits; a door that stops listening never does.
    nonisolated static func untilStopped<T: Sendable>(_ flag: URL?, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let flag else { return try await work() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                let changes = FileChangeEvents(paths: [URL(fileURLWithPath: flag.path)])
                defer { changes.cancel() }
                for await _ in changes.stream where ChatCancelFlag.isRaised(flag) { break }
                return nil
            }
            // The work's own end (a value, or its stop carrying the partial) is the
            // answer; only a raised flag cancels it.
            while let next = try await group.next() {
                if let value = next { group.cancelAll(); return value }
                if ChatCancelFlag.isRaised(flag) { group.cancelAll() }
            }
            throw CancellationError()
        }
    }

    nonisolated static func checkpoint(_ saved: DeskContinuation, turnId: String, sessionId: String) -> TurnCheckpoint {
        TurnCheckpoint(runId: saved.runID, turnId: turnId, sessionId: sessionId, surface: saved.surface,
            userMessage: saved.remainingWork, envelope: saved.envelope, replyRoute: saved.replyRoute,
            fileAccess: saved.fileAccess, capabilityProfile: saved.capabilityProfile, peerSources: saved.peerSources,
            commandSignatureVerified: saved.commandSignatureVerified, declaredRemote: saved.declaredRemote,
            helperDefinition: saved.helperDefinition)
    }

    public func executeTurnWithStreamingToolLoop(
        surface: String = "chat", userMessage: String, sessionId: String? = nil,
        toolSessionId: String? = nil, runId: String? = nil,
        llm: any LLMClient,
        tools: any ToolDispatchClient, preBuiltContext: TurnContext? = nil,
        progress: ChatOrchestrationProgressHandler? = nil,
        cancelFlagPath: URL? = nil, providerAdmission: (@Sendable () async throws -> Void)? = nil,
        fileAccess: String = "auto", capabilityProfile: String? = nil
    ) async throws -> TurnEngineResult {
        let heardID = sessionId == nil ? TurnTraceContext.turnId : ChatToolSessionContext.envelope?.answerExperienceID
        let effectiveProgress: ChatOrchestrationProgressHandler = { [remPinsDataRoot] event in
            if let root = remPinsDataRoot, let heardID {
                switch event {
                case .delta, .toolUse, .toolResult, .notice, .replyTextSettled:
                    ExperienceStore.record(root, heardID) { try await $0.append([.progress("working")], to: heardID) }
                case .final, .error: break
                }
            }
            await progress?(event)
        }
        let saved = remPinsDataRoot == nil ? nil : try Self.continuation(runId: runId, sessionId: sessionId,
            surface: surface, userMessage: userMessage, fileAccess: fileAccess, capabilityProfile: capabilityProfile)
        let journal: DeskContinuationTurn?
        if let current = DeskContinuationScope.current { journal = current }
        else if let root = remPinsDataRoot, let saved {
            journal = DeskContinuationTurn(store: SwiftNativeDeskStore(dataRoot: root), record: saved)
        } else { journal = nil }
        let ownsJournal = await journal?.snapshot().runID == runId
        // A worker has no conversation: its run owns the checkpoint, and it
        // settles that checkpoint itself when it ends (its caller holds the answer).
        let checkpoint: TurnCheckpointWriter?
        var workerRecord: TurnCheckpoint?
        if let root = remPinsDataRoot, let saved, let owner = sessionId ?? runId.map({ "worker-" + $0 }),
           let turnId = TurnTraceContext.turnId {
            let restarted = TurnCheckpointScope.resuming.flatMap { $0.runId == runId && $0.turnId == turnId ? $0 : nil }
            let record = restarted ?? Self.checkpoint(saved, turnId: turnId, sessionId: owner)
            if sessionId == nil { workerRecord = record }
            checkpoint = TurnCheckpointWriter(record: record, dataRoot: root)
        } else { checkpoint = nil }
        func settleWorker() {
            guard let workerRecord, let root = remPinsDataRoot else { return }
            do { try workerRecord.remove(dataRoot: root) }
            catch { nativeLog("A worker's checkpoint was not removed; launch recovery will find it: %@", error.localizedDescription) }
        }
        return try await TurnCheckpointScope.$current.withValue(checkpoint) {
        return try await DeskContinuationScope.$current.withValue(journal) {
            do {
                let result = try await Self.untilStopped(cancelFlagPath) { [self] in
                    try await executeContinuationTurnBody(
                        surface: surface, userMessage: userMessage, sessionId: sessionId,
                        toolSessionId: toolSessionId, runId: runId,
                        llm: llm, tools: tools,
                        preBuiltContext: preBuiltContext, progress: effectiveProgress,
                        cancelFlagPath: cancelFlagPath, providerAdmission: providerAdmission)
                }
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
                settleWorker()
                return result
            } catch {
                let canceled = Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath)
                if ownsJournal {
                    try await journal?.finish(state: canceled ? .canceled : .ready, reply: "",
                        reason: canceled ? "canceled" : "turn_interrupted",
                        peerSources: PeerDataTaint.current?.checkpointSources)
                }
                settleWorker()
                throw error
            }
        }
        }
    }
}
