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
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
import ChatToolRuntime
import ToolRegistry
// Blueprint: | `ChatOrchestrationClient+MessagePersistence.swift` | `SwiftNativeChatOrchestrationClient`: durable message append/replacement, partial/failure settlement, contact sends/imports and session-index publication; exact row identities and source keys from bound delivery identity |

extension SwiftNativeChatOrchestrationClient {
    /// Log every transcript-write failure and notify through `onNotice` or `ToolNoticeBus.emit` when available.
    static func reportTranscriptWriteFailure(
        label: String,
        path: URL,
        error: Error,
        userText: String,
        onNotice: (@Sendable (String, String) async -> Void)?
    ) async {
        nativeLog("%@: transcript write FAILED for %@: %@",
              label, path.lastPathComponent, String(describing: error))
        let emit = onNotice ?? ToolNoticeBus.emit
        await emit?("transcript_write_failed", userText)
    }

    /// Save partial/cancelled assistant replies with explicit metadata; log, notify and rethrow write failures.
    func persistPartialIfNeeded(
        sessionId: String,
        runId: String,
        text: String,
        attachments: [MultimodalAttachment] = [],
        cancelled: Bool,
        failure: Error? = nil,
        source: String = "app",
        outcomeContext: TurnContext? = nil,
        onNotice: @escaping @Sendable (String, String) async -> Void
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
            try await appendMessage(sessionId: sessionId, role: "assistant", content: visibleText,
                runId: runId, attachments: attachments, source: source, outcomeContext: outcomeContext,
                responseOutcomeStatus: cancelled ? "cancelled" : "partial",
                responseFailure: cancelled ? nil : failure.map { ProviderFailure.report($0)?.personDescription ?? "The reply could not be completed." },
                providerRefusal: refused,
                onNotice: onNotice)
        } catch {
            await Self.reportTranscriptWriteFailure(label: "persistPartialIfNeeded",
                path: dataRoot.appendingPathComponent("chat/messages/\(safeSessionId).jsonl"),
                error: error,
                userText: "Couldn't save this turn's partial reply - it may be missing when the conversation reloads.",
                onNotice: onNotice)
            throw error
        }
        return visibleText
    }

    /// Durably append an outgoing contact message without running a turn.
    /// `appendMessage` can throw after persistence; callers must reconcile an ambiguous write against the store.
    /// `byPerson`: the person typed it in the contact's thread; she did not send it.
    public func appendAgentConversationSend(sessionID: String, text: String, clientUserMessageID: String? = nil,
                                            byPerson: Bool = false) async throws {
        try await ChatPersistenceContext.$threadKind.withValue(.agent) {
        try await ChatPersistenceContext.$ownedSessionID.withValue(sessionID) {
        _ = try await appendMessage(sessionId: sessionID, role: "assistant", content: text,
                                runId: nil, attachments: [], source: "agent-bridge", agentConversationSendID: clientUserMessageID,
                                agentConversationSendByPerson: byPerson)
        }
        }
    }

    /// A send's last state on its own row (`ContactThread.Entry.state`), once the
    /// record's bounded ledger let the send go: in the live transcript, or the
    /// archived copy a compaction kept. False: the send has no row anywhere,
    /// so no line of it exists to show the state.
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

    /// Deliver the contact turn’s answer once per deliveryID into the asking chat.
    public func appendAnswerForAskingChat(sessionID: String, text: String, attachments: [MultimodalAttachment],
                                          surface: String, deliveryID: String) async throws {
        try await appendAnswerForAskingChat(sessionID: sessionID, text: text, attachments: attachments,
            surface: surface, deliveryID: deliveryID, mechanicalRow: nil)
    }

    /// Native helper receipts use the same idempotent writer, explicitly
    /// marked as receipts so they never become her lived assistant prose.
    public func appendAnswerForAskingChat(sessionID: String, text: String, attachments: [MultimodalAttachment],
                                          surface: String, deliveryID: String,
                                          mechanicalRow: CognitiveMechanicalRowKind?) async throws {
        try await appendMessage(sessionId: sessionID, role: "assistant", content: text, runId: UUID().uuidString,
                                attachments: attachments, source: surface, mechanicalRow: mechanicalRow, answerFor: deliveryID)
    }

    /// Import contact history by time without reordering existing rows; send/reply identities deduplicate it.
    /// Older unkeyed bridge sends adopt their own row IDs.
    public func importAgentConversationHistory(sessionID: String, rows imported: [JSONValue]) async throws -> Int {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        try await SessionConversation.declare(safeSessionId, kind: .agent, title: "Agent conversation", source: "agent-bridge", dataRoot: dataRoot, createIfMissing: false)
        _ = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
        let path = dataRoot.appendingPathComponent("chat/messages/\(safeSessionId).jsonl")
        @Sendable func key(_ row: JSONValue) -> String? {
            guard case .object(let object) = row, case .object(let metadata)? = object["metadata"] else { return nil }
            if case .string(let id)? = metadata["dotClientUserMessageID"] { return "send:" + id }
            if case .object(let origin)? = metadata["origin"], case .string(let id)? = origin["replyTo"] { return "reply:" + id }
            return nil
        }
        @Sendable func date(_ row: JSONValue) -> Date? {
            guard case .object(let object) = row, case .string(let raw)? = object["createdAt"] else { return nil }
            return NativeTimestampFormat.parseISO8601FractionalFirst(raw)
        }
        ChatSessionIndexFile.beginTranscriptIndexSync(at: path)
        defer { ChatSessionIndexFile.endTranscriptIndexSync(at: path) }
        let changed: (count: Int, last: JSONValue?) = try await SwiftNativePersistenceCore.withFileLock(path) {
            var rows: [JSONValue] = []
            if FileManager.default.fileExists(atPath: path.path) {
                let (read, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
                // A row it could not read would be lost in the rewrite.
                guard report.isClean else { throw ChatOrchestrationError.underlying("transcript has unreadable rows") }
                rows = read
            }
            var count = 0
            for index in rows.indices {
                guard case .object(var row) = rows[index], row["role"] == .string("assistant"), row["runId"] == nil,
                      row["source"] == .string("agent-bridge"), case .string(let id)? = row["id"] else { continue }
                var metadata: [String: JSONValue] = if case .object(let value)? = row["metadata"] { value } else { [:] }
                guard metadata["dotClientUserMessageID"] == nil else { continue }
                metadata["dotClientUserMessageID"] = .string(id)
                row["metadata"] = .object(metadata)
                rows[index] = .object(row)
                count += 1
            }
            var present = Set(rows.compactMap(key))
            for row in imported.sorted(by: { (date($0) ?? .distantPast) < (date($1) ?? .distantPast) }) {
                guard let rowKey = key(row), present.insert(rowKey).inserted, let at = date(row) else { continue }
                let index = rows.firstIndex { (date($0) ?? .distantPast) > at } ?? rows.count
                rows.insert(row, at: index)
                count += 1
            }
            guard count > 0 else { return (0, nil) }
            try ContactThread.replace(rows, to: path)
            ChatTranscriptLineCountCache.shared.record(count: rows.count, at: path)
            return (count, rows.last)
        }
        guard changed.count > 0, case .object(let last)? = changed.last, case .string(let content)? = last["content"],
              case .string(let at)? = last["createdAt"] else { return changed.count }
        let role: String = if case .string(let value)? = last["role"] { value } else { "assistant" }
        let lastID: String = if case .string(let id)? = last["id"] { id } else { "" }
        let lastMetadata: [String: JSONValue] = if case .object(let metadata)? = last["metadata"] { metadata } else { [:] }
        let stamp = TranscriptRowStamp.of(id: lastID, role: role, metadata: lastMetadata, rowSource: "agent-bridge")
        try await syncSessionIndex(sessionId: safeSessionId, role: role, content: content, timestamp: at,
                                   messagesPath: path, source: "agent-bridge", metadata: nil, stamp: stamp)
        NotificationCenter.default.post(name: .nativeAgentChatTranscriptDidChange, object: safeSessionId)
        return changed.count
    }

    public func enqueueUserMessage(
        message: String,
        sessionId: String?,
        persona: String?,
        surface: String,
        attachments: [MultimodalAttachment] = [],
        // Set by a caller that is enqueueing MACHINE text on the user row — the
        // bridge's transport notices, a bot's composed brief. The user row is
        // the one place a templated line can pass for something User said.
        mechanicalRow: CognitiveMechanicalRowKind? = nil,
        awaitingConsumption: Bool = true
    ) async throws -> EnqueuedUserMessage {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        // A door that registered its run for Stop at admission pinned it; the row is that run.
        let runId = ChatPersistenceContext.pinnedTurnRunID ?? UUID().uuidString
        try await appendMessage(
            sessionId: resolvedSession,
            role: "user",
            content: message,
            runId: runId,
            attachments: attachments,
            persona: persona,
            source: surface,
            mechanicalRow: mechanicalRow,
            awaitingConsumption: awaitingConsumption,
            messageId: ChatPersistenceContext.pinnedUserMessageID ?? UUID().uuidString
        )
        return EnqueuedUserMessage(sessionId: resolvedSession, runId: runId)
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

    /// A handoff is recorded without constructing a provider turn.
    public func recordControlHandoff(message: String, reply: String, sessionId: String, surface: String, runId: String = UUID().uuidString) async throws {
        try await appendMessage(sessionId: sessionId, role: "user", content: message,
                                runId: runId, attachments: [], source: surface)
        try await appendMessage(sessionId: sessionId, role: "assistant", content: reply,
                                runId: runId, attachments: [], source: surface, canonicalAssistantCompletion: true)
    }

    /// Keep the enqueue identity available when bookkeeping throws after the
    /// user row commits. Only that exact row proves a steering offer saved.
    func enqueueSteeringMessage(
        message: String, sessionId: String, surface: String, runId: String
    ) async throws -> AfterTurnOrigin? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatOrchestrationError.emptyMessage
        }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        do {
            return try await appendMessage(
                sessionId: resolvedSession, role: "user", content: message,
                runId: runId, attachments: [], source: surface
            )
        } catch {
            let evidence = try await Self.reconcileSteeringMessage(
                message: message, sessionId: resolvedSession, runId: runId,
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

    /// Append a transcript JSONL row readable by `SessionHistoryReader`.
    /// Recalled MemoryV2 IDs reach `attentionSignals(at:)` through the completed assistant event's `memoryRecordIds`.
    @discardableResult
    func appendMessage(
        sessionId: String,
        role: String,
        content: String,
        runId: String?,
        attachments: [MultimodalAttachment],
        persona: String? = nil,
        source: String = "app",
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
        onNotice: (@Sendable (String, String) async -> Void)? = ToolNoticeBus.emit
    ) async throws -> AfterTurnOrigin? {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        let partial = responseOutcomeStatus == "partial" || responseOutcomeStatus == "cancelled"
        let messageSource = ChatThreadKind.normalizedSource(source)
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        // New messages require a readable index; partial settlement saves produced work first.
        let sessions = try SessionConversation(rows: partial ? [] : ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath))
        let sessionKind: ChatThreadKind
        if ChatPersistenceContext.ownedSessionID == sessionId, let declared = ChatPersistenceContext.threadKind {
            sessionKind = declared
        } else {
            sessionKind = sessions.kind(sessionId) ?? ChatPersistenceContext.threadKind
                ?? ChatThreadKind.inferred(fromSource: messageSource)
        }
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let persistedAt = clock()
        let createdAt = role == "user"
            ? ChatPersistenceContext.importedMessageCreatedAt ?? NativeTimestampFormat.fractionalZulu(persistedAt)
            : NativeTimestampFormat.fractionalZulu(persistedAt)
        // Precompute and encode the complete payload-free observation before
        // entering the transcript lock. The lock performs no awaits and no
        // future-state lookup; it only appends/replaces immutable bytes.
        let responseStatus = responseOutcomeStatus
            ?? (canonicalAssistantCompletion && role == "assistant" ? "persisted" : nil)
        let outcomeObservation = responseStatus.flatMap {
            ResponseOutcomeObservationV2.make(
                turnID: outcomeTurnID ?? TurnTraceContext.turnId ?? runId,
                messageID: messageId,
                sessionID: sessionId,
                surface: messageSource,
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
            metadata["untrusted_sources"] = .array((PeerDataTaint.current?.checkpointSources ?? []).map(JSONValue.string))
            if let responseFailure { metadata["error"] = .string(responseFailure) }
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
        if let sources = PeerDataTaint.current?.checkpointSources, !sources.isEmpty {
            metadata["untrusted_sources"] = .array(sources.map(JSONValue.string))
        }
        // Only user rows carry external origin; assistant replies belong to the agent, not the originating bridge.
        let originProvenance = role == "user"
            ? ChatPersistenceContext.originProvenance
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
            let steer = PeerDataTaint.carried(
                peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: messageSource),
                peerID: ChatToolSessionContext.envelope?.verifiedUserId
            )
            originObject["peerSources"] = .array(steer.sources.map(JSONValue.string))
            originObject["elevatedPeerSources"] = .array(steer.elevated.map(JSONValue.string))
            metadata["origin"] = .object(originObject)
        }
        // Every conversational row's envelope records turn identity and reply routing, including assistant rows.
        // Persisted envelopes carry no trust verdict and grant no authority; tool calls use the current turn's envelope.
        let turnEnvelope: TurnEnvelope = {
            let live = TurnEnvelope.current(surface: messageSource)
            guard let origin = originProvenance else { return live }
            // A bridged turn's honest surface is the bridge it arrived on, and
            // its lane is the agent. `messageSource` is the TOOL-AUTHORIZATION
            // surface (the bridges deliberately run as "chat"), so the two
            // must not be conflated on a provenance row.
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
           let binding = ChatPersistenceContext.codexCompletionBinding,
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
                // The successful turn context is the execution truth. A shell
                // may bind blank/stale request evidence before admission, but
                // crash recovery must cache the tuple that actually produced
                // this canonical assistant row.
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
        // Payload-free outcome correlation: canonical assistant completions
        // retain the opaque turn receipt identity that produced them. This is
        // not prompt context and is never reconstructed from message prose.
        // It lets an explicit regenerate replacement name the exact earlier
        // turn rather than guessing that the preceding assistant row was it.
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
            // What the turn left changed in the world: her next turn here starts from it.
            // It started when it was first accepted, before any relaunch it resumed
            // across; a turn with no checkpoint never resumed, so its own clock is its life.
            let turn = outcomeTurnID ?? TurnTraceContext.turnId
            let accepted = turn.flatMap { try? TurnCheckpoint.read(dataRoot: dataRoot, sessionId: safeSessionId, turnId: $0) }?.acceptedAt
            if let world = await ChatWrittenFileArtifacts.world(from: result.toolDispatches,
                    since: accepted ?? persistedAt.addingTimeInterval(-Double(result.elapsedMs) / 1000), dataRoot: dataRoot) {
                metadata["world"] = world
            }
        }
        // Where this assistant row's working commentary ends and its answer
        // begins. Content is untouched; the transcript uses this to fold the
        // commentary into a detail once the turn has settled.
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
        let (appended, replacedTurnTraceID): (Bool, String?) = try await SwiftNativePersistenceCore.withFileLock(path) {
            let bytes = try (expectedLastMessageID != nil || (answerFor != nil && FileManager.default.fileExists(atPath: path.path)))
                ? Data(contentsOf: path) : nil
            if let answerFor, let bytes {
                let rows = SwiftNativePersistenceCore.decodeJSONL(bytes) { value, _ in value }.rows
                if rows.contains(where: { row in
                    guard case .object(let object) = row, case .object(let metadata)? = object["metadata"] else { return false }
                    return metadata["answerFor"] == .string(answerFor)
                }) { return (false, nil) }
            }
            if let expectedLastMessageID, let bytes {
                guard bytes.count <= 8 * 1024 * 1024,
                      let text = String(data: bytes, encoding: .utf8),
                      let tail = text.split(separator: "\n", omittingEmptySubsequences: true).last,
                      let last = try? JSONValue.parse(Data(tail.utf8)),
                      Self.messageID(in: last) == expectedLastMessageID else {
                    throw ChatOrchestrationError.underlying("The conversation changed before the reply could be saved. Reopen it before replying.")
                }
            }
            if canonicalAssistantCompletion,
               role == "assistant",
               let replacementID = ChatPersistenceContext.replacementAssistantMessageID?
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
                // A replacement is row-count neutral by construction: one row
                // replaces exactly one match, after its receipts. `ContactThread.replace`
                // emits one non-blank line per row, which is precisely what
                // `countJSONLLines` counts.
                ChatTranscriptLineCountCache.shared.record(count: replaced.count, at: path)
                return (true, priorTurnTraceID)
            } else {
                let priorCount = ChatTranscriptLineCountCache.shared.count(
                    at: path,
                    recount: Self.countJSONLLines(at:)
                )
                // Every conversational row is durable under the transcript owner's lock.
                try await ContactThread.append(messageRow, to: path)
                // `appendJSONLDurable` writes exactly one serialized line plus "\n".
                ChatTranscriptLineCountCache.shared.record(count: priorCount + 1, at: path)
                return (true, nil)
            }
        }
        guard appended else { return nil }
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
        // This receipt means exactly one thing: the locked canonical transcript
        // replacement committed. It does not call the retry a correction, say
        // that the old response was bad, or give the shadow any control.
        if let targetTurnID = OutcomeTraceIdentity.normalized(replacedTurnTraceID),
           let reactionTurnID = OutcomeTraceIdentity.normalized(TurnTraceContext.turnId),
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
                ])
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
                stamp: TranscriptRowStamp.of(id: messageId, role: role, metadata: metadata, rowSource: partial ? nil : messageSource)
            )
        } catch {
            await Self.reportTranscriptWriteFailure(label: "appendMessage session index", path: sessionsPath,
                error: error, userText: partial
                    ? "Saved this turn's partial reply, but couldn't update the conversation list."
                    : "Saved the message, but couldn't update the conversation list.",
                onNotice: onNotice)
        }
        // One signal for every row any door writes: an open chat and the phone
        // see Telegram, phone and agent turns as they land, not on the next turn.
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
        outcomeTurnID: String? = nil
    ) async throws {
        let report = failure.flatMap { ProviderFailure.report($0) }
        let canDraft = report?.cause == .refused && report?.work == .nothingRan
            && outcomeContext?.providerId?.isEmpty == false
            && outcomeContext?.modelId.isEmpty == false
        let content: String
        if report?.cause == .refused {
            let route = outcomeContext?.providerId ?? "unknown route"
            let model = outcomeContext?.modelId ?? "unknown model"
            let recovery = ChatThreadKind.normalizedSource(surface) == "app"
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
        if let runId, !runId.isEmpty, await Self.completedAssistantRunIds(path: path).contains(runId) {
            return
        }
        try await appendMessage(
            sessionId: sessionId,
            role: "assistant",
            content: content,
            runId: runId,
            attachments: [],
            persona: persona,
            source: surface,
            outcomeContext: outcomeContext,
            outcomeTurnID: outcomeTurnID,
            responseOutcomeStatus: "failed",
            providerRefusal: report?.cause == .refused,
            providerRefusalDraft: canDraft,
            // What had run when it broke, so the failure card can say whether
            // Retry is safe. Without a typed report nothing proves it was.
            failureWork: (report?.work ?? .outcomeUnknown).rawValue,
            // Mark the failure as mechanical; provider physiology already owns its lived effect.
            mechanicalRow: .systemRow
        )
    }

    static func shouldPersistFailureMessage(surface: String) -> Bool {
        // Every surface except helpers persists a visible failure row.
        !["bot"].contains(surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The one public boundary that admits an identity to durable chat state.
    /// Mounted surfaces creating a new conversation must generate and retain an
    /// ID before calling this; persistence itself never manufactures one.
    public static func resolveSessionId(_ sessionId: String?) throws -> String {
        // A transcript operation may never invent an identity. A caller that
        // lost its session id must fail at this boundary instead of silently
        // creating an orphan transcript and sessions.json row that no visible
        // conversation owns. New-session creation belongs to the mounted
        // surface before it calls into persistence, where it can retain and
        // display the generated identity.
        guard let raw = sessionId else {
            throw ChatOrchestrationError.underlying("missing chat session id")
        }
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(raw) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        return safe
    }

    static func completedAssistantRunIds(path: URL) async -> Set<String> {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var completed = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(rawLine).data(using: .utf8),
                  case .object(let row)? = try? JSONValue.parse(lineData),
                  case .string(let runId)? = row["runId"], !runId.isEmpty,
                  row["role"] == .string("assistant"), row["cancelled"] != .bool(true) else { continue }
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
        /// The previewed row's own stamp, kept beside its preview text.
        stamp: TranscriptRowStamp
    ) async throws {
        let dataRoot = self.dataRoot
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let preview = Self.previewText(content)
        let envelope = ChatToolSessionContext.envelope
        let contactName: String? = if envelope?.commandSignatureVerified == true,
            let id = envelope?.verifiedUserId {
            (try? AgentPeerStore(dataRoot: dataRoot).list())?.first(where: { $0.id == id })?.name
        } else { nil }
        let title = normalizedRole == "user"
            ? (contactName ?? Self.peerBridgeTitle(content: content, source: source) ?? Self.titleText(content))
            : nil
        let sourceKey = Self.sessionSourceKey(source: source)
        // Continuity is person-bound, never inferred from a title, allowlist,
        // or storage key. A paired phone and this Mac belong to the operator;
        // remote senders remain in their transport's identity namespace.
        let continuity: [String: JSONValue]? = {
            guard normalizedRole == "user", PeerDataTaint.abilityWriteCheck() == nil,
                  source != "ios" || envelope?.commandSignatureVerified == true
                    || ChatToolSessionContext.commandSignatureVerified == true,
                  case .object(let binding)? = ChatSessionRecollections.continuityBinding(
                    role: normalizedRole, metadata: metadata) else { return nil }
            return binding
        }()
        let continuityParticipant: String? = if case .string(let value)? = continuity?["participant"] { value } else { nil }
        let continuityScope: String? = if case .string(let value)? = continuity?["scope"] { value } else { nil }
        try await ChatSessionIndexFile.recordMessage(
            sessionId: sessionId, role: normalizedRole, source: source, sourceKey: sourceKey, kind: ChatPersistenceContext.threadKind,
            ownedSessionID: ChatPersistenceContext.ownedSessionID,
            timestamp: timestamp, syncedAt: NativeTimestampFormat.fractionalZulu(clock()), preview: preview, stamp: stamp,
            title: title, continuityParticipant: continuityParticipant, continuityScope: continuityScope,
            dataRoot: dataRoot, messagesPath: messagesPath, countMessages: { ChatTranscriptLineCountCache.shared.count(at: $0, recount: Self.countJSONLLines(at:)) },
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

    private nonisolated static func countJSONLLines(at path: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        var lineHasContent = false
        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024),
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

    /// Bridge session titles use the peer name from its turn header; other surfaces or missing headers yield nil.
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
    private nonisolated static func sessionSourceKey(source: String) -> String? {
        if let bound = ChatToolSessionContext.envelope?.deliveryRoute?.sourceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !bound.isEmpty {
            return bound
        }
        if let route = ChatToolSessionContext.replyRoute?.sourceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !route.isEmpty {
            return route
        }
        return source == "app" ? "app" : nil
    }
}
