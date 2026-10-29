import Foundation
import NativeAgentCore
import AuthoredCapabilities
import ChatTurnRuntime
import ChatTurnContracts
import PersistenceCore
import ProviderRouting
import Transcripts
import TurnTrace
import NativeAgentShared
import BackgroundLoops
// Blueprint: | `SlackSocketModeLoop+Answers.swift` | `SlackSocketModeLoop`: journal-owned inbound handling, durable answer recovery and delivery, accepted-reply reconciliation and deferred settings settlement |

/// One notice per kind per turn. A reconnect ladder emits up to ten
/// `provider_retry` notices; posting each would bury the channel.
private actor SlackTurnNoticeMemory {
    private var announced: Set<String> = []
    func claim(_ kind: String) -> Bool { announced.insert(kind).inserted }
    /// Release a failed post's claim so the same notice kind can be sent again.
    func release(_ kind: String) { announced.remove(kind) }
}

extension SlackSocketModeLoop {
    /// A settings change must not stop the handler delivering its own receipt.
    @discardableResult
    public static func afterCurrentHandling(_ operation: @escaping @Sendable () async -> Void) async -> Bool {
        if let deferAfterHandling {
            await deferAfterHandling(operation)
            return true
        }
        await operation()
        return false
    }

    /// An accepted human message is her turn, not the socket's: it runs
    /// under its own lifetime (the journal owns admission and settlement), so
    /// a closing or recycled socket changes only the reply's delivery. It
    /// also never inherits the socket loop's utility priority.
    func spawnInboundHandling(_ inbound: SlackInboundMessage) async {
        await deliveryJournal.startHandler(eventId: inbound.eventId) {
            _ = await handleClaimedInbound(inbound)
        }
    }

    public func recoverReply(_ response: ChatResponse, originRunId: String,
                             route: AgentBridgeCompletionRoute? = nil, priorVerdict: String? = nil) async throws -> String {
        var indexed = try await deliveryJournal.answerRecord(runId: response.runId, originRunId: originRunId)
        if indexed == nil, let route, let session = response.sessionId, let channel = route.destinationId, !channel.isEmpty {
            let inbound = SlackInboundMessage(eventId: "answer:" + response.runId, teamId: config.teamId ?? "",
                channelId: channel, userId: route.requesterUserId ?? "", eventType: "answer", text: "",
                ts: "", threadTs: route.threadId, channelType: nil,
                isDirectMessage: channel.hasPrefix("D"), files: [], opensReplyThread: false)
            indexed = try await deliveryJournal.reserveReply(inbound, reply: Self.preparedReply(text: response.output, attachments: response.attachments ?? []),
                runId: response.runId, sessionId: session, priorVerdict: priorVerdict)
        }
        guard let indexed else {
            throw SlackInboundJournalError.missingClaim(response.runId)
        }
        guard route == nil || indexed.inbound.channelId == route?.destinationId
            && indexed.inbound.replyThreadTs == route?.threadId else { throw SlackInboundJournalError.malformed }
        let eventId = indexed.inbound.eventId
        guard await deliveryJournal.acquireHandler(eventId: eventId) else { return "owed" }
        do {
            let verdict = try await recoverClaimedReply(response, eventId: eventId, priorVerdict: priorVerdict)
            await deliveryJournal.releaseHandler(eventId: eventId)
            return verdict
        } catch {
            await deliveryJournal.releaseHandler(eventId: eventId)
            throw error
        }
    }

    private func recoverClaimedReply(_ response: ChatResponse, eventId: String, priorVerdict: String?) async throws -> String {
        guard let record = try await deliveryJournal.record(eventId: eventId),
              let session = response.sessionId, record.assistantSessionId == session else {
            throw SlackInboundJournalError.missingClaim(response.runId)
        }
        let inbound = record.inbound
        guard config.teamId == nil || config.teamId == inbound.teamId,
              inbound.eventType == "answer" || config.allowedChannelIds.contains(inbound.channelId) || config.allowedUserIds.contains(inbound.userId) else {
            throw SlackSocketModeError.api("Recovery paused: current Slack workspace or admission policy no longer matches the accepted message")
        }
        if let phase = record.settledAssistantRuns?[response.runId] {
            guard ["delivered", "sent_unconfirmed", "failed_before_answer"].contains(phase) else { throw SlackInboundJournalError.malformed }
            let verdict = phase == "delivered" ? "completed" : phase
            try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot, sessionId: session,
                                                                               runId: response.runId, verdict: verdict)
            return verdict
        }
        if record.assistantRunId == response.runId, record.phase.isTerminal {
            let verdict = record.phase == .failedBeforeAnswer ? "failed_before_answer"
                : record.phase == .sentUnconfirmed ? "sent_unconfirmed" : "completed"
            try await settleCheckpoint(record, verdict: verdict)
            return verdict
        }
        if record.assistantRunId != response.runId {
            guard record.phase.isTerminal else { return "owed" }
            try await deliveryJournal.prepareSuccessor(eventId: record.inbound.eventId,
                response: Self.preparedReply(text: response.output, attachments: response.attachments ?? []), runId: response.runId, sessionId: session)
        }
        if record.assistantRunId == response.runId, record.phase == .generating || record.phase == .claimed {
            _ = try await deliveryJournal.prepare(eventId: record.inbound.eventId, reply: Self.preparedReply(text: response.output, attachments: response.attachments ?? []))
        }
        if let priorVerdict {
            let migrated = priorVerdict == "completed"
                ? try await deliveryJournal.markDelivered(eventId: eventId)
                : try await deliveryJournal.settleUnconfirmed(eventId: eventId)
            try await settleCheckpoint(migrated, verdict: priorVerdict)
            return priorVerdict
        }
        guard await processDurableInbound(inbound) else { return "owed" }
        let settled = try await deliveryJournal.record(eventId: record.inbound.eventId)
        return settled?.phase == .failedBeforeAnswer ? "failed_before_answer"
            : settled?.phase == .sentUnconfirmed ? "sent_unconfirmed" : "completed"
    }

    private static func preparedReply(text: String, attachments: [ChatTurnRuntime.MultimodalAttachment]) -> SlackPreparedReply {
        let uploads = uploadableImageAttachments(attachments).map {
            SlackPreparedUpload(path: $0.path ?? "", name: $0.name ?? URL(fileURLWithPath: $0.path ?? "").lastPathComponent, mime: $0.mime)
        }
        return .make(text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !uploads.isEmpty
            ? "Generated image" : text, uploads: uploads)
    }

    private func settleCheckpoint(_ record: SlackInboundDeliveryRecord, verdict: String) async throws {
        if let session = record.assistantSessionId, let run = record.assistantRunId {
            try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot, sessionId: session,
                                                                               runId: run, verdict: verdict)
        }
    }

    public func reconcileSavedReplies() async throws {
        for record in try await deliveryJournal.unresolved() {
            guard !Task.isCancelled else { throw CancellationError() }
            let inbound = record.inbound
            // A credential/workspace change must not replay old workspace
            // work into the newly selected Slack installation.
            guard config.teamId == nil || config.teamId == inbound.teamId,
                  inbound.eventType == "answer" || config.allowedChannelIds.contains(inbound.channelId)
                    || config.allowedUserIds.contains(inbound.userId) else {
                await recordError(
                    context: "inbound_recovery_policy_mismatch",
                    error: SlackSocketModeError.api("Recovery paused: current Slack workspace or admission policy no longer matches the accepted message"),
                    inbound: inbound
                )
                continue
            }
            await spawnInboundHandling(inbound)
        }
    }

    /// The production receive/history paths use this durable lifecycle. A
    /// prepared reply may be safely retried without invoking the model again.
    /// A dispatch whose outcome is ambiguous is reconciled, never blindly
    /// replayed. History absence is NOT proof of non-delivery (retention,
    /// deletion, visibility, and eventual consistency can all hide a post).
    @discardableResult
    func handleDurableInbound(_ inbound: SlackInboundMessage) async -> Bool {
        guard await deliveryJournal.acquireHandler(eventId: inbound.eventId) else { return false }
        let delivered = await handleClaimedInbound(inbound)
        await deliveryJournal.releaseHandler(eventId: inbound.eventId)
        return delivered
    }

    private func handleClaimedInbound(_ inbound: SlackInboundMessage) async -> Bool {
        let completion = SlackHandlingCompletion()
        let delivered = await Self.$deferAfterHandling.withValue({ operation in
            await completion.append(operation)
        }) {
            await processDurableInbound(inbound)
        }
        await completion.finish()
        return delivered
    }

    private func processDurableInbound(_ received: SlackInboundMessage) async -> Bool {
        do {
            let claim = try await deliveryJournal.claim(received)
            guard case .claimed(var record) = claim else { return true }
            let inbound = record.inbound
            // Once the pass that ran its turn has handled it, whatever the outcome.
            var handled: (session: String, run: String)?
            defer {
                if let handled {
                    var payload: [String: JSONValue] = ["text": .string(inbound.text), "channel_id": .string(inbound.channelId),
                        "user_id": .string(inbound.userId), "session_id": .string(handled.session), "turn_id": .string(handled.run)]
                    if !config.allowedUserIds.contains(inbound.userId) { payload["agent"] = .string("slack:" + inbound.userId) }
                    AbilityStore(dataRoot: dataRoot).signal("message.arrived:slack", payload)
                }
            }
            // Only unresolved messages can wake bots; the durable claim keeps
            // socket, history and recovery from repeating the same fan-out.
            if (try? await deliveryJournal.claimBotEvent(eventId: inbound.eventId)) == true {
                await botEventIntake(inbound.channelId, inbound.text, inbound.userId)
            }
            if record.phase == .claimed, inbound.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/retry resend" {
                if let rejected = try await deliveryJournal.retryRejectedReply(for: inbound) {
                    return await handleDurableInbound(rejected.inbound)
                }
                let saved = try await deliveryJournal.savedUnconfirmedReply(for: inbound)
                if let saved, let reply = saved.prepared, let session = saved.assistantSessionId {
                    try await deliveryJournal.prepareSuccessor(eventId: saved.inbound.eventId,
                        response: reply, runId: "resend:" + inbound.eventId, sessionId: session)
                    _ = try await deliveryJournal.markDelivered(eventId: inbound.eventId)
                    return await handleDurableInbound(saved.inbound)
                }
                record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                    reply: .make(text: "There's no saved answer waiting to be delivered.", uploads: []))
            }
            if record.phase == .generating {
                if let session = record.assistantSessionId, let run = record.assistantRunId {
                    if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: run) {
                        record = try await deliveryJournal.prepare(eventId: inbound.eventId, reply: Self.preparedReply(text: response.output, attachments: response.attachments ?? []))
                    } else {
                        // The checkpoint owns an unfinished turn; do not run the inbound again.
                        if try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run) { return false }
                        record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                            reply: .make(text: "Couldn't finish the reply.", uploads: []), failedBeforeAnswer: true)
                    }
                } else {
                    record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                        reply: .make(text: "Couldn't finish the reply.", uploads: []), failedBeforeAnswer: true)
                }
            }
            if record.phase == .outcomeUnknown && record.prepared == nil {
                if let session = record.assistantSessionId, let run = record.assistantRunId {
                    if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: run) {
                        record = try await deliveryJournal.prepare(eventId: inbound.eventId, reply: Self.preparedReply(text: response.output, attachments: response.attachments ?? []))
                    } else if try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run) { return false }
                }
            }
            if record.phase == .outcomeUnknown && record.prepared == nil {
                // An interrupted turn without a prepared reply keeps no-replay evidence.
                _ = try await deliveryJournal.settleUnconfirmed(eventId: inbound.eventId, failedBeforeAnswer: true)
                return true
            }
            if record.phase == .dispatching || record.phase == .outcomeUnknown {
                return await reconcileDurableReply(record)
            }
            if record.phase == .claimed {
                let hydration = await hydratingAttachments(inbound)
                guard !hydration.hasTransientFailure else { return false }
                let hydrated = hydration.inbound
                guard hydration.notice != nil || !hydrated.text.isEmpty || !hydrated.attachments.isEmpty else {
                    await recordError(context: "download_inbound_file", error: SlackSocketModeError.api("no supported Slack attachment could be read"), inbound: inbound)
                    return false
                }
                guard !Task.isCancelled else { return false }
                let sessionId = try await SlackSessionStore(dataRoot: dataRoot).activeSessionId(for: inbound)
                let runId = UUID().uuidString
                // Registered for Stop at admission, before any await: a Stop from
                // here on names this run; the turn's acceptance is the same one.
                let turnId = TurnTraceContext.mintTurnId()
                let stopFlag = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: sessionId, runId: runId, turnId: turnId)
                defer { ChatCancelFlag.finish(stopFlag) }
                record = try await deliveryJournal.beginGeneration(eventId: inbound.eventId, runId: runId, sessionId: sessionId)
                handled = (sessionId, runId)
                let reply: SlackSocketModeReply
                var failedBeforeAnswer = false
                do {
                    reply = try await TurnTraceContext.$turnId.withValue(turnId) {
                        try await ChatPersistenceContext.$pinnedTurnRunID.withValue(runId) {
                            try await attachmentAwareReply(hydration, original: inbound, sessionId: sessionId)
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return false }
                    failedBeforeAnswer = true
                    await recordError(context: "chat_handler", error: error, inbound: inbound)
                    // Prepare the error notice too. Its delivery is a real
                    // external effect and must not multiply on retry.
                    let detail = error is SlackSessionStorageError
                        ? "Slack conversation storage needs repair before this message can be answered. Existing conversation bindings were preserved."
                        : ProviderRecoveryPolicy.personMessage(error) ?? "Couldn't finish the reply."
                    reply = SlackSocketModeReply(text: (hydration.notice.map { $0 + "\n\n" } ?? "") + detail)
                }
                let prepared = Self.preparedReply(text: reply.text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: reply.attachments)
                guard !prepared.text.isEmpty || !prepared.uploads.isEmpty else {
                    await recordError(context: "empty_reply", error: SlackSocketModeError.api("chat returned empty reply"), inbound: inbound)
                    return false
                }
                record = try await deliveryJournal.prepare(
                    eventId: inbound.eventId,
                    reply: prepared,
                    failedBeforeAnswer: failedBeforeAnswer
                )
            }
            guard let prepared = record.prepared else { throw SlackInboundJournalError.malformed }
            guard !TurnQuietHoursWindow.holdsResidentWake(session: record.assistantSessionId, dataRoot: dataRoot) else { return false }
            guard record.lastRejection?.preparedFingerprint != prepared.fingerprint else { return false }
            guard !Task.isCancelled else { return false }
            // Missing local artifacts are a pre-dispatch failure. Preserve the
            // prepared reply and do not rerun the chat/tool turn to recreate it.
            guard prepared.uploads.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                _ = try await deliveryJournal.retryPrepared(eventId: inbound.eventId, detail: "prepared Slack image is no longer available")
                await recordError(context: "prepared_reply_artifact_missing", error: SlackSocketModeError.api("prepared Slack image is no longer available"), inbound: inbound)
                return false
            }
            guard !config.botToken.isEmpty else { throw SlackSocketModeError.api("Slack reply token is unavailable") }
            let uploads = try prepared.uploads.map { upload in
                let data = try Data(contentsOf: URL(fileURLWithPath: upload.path))
                guard !data.isEmpty else {
                    throw SlackSocketModeError.api("Prepared Slack image is empty")
                }
                return (upload, data)
            }
            if record.confirmedText != true {
                _ = try await deliveryJournal.beginDispatch(eventId: inbound.eventId)
                var input: [String: JSONValue] = [
                    "channel": .string(inbound.channelId),
                    "text": .string(prepared.text),
                    "metadata": Self.deliveryMetadata(eventId: inbound.eventId, fingerprint: prepared.fingerprint),
                ]
                if let run = record.assistantRunId, let id = UUID(uuidString: run) { input["client_msg_id"] = .string(id.uuidString) }
                if let threadTs = inbound.replyThreadTs { input["thread_ts"] = .string(threadTs) }
                guard try CodexCompletionReadout.permitsDelivery(sessionId: record.assistantSessionId,
                    runId: record.assistantRunId, configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
                    dataRoot: dataRoot) else { return false }
                let posted: JSONValue
                do {
                    posted = try await SlackWebAPI.postMessage(input: input, dataRoot: dataRoot, tokenOverride: config.botToken)
                } catch {
                    return await recordUnknownDelivery(inbound, detail: "Reply dispatch outcome is unknown: \(Self.redact(String(describing: error)))")
                }
                guard Self.envelopeOK(posted) else {
                    if Self.isProvenSlackRejection(posted) {
                        let fields = posted.objectValue
                        let reason = fields?["error"]?.stringValue ?? fields?["response"]?.objectValue?["error"]?.stringValue ?? ""
                        _ = try await deliveryJournal.retryPrepared(eventId: inbound.eventId,
                            detail: "Reply rejected before acceptance: \(reason). Use /retry resend to deliver the saved answer.",
                            rejectionReason: reason)
                        await recordError(context: "post_reply", error: SlackSocketModeError.api(String(describing: posted)), inbound: inbound)
                        return false
                    }
                    return await recordUnknownDelivery(inbound, detail: "Slack returned an ambiguous reply failure")
                }
                record = try await deliveryJournal.confirmReplyPart(eventId: inbound.eventId, isText: true)
            }
            // File completion has no message-metadata hook. Once any upload
            // begins, a failed/crashed attempt is explicitly ambiguous; it is
            // never replayed merely because the text marker is visible.
            for (upload, data) in uploads.dropFirst(record.confirmedUploadCount ?? 0) {
                _ = try await deliveryJournal.beginDispatch(eventId: inbound.eventId)
                guard try CodexCompletionReadout.permitsDelivery(sessionId: record.assistantSessionId,
                    runId: record.assistantRunId, configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
                    dataRoot: dataRoot) else { return false }
                do {
                    guard Self.envelopeOK(try await SlackWebAPI.uploadFile(upload, data: data,
                        channel: inbound.channelId, threadTs: inbound.replyThreadTs,
                        dataRoot: dataRoot, tokenOverride: config.botToken)) else {
                        return await recordUnknownDelivery(inbound, detail: "Text reply accepted; image completion is unconfirmed")
                    }
                } catch {
                    return await recordUnknownDelivery(inbound, detail: "Text reply accepted; image dispatch outcome is unknown")
                }
                record = try await deliveryJournal.confirmReplyPart(eventId: inbound.eventId, isText: false)
            }
            _ = try await deliveryJournal.markDelivered(eventId: inbound.eventId)
            try await settleCheckpoint(record, verdict: "completed")
            await recordReceipt(kind: "reply", inbound: inbound, reply: prepared.text)
            await writeState([
                "lastDeliveryOutcome": .string("delivered"),
                "lastDeliveryOutcomeEventId": .string(inbound.eventId),
                "lastDeliveryOutcomeDetail": .null,
            ])
            return true
        } catch {
            await recordError(context: "inbound_delivery_journal", error: error, inbound: received)
            return false
        }
    }

    /// Generate a reply with in-turn notices.
    func generateReply(
        _ inbound: SlackInboundMessage, sessionId: String,
        sink: @escaping SlackChatProgressSink
    ) async throws -> SlackSocketModeReply {
        if let progressChatHandler {
            return try await progressChatHandler(inbound, sessionId, sink)
        }
        throw SlackSocketModeError.api("no Slack chat handler configured")
    }

    /// Post each notice kind once in the reply thread; a failed post releases its claim.
    func noticeSink(for inbound: SlackInboundMessage) -> SlackChatProgressSink {
        let memory = SlackTurnNoticeMemory()
        // Notices use the same captured credential snapshot as reply delivery.
        let botToken = config.botToken
        let dataRoot = self.dataRoot
        let channelId = inbound.channelId
        let threadTs = inbound.replyThreadTs
        return { kind, text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, await memory.claim(kind) else { return }
            var input: [String: JSONValue] = [
                "channel": .string(channelId),
                "text": .string(trimmed),
            ]
            if let threadTs { input["thread_ts"] = .string(threadTs) }
            let posted = (try? await SlackWebAPI.postMessage(input: input, dataRoot: dataRoot, tokenOverride: botToken)).map(Self.envelopeOK) ?? false
            if !posted { await memory.release(kind) }
        }
    }

    private func recordUnknownDelivery(_ inbound: SlackInboundMessage, detail: String) async -> Bool {
        do {
            _ = try await deliveryJournal.markOutcomeUnknown(eventId: inbound.eventId, detail: detail)
        } catch {
            await recordError(context: "inbound_delivery_journal", error: error, inbound: inbound)
        }
        await writeState([
            "lastDeliveryOutcome": .string("outcome_unknown"),
            "lastDeliveryOutcomeEventId": .string(inbound.eventId),
            "lastDeliveryOutcomeDetail": .string(detail),
        ])
        await recordError(context: "reply_outcome_unknown", error: SlackSocketModeError.api(detail), inbound: inbound)
        do {
            guard let record = try await deliveryJournal.record(eventId: inbound.eventId) else { return false }
            return await reconcileDurableReply(record)
        } catch { return false }
    }

    private func reconcileDurableReply(_ record: SlackInboundDeliveryRecord) async -> Bool {
        let inbound = record.inbound
        guard let prepared = record.prepared, let botUserId = config.botUserId, !botUserId.isEmpty else {
            return await settleUnconfirmedReply(record, detail: "Cannot reconcile reply without its prepared artifact and bot identity")
        }
        var params: [String: String] = [
            "channel": inbound.channelId,
            "oldest": inbound.ts,
            "inclusive": "false",
            "include_all_metadata": "true",
            "limit": "100",
        ]
        let method: String
        if let threadTs = inbound.replyThreadTs {
            method = "conversations.replies"
            params["ts"] = threadTs
        } else {
            method = "conversations.history"
        }
        do {
            let response = try await slackAPI(method: method, httpMethod: "GET", params: params)
            guard Self.hasUniqueAcceptedReply(
                response: response,
                inbound: inbound,
                fingerprint: prepared.fingerprint,
                botUserId: botUserId
            ) else {
                return await settleUnconfirmedReply(record, detail: "Slack history does not uniquely prove acceptance")
            }
            guard prepared.uploads.isEmpty else {
                return await settleUnconfirmedReply(record, detail: "Text reply accepted; image completion is unconfirmed")
            }
            _ = try await deliveryJournal.markDelivered(eventId: inbound.eventId)
            try await settleCheckpoint(record, verdict: "completed")
            await recordReceipt(kind: "reply_reconciled", inbound: inbound, reply: prepared.text)
            await writeState([
                "lastDeliveryOutcome": .string("delivered"),
                "lastDeliveryOutcomeEventId": .string(inbound.eventId),
                "lastDeliveryOutcomeDetail": .string("Accepted reply reconciled from Slack history"),
            ])
            return true
        } catch {
            return await settleUnconfirmedReply(record, detail: "Slack reply reconciliation unavailable: \(Self.redact(String(describing: error)))")
        }
    }

    private func settleUnconfirmedReply(_ record: SlackInboundDeliveryRecord, detail: String) async -> Bool {
        do {
            _ = try await deliveryJournal.markOutcomeUnknown(eventId: record.inbound.eventId, detail: detail)
            _ = try await deliveryJournal.settleUnconfirmed(eventId: record.inbound.eventId)
            try await settleCheckpoint(record, verdict: "sent_unconfirmed")
            await recordError(context: "reply_sent_unconfirmed", error: SlackSocketModeError.api(detail), inbound: record.inbound)
            return true
        } catch {
            await recordError(context: "inbound_delivery_journal", error: error, inbound: record.inbound)
            return false
        }
    }

    static func deliveryMetadata(eventId: String, fingerprint: String) -> JSONValue {
        .object([
            "event_type": .string("nativeagent_reply"),
            "event_payload": .object([
                "event_id": .string(eventId),
                "fingerprint": .string(fingerprint),
            ]),
        ])
    }

    /// Positive proof only. Incomplete/filtered history cannot establish
    /// uniqueness, and a missing message never establishes non-delivery.
    static func hasUniqueAcceptedReply(
        response: [String: JSONValue],
        inbound: SlackInboundMessage,
        fingerprint: String,
        botUserId: String
    ) -> Bool {
        guard response["ok"]?.boolValue == true,
              response["has_more"]?.boolValue == false,
              response["is_limited"]?.boolValue != true,
              response["response_metadata"]?.objectValue?["next_cursor"]?.stringValue?.isEmpty != false,
              case .array(let messages)? = response["messages"] else { return false }
        var matches = 0
        for raw in messages {
            guard let message = raw.objectValue else { return false }
            guard let metadata = message["metadata"]?.objectValue,
                  metadata["event_type"]?.stringValue == "nativeagent_reply",
                  let payload = metadata["event_payload"]?.objectValue,
                  payload["event_id"]?.stringValue == inbound.eventId else { continue }
            guard payload["fingerprint"]?.stringValue == fingerprint,
                  message["user"]?.stringValue == botUserId,
                  let ts = message["ts"]?.stringValue, !ts.isEmpty else { return false }
            let thread = message["thread_ts"]?.stringValue
            if let expected = inbound.replyThreadTs {
                guard thread == expected else { return false }
            } else if let thread, thread != ts {
                return false
            }
            matches += 1
        }
        return matches == 1
    }

    static func isProvenSlackRejection(_ envelope: JSONValue) -> Bool {
        guard let value = envelope.objectValue, value["ok"]?.boolValue == false,
              let error = value["error"]?.stringValue ?? value["response"]?.objectValue?["error"]?.stringValue else { return false }
        // Slack documents internal_error/fatal_error as potentially partially
        // successful. Only these explicit classes prove non-acceptance.
        return Set([
            "invalid_auth", "not_authed", "token_expired", "token_revoked",
            "missing_scope", "no_permission", "not_in_channel", "channel_not_found",
            "is_archived", "no_text", "msg_too_long", "invalid_arguments",
            "invalid_metadata", "metadata_too_large", "ratelimited", "rate_limited",
        ]).contains(error)
    }

    private static func envelopeOK(_ value: JSONValue) -> Bool {
        guard case .object(let obj) = value,
              case .bool(let ok)? = obj["ok"] else {
            return false
        }
        return ok
    }
}
