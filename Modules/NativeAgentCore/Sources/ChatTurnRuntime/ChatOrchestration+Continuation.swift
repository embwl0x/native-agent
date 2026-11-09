import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Experiences
import Transcripts
import TurnTrace
import ProviderRouting
import NativeAgentShared
// Blueprint: | `ChatOrchestration+Continuation.swift` | `SwiftNativeTurnEngine`: `executeTurnWithStreamingToolLoop`, closing expansion predictions through `Expansion.withTurn` after the whole turn, including deferred after-reply work or its abandonment; explicit checkpoint and resume inputs, serialized `TurnCheckpointWriter`; same-turn transcript/receipt recovery and finished-run cleanup |


/// Serialize with receipts so checkpoints never claim unrecorded effects. Failed writes owe repair; the next committed write settles it.
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
                 startingCalls: Int = 0, turn: Turn) {
        record.log = log
        record.keptProse = prose
        record.workingCommentaryCharacters = commentaryCharacters
        pendingCalls += startingCalls
        record.runningStep = pendingCalls > 0 ? 1 : nil
        record.peerSources = turn.peerSteering?.checkpointSources ?? record.peerSources
        record.answeredPeers = turn.peerSteering?.elevatedSources ?? record.answeredPeers
        persist()
    }

    func receiptWritten(turn: Turn) {
        pendingCalls = max(0, pendingCalls - 1)
        record.runningStep = pendingCalls > 0 ? 1 : nil
        record.replyChoices = turn.replyChoices?.paths ?? record.replyChoices
        record.peerSources = turn.peerSteering?.checkpointSources ?? record.peerSources
        record.answeredPeers = turn.peerSteering?.elevatedSources ?? record.answeredPeers
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

    /// Checkpoint write failures retain their path and cause as owed repair, without ending the turn.
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
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let read = try await SwiftNativePersistenceCore.readJSONLReporting(path)
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
            try ContactThread.replace(rows, to: path)
        }
    }

    /// Settle delivery before retiring its checkpoint so relaunch can confirm through the route's ledger without resending.
    /// Only `completed` or `sent_unconfirmed` settle it; `accepted_by_transport` is transport evidence alone.
    /// Log failed settlement writes without holding the checkpoint.
    public static func settleReplyCheckpoint(dataRoot: URL, sessionId: String, runId: String, verdict: String) async throws {
        for checkpoint in try replyCheckpoints(dataRoot: dataRoot, sessionId: sessionId, runId: runId).matching
            where checkpoint.deliveryPending {
            if let key = checkpoint.owedDelivery(status: "completed")?.key {
                let settle: ExperienceStore.Change? = switch verdict {
                case "completed": .obligation(key: key, phase: .accepted)
                case "sent_unconfirmed", "let_go": .letGo(key: key, reason: .abandoned)
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

    /// Unreadable checkpoints stay owed but schedule no recovery until their contents can be read.
    public static func hasResumableReplyCheckpoint(dataRoot: URL, sessionId: String, runId: String) throws -> Bool {
        try !replyCheckpoints(dataRoot: dataRoot, sessionId: sessionId, runId: runId).matching.isEmpty
    }

    public static func removeReplyCheckpoint(dataRoot: URL, sessionId: String, runId: String) throws {
        for checkpoint in try replyCheckpoints(dataRoot: dataRoot, sessionId: sessionId, runId: runId).matching {
            try checkpoint.remove(dataRoot: dataRoot)
        }
    }

    /// Read checkpoints independently; retain and name unreadable files because they may belong to this run.
    static func replyCheckpoints(dataRoot: URL, sessionId: String, runId: String) throws
        -> (matching: [TurnCheckpoint], damaged: [String]) {
        var found: (matching: [TurnCheckpoint], damaged: [String]) = ([], [])
        for turnId in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: sessionId) {
            do {
                if let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId),
                   checkpoint.stoppedReason == nil, checkpoint.runId == runId { found.matching.append(checkpoint) }
            } catch {
                found.damaged.append(turnId)
                nativeLog("Turn checkpoint %@ is unreadable and may be run %@; its answer stays owed: %@",
                          turnId, runId, error.localizedDescription)
            }
        }
        return found
    }

    /// Silence has no transcript row: the agent's experience records the choice and its settled answer obligation.
    public static func silentTurn(dataRoot: URL, sessionId: String?, runId: String, turnId: String? = nil) throws -> String? {
        let store = ExperienceStore.at(dataRoot)
        guard let answer = try store.recordedExperience(Experience.answer(run: runId)),
              let silence = answer.evidence.first(where: { $0.source == "silence" }),
              turnId == nil || silence.id == turnId else { return nil }
        if let sessionId, !answer.evidence.contains(.init(source: "conversation", id: sessionId)) { return nil }
        guard answer.kind == .answer, answer.outcome?.domain == "turn", answer.outcome?.status == "completed",
              answer.face == nil, answer.addressedTo.isEmpty, answer.owes.isEmpty,
              let heardID = answer.cause.first, let heard = try store.recordedExperience(heardID),
              heard.owes["answer"]?.phase == .accepted, heard.owes["answer"]?.evidence == silence else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return silence.id
    }

    public static func savedReply(dataRoot: URL, sessionId: String, runId: String?, turnId: String? = nil,
                                  deliveryId: String? = nil, requestDigest: String? = nil) async throws -> ChatResponse? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        let read = try await SwiftNativePersistenceCore.withFileLock(path) { try await SwiftNativePersistenceCore.readJSONLReporting(path) }
        guard read.report.malformedLineCount == 0, !read.report.trailingPartialLine,
              read.rows.allSatisfy({ if case .object = $0 { return true }; return false }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rows = read.rows
        guard let runId = try runId ?? deliveryId.flatMap({
            try CodexCompletionTranscriptEvidence.recoverRunId(from: rows, deliveryId: $0,
                requestDigest: requestDigest, sessionId: sessionId)
        }) else { return nil }
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
                response.runtimeStatus = state == .waiting ? "waiting on you" : state.rawValue
            }
            let answerRef = Self.transcriptRef(sessionId, outcome.messageID)
            let heardID = TurnEnvelope.fromPersistedMetadata(metadata["envelope"])?.answerExperienceID ?? outcome.turnID
            // Preserve the turn's original birth across recovery.
            await Self.recordAnswer(runID: runId, heardID: heardID, evidence: answerRef, state: state,
                dataRoot: dataRoot, words: content, attachments: response.attachments ?? [],
                conversation: (sessionId, outcome.turnID))
            return response
        }
        if try silentTurn(dataRoot: dataRoot, sessionId: sessionId, runId: runId, turnId: turnId) != nil {
            return ChatResponse(runId: runId, model: "", output: "", sessionId: sessionId, terminalState: .completed)
        }
        return nil
    }

    func settleTurnCheckpoint(_ terminal: TurnTraceEvent, sessionId: String, runId: String) async throws {
        let silent = terminal.payload.objectValue?["silence"] == .string(terminal.turnId)
        // This turn's own checkpoint, read alone: a damaged sibling never holds it.
        var checkpoints = try [TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: terminal.turnId)]
            .compactMap { $0 }.filter { $0.runId == runId }
        for index in checkpoints.indices {
            if case .object(let payload) = terminal.payload,
               payload["status"] == .string("completed") || payload["status"] == .string("waiting"),
               checkpoints[index].hasRedeliveryOwner, !silent {
                // Persist ownership before the terminal so a kill at either write remains resumable.
                checkpoints[index].deliveryPending = true
                try checkpoints[index].write(dataRoot: dataRoot)
            } else { checkpoints[index].deliveryPending = false }
        }
        if case .object(let payload) = terminal.payload,
           payload["status"] == .string("completed") || payload["status"] == .string("waiting"), !silent {
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
                           progress: TurnEventSink? = nil, turn: Turn, work: ChatTurnWork) async throws -> ChatResponse {
        guard try DataRootLife.isCurrent(checkpoint.lifeID, in: dataRoot) else { throw CancellationError() }
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
            let terminal = TurnTraceEvent(turnId: checkpoint.turnId, kind: "turn.terminal",
                sessionId: checkpoint.sessionId, surface: checkpoint.surface, payload: .object([
                    "schema": .string("metacognition.observed.v1"), "status": .string(state.rawValue),
                    "terminalReason": .string(reason.rawValue), "observedBy": .string("checkpoint_recovery"),
                    "silence": response.isSilentCompletion ? .string(checkpoint.turnId) : .null]), turn: turn)
            let settled: Result<Void, any Error> = await settle { [self] in
                do {
                    try await settleTurnCheckpoint(terminal, sessionId: checkpoint.sessionId, runId: checkpoint.runId)
                    return .success(())
                } catch { return .failure(error) }
            }
            try settled.get()
            return response
        }
        var request = request
        var restoredTurn = turn
        restoredTurn.fileAccess = checkpoint.fileAccess
        if let ceiling = checkpoint.fileAccessCeiling { restoredTurn.fileAccessCeiling = ceiling }
        // Joined readings replay from the held log, outside history, which ends before this turn's first shown input.
        let joinedRuns = Set((checkpoint.log ?? []).compactMap { $0.objectValue?["arrival"]?.objectValue?["run"]?.stringValue })
        if let boundary = history.messages.first(where: { row in
            guard row.role == "user", let run = row.extras?.objectValue?["runId"]?.stringValue else { return false }
            return run == checkpoint.runId || joinedRuns.contains(run)
        }) {
            guard let id = boundary.extras?.objectValue?["id"]?.stringValue else {
                throw ChatOrchestrationError.underlying("The resumed turn's history boundary has no row identity; repair its transcript.")
            }
            restoredTurn.rows.replacementUserMessageID = id
        }
        if let input = checkpoint.hiddenInput {
            request.message = checkpoint.userMessage
            request.suppressUserAppend = true
            request.persona = input.persona
            request.origin = .some(try input.origin.map {
                try JSONDecoder().decode(ChatMessageOrigin.self, from: $0.serializedData(pretty: false))
            })
            request.attachments = input.attachments
            request.codexCompletion = .some(try input.completion.map {
                try JSONDecoder().decode(CodexCompletionTranscriptBinding.self, from: $0.serializedData(pretty: false))
            })
            request.queryUserMessage = .some(input.queryUserMessage)
            request.threadKind = input.threadKind
            request.ownedSessionID = input.ownedSessionID
            request.verifiedSessionID = .some(input.verifiedSessionID)
            restoredTurn.rows.hiddenInput = input
            restoredTurn.rows.questionRunID = input.questionRunID
        } else {
            guard let user = rows.first(where: { $0.role == "user" }) else {
                throw ChatOrchestrationError.underlying("The resumed turn's saved user message is missing; repair its transcript.")
            }
            guard case .object(let fields)? = user.extras, case .object(let metadata)? = fields["metadata"] else {
                throw ChatOrchestrationError.underlying("The resumed turn's input metadata is missing; repair its transcript.")
            }
            if case .string(let persona)? = metadata["persona"] { request.persona = persona }
            request.origin = try metadata["origin"].map {
                try JSONDecoder().decode(ChatMessageOrigin.self, from: $0.serializedData(pretty: false))
            }
            request.attachments = try CodexCompletionTranscriptEvidence.savedAttachments(metadata["attachments"])
        }
        let turn = restoredTurn
        var record = checkpoint
        let sources = rows.flatMap { row -> [String] in
            guard case .object(let fields)? = row.extras, case .object(let metadata)? = fields["metadata"],
                  case .array(let saved)? = metadata["untrusted_sources"] else { return [] }
            return saved.compactMap { if case .string(let source) = $0 { return source }; return nil }
        }
        // Restore recorded steering; rereading saved evidence never adds steering peers.
        let taint = PeerDataTaint(restoring: (record.peerSources ?? []) + sources
            + (turn.peerSteering?.checkpointSources ?? []),
            elevated: (record.answeredPeers ?? []) + (turn.peerSteering?.elevatedSources ?? []))
        try await work.journal?.resume()
        return try await holding(turn.with(\.peerSteering, taint)) { turn in
        record.peerSources = taint.checkpointSources
        record.answeredPeers = taint.elevatedSources
        return try await TurnTraceContext.$turnId.withValue(record.turnId) {
        try await holding(turn.with(\.resumingCheckpoint, record)) { turn in
        try await holding(work.with(\.resumedRows, rows)) { work in
            if let bot = turn.standingBot {
                return try await holding(request.turn(id: record.turnId, parent: turn).with(\.resumingCheckpoint, record)) { turn in
                    try await chat(message: request.message, sessionId: checkpoint.sessionId,
                        choice: turn.providerChoice, tokenLimit: bot.budget.tokens, surface: request.surface,
                        fileAccess: request.fileAccess, suppressUserAppend: true, mechanicalRow: .botReceipt,
                        progress: progress, turn: turn, work: work)
                }
            }
            return try await chat(message: request.message, sessionId: request.sessionID, model: request.model,
                reasoningEffort: request.reasoningEffort, fileAccess: request.fileAccess,
                attachments: request.attachments, persona: request.persona, surface: request.surface,
                suppressUserAppend: request.suppressUserAppend, progress: progress,
                turn: request.turn(id: record.turnId, parent: turn), serviceTier: request.serviceTier ?? nil, work: work)
        }
        }
        }
        }
    }
}

extension SwiftNativeTurnEngine {
    nonisolated static func continuation(dataRoot: URL, runId: String?, sessionId: String?, surface: String, userMessage: String,
                                         fileAccess: String, capabilityProfile: String?, turn: Turn) throws -> DeskContinuation? {
        guard let runId, !runId.isEmpty else { return nil }
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        guard case .object(let metadata) = envelope.persistedMetadata() else { throw DeskContinuationError.unavailable }
        let route = turn.replyRoute ?? envelope.deliveryRoute
        var reply: [String: JSONValue] = ["surface": .string(route?.surface ?? surface)]
        for (key, value) in [("destinationId", route?.destinationId), ("threadId", route?.threadId),
                             ("sourceKey", route?.sourceKey), ("replyTo", route?.replyTo),
                             ("correlationId", route?.correlationId), ("requesterUserId", route?.requesterUserId)] {
            if let value { reply[key] = .string(value) }
        }
        var record = DeskContinuation(runID: runId, sessionID: sessionId, surface: surface,
                envelope: metadata, replyRoute: reply, remainingWork: userMessage, fileAccess: fileAccess,
                peerSources: turn.peerSteering?.checkpointSources, capabilityProfile: capabilityProfile,
                commandSignatureVerified: envelope.commandSignatureVerified, declaredRemote: envelope.declaredRemote,
                helperDefinition: try turn.standingBot.map { try JSONValue.fromEncodable($0) })
        record.lifeID = try DataRootLife.current(in: dataRoot)
        record.fileAccessCeiling = turn.fileAccessCeiling.intersecting(.init(fileAccess))
        return record
    }

    /// Only the run's Stop flag cancels its work; a disconnected listener does not.
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
            // Keep the work's value or stopped partial as its answer; only a raised Stop flag cancels it.
            while let next = try await group.next() {
                if let value = next { group.cancelAll(); return value }
                if ChatCancelFlag.isRaised(flag) { group.cancelAll() }
            }
            throw CancellationError()
        }
    }

    nonisolated static func checkpoint(_ saved: DeskContinuation, turnId: String, sessionId: String,
                                       hiddenInput: TurnCheckpoint.HiddenInput? = nil) -> TurnCheckpoint {
        var record = TurnCheckpoint(runId: saved.runID, turnId: turnId, sessionId: sessionId, surface: saved.surface,
            userMessage: saved.remainingWork, envelope: saved.envelope, replyRoute: saved.replyRoute,
            fileAccess: saved.fileAccess, capabilityProfile: saved.capabilityProfile, peerSources: saved.peerSources,
            commandSignatureVerified: saved.commandSignatureVerified, declaredRemote: saved.declaredRemote,
            helperDefinition: saved.helperDefinition, lifeID: saved.lifeID)
        record.hiddenInput = hiddenInput
        record.fileAccessCeiling = saved.fileAccessCeiling
        return record
    }

    public func executeTurnWithStreamingToolLoop(
        surface: String = "chat", userMessage: String, sessionId: String? = nil,
        toolSessionId: String? = nil, runId: String? = nil,
        llm: any LLMClient,
        tools: any ExpansionToolDispatchClient, preBuiltContext: TurnContext,
        progress: ToolProgress? = nil,
        onDelivery: (@Sendable () async -> Void)? = nil,
        cancelFlagPath: URL? = nil, providerAdmission: (@Sendable () async throws -> Void)? = nil,
        fileAccess: String = "auto", capabilityProfile: String? = nil,
        turn: Turn, work: ChatTurnWork, call: LLMCall) async throws -> TurnEngineResult {
        var heldTurn = turn
        if heldTurn.providerRecovery == nil { heldTurn.providerRecovery = ProviderRecovery() }
        let turn = heldTurn
        let heardID = sessionId == nil ? turn.id : turn.envelope?.answerExperienceID
        let effectiveProgress = ToolProgress { [remPinsDataRoot] event, receipt, invocationID in
            if let root = remPinsDataRoot, let heardID {
                switch event {
                case .delta, .toolUse, .toolResult, .notice, .replyTextSettled:
                    ExperienceStore.record(root, heardID) { try await $0.append([.progress("working")], to: heardID) }
                case .final, .error, .writing: break
                }
            }
            await progress?(event, receipt: receipt, invocationID: invocationID)
        }
        let saved = try remPinsDataRoot.map { try Self.continuation(dataRoot: $0, runId: runId, sessionId: sessionId,
            surface: surface, userMessage: userMessage, fileAccess: fileAccess, capabilityProfile: capabilityProfile, turn: turn) } ?? nil
        let journal: DeskContinuationTurn?
        if let current = work.journal { journal = current }
        else if let root = remPinsDataRoot, let saved {
            journal = DeskContinuationTurn(store: SwiftNativeDeskStore(dataRoot: root), record: saved)
        } else { journal = nil }
        let ownsJournal = await journal?.snapshot().runID == runId
        // Workers have no conversation, so their run owns and settles the checkpoint while their caller retains the answer.
        let checkpoint: TurnCheckpointWriter?
        var workerRecord: TurnCheckpoint?
        if let root = remPinsDataRoot, let saved, let owner = sessionId ?? runId.map({ "worker-" + $0 }),
           case let turnId = turn.id {
            let restarted = turn.resumingCheckpoint.flatMap { $0.runId == runId && $0.turnId == turnId ? $0 : nil }
            let record = restarted ?? Self.checkpoint(saved, turnId: turnId, sessionId: owner, hiddenInput: turn.rows.hiddenInput)
            if sessionId == nil { workerRecord = record }
            checkpoint = TurnCheckpointWriter(record: record, dataRoot: root)
        } else { checkpoint = nil }
        func settleWorker() {
            guard let workerRecord, let root = remPinsDataRoot else { return }
            do { try workerRecord.remove(dataRoot: root) }
            catch { nativeLog("A worker's checkpoint was not removed; launch recovery will find it: %@", error.localizedDescription) }
        }
        return try await holding(work.with(\.checkpoint, checkpoint)) { work in
        return try await holding(work.with(\.journal, journal)) { work in
            do {
                let result = try await Expansion.withTurn(dataRoot: remPinsDataRoot, turn: turn, afterReply: { $0.afterReply }) {
                    try await Self.untilStopped(cancelFlagPath) { [self] in
                        try await executeContinuationTurnBody(
                            surface: surface, userMessage: userMessage, sessionId: sessionId,
                            toolSessionId: toolSessionId, runId: runId,
                            llm: llm, tools: tools,
                            preBuiltContext: preBuiltContext, progress: effectiveProgress, onDelivery: onDelivery,
                            cancelFlagPath: cancelFlagPath, providerAdmission: providerAdmission, turn: turn, work: work, call: call)
                    }
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
                        peerSources: turn.peerSteering?.checkpointSources)
                }
                settleWorker()
                return result
            } catch {
                let canceled = Task.isCancelled || ChatCancelFlag.isRaised(cancelFlagPath)
                if ownsJournal {
                    try await journal?.finish(state: canceled ? .canceled : .ready, reply: "",
                        reason: canceled ? "canceled" : "turn_interrupted",
                        peerSources: turn.peerSteering?.checkpointSources)
                }
                settleWorker()
                throw error
            }
        }
        }
    }
}
