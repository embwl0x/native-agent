import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import PersonaEngine
import MemoryV2
import NativeAgentShared
import ProviderRouting
import TrustCenter
import ChatTurnContracts
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
import ChatToolRuntime
import ToolRegistry
// Blueprint: | `ChatOrchestrationClient+MessagePersistence.swift` | `SwiftNativeChatOrchestrationClient`; Exact-row durable persistence and index publication |

extension SwiftNativeChatOrchestrationClient {
    static func reportTranscriptWriteFailure(
        label: String,
        path: URL,
        error: Error,
        userText: String,
        onNotice: (@Sendable (String, String) async -> Void)?,
        turn: Turn
    ) async {
        nativeLog("%@: transcript write FAILED for %@: %@",
              label, path.lastPathComponent, String(describing: error))
        let emit = onNotice ?? turn.notices
        await emit?("transcript_write_failed", userText)
    }

    /// Partial output must retain explicit cancellation metadata; failed writes are reported and rethrown.
    func persistPartialIfNeeded(
        sessionId: String,
        runId: String,
        text: String,
        attachments: [MultimodalAttachment] = [],
        cancelled: Bool,
        failure: Error? = nil,
        source: String,
        outcomeContext: TurnContext? = nil,
        replyRowID: String?,
        onNotice: @escaping @Sendable (String, String) async -> Void,
        turn: Turn
    ) async throws -> String? {
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return nil }
        let refused = !cancelled && failure.flatMap { ProviderFailure.report($0)?.cause } == .refused
        let visibleText: String
        if refused {
            let route = outcomeContext?.providerId ?? "unknown route"
            let model = outcomeContext?.modelId ?? "unknown model"
            visibleText = text + "\n\noutcome unknown — inspect before retry. The \(route) route rejected this request on \(model); some steps may have run."
        } else {
            visibleText = text
        }
        do {
            // Save partial output under the live bubble's original identity.
            try await appendMessage(sessionId: sessionId, role: "assistant", content: visibleText,
                runId: runId, attachments: attachments, source: source, outcomeContext: outcomeContext,
                responseOutcomeStatus: cancelled ? "cancelled" : "partial",
                responseFailure: cancelled ? nil : failure.map { ProviderFailure.report($0)?.personDescription ?? "The reply could not be completed." },
                providerRefusal: refused,
                messageId: replyRowID ?? UUID().uuidString,
                onNotice: onNotice, turn: turn)
        } catch {
            await Self.reportTranscriptWriteFailure(label: "persistPartialIfNeeded",
                path: dataRoot.appendingPathComponent("chat/messages/\(safeSessionId).jsonl"),
                error: error,
                userText: "Couldn't save this turn's partial reply - it may be missing when the conversation reloads.",
                onNotice: onNotice, turn: turn)
            throw error
        }
        return visibleText
    }

    /// Contact appends may throw after persistence; reconcile ambiguous writes against the store before repeating.
    /// `byPerson` distinguishes the user's typed send from agent-authored work; a completion can bind its existing answer as the send without another row.
    public func appendAgentConversationSend(sessionID: String, text: String, clientUserMessageID: String? = nil,
                                            byPerson: Bool = false, reusingCompletionID: String? = nil, turn: Turn) async throws {
        if let completionID = reusingCompletionID {
            guard let sendID = clientUserMessageID, !byPerson else {
                throw ChatOrchestrationError.underlying("A saved contact answer needs its exact send identity.")
            }
            let session = try Self.resolveSessionId(sessionID)
            let files = try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, sessionId: session,
                archived: ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot)).map(\.1)
            var answerPath: URL?
            for file in files {
                let matches = try await SwiftNativePersistenceCore.withFileLock(file) {
                    let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(file)
                    guard report.isClean else { throw ChatOrchestrationError.underlying("The contact answer's transcript needs repair.") }
                    return rows.filter { value in
                        guard case .object(let row) = value, row["role"] == .string("assistant"),
                              case .object(let metadata)? = row["metadata"], case .object(let binding)? = metadata["codexCompletion"] else { return false }
                        return binding["deliveryId"] == .string(completionID)
                    }.count
                }
                guard matches <= 1, matches == 0 || answerPath == nil else {
                    throw ChatOrchestrationError.underlying("The completion has repeated contact answers; repair its transcript.")
                }
                if matches == 1 { answerPath = file }
            }
            guard let path = answerPath else {
                throw ChatOrchestrationError.underlying("The completion has no saved contact answer; nothing was held.")
            }
            let changed = try await SwiftNativePersistenceCore.withFileLock(path) {
                let (read, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
                guard report.isClean else { throw ChatOrchestrationError.underlying("The contact answer's transcript needs repair.") }
                let matches = read.indices.filter { index in
                    guard case .object(let row) = read[index], row["role"] == .string("assistant"),
                          case .object(let metadata)? = row["metadata"],
                          case .object(let binding)? = metadata["codexCompletion"] else { return false }
                    return binding["deliveryId"] == .string(completionID)
                }
                guard matches.count == 1, let index = matches.first,
                      case .object(var row) = read[index], case .object(var metadata)? = row["metadata"],
                      metadata["completionState"] == .string("completed") else {
                    throw ChatOrchestrationError.underlying("The completion has no unique completed contact answer; nothing was held.")
                }
                if metadata["dotClientUserMessageID"] == .string(sendID) { return false }
                guard metadata["dotClientUserMessageID"] == nil else {
                    throw ChatOrchestrationError.underlying("The contact answer already belongs to another send; nothing was held.")
                }
                metadata["dotClientUserMessageID"] = .string(sendID)
                row["metadata"] = .object(metadata)
                var rows = read
                rows[index] = .object(row)
                try ContactThread.replace(rows, to: path)
                return true
            }
            if changed { await bumpSessionTranscriptGeneration(sessionId: session) }
            return
        }
        try await holding(turn.with(\.rows.threadKind, .agent)) { turn in
        try await holding(turn.with(\.rows.ownedSessionID, sessionID)) { turn in
        _ = try await appendMessage(sessionId: sessionID, role: "assistant", content: text,
                                runId: nil, attachments: [], source: "agent-bridge", agentConversationSendID: clientUserMessageID,
                                agentConversationSendByPerson: byPerson, turn: turn)
        }
        }
    }

    /// A send may live in the transcript or an archive; only a confirmed absence from both permits a missing-row verdict.
    @discardableResult
    public func recordAgentConversationSendState(sessionID: String, sendID: String, status: String) async throws -> Bool {
        let sessionId = try Self.resolveSessionId(sessionID)
        let files = try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, sessionId: sessionId,
            archived: ChatSessionRetention.archivedTranscripts(dataRoot: dataRoot)).map(\.1)
        for path in files where FileManager.default.fileExists(atPath: path.path) {
            let found = try await SwiftNativePersistenceCore.withFileLock(path) {
                let (read, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
                // An unreadable row may be the send, and would be lost in a rewrite:
                // the evidence stays held until the transcript is repaired.
                guard report.isClean else { throw ChatOrchestrationError.underlying("\(path.lastPathComponent) has unreadable rows") }
                var rows = read
                guard let index = rows.lastIndex(where: { row in
                    guard case .object(let object) = row, case .object(let metadata)? = object["metadata"] else { return false }
                    return metadata["dotClientUserMessageID"] == .string(sendID)
                }), case .object(var row) = rows[index], case .object(var metadata)? = row["metadata"] else { return false }
                guard metadata["sendState"] != .string(status) else { return true }
                metadata["sendState"] = .string(status)
                row["metadata"] = .object(metadata)
                rows[index] = .object(row)
                try ContactThread.replace(rows, to: path)
                return true
            }
            if found { return true }
        }
        return false
    }

    public func appendAnswerForAskingChat(sessionID: String, text: String, attachments: [MultimodalAttachment],
                                          surface: String, deliveryID: String, turn: Turn) async throws {
        try await appendAnswerForAskingChat(sessionID: sessionID, text: text, attachments: attachments,
            surface: surface, deliveryID: deliveryID, mechanicalRow: nil, turn: turn)
    }

    public func appendAnswerForAskingChat(sessionID: String, text: String, attachments: [MultimodalAttachment],
                                          surface: String, deliveryID: String,
                                          mechanicalRow: CognitiveMechanicalRowKind?, turn: Turn) async throws {
        try await appendMessage(sessionId: sessionID, role: "assistant", content: text, runId: UUID().uuidString,
                                attachments: attachments, source: ChatThreadKind.transcriptSource(surface: surface), mechanicalRow: mechanicalRow,
                                answerFor: deliveryID, turn: turn)
    }

    public func enqueueUserMessage(
        message: String,
        sessionId: String?,
        persona: String?,
        surface: String,
        attachments: [MultimodalAttachment] = [],
        // Callers stamp machine-authored user rows explicitly so templated input cannot pass for the user's own words.
        mechanicalRow: CognitiveMechanicalRowKind? = nil,
        awaitingConsumption: Bool = true,
        turn: Turn
    ) async throws -> EnqueuedUserMessage {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        // An ingress-pinned run supplies the row's exact Stop identity.
        let runId = turn.run
        try await appendMessage(
            sessionId: resolvedSession,
            role: "user",
            content: message,
            runId: runId,
            attachments: attachments,
            persona: persona,
            source: ChatThreadKind.transcriptSource(surface: turn.arrivalSurface(authorizing: surface)),
            mechanicalRow: mechanicalRow,
            awaitingConsumption: awaitingConsumption,
            messageId: turn.rows.pinnedUserMessageID ?? UUID().uuidString,
         turn: turn)
        return EnqueuedUserMessage(sessionId: resolvedSession, runId: runId)
    }

    /// A door saves an arrival before accepting it: its row awaits consumption (files included) and its checkpoint lets a relaunch resume it.
    public func saveArrival(message: String, sessionId: String, surface: String, attachments: [MultimodalAttachment],
                            fileAccess: String, turn: Turn) async throws {
        // As the chat path does: an untainted send carries an empty steering record, which its resume requires.
        var turn = turn
        turn.peerSteering = turn.peerSteering ?? PeerDataTaint()
        _ = try await enqueueUserMessage(message: message, sessionId: sessionId, persona: nil, surface: surface,
                                         attachments: attachments, turn: turn)
        guard let root = engine.remPinsDataRoot,
              let saved = try SwiftNativeTurnEngine.continuation(dataRoot: root, runId: turn.run, sessionId: sessionId, surface: surface,
                  userMessage: message, fileAccess: fileAccess, capabilityProfile: continuationCapabilityProfile, turn: turn) else { return }
        if let unwritten = TurnCheckpointWriter.persist(SwiftNativeTurnEngine.checkpoint(saved, turnId: turn.id, sessionId: sessionId),
                                                        dataRoot: root) {
            throw ChatOrchestrationError.underlying(unwritten)
        }
    }

    /// Admission makes only this pre-appended input available to future prompts.
    func consumeEnqueuedMessage(sessionId: String, runId: String) async throws -> AfterTurnOrigin? {
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            var (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
            guard report.isClean else {
                throw ChatOrchestrationError.underlying("Queued input cannot be consumed until its transcript is repaired")
            }
            for index in rows.indices {
                guard case .object(var row) = rows[index], row["role"] == .string("user"),
                      row["runId"] == .string(runId), case .object(var metadata)? = row["metadata"],
                      metadata.removeValue(forKey: "awaitingConsumption") == .bool(true) else { continue }
                row["metadata"] = .object(metadata)
                rows[index] = .object(row)
                try ContactThread.replace(rows, to: path)
                break
            }
            return try Self.afterTurnOrigin(in: rows, sessionId: sessionId, runId: runId)
        }
    }

    public func recordControlHandoff(message: String, reply: String, sessionId: String, surface: String, runId: String = UUID().uuidString,
        turn: Turn) async throws {
        let source = ChatThreadKind.transcriptSource(surface: surface)
        try await appendMessage(sessionId: sessionId, role: "user", content: message,
                                runId: runId, attachments: [], source: source, turn: turn)
        try await appendMessage(sessionId: sessionId, role: "assistant", content: reply,
                                runId: runId, attachments: [], source: source, canonicalAssistantCompletion: true, turn: turn)
    }

    /// The arrival's row as its own turn writes it: its run, its shown row id, its files.
    /// Only that exact row proves a steering offer saved when bookkeeping throws after the row commits.
    func enqueueSteeringMessage(
        message: String, sessionId: String, surface: String, attachments: [MultimodalAttachment],
        turn: Turn
    ) async throws -> AfterTurnOrigin? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            throw ChatOrchestrationError.emptyMessage
        }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        do {
            return try await appendMessage(
                sessionId: resolvedSession, role: "user", content: message,
                runId: turn.run, attachments: attachments,
                source: ChatThreadKind.transcriptSource(surface: turn.arrivalSurface(authorizing: surface)),
                mechanicalRow: turn.execution?.transcriptRowKind,
                messageId: turn.rows.pinnedUserMessageID ?? UUID().uuidString,
             turn: turn)
        } catch {
            let evidence = try await Self.reconcileSteeringMessage(
                message: message, sessionId: resolvedSession, runId: turn.run,
                dataRoot: dataRoot
            )
            guard evidence.committed else { throw error }
            nativeLog("Steering message committed; transcript bookkeeping failed: \(error)")
            return try evidence.origin.get()
        }
    }

    /// A failed read leaves the enqueue unresolved; only a clean locked scan
    /// can prove absence and permit queue replay to append a new user row.
    public static func reconcileSteeringMessage(
        message: String, sessionId: String, runId: String,
        dataRoot: URL
    ) async throws -> (committed: Bool, origin: Result<AfterTurnOrigin?, any Error>) {
        let resolvedSession = try resolveSessionId(sessionId)
        let path = dataRoot.appendingPathComponent("chat/messages/\(resolvedSession).jsonl")
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
            let committed = rows.contains { row in
                guard case .object(let object) = row else { return false }
                return object["role"] == .string("user")
                    && object["sessionId"] == .string(resolvedSession)
                    && object["runId"] == .string(runId)
                    && object["content"] == .string(message)
            }
            guard committed || report.isClean else {
                throw ChatOrchestrationError.underlying("Steering enqueue reconciliation is unavailable")
            }
            let origin = Result<AfterTurnOrigin?, any Error> {
                guard report.isClean else {
                    throw ChatOrchestrationError.underlying("Steering origin reconciliation is unavailable")
                }
                return try Self.afterTurnOrigin(in: rows, sessionId: resolvedSession, runId: runId)
            }
            return (committed, origin)
        }
    }

    /// Completed assistant events carry recalled memory IDs to `attentionSignals(at:)`, correlating transcript and substrate.
    @discardableResult
    func appendMessage(
        sessionId: String,
        role: String,
        content: String,
        runId: String?,
        attachments: [MultimodalAttachment],
        persona: String? = nil,
        source: String,
        recalledMemoryIds: [String] = [],
        canonicalAssistantCompletion: Bool = false,
        outcomeResult: TurnEngineResult? = nil,
        outcomeContext: TurnContext? = nil,
        outcomeTurnID: String? = nil,
        responseOutcomeStatus: String? = nil,
        responseFailure: String? = nil,
        providerRefusal: Bool = false,
        providerRefusalDraft: Bool = false,
        failureWork: String? = nil,
        expectedLastMessageID: String? = nil,
        // A mechanical row names its writer so cognition excludes it from lived state.
        mechanicalRow: CognitiveMechanicalRowKind? = nil,
        requestedResultIntent: JSONValue? = nil,
        agentConversationSendID: String? = nil,
        agentConversationSendByPerson: Bool = false,
        answerFor: String? = nil,
        proactiveSpeechIdempotencyKey: String? = nil,
        awaitingConsumption: Bool = false,
        messageId: String = UUID().uuidString,
        onNotice: (@Sendable (String, String) async -> Void)? = nil,
        turn: Turn
    ) async throws -> AfterTurnOrigin? {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        let partial = responseOutcomeStatus == "partial" || responseOutcomeStatus == "cancelled"
        let messageSource = ChatThreadKind.normalizedSource(source)
        // The row records a source; outcome receipts, envelopes and peer checks speak surfaces, so cross once here.
        let messageSurface = ChatThreadKind.surface(transcriptSource: messageSource)
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        // New messages require a readable index; partial settlement saves produced work first.
        let sessions = try SessionConversation(rows: partial ? [] : ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath))
        let sessionKind: ChatThreadKind
        if turn.rows.ownedSessionID == sessionId, let declared = turn.rows.threadKind {
            sessionKind = declared
        } else {
            sessionKind = sessions.kind(sessionId) ?? turn.rows.threadKind
                ?? ChatThreadKind.inferred(fromSource: messageSource)
        }
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let persistedAt = clock()
        let createdAt = role == "user"
            ? turn.rows.importedMessageCreatedAt ?? NativeTimestampFormat.fractionalZulu(persistedAt)
            : NativeTimestampFormat.fractionalZulu(persistedAt)
        // Encode immutable payload-free observations before the lock; appending and replacement must neither await nor read future state.
        let responseStatus = responseOutcomeStatus
            ?? (canonicalAssistantCompletion && role == "assistant" ? "persisted" : nil)
        let outcomeObservation = responseStatus.flatMap {
            ResponseOutcomeObservationV2.make(
                turnID: outcomeTurnID ?? turn.id,
                messageID: messageId,
                sessionID: sessionId,
                surface: messageSurface,
                observedAt: persistedAt,
                responsePersistence: $0,
                result: outcomeResult,
                context: outcomeContext
            )
        }
        var record: [String: JSONValue] = [
            "id": .string(messageId),
            "sessionId": .string(sessionId),
            "role": .string(role),
            "content": .string(content),
            "createdAt": .string(createdAt),
            "source": .string(messageSource),
        ]
        if !partial { record["threadKind"] = .string(sessionKind.rawValue) }
        if let runId { record["runId"] = .string(runId) }
        var metadata: [String: JSONValue] = [:]
        if partial {
            let cancelled = responseOutcomeStatus == "cancelled"
            record["cancelled"] = .bool(cancelled)
            metadata["partial"] = .bool(true)
            metadata["cancelled"] = .bool(cancelled)
            metadata["untrusted_sources"] = .array((turn.peerSteering?.checkpointSources ?? []).map(JSONValue.string))
            if let responseFailure { metadata["error"] = .string(responseFailure) }
            // The saved words are an incomplete reply whose turn ended stopped or failed; recovery reads that ending, never a completed answer.
            metadata["completionState"] = .string("incomplete")
            metadata["terminalState"] = .string((cancelled ? TurnEngineResult.TerminalState.stopped : .failed).rawValue)
        }
        if awaitingConsumption { metadata["awaitingConsumption"] = .bool(true) }
        if let proactiveSpeechIdempotencyKey {
            metadata["proactiveSpeechIdempotencyKey"] = .string(proactiveSpeechIdempotencyKey)
        }
        if canonicalAssistantCompletion, role == "assistant" {
            metadata["completionState"] = .string(outcomeResult?.completionState == .incomplete ? "incomplete" : "completed")
        }
        if let agentConversationSendID { metadata["dotClientUserMessageID"] = .string(agentConversationSendID) }
        if agentConversationSendByPerson { metadata["byPerson"] = .bool(true) }
        if let answerFor { metadata["answerFor"] = .string(answerFor) }
        if let failureWork, role == "assistant" { metadata["failureWork"] = .string(failureWork) }
        if let requestedResultIntent { metadata["resultDelivery"] = requestedResultIntent }
        if !attachments.isEmpty {
            // The transcript holds metadata and references; attachment bytes stay separate.
            var arr: [JSONValue] = []
            for (index, a) in attachments.enumerated() {
                var item = CodexCompletionTranscriptEvidence.identityRow(for: a)
                if !partial, let utterance = a.utterance {
                    item["utterance"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(utterance))
                }
                if let path = a.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    item["path"] = .string(path)
                } else if role == "user", !a.base64.isEmpty {
                    guard let runId, NativeAgentChatSessionID.normalizedPathComponent(runId) == runId,
                          let bytes = Data(base64Encoded: a.base64) else {
                        throw ChatOrchestrationError.underlying("Couldn't save this turn's attachment for restart recovery.")
                    }
                    let path = try await Self.persistAttachment(bytes,
                        chatRoot: dataRoot.appendingPathComponent("chat"), runId: runId, index: index)
                    item["path"] = .string(path.path)
                }
                arr.append(.object(item))
            }
            metadata["attachments"] = .array(arr)
        }
        if let persona, !persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["persona"] = .string(persona)
        }
        // Both user and assistant rows persist their mechanical writer provenance for transcript-only readers.
        if let mechanicalRow {
            metadata[CognitiveMechanicalRowKind.metadataKey] = .string(mechanicalRow.rawValue)
        }
        if providerRefusal { metadata["provider_refusal"] = .bool(true) }
        if providerRefusalDraft { metadata["provider_refusal_draft"] = .bool(true) }
        if let sources = turn.peerSteering?.checkpointSources, !sources.isEmpty {
            metadata["untrusted_sources"] = .array(sources.map(JSONValue.string))
        }
        // Only user rows carry external origin; assistant replies belong to the agent, not the originating bridge.
        let originProvenance = role == "user"
            ? turn.origin
            : nil
        if let origin = originProvenance {
            var originObject: [String: JSONValue] = [
                "surface": .string(origin.surface),
            ]
            if let agent = origin.agent,
               !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                originObject["agent"] = .string(agent)
            }
            if let replyTo = origin.replyTo { originObject["replyTo"] = .string(replyTo) }
            if let authored = origin.authored { originObject["authored"] = .string(authored.rawValue) }
            let steer = PeerDataTaint.carried(turn: turn,
                peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: messageSurface),
                peerID: turn.envelope?.verifiedUserId
            )
            originObject["peerSources"] = .array(steer.sources.map(JSONValue.string))
            originObject["elevatedPeerSources"] = .array(steer.elevated.map(JSONValue.string))
            metadata["origin"] = .object(originObject)
        }
        // Every conversational row's envelope records turn identity and reply routing, including assistant rows.
        // Persisted envelopes carry no trust verdict and grant no authority; tool calls use the current turn's envelope.
        let turnEnvelope: TurnEnvelope = {
            let live = TurnEnvelope.current(turn: turn, surface: messageSurface)
            guard let origin = originProvenance else { return live }
            // Keep bridge provenance distinct from tool authorization: a bridge may authorize through `chat` while retaining its actual source.
            return TurnEnvelope(
                surface: origin.surface,
                agent: origin.agent,
                verifiedChatId: live.verifiedChatId,
                verifiedUserId: live.verifiedUserId,
                commandSignatureVerified: live.commandSignatureVerified,
                deliveryRoute: live.deliveryRoute,
                declaredRemote: live.declaredRemote,
                answerExperienceID: live.answerExperienceID
            )
        }()
        metadata["envelope"] = turnEnvelope.persistedMetadata()
        if canonicalAssistantCompletion,
           role == "assistant",
           let binding = turn.rows.codexCompletion,
           !binding.deliveryId.isEmpty,
           !binding.requestDigest.isEmpty {
            let executedModel = outcomeContext?.modelId
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let completionModel = if let executedModel, !executedModel.isEmpty {
                executedModel
            } else { binding.model }
            let completionEffort = outcomeContext?.reasoningEffort
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var completion: [String: JSONValue] = [
                "deliveryId": .string(binding.deliveryId),
                "requestDigest": .string(binding.requestDigest),
                // Cache the admitted execution tuple that produced the saved reply, never a shell's stale pre-admission binding.
                "model": .string(completionModel),
                "responseDigest": .string(CodexCompletionTranscriptEvidence.responseDigest(
                    sessionId: sessionId,
                    runId: runId ?? "",
                    content: content,
                    attachments: attachments
                )),
            ]
            if let effort = completionEffort?.isEmpty == false
                ? completionEffort
                : binding.reasoningEffort {
                completion["reasoningEffort"] = .string(effort)
            }
            metadata["codexCompletion"] = .object(completion)
        }
        // Persist opaque completion identity so regeneration names the exact earlier turn without guessing from neighboring prose.
        if let outcomeObservation, role == "assistant" {
            metadata["turnTraceId"] = .string(outcomeObservation.turnID)
            metadata["outcomeObservation"] = outcomeObservation.jsonValue
        }
        if role == "assistant", let result = outcomeResult {
            metadata["completionState"] = .string(result.completionState == .incomplete ? "incomplete" : "completed")
            metadata["terminalState"] = .string(result.resolvedTerminalReason(dataRoot: dataRoot).state.rawValue)
            let writtenFiles = ChatWrittenFileArtifacts.files(from: result.toolDispatches)
            if !writtenFiles.isEmpty {
                metadata["outputFiles"] = .array(writtenFiles.map(\.reference))
            }
            // Keep landed effects and original acceptance time across relaunch so the next turn starts from what actually happened.
            let outcomeID = outcomeTurnID ?? turn.id
            let accepted = (try? TurnCheckpoint.read(dataRoot: dataRoot, sessionId: safeSessionId, turnId: outcomeID))?.acceptedAt
            if let world = await ChatWrittenFileArtifacts.world(from: result.toolDispatches,
                    since: accepted ?? persistedAt.addingTimeInterval(-Double(result.elapsedMs) / 1000), dataRoot: dataRoot, turn: turn) {
                metadata["world"] = world
            }
        }
        // Store the commentary boundary as metadata so presentation can fold it without changing reply text.
        if role == "assistant",
           let commentary = outcomeResult?.workingCommentaryCharacters,
           commentary > 0, commentary < content.count {
            metadata["workingCommentaryChars"] = .int(Int64(commentary))
        }
        if !metadata.isEmpty {
            record["metadata"] = .object(metadata)
        }
        // The owner lock protects appends against concurrent transcript rewrites.
        let messageRow: JSONValue = .object(record)
        ChatSessionIndexFile.beginTranscriptIndexSync(at: path)
        defer { ChatSessionIndexFile.endTranscriptIndexSync(at: path) }
        // The transcript lock makes the committed row count authoritative for index sync.
        let (appended, replacedTurnTraceID, existingUserOrigin): (Bool, String?, AfterTurnOrigin?) = try await SwiftNativePersistenceCore.withFileLock(path) {
            if let sendID = agentConversationSendID {
                let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
                guard report.isClean else { throw ChatOrchestrationError.underlying("The contact send's transcript needs repair.") }
                let matches = rows.filter { row in
                    guard case .object(let fields) = row, case .object(let metadata)? = fields["metadata"] else { return false }
                    return metadata["dotClientUserMessageID"] == .string(sendID)
                }
                if !matches.isEmpty {
                    guard matches.count == 1, case .object(let row) = matches[0], row["role"] == .string("assistant"),
                          row["content"] == .string(content), case .object(let metadata)? = row["metadata"],
                          (metadata["byPerson"] == .bool(true)) == agentConversationSendByPerson else {
                        throw ChatOrchestrationError.underlying("This send identity already has different or repeated words; repair its transcript.")
                    }
                    return (false, nil, nil)
                }
            }
            if role == "user", let runId {
                let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
                guard report.isClean else {
                    throw ChatOrchestrationError.underlying("User input cannot be admitted until its transcript is repaired")
                }
                let submitted = rows.filter { row in
                    guard case .object(let object) = row else { return false }
                    return object["role"] == .string("user")
                        && object["sessionId"] == .string(sessionId)
                        && object["runId"] == .string(runId)
                }
                if !submitted.isEmpty {
                    guard submitted.count == 1, case .object(var row) = submitted[0], row["content"] == .string(content) else {
                        throw ChatOrchestrationError
                            .underlying("This input run already has a different or repeated saved user row; repair its transcript before resuming")
                    }
                    // A run's user row is written once: writing it again as its turn consumes the row its door saved first.
                    if !awaitingConsumption, case .object(var saved)? = row["metadata"], saved["awaitingConsumption"] != nil,
                       let index = rows.firstIndex(of: .object(row)) {
                        saved.removeValue(forKey: "awaitingConsumption")
                        row["metadata"] = .object(saved)
                        var consumed = rows
                        consumed[index] = .object(row)
                        try ContactThread.replace(consumed, to: path)
                    }
                    guard let origin = try Self.afterTurnOrigin(in: rows, sessionId: sessionId, runId: runId) else {
                        throw ChatOrchestrationError.underlying("The saved input has no readable row identity; repair its transcript before resuming")
                    }
                    return (false, nil, origin)
                }
            }
            if let answerFor, FileManager.default.fileExists(atPath: path.path) {
                let bytes = try Data(contentsOf: path)
                let rows = SwiftNativePersistenceCore.decodeJSONL(bytes) { value, _ in value }.rows
                if rows.contains(where: { row in
                    guard case .object(let object) = row, case .object(let metadata)? = object["metadata"] else { return false }
                    return metadata["answerFor"] == .string(answerFor)
                }) { return (false, nil, nil) }
            }
            if let expectedLastMessageID {
                // Match the recent conversation window under the append lock; a leading fragment cannot prove the last row's identity.
                guard let tail = try SwiftNativePersistenceCore.tailPhysicalLines(path, limit: 2048, maxBytes: 1024 * 1024),
                      let line = tail.lines.dropFirst(tail.leadingFragment ? 1 : 0).last(where: {
                          String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
                      }),
                      String(data: line, encoding: .utf8) != nil,
                      let last = try? JSONValue.parse(line),
                      Self.messageID(in: last) == expectedLastMessageID else {
                    throw ChatOrchestrationError.underlying("The conversation changed before the reply could be saved. Reopen it before replying.")
                }
            }
            if canonicalAssistantCompletion,
               role == "assistant",
               let replacementID = turn.rows.replacementAssistantMessageID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !replacementID.isEmpty {
                let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
                guard report.isClean else {
                    throw ChatOrchestrationError.underlying("The conversation contains unreadable rows. Its reply was not replaced.")
                }
                let matching = rows.indices.filter { index in
                    Self.messageID(in: rows[index]) == replacementID
                }
                guard matching.count == 1, let index = matching.first else {
                    throw ChatOrchestrationError.underlying(
                        "regenerate replacement target must identify exactly one persisted message"
                    )
                }
                guard Self.messageRole(in: rows[index]) == "assistant" else {
                    throw ChatOrchestrationError.underlying(
                        "regenerate replacement target is not an assistant message"
                    )
                }
                // Retry may already have persisted its own tool receipts. They
                // are not a newer conversational turn, but must stay ahead of
                // its final answer. No foreign or untyped trailing row qualifies.
                let onlyOwnRetryReceipts = rows[(index + 1)...].allSatisfy { row in
                    guard let runId, !runId.isEmpty,
                          case .object(let object) = row,
                          object["role"] == .string("tool"),
                          object["runId"] == .string(runId),
                          object["sessionId"] == .string(sessionId),
                          case .string(let rowID)? = object["id"], !rowID.isEmpty,
                          case .object(let metadata)? = object["metadata"],
                          case .string(let toolName)? = metadata["toolName"], !toolName.isEmpty,
                          case .string(let kind)? = metadata["kind"]
                    else { return false }
                    return kind == ChatTranscriptToolMessageKind.toolUse
                        || kind == ChatTranscriptToolMessageKind.approvalPending
                        || kind == InlineInteractionWire.transcriptKind
                }
                guard onlyOwnRetryReceipts else {
                    throw ChatOrchestrationError.underlying(
                        "regenerate replacement target is no longer the transcript tail"
                    )
                }
                let priorTurnTraceID = Self.messageTurnTraceID(in: rows[index])
                var replaced = rows
                replaced.remove(at: index)
                replaced.append(messageRow)
                try ContactThread.replace(replaced, to: path)
                // Exact replacement is row-count neutral; count the same nonblank JSONL lines emitted by `ContactThread.replace`.
                ChatTranscriptLineCountCache.shared.record(count: replaced.count, at: path)
                return (true, priorTurnTraceID, nil)
            } else {
                let priorCount = try ChatTranscriptLineCountCache.shared.count(
                    at: path,
                    recount: Self.countJSONLLines(at:)
                )
                // Every conversational row is durable under the transcript owner's lock.
                try await ContactThread.append(messageRow, to: path)
                ChatTranscriptLineCountCache.shared.record(count: priorCount + 1, at: path)
                return (true, nil, nil)
            }
        }
        guard appended else { return existingUserOrigin }
        ChatHistoryIndex.absorb(path, dataRoot: dataRoot)
        if role == "user" {
            do {
                _ = try await OutcomeFeedbackStore(
                    dataRoot: dataRoot,
                    clock: { persistedAt }
                ).recordConversationContinuation(
                    sessionID: safeSessionId,
                    reactionMessageID: messageId
                )
            } catch {
                // The user row is already durable state. Reaction learning is
                // additive evidence and cannot roll the user's message back.
                nativeLog("OutcomeFeedbackStore: continuation receipt failed: \(error)")
            }
        }
        // This receipt proves only that locked transcript replacement committed; it judges no prior answer and grants no control.
        if let targetTurnID = OutcomeTraceIdentity.normalized(replacedTurnTraceID),
           let reactionTurnID = OutcomeTraceIdentity.normalized(turn.id),
           targetTurnID != reactionTurnID {
            TurnTraceBus.fire(TurnTraceEvent(
                turnId: reactionTurnID,
                kind: "turn.reaction",
                sessionId: sessionId,
                surface: source,
                payload: .object([
                    "schema": .string("metacognition.reaction.v1"),
                    "controlAuthority": .bool(false),
                    "reaction": .string("explicit_retry"),
                    "targetTurnId": .string(targetTurnID),
                    "observedBy": .string("transcript.regenerate_replacement"),
                ]),
                turn: turn
            ), on: turnTraceBus)
        }
        // The transcript is committed. Index projection cannot turn that saved
        // row back into an unsaved reply or prevent its turn from settling.
        do {
            try await syncSessionIndex(
                sessionId: sessionId,
                role: role,
                content: content,
                timestamp: createdAt,
                messagesPath: path,
                source: messageSource,
                metadata: partial ? nil : metadata,
                stamp: TranscriptRowStamp.of(id: messageId, role: role, metadata: metadata, rowSource: partial ? nil : messageSource),
             turn: turn)
        } catch {
            await Self.reportTranscriptWriteFailure(label: "appendMessage session index", path: sessionsPath,
                error: error, userText: partial
                    ? "Saved this turn's partial reply, but couldn't update the conversation list."
                    : "Saved the message, but couldn't update the conversation list.",
                onNotice: onNotice, turn: turn)
        }
        // Publish every row through one signal so open chat and phone views see cross-surface writes immediately.
        NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: sessionId)
        if !partial { await observeCognitiveMessage(
            sessionId: sessionId,
            role: role,
            content: content,
            runId: runId,
            source: messageSource,
            createdAt: createdAt,
            messageId: messageId,
            origin: originProvenance,
            recalledMemoryIds: recalledMemoryIds,
            mechanicalRow: mechanicalRow
        ) }
        return role == "user" ? AfterTurnOrigin(sessionId: sessionId, runId: runId,
            messageId: messageId, occurredAt: persistedAt, userMessage: content) : nil
    }

    private static func messageID(in row: JSONValue) -> String? {
        guard case .object(let object) = row else { return nil }
        if case .string(let id)? = object["id"] { return id }
        if case .string(let id)? = object["message_id"] { return id }
        return nil
    }

    private static func messageRole(in row: JSONValue) -> String? {
        guard case .object(let object) = row,
              case .string(let role)? = object["role"] else { return nil }
        return role
    }

    private static func messageTurnTraceID(in row: JSONValue) -> String? {
        guard case .object(let object) = row,
              case .object(let metadata)? = object["metadata"],
              case .string(let raw)? = metadata["turnTraceId"]
        else { return nil }
        return OutcomeTraceIdentity.normalized(raw)
    }

    func appendFailureMessageIfNeeded(
        sessionId: String,
        runId: String?,
        failure: Error? = nil,
        persona: String?,
        surface: String,
        outcomeContext: TurnContext? = nil,
        outcomeTurnID: String? = nil,
        turn: Turn
    ) async throws {
        let report = failure.flatMap { ProviderFailure.report($0) }
        let canDraft = report?.cause == .refused && report?.work == .nothingRan
            && outcomeContext?.providerId?.isEmpty == false
            && outcomeContext?.modelId.isEmpty == false
        let content: String
        if report?.cause == .refused {
            let route = outcomeContext?.providerId ?? "unknown route"
            let model = outcomeContext?.modelId ?? "unknown model"
            let recovery = ChatThreadKind.transcriptSource(surface: surface) == "app"
                ? "Use Retry draft below, choose another configured model in the chat model picker, then send it."
                : "Choose another configured model for this conversation, then resend your request."
            content = "The \(route) route rejected this request on \(model). "
                + (canDraft
                    ? recovery
                    : "outcome unknown — inspect before retry. Some steps may have run.")
        } else {
            content = report?.personDescription ?? "The reply could not be completed."
        }
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return
        }
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        if let runId, !runId.isEmpty, try await Self.completedAssistantRunIds(path: path).contains(runId) {
            return
        }
        try await appendMessage(
            sessionId: sessionId,
            role: "assistant",
            content: content,
            runId: runId,
            attachments: [],
            persona: persona,
            source: ChatThreadKind.transcriptSource(surface: turn.arrivalSurface(authorizing: surface)),
            outcomeContext: outcomeContext,
            outcomeTurnID: outcomeTurnID,
            responseOutcomeStatus: "failed",
            providerRefusal: report?.cause == .refused,
            providerRefusalDraft: canDraft,
            // Only typed execution evidence can tell the failure card whether repeating the work is safe.
            failureWork: (report?.work ?? .outcomeUnknown).rawValue,
            // Mark the failure as mechanical; provider physiology already owns its lived effect.
            mechanicalRow: .systemRow,
         turn: turn)
    }

    static func shouldPersistFailureMessage(surface: String) -> Bool {
        // Every surface except helpers persists a visible failure row.
        !["bot"].contains(surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Mounted surfaces create and retain conversation IDs before durable persistence; this boundary never invents one.
    public static func resolveSessionId(_ sessionId: String?) throws -> String {
        // Missing session identity must fail here; generating one would orphan a transcript from its visible conversation.
        guard let raw = sessionId else {
            throw ChatOrchestrationError.underlying("missing chat session id")
        }
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(raw) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        return safe
    }

    static func completedAssistantRunIds(path: URL) async throws -> Set<String> {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChatOrchestrationError
                .underlying("Completion evidence is not UTF-8: \(path.path). Repair the transcript before deciding whether this run already completed.")
        }
        var completed = Set<String>()
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let value: JSONValue
            do { value = try JSONValue.parse(Data(rawLine.utf8)) }
            catch { throw ChatOrchestrationError
                .underlying("""
                    Completion evidence is unreadable at \(path.path):\(index + 1): \(error.localizedDescription). Repair this \
                    row before deduplication.
                    """) }
            guard case .object(let row) = value, case .string? = row["role"] else {
                throw ChatOrchestrationError
                    .underlying("Completion evidence is damaged at \(path.path):\(index + 1); repair the transcript before deduplication.")
            }
            if let run = row["runId"], run.stringValue == nil {
                throw ChatOrchestrationError.underlying("Completion evidence has an invalid runId at \(path.path):\(index + 1).")
            }
            if let cancelled = row["cancelled"], cancelled != .bool(true) && cancelled != .bool(false) {
                throw ChatOrchestrationError.underlying("Completion evidence has invalid cancellation evidence at \(path.path):\(index + 1).")
            }
            guard case .string(let runId)? = row["runId"], !runId.isEmpty,
                  row["role"] == .string("assistant"), row["cancelled"] != .bool(true) else { continue }
            if let metadata = row["metadata"], metadata.objectValue == nil {
                throw ChatOrchestrationError.underlying("Completion evidence has invalid metadata at \(path.path):\(index + 1).")
            }
            if case .object(let metadata)? = row["metadata"],
               metadata["partial"] == .bool(true) || metadata["cancelled"] == .bool(true) { continue }
            if case .string(let content)? = row["content"],
               content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            completed.insert(runId)
        }
        return completed
    }

    private func syncSessionIndex(
        sessionId: String,
        role: String,
        content: String,
        timestamp: String,
        messagesPath: URL,
        source: String,
        metadata: [String: JSONValue]?,
        /// Keep the preview's own provenance stamp beside its text.
        stamp: TranscriptRowStamp,
        turn: Turn
    ) async throws {
        let dataRoot = self.dataRoot
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let preview = Self.previewText(content)
        let envelope = turn.envelope
        let contactName: String? = if envelope?.commandSignatureVerified == true,
            let id = envelope?.verifiedUserId {
            (try? AgentPeerStore(dataRoot: dataRoot).list())?.first(where: { $0.id == id })?.name
        } else { nil }
        let title = normalizedRole == "user"
            ? (contactName ?? Self.peerBridgeTitle(content: content, source: source) ?? Self.titleText(content))
            : nil
        let sourceKey = Self.sessionSourceKey(source: source, turn: turn)
        // Continuity is person-bound, never inferred from a title, allowlist,
        // or storage key. A paired phone and this Mac belong to the operator;
        // remote senders remain in their transport's identity namespace.
        let continuity: [String: JSONValue]? = {
            guard normalizedRole == "user", PeerDataTaint.abilityWriteCheck(turn: turn) == nil,
                  source != "ios" || envelope?.commandSignatureVerified == true
                    || turn.envelope?.commandSignatureVerified == true,
                  case .object(let binding)? = ConversationHistory.continuityBinding(
                    role: normalizedRole, metadata: metadata) else { return nil }
            return binding
        }()
        let continuityParticipant: String? = if case .string(let value)? = continuity?["participant"] { value } else { nil }
        let continuityScope: String? = if case .string(let value)? = continuity?["scope"] { value } else { nil }
        try await ChatSessionIndexFile.recordMessage(
            sessionId: sessionId, role: normalizedRole, source: source, sourceKey: sourceKey, kind: turn.rows.threadKind,
            ownedSessionID: turn.rows.ownedSessionID,
            timestamp: timestamp, syncedAt: NativeTimestampFormat.fractionalZulu(clock()), preview: preview, stamp: stamp,
            title: title, continuityParticipant: continuityParticipant, continuityScope: continuityScope,
            dataRoot: dataRoot, messagesPath: messagesPath, countMessages: { try ChatTranscriptLineCountCache.shared.count(at: $0, recount: Self
                .countJSONLLines(at:)) },
            clock: clock)
    }

    /// Record transcript rewrites through the index owner; display-ordering failures cannot fail an already durable turn.
    func bumpSessionTranscriptGeneration(sessionId: String) async {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return }
        do {
            try await ChatSessionIndexFile.recordTranscriptRewrite(
                sessionID: safeSessionId, dataRoot: dataRoot, countMessages: Self.countJSONLLines(at:))
        } catch {
            nativeLog("ChatOrchestrationClient: transcript generation bump failed: \(error)")
        }
    }

    private nonisolated static func countJSONLLines(at path: URL) throws -> Int {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: path) }
        catch let error as CocoaError where error.isFileAbsent { return 0 }
        defer { try? handle.close() }
        var count = 0
        var lineHasContent = false
        while true {
            guard let chunk = try handle.read(upToCount: 256 * 1024),
                  !chunk.isEmpty else { break }
            for byte in chunk {
                if byte == 0x0A {
                    if lineHasContent { count += 1 }
                    lineHasContent = false
                } else if byte != 0x0D && byte != 0x20 && byte != 0x09 {
                    lineHasContent = true
                }
            }
        }
        if lineHasContent { count += 1 }
        return count
    }

    private nonisolated static func previewText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(collapsed.prefix(180))
    }

    private nonisolated static func peerBridgeTitle(content: String, source: String) -> String? {
        guard PeerTurnEffectPolicy.isPeerBridge(surface: source),
              let name = PeerTurnEffectPolicy.peerName(inTurnHeader: content)
        else { return nil }
        return "\(name) · bridge"
    }

    private nonisolated static func titleText(_ raw: String) -> String {
        let preview = previewText(raw)
        guard !preview.isEmpty else { return "New Chat" }
        return String(preview.prefix(60))
    }

    /// Use the bound envelope/reply route's sourceKey, or local `app`; never infer identity from a session ID.
    private nonisolated static func sessionSourceKey(source: String, turn: Turn) -> String? {
        if let bound = turn.envelope?.deliveryRoute?.sourceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !bound.isEmpty {
            return bound
        }
        if let route = turn.replyRoute?.sourceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !route.isEmpty {
            return route
        }
        return source == "app" ? "app" : nil
    }
}
