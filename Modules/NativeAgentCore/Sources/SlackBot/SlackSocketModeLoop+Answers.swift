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
// Blueprint: | `SlackSocketModeLoop+Answers.swift` | `SlackSocketModeLoop`: durable replies, live publication and reconciliation |

/// One notice per kind per turn. Repeated progress notices share a claim; an unconfirmed post must not be repeated.
private actor SlackTurnNoticeMemory {
    private var announced: Set<String> = []
    func claim(_ kind: String) -> Bool { announced.insert(kind).inserted }
    /// Release only after Slack positively proves non-acceptance.
    func release(_ kind: String) { announced.remove(kind) }
}

extension SlackSocketModeLoop {
    /// The journal owns accepted turns independently of socket lifetime and utility priority; closing or recycling a socket changes only reply delivery.
    func spawnInboundHandling(_ inbound: SlackInboundMessage) async {
        await deliveryJournal.startHandler(eventId: inbound.eventId) {
            _ = await handleClaimedInbound(inbound)
        }
    }

    public func recoverReply(_ response: ChatResponse, originRunId: String,
                             route: AgentBridgeCompletionRoute? = nil) async throws -> String {
        var indexed = try await deliveryJournal.answerRecord(runId: response.runId, originRunId: originRunId)
        if response.isSilentCompletion {
            if let indexed, let session = response.sessionId {
                guard try await settleSilentInbound(indexed.inbound, sessionId: session, runId: response.runId) else {
                    throw SlackInboundJournalError.malformed
                }
            }
            return "completed"
        }
        if indexed == nil, let route, let session = response.sessionId, let channel = route.destinationId, !channel.isEmpty {
            let inbound = SlackInboundMessage(eventId: "answer:" + response.runId, teamId: config.teamId ?? "",
                channelId: channel, userId: route.requesterUserId ?? "", eventType: "answer", text: "",
                ts: "", threadTs: route.threadId, channelType: nil,
                isDirectMessage: channel.hasPrefix("D"), files: [], opensReplyThread: false)
            indexed = try await deliveryJournal.reserveReply(inbound,
                reply: Self.preparedReply(text: Self.replyText(response), attachments: response.attachments ?? []),
                runId: response.runId, sessionId: session)
        }
        guard let indexed else {
            throw SlackInboundJournalError.missingClaim(response.runId)
        }
        guard route == nil || indexed.inbound.channelId == route?.destinationId
            && indexed.inbound.replyThreadTs == route?.threadId else { throw SlackInboundJournalError.malformed }
        let eventId = indexed.inbound.eventId
        guard await deliveryJournal.acquireHandler(eventId: eventId) else { return "owed" }
        do {
            let verdict = try await recoverClaimedReply(response, eventId: eventId)
            await deliveryJournal.releaseHandler(eventId: eventId)
            return verdict
        } catch {
            await deliveryJournal.releaseHandler(eventId: eventId)
            throw error
        }
    }

    private func recoverClaimedReply(_ response: ChatResponse, eventId: String) async throws -> String {
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
            guard ["delivered", "completed_without_post", "sent_unconfirmed", "failed_before_answer"].contains(phase) else {
                throw SlackInboundJournalError.malformed
            }
            let verdict = ["delivered", "completed_without_post"].contains(phase) ? "completed" : phase
            try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot, sessionId: session,
                                                                               runId: response.runId, verdict: verdict)
            return verdict
        }
        if record.assistantRunId == response.runId, record.phase.isTerminal, record.phase != .interrupted {
            let verdict = Self.replyVerdict(record)
            guard verdict != "owed" else { return verdict }
            try await settleCheckpoint(record, verdict: verdict)
            return verdict
        }
        if record.assistantRunId != response.runId {
            guard record.phase.isTerminal else { return "owed" }
            try await deliveryJournal.prepareSuccessor(eventId: record.inbound.eventId,
                response: Self.preparedReply(text: Self.replyText(response), attachments: response.attachments ?? []),
                runId: response.runId, sessionId: session)
        }
        if record.assistantRunId == response.runId,
           record.phase == .generating || record.phase == .claimed || record.phase == .interrupted {
            _ = try await deliveryJournal.prepare(
                eventId: record.inbound.eventId,
                reply: Self.preparedReply(text: Self.replyText(response), attachments: response.attachments ?? [])
            )
        }
        guard await handleClaimedInbound(inbound) else { return "owed" }
        guard let settled = try await deliveryJournal.record(eventId: record.inbound.eventId),
              settled.assistantRunId == response.runId else {
            throw SlackInboundJournalError.missingClaim(response.runId)
        }
        return Self.replyVerdict(settled)
    }

    private static func replyVerdict(_ record: SlackInboundDeliveryRecord) -> String {
        switch record.phase {
        case .delivered, .completedWithoutPost: "completed"
        case .failedBeforeAnswer: "failed_before_answer"
        case .sentUnconfirmed: "sent_unconfirmed"
        default: "owed"
        }
    }

    private static func preparedReply(text: String, attachments: [ChatTurnRuntime.MultimodalAttachment]) -> SlackPreparedReply {
        let uploads = uploadableImageAttachments(attachments).map {
            SlackPreparedUpload(path: $0.path ?? "", name: $0.name ?? URL(fileURLWithPath: $0.path ?? "").lastPathComponent, mime: $0.mime)
        }
        return .make(text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !uploads.isEmpty
            ? "Generated image" : text, uploads: uploads)
    }

    /// A stopped or failed turn's saved words go out once, closed by the words this door already uses for a stop or a failure.
    private static func replyText(_ response: ChatResponse) -> String {
        let ending: String
        switch response.terminalState {
        case .stopped?: ending = "Stopped."
        case .failed?: ending = response.statusDetail ?? "Couldn't finish the reply."
        default: return response.output
        }
        return [response.output, ending].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
            // A credential/workspace change must not replay old workspace work into the newly selected Slack installation.
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

    /// Retry prepared replies without rerunning the model; reconcile ambiguous dispatches before replay. History absence cannot prove non-delivery: retention,
    /// deletion, visibility and eventual consistency can hide a post.
    @discardableResult
    func handleDurableInbound(_ inbound: SlackInboundMessage) async -> Bool {
        guard await deliveryJournal.acquireHandler(eventId: inbound.eventId) else { return false }
        let delivered = await handleClaimedInbound(inbound)
        await deliveryJournal.releaseHandler(eventId: inbound.eventId)
        return delivered
    }

    private func handleClaimedInbound(_ received: SlackInboundMessage) async -> Bool {
        do {
            let claim = try await deliveryJournal.claim(received)
            guard case .claimed(var record) = claim else { return true }
            let inbound = record.inbound
            if record.phase == .generating || record.phase == .outcomeUnknown,
               let session = record.assistantSessionId, let run = record.assistantRunId,
               try await settleSilentInbound(inbound, sessionId: session, runId: run) { return true }
            var handled: (session: String, run: String)?
            defer {
                if let handled {
                    var payload: [String: JSONValue] = ["text": .string(inbound.text), "channel_id": .string(inbound.channelId),
                        "user_id": .string(inbound.userId), "session_id": .string(handled.session), "turn_id": .string(handled.run)]
                    if !config.allowedUserIds.contains(inbound.userId) { payload["agent"] = .string("slack:" + inbound.userId) }
                    AbilityStore(dataRoot: dataRoot).signal("message.arrived:slack", payload)
                }
            }
            // Durable claims prevent socket and recovery from repeating bot fan-out.
            if try await deliveryJournal.claimBotEvent(eventId: inbound.eventId) {
                try await botEventIntake(inbound.channelId, inbound.text, inbound.userId, inbound.eventId)
            }
            if record.phase == .claimed, record.resolvedRetryInbound == nil,
               inbound.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/retry" {
                if let interrupted = try await deliveryJournal.retryInterruptedGeneration(for: inbound) {
                    record = interrupted
                } else {
                    record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                        reply: .make(text: "There's no interrupted message to retry. Use /retry resend for a saved answer.", uploads: []))
                }
            }
            if record.phase == .claimed, inbound.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/retry resend" {
                if let rejected = try await deliveryJournal.retryRejectedReply(for: inbound) {
                    return await handleDurableInbound(rejected.inbound)
                }
                let saved = try await deliveryJournal.savedUnconfirmedReply(for: inbound)
                if let saved, saved.prepared != nil, saved.assistantSessionId != nil {
                    try await deliveryJournal.resumeUnconfirmedReply(eventId: saved.inbound.eventId)
                    _ = try await deliveryJournal.markDelivered(eventId: inbound.eventId)
                    return await handleDurableInbound(saved.inbound)
                }
                record = try await deliveryJournal.prepare(eventId: inbound.eventId,
                    reply: .make(text: "There's no saved answer waiting to be delivered.", uploads: []))
            }
            if record.phase == .generating || record.phase == .outcomeUnknown && record.prepared == nil {
                guard let session = record.assistantSessionId, let run = record.assistantRunId else {
                    throw SlackInboundJournalError.malformed
                }
                if let response = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: session, runId: run) {
                    record = try await deliveryJournal.prepare(
                        eventId: inbound.eventId,
                        reply: Self.preparedReply(text: Self.replyText(response), attachments: response.attachments ?? [])
                    )
                } else {
                    // A live turn owns its eventual answer; only an orphaned generation is interrupted.
                    guard !ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).contains(where: {
                        $0.sessionId == session && $0.runId == run
                    }) else { return false }
                    await settle { [record] in
                        do {
                            try await settleCheckpoint(record, verdict: "let_go")
                            let detail = "Generation interrupted without a saved answer. Check any tool effects before explicitly running /retry."
                            _ = try await deliveryJournal.interruptGeneration(eventId: inbound.eventId, detail: detail)
                            await recordError(context: "generation_interrupted", error: SlackSocketModeError.api(detail), inbound: inbound)
                            let notice = noticeSink(for: inbound, preview: replyPreview(for: inbound, sessionId: session))
                            await notice(.notice(kind: "generation_interrupted", text: detail))
                        } catch { await recordError(context: "generation_interrupted", error: error, inbound: inbound) }
                    }
                    return false
                }
            }
            if record.phase == .dispatching || record.phase == .outcomeUnknown {
                return await reconcileDurableReply(record)
            }
            if record.phase == .claimed {
                let hydration = await hydratingAttachments(record.resolvedRetryInbound ?? inbound)
                let hydrated = hydration.inbound
                guard hydration.notice != nil || !hydrated.text.isEmpty || !hydrated.attachments.isEmpty else {
                    await recordError(
                        context: "download_inbound_file",
                        error: SlackSocketModeError.api("no supported Slack attachment could be read"),
                        inbound: inbound
                    )
                    return false
                }
                guard !Task.isCancelled else { return false }
                // A replayed event keeps its run and conversation, so a row the agent's turn already saved stays the one row.
                let sessionId: String
                if let held = record.assistantSessionId { sessionId = held }
                else { sessionId = try await SlackSessionStore(dataRoot: dataRoot).activeSessionId(for: inbound) }
                let runId = record.assistantRunId ?? UUID().uuidString
                // Register Stop before any await so cancellation names the admitted run.
                let turn = Turn(run: runId, session: sessionId)
                let handler = SlackHandler(turn: turn)
                let stopFlag = ChatCancelFlag.accept(dataRoot: dataRoot, sessionId: sessionId, runId: turn.run, turnId: turn.id)
                defer { ChatCancelFlag.finish(stopFlag) }
                record = try await deliveryJournal.beginGeneration(eventId: inbound.eventId, runId: runId, sessionId: sessionId)
                handled = (sessionId, runId)
                let reply: SlackSocketModeReply
                var failedBeforeAnswer = false
                do {
                    reply = try await TurnTraceContext.$turnId.withValue(turn.id) {
                        try await attachmentAwareReply(hydration, original: inbound, sessionId: sessionId, handler: handler)
                    }
                } catch {
                    guard !Task.isCancelled else { return false }
                    await recordError(context: "chat_handler", error: error, inbound: inbound)
                    // Persist error notices too: their external delivery must not multiply on retry.
                    let detail = error is SlackSessionStorageError
                        ? "Slack conversation storage needs repair before this message can be answered. Existing conversation bindings were preserved."
                        : ProviderRecoveryPolicy.personMessage(error) ?? "Couldn't finish the reply."
                    // A failed turn's saved words lead its notice and replace its preview, so they reach the person once.
                    var words = "", ending = detail
                    do {
                        if let saved = try await SwiftNativeChatOrchestrationClient.savedReply(dataRoot: dataRoot, sessionId: sessionId,
                            runId: runId), saved.terminalState == .failed || saved.terminalState == .stopped {
                            words = saved.output
                            // A turn stopped from another door ends here as a stop, not as a failure.
                            if saved.terminalState == .stopped { ending = "Stopped." }
                        }
                    } catch { await recordError(context: "saved_partial_read", error: error, inbound: inbound) }
                    failedBeforeAnswer = words.isEmpty
                    reply = SlackSocketModeReply(text: (hydration.notice.map { $0 + "\n\n" } ?? "")
                        + [words, ending].filter { !$0.isEmpty }.joined(separator: "\n\n"))
                }
                if let readBy = reply.readBy {
                    // The agent's turn in progress read it; that turn's reply answers it, so this event posts nothing.
                    _ = try await deliveryJournal.markSteered(eventId: inbound.eventId, turnID: readBy)
                    await recordReceipt(kind: "steered", inbound: inbound, reply: "")
                    return true
                }
                let prepared = Self.preparedReply(text: reply.text, attachments: reply.attachments)
                guard !prepared.text.isEmpty || !prepared.uploads.isEmpty else {
                    if try await settleSilentInbound(inbound, sessionId: sessionId, runId: runId) { return true }
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
            guard record.lastRejection?.preparedFingerprint != prepared.fingerprint else { return false }
            guard !Task.isCancelled else { return false }
            // Missing artifacts must preserve the prepared reply, never rerun its chat/tool effects.
            guard prepared.uploads.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                _ = try await deliveryJournal.retryPrepared(eventId: inbound.eventId, detail: "prepared Slack image is no longer available")
                await recordError(
                    context: "prepared_reply_artifact_missing",
                    error: SlackSocketModeError.api("prepared Slack image is no longer available"),
                    inbound: inbound
                )
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
            let parts = prepared.textParts
            for (index, part) in parts.enumerated().dropFirst(record.confirmedTextCount) {
                guard !Task.isCancelled else { return false }
                if record.previewCreationUnknown == true, record.previewMessageTs == nil {
                    return await recordUnknownDelivery(inbound, detail: "Live reply creation is unconfirmed; no second reply was posted")
                }
                _ = try await deliveryJournal.beginDispatch(eventId: inbound.eventId)
                var input: [String: JSONValue] = [
                    "channel": .string(inbound.channelId),
                    "text": .string(part),
                    "metadata": Self.deliveryMetadata(eventId: inbound.eventId, fingerprint: prepared.partFingerprint(index)),
                ]
                if index == 0, let run = record.assistantRunId, let id = UUID(uuidString: run) { input["client_msg_id"] = .string(id.uuidString) }
                if let threadTs = inbound.replyThreadTs { input["thread_ts"] = .string(threadTs) }
                guard try CodexCompletionReadout.permitsDelivery(sessionId: record.assistantSessionId,
                    runId: record.assistantRunId, configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
                    dataRoot: dataRoot) else { return false }
                let posted: JSONValue
                do {
                    posted = try await SlackWebAPI.postMessage(input: input, dataRoot: dataRoot,
                        tokenOverride: config.botToken,
                        // Failure notices must preserve words already delivered.
                        updatingMessageTs: index == 0 && record.failedBeforeAnswer != true ? record.previewMessageTs : nil)
                } catch {
                    return await recordUnknownDelivery(inbound, detail: "Reply dispatch outcome is unknown: \(Self.redact(String(describing: error)))")
                }
                guard Self.envelopeOK(posted) else {
                    if try SlackWebAPI.isProvenMessageRejection(posted) {
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
                if try SlackWebAPI.hasTruncationWarning(posted) {
                    return await settleUnconfirmedReply(record, detail: "Slack truncated reply part \(index + 1); complete delivery is unconfirmed. "
                        + "Inspect the post before requesting a resend.")
                }
                guard let timestamp = posted.objectValue?["response"]?.objectValue?["ts"]?.stringValue,
                      !timestamp.isEmpty else {
                    return await recordUnknownDelivery(inbound, detail: "Slack reply acceptance has no message timestamp")
                }
                record = try await deliveryJournal.confirmReplyPart(eventId: inbound.eventId, isText: true)
            }
            // Uploads have no message-metadata hook; a visible text marker cannot prove a failed upload safe to replay.
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

    private func settleSilentInbound(_ inbound: SlackInboundMessage, sessionId: String, runId: String) async throws -> Bool {
        guard let turnID = try SwiftNativeChatOrchestrationClient.silentTurn(
            dataRoot: dataRoot, sessionId: sessionId, runId: runId) else { return false }
        _ = try await deliveryJournal.markSilent(eventId: inbound.eventId, turnID: turnID)
        await recordReceipt(kind: "silence", inbound: inbound, reply: "")
        return true
    }

    func generateReply(
        _ inbound: SlackInboundMessage, sessionId: String, handler: SlackHandler
    ) async throws -> SlackSocketModeReply {
        if let progressChatHandler {
            return try await progressChatHandler(inbound, sessionId, handler)
        }
        throw SlackSocketModeError.api("no Slack chat handler configured")
    }

    /// Prose updates one reply; notices retain their per-kind thread posts.
    func replyPreview(for inbound: SlackInboundMessage, sessionId: String) -> SlackReplyPreview {
        SlackReplyPreview(publish: { text in
            guard !Task.isCancelled,
                  let record = try await deliveryJournal.record(eventId: inbound.eventId),
                  !record.phase.isTerminal, record.phase == .generating,
                  record.previewCreationUnknown != true,
                  let turn = ChatCancelFlag.inFlightTurns(dataRoot: dataRoot).first(where: {
                      $0.sessionId == sessionId && $0.runId == record.assistantRunId
                  }), !ChatCancelFlag.isRaised(turn.stop),
                  try CodexCompletionReadout.permitsDelivery(sessionId: sessionId, runId: record.assistantRunId,
                    configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot), dataRoot: dataRoot)
            else { return }
            guard let safe = SlackWebAPI.messageParts(text).first else { return }
            var input: [String: JSONValue] = ["channel": .string(inbound.channelId), "text": .string(safe)]
            if let thread = inbound.replyThreadTs { input["thread_ts"] = .string(thread) }
            if record.previewMessageTs == nil {
                try await deliveryJournal.recordPreview(eventId: inbound.eventId, messageTs: nil, creationUnknown: true)
            }
            if ChatCancelFlag.isRaised(turn.stop) {
                if record.previewMessageTs == nil {
                    try await deliveryJournal.recordPreview(eventId: inbound.eventId, messageTs: nil, creationUnknown: false)
                }
                return
            }
            let posted = try await SlackWebAPI.postMessage(input: input, dataRoot: dataRoot,
                tokenOverride: config.botToken, updatingMessageTs: record.previewMessageTs)
            guard Self.envelopeOK(posted) else {
                if record.previewMessageTs == nil, try SlackWebAPI.isProvenMessageRejection(posted) {
                    try await deliveryJournal.recordPreview(eventId: inbound.eventId, messageTs: nil, creationUnknown: false)
                }
                throw SlackSocketModeError.api("Live reply publication failed: \(posted)")
            }
            guard let ts = record.previewMessageTs ?? posted.objectValue?["response"]?.objectValue?["ts"]?.stringValue,
                  !ts.isEmpty else { throw SlackSocketModeError.api("Live reply acceptance has no message timestamp") }
            try await deliveryJournal.recordPreview(eventId: inbound.eventId, messageTs: ts, creationUnknown: false)
        }, failure: { error in
            await recordError(context: "reply_preview", error: error, inbound: inbound)
        })
    }

    func noticeSink(for inbound: SlackInboundMessage, preview: SlackReplyPreview) -> SlackChatProgressSink {
        let memory = SlackTurnNoticeMemory()
        // Notices use the same captured credential snapshot as reply delivery.
        let botToken = config.botToken
        let dataRoot = self.dataRoot
        let channelId = inbound.channelId
        let threadTs = inbound.replyThreadTs
        return { event in
            if case .delta(let chunk) = event { await preview.append(chunk); return }
            guard case .notice(let kind, let text) = event else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, await memory.claim(kind) else { return }
            var input: [String: JSONValue] = [
                "channel": .string(channelId),
                "text": .string(trimmed),
            ]
            if let threadTs { input["thread_ts"] = .string(threadTs) }
            do {
                let posted = try await SlackWebAPI.postMessage(input: input, dataRoot: dataRoot, tokenOverride: botToken)
                if try SlackWebAPI.isProvenMessageRejection(posted) { await memory.release(kind) }
                if !Self.envelopeOK(posted) {
                    await recordError(context: "turn_notice", error: SlackSocketModeError.api("Notice \(kind): \(posted)"), inbound: inbound)
                }
            } catch {
                // The request may have reached Slack. Retain the claim so a later notice cannot repeat an unconfirmed external effect.
                await recordError(context: "turn_notice", error: error, inbound: inbound)
            }
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
        let nextPart = record.confirmedTextCount
        guard let text = prepared.textParts.dropFirst(nextPart).first else {
            // Text is confirmed already; an uncertain upload has no message metadata that could prove its acceptance.
            return await settleUnconfirmedReply(record, detail: "Text reply accepted; image completion is unconfirmed")
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
                fingerprint: prepared.partFingerprint(nextPart),
                botUserId: botUserId
            ) else {
                return await settleUnconfirmedReply(record, detail: "Slack history does not uniquely prove acceptance")
            }
            _ = try await deliveryJournal.confirmReplyPart(eventId: inbound.eventId, isText: true)
            await recordReceipt(kind: "reply_part_reconciled", inbound: inbound, reply: text)
            // Continue the saved artifact at the next unconfirmed part, under the same handler claim.
            return await handleClaimedInbound(inbound)
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

    /// Positive proof only. Incomplete/filtered history cannot establish uniqueness, and a missing message never establishes non-delivery.
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
            // Earlier accepted parts share this event; only this part's identity can settle this dispatch.
            guard payload["fingerprint"]?.stringValue == fingerprint else { continue }
            // Slack renders URLs and emoji in text; the echoed metadata owns this part's identity.
            guard message["user"]?.stringValue == botUserId,
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

    private static func envelopeOK(_ value: JSONValue) -> Bool {
        guard case .object(let obj) = value,
              case .bool(let ok)? = obj["ok"] else {
            return false
        }
        return ok
    }
}
