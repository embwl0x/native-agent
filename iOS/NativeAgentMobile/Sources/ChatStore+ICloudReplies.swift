import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    /// Dispatch signed Mac events; terminal receipts share one settlement path.
    func receiveICloudReply(_ msg: BridgeMessage) async {
        await restorationTask?.value
        guard msg.sender == "mac" else { return }  // only accept Mac replies
        // How a Steer ended: read by the turn that was working (its reply
        // answers it), or given back, to run as its own message.
        if let kind = msg.metadata?["kind"], kind == "steered" || kind == "steer_returned",
           let queued = queuedSends.first(where: { $0.id.uuidString == msg.correlationID }) {
            steeringQueuedIDs.remove(queued.id)
            if kind == "steer_returned" {
                if let client = pendingRetryClient {
                    sendAsOwnMessage(queued.id, client: client, rowWritten: msg.metadata?["rowWritten"] == "true")
                }
                return
            }
            queuedSends.removeAll { $0.id == queued.id }
            // Read by another conversation's turn: its transcript carries it, never this one.
            guard queueSessionKey(queued.sessionID) == queueSessionKey(selectedSessionID) else { return }
            var note = ChatMessage(role: .assistant, text: msg.text, awaitingMacTranscript: true, runId: msg.correlationID)
            note.completionState = "completed"
            messages.append(contentsOf: [ChatMessage(id: queued.id, role: .user, text: queued.text, awaitingMacTranscript: true, runId: msg.correlationID), note])
            return
        }
        let kind = msg.metadata?["kind"]
        if msg.metadata?["live"] != "true",
           [nil, "reply", "final", "error", "cancelled"].contains(kind) {
            receiveTerminalReply(msg)
            return
        }
        if kind == "rejection",
           let correlationID = msg.correlationID,
           let record = pendingExchanges[correlationID],
           record.sessionID != Self.cleanSessionID(selectedSessionID) {
            let rejection = ICloudBridgeRejectedMessage(
                messageID: msg.id,
                correlationID: correlationID,
                reason: msg.metadata?["reason"] ?? msg.text
            )
            if rejection.isExpiredRequest, record.request != nil {
                markPendingExchangeExpired(
                    correlationID: correlationID,
                    message: rejection.userMessage
                )
            } else {
                closePendingExchange(correlationID)
            }
            markICloudReplyResolved(correlationID)
            return
        }
        if let correlationID = msg.correlationID, resolvedICloudReplyIds.contains(correlationID) {
            return
        }
        // Nonterminal events only update the conversation on screen.
        if let incoming = Self.cleanSessionID(msg.sessionID),
           let selected = Self.cleanSessionID(selectedSessionID), incoming != selected {
            return
        }
        acknowledgePublishedSession(msg.sessionID)
        if msg.metadata?["live"] == "true" {
            receiveLiveTurn(msg)
        } else if ["progress", "notice", "tool_use", "tool_result"].contains(kind ?? "") {
            receiveICloudProgress(msg)
        } else if kind == "text_delta" {
            receiveICloudTextDelta(msg)
        } else if kind == "rejection" {
            receiveICloudRejection(ICloudBridgeRejectedMessage(
                messageID: msg.id,
                correlationID: msg.correlationID,
                reason: msg.metadata?["reason"] ?? msg.text
            ))
        } else {
            receiveTerminalReply(msg)
        }
    }

    /// Bridge receipts resolve their correlation and conversation once. A
    /// detached exchange still settles even though its conversation is hidden.
    private func receiveTerminalReply(_ msg: BridgeMessage) {
        let kind = msg.metadata?["kind"]
        let failed = kind == "error"
        let stopped = kind == "cancelled"
        let pendingId = msg.correlationID.flatMap { $0.isEmpty ? nil : $0 }
            ?? (!failed && !stopped ? pendingICloudPlaceholders.first?.key : nil)
        let record = pendingId.flatMap { pendingExchanges[$0] }
        let offscreen = record.map { $0.sessionID != Self.cleanSessionID(selectedSessionID) } ?? false
        let placeholderId = pendingId.flatMap {
            pendingICloudPlaceholders[$0] ?? timedOutPendingIds[$0] ?? record?.placeholderID
        }
        let wasLate = pendingId.map { timedOutPendingIds[$0] != nil } ?? false
        if !offscreen {
            if let pendingId, resolvedICloudReplyIds.contains(pendingId) { return }
            if let incoming = Self.cleanSessionID(msg.sessionID),
               let selected = Self.cleanSessionID(selectedSessionID), incoming != selected { return }
            acknowledgePublishedSession(msg.sessionID)
            if let incoming = Self.cleanSessionID(msg.sessionID), selectedSessionID == nil {
                migrateQueuedSends(from: nil, to: incoming)
                if let outgoing = iCloudSyncEngine.shared.chatTranscripts.removeValue(forKey: Self.nilQueueSessionKey) {
                    var transcript = iCloudSyncEngine.shared.chatTranscripts[incoming]
                        ?? .init(records: [], messages: [], generation: nil)
                    let ids = Set(transcript.messages.map(\.id))
                    transcript.messages.append(contentsOf: outgoing.messages.filter { !ids.contains($0.id) })
                    iCloudSyncEngine.shared.chatTranscripts[incoming] = transcript
                }
                setSelectedSessionID(incoming)
            }
            if let pendingId { insertPendingUserIfNeeded(pendingId: pendingId, before: placeholderId) }
        }

        receiveTerminalReply(msg, runID: pendingId, placeholderID: placeholderId,
                             sessionID: record?.sessionID, visibleEffects: !offscreen, live: false)
        if let pendingId { settlePendingReply(pendingId, placeholderId: placeholderId) }
        if !offscreen {
            if failed { errorBanner = msg.metadata?["errorDetail"].flatMap { $0.isEmpty ? nil : $0 } ?? msg.text }
            if !failed && !stopped {
                onReply?(msg.text)
                if wasLate {
                    requestScrollToBottom()
                    SystemToastCenter.shared.push(info: "Reply arrived")
                }
            }
        }
    }

    /// Mutate an admitted run once; visible effects belong only to its visible door.
    private func receiveTerminalReply(_ msg: BridgeMessage, runID: String?, placeholderID: UUID?,
                                      sessionID: String?, visibleEffects: Bool, live: Bool) {
        let kind = msg.metadata?["kind"]
        let failed = kind == "error", stopped = kind == "cancelled"
        let key = sessionID ?? Self.nilQueueSessionKey
        var transcript = iCloudSyncEngine.shared.chatTranscripts[key]
            ?? .init(records: [], messages: [], generation: nil)
        var rows = visibleEffects ? messages : transcript.messages
        let failure = live ? (failed ? msg.metadata?["errorDetail"] ?? msg.text : msg.metadata?["status"]) : nil
        let state = failed ? "failed" : stopped || (live && kind == "incomplete") ? "incomplete" : "completed"
        let publishedIDs = live ? transcript.publishedIDs : []
        let saved = live ? rows.firstIndex {
            $0.runId == runID && $0.isTerminalReply && publishedIDs.contains($0.id)
        } : nil
        if let saved, let failure {
            rows[saved].failureDetail = failure
            rows[saved].completionState = state
        }
        if live && (saved != nil || (msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && failure == nil)) {
            if let placeholderID, !publishedIDs.contains(placeholderID) { rows.removeAll { $0.id == placeholderID } }
        } else if placeholderID != nil || live || (!failed && !stopped) {
            let index = placeholderID.flatMap { id in rows.firstIndex { $0.id == id } }
            var reply = index.map { rows[$0] } ?? ChatMessage(
                id: placeholderID ?? UUID(), role: .assistant,
                text: runID.flatMap { pendingExchanges[$0]?.partialText } ?? "",
                awaitingMacTranscript: true, runId: runID)
            reply.isStreaming = false
            reply.awaitingMacTranscript = true
            reply.runId = runID
            if live {
                reply.text = msg.text
                reply.failureDetail = failure
                reply.completionState = state
            } else if failed || stopped {
                Self.end(&reply, lifecycle: failed ? Self.errorExplanation(msg) : "Stopped", state: state)
            } else {
                reply.text = msg.text
                reply.attachments = (msg.attachments ?? []).map {
                    ChatAttachmentSummary($0, fallbackName: $0.type == "image" ? "Image" : "Attachment")
                }
                reply.completionState = state
            }
            if let index, visibleEffects { rows[index] = reply }
            else { rows.removeAll { $0.id == reply.id }; rows.append(reply) }
        }
        if visibleEffects {
            messages = rows
            if let placeholderID { streamingHintsByMessageId.removeValue(forKey: placeholderID) }
            if !live && !failed && !stopped && placeholderID != nil {
                errorBanner = nil
                Haptics.replyFinalized()
            }
        } else {
            transcript.messages = rows
            iCloudSyncEngine.shared.chatTranscripts[key] = transcript
        }
    }

    /// Snapshot recovery and terminal bridge receipts share retirement.
    func settlePendingReply(_ pendingId: String, placeholderId: UUID?) {
        markICloudReplyResolved(pendingId)
        closePendingExchange(pendingId)
        if let placeholderId {
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            releaseLoading(for: placeholderId)
        }
        isPollingFallback = false
    }

    /// A turn another door (the Mac, Telegram) started in this conversation,
    /// shown as it streams: the Mac sends its text so far under the turn's run
    /// id, then the saved answer, failure sentence, or explicit cancellation. The
    /// bubble awaits the Mac transcript like any reply, so the snapshot
    /// settles it into the saved row.
    private func receiveLiveTurn(_ msg: BridgeMessage) {
        guard let runId = msg.correlationID, !runId.isEmpty else { return }
        let kind = msg.metadata?["kind"]
        let existingBubble = liveTurnBubbles[runId] ?? messages.last {
            $0.role == .assistant && $0.runId == runId && $0.interaction == nil
        }?.id
        if kind == "text_delta" {
            let seq = Int(msg.metadata?["seq"] ?? "") ?? 0
            setStreamingText(existingBubble, msg.text, correlationID: runId, sequence: seq, live: true)
            return
        }
        settlePendingReply(runId, placeholderId: existingBubble)
        if kind == "cancelled" { errorBanner = "Stopped. Any partial reply has been kept." }
        let failure = kind == "error" ? msg.metadata?["errorDetail"] ?? msg.text : msg.metadata?["status"]
        if kind == "error", let failure { errorBanner = "Interrupted. \(failure)" }
        receiveTerminalReply(msg, runID: runId, placeholderID: liveTurnBubbles.removeValue(forKey: runId) ?? existingBubble,
                             sessionID: selectedSessionID, visibleEffects: true, live: true)
    }

    /// The Mac says its transcript goes back further than the snapshot's
    /// window, and no page here has reached the start yet.
    var canLoadOlderHistory: Bool {
        guard let session = Self.cleanSessionID(selectedSessionID) else { return false }
        return (iCloudSyncEngine.shared.chatTranscripts[session]?.hasOlder ?? pagedSessionsWithOlder.contains(session))
            && !historyExhaustedSessionIDs.contains(session)
    }

    /// Older history the snapshot window leaves out, from the Mac on request.
    func loadOlderHistory() async {
        guard let session = Self.cleanSessionID(selectedSessionID), !isLoadingHistory else { return }
        let transcript = iCloudSyncEngine.shared.chatTranscripts[session]
        let historyIDs = (transcript?.publishedIDs ?? []).union(transcript?.historyIDs ?? [])
        guard let oldest = messages.first(where: { historyIDs.contains($0.id) }) else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await iCloudSyncEngine.shared.chatHistoryPage(sessionID: session, beforeID: oldest.id.uuidString)
            guard Self.cleanSessionID(selectedSessionID) == session else { return }
            if !page.hasOlder { historyExhaustedSessionIDs.insert(session) }
        } catch {
            errorBanner = "Earlier messages did not load: \(error.localizedDescription)"
        }
    }

    /// The whole text of a message the snapshot cut short.
    func loadWholeMessage(_ id: UUID) async {
        guard let session = Self.cleanSessionID(selectedSessionID), !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            _ = try await iCloudSyncEngine.shared.chatHistoryPage(sessionID: session, throughID: id.uuidString, limit: 1)
        } catch {
            errorBanner = "The whole message did not load: \(error.localizedDescription)"
        }
    }

    func receiveICloudRejection(_ rejection: ICloudBridgeRejectedMessage) {
        // Reply authentication failure says nothing about request execution.
        // Keep observing the original identity; even its correlation is untrusted.
        if rejection.reason.contains("signature") {
            // Deduplicate signature-error banners in a bounded set while the bridge retains verification eligibility.
            guard !surfacedSignatureRejectionIDs.contains(rejection.messageID) else { return }
            surfacedSignatureRejectionIDs.insert(rejection.messageID)
            if surfacedSignatureRejectionIDs.count > 200 { surfacedSignatureRejectionIDs.removeAll() }
            errorBanner = "Could not verify one Mac reply. Check pairing; verification will retry when pairing changes."
            return
        }
        guard !pendingICloudPlaceholders.isEmpty else {
            errorBanner = rejection.userMessage
            return
        }

        let match: (String, UUID)?
        if let correlationID = rejection.correlationID, !correlationID.isEmpty {
            match = pendingICloudPlaceholders[correlationID].map { (correlationID, $0) }
        } else {
            match = pendingICloudPlaceholders.first
        }

        guard let (pendingId, placeholderId) = match else {
            errorBanner = rejection.userMessage
            return
        }

        // A signed expiry proves the request never started; retain it for "Send now".
        if rejection.isExpiredRequest, pendingExchanges[pendingId]?.request != nil {
            failPendingReply(
                pendingId: pendingId,
                placeholderId: placeholderId,
                placeholderText: rejection.userMessage,
                banner: rejection.userMessage
            )
            markPendingExchangeExpired(
                correlationID: pendingId,
                message: rejection.userMessage
            )
            timedOutPendingIds.removeValue(forKey: pendingId)
            return
        }
        failPendingReply(
            pendingId: pendingId,
            placeholderId: placeholderId,
            placeholderText: "(Mac reply rejected — re-pair this iPhone with the Mac)",
            banner: rejection.userMessage
        )
        // An unresumable rejection closes the durable observation.
        closePendingExchange(pendingId)
    }

    /// An unsigned resync envelope is only delivered here after the bridge
    /// durably installed a different KVS key. It authorizes observation only,
    /// never a new request, session, or placeholder.
    func receiveICloudResyncHint(_ hint: BridgeMessage, client: MacBridgeClient) {
        _ = hint
        guard !pendingICloudPlaceholders.isEmpty else { return }
        Task { await client.pollICloudRepliesNow() }
    }


    private func receiveICloudProgress(_ msg: BridgeMessage) {
        guard let correlationID = msg.correlationID,
              let placeholderId = pendingICloudPlaceholders[correlationID],
              let idx = messages.firstIndex(where: { $0.id == placeholderId })
        else { return }
        let clean = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let kind = msg.metadata?["kind"]
        if kind == "tool_use" || kind == "tool_result" {
            let seq = Int(msg.metadata?["toolSeq"] ?? "")
            guard let seq else { return }
            let activity = msg.metadata?["activity"]
            var bubble = messages[idx]
            if let eventIndex = bubble.toolEvents.firstIndex(where: { $0.seq == seq }) {
                if let activity { bubble.toolEvents[eventIndex].activity = activity }
            } else {
                bubble.toolEvents.append(ToolEvent(name: clean, seq: seq, activity: activity))
                bubble.toolEvents.sort { $0.seq < $1.seq }
            }
            if kind == "tool_result", let eventIndex = bubble.toolEvents.firstIndex(where: { $0.seq == seq }) {
                bubble.toolEvents[eventIndex].outcome = msg.metadata?["outcome"]
                bubble.toolEvents[eventIndex].resultDetail = msg.metadata?["resultDetail"]
            }
            messages[idx] = bubble
            noteEvidencedActivity(correlationID: correlationID,
                                  activity: activity ?? ToolActivityPresentation.progress(clean))
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
        } else {
            // The Mac evidenced this activity; the waiting line ages from here
            // instead of narrating the Mac from a local clock.
            noteEvidencedActivity(correlationID: correlationID, activity: clean)
            streamingHintsByMessageId[placeholderId] = clean
        }
        pendingTimeouts.removeValue(forKey: correlationID)?.cancel()
        armTimeout(for: correlationID, placeholderId: placeholderId)
    }

    /// Phone deltas require an explicit sequence and an existing placeholder.
    private func receiveICloudTextDelta(_ msg: BridgeMessage) {
        guard let correlationID = msg.correlationID,
              let placeholderId = pendingICloudPlaceholders[correlationID],
              messages.contains(where: { $0.id == placeholderId }),
              let seqText = msg.metadata?["seq"], let seq = Int(seqText)
        else { return }
        setStreamingText(placeholderId, msg.text, correlationID: correlationID, sequence: seq, live: false)
    }

    /// Replace accumulated text only with a newer admitted snapshot.
    private func setStreamingText(_ placeholderId: UUID?, _ text: String, correlationID: String, sequence seq: Int, live: Bool) {
        guard seq > (maxDeltaSeqByCorrelation[correlationID] ?? -1) else { return }
        maxDeltaSeqByCorrelation[correlationID] = seq
        let index = placeholderId.flatMap { id in messages.firstIndex { $0.id == id } }
        var reply = index.map { messages[$0] } ?? ChatMessage(role: .assistant, text: "", awaitingMacTranscript: true, runId: correlationID)
        reply.text = text
        if !live { reply.isStreaming = true }
        if let index { messages[index] = reply } else { messages.append(reply) }
        if live { liveTurnBubbles[correlationID] = reply.id }
        else {
            noteEvidencedActivity(correlationID: correlationID, activity: nil, partialText: text)
            streamingHintsByMessageId.removeValue(forKey: reply.id)
            armTimeout(for: correlationID, placeholderId: reply.id)
        }
    }

    func streamingHint(for message: ChatMessage) -> String {
        if let hint = streamingHintsByMessageId[message.id], !hint.isEmpty {
            return hint
        }
        if isPollingFallback {
            // No evidenced activity to repeat — say only what this phone knows.
            return ChatWaitStatusPresentation.unacknowledged
        }
        return "Typing"
    }

    /// A terminal receipt must retire both wait tasks together.  Keeping this
    /// paired prevents a late timeout from contradicting a reply already shown.
    func cancelReplyWaits(for pendingId: String) {
        pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
        if pendingICloudPlaceholders.isEmpty {
            replyCatchUpTask?.cancel()
            replyCatchUpTask = nil
        }
    }

    /// Arm the silence watchdog without ending the pending exchange. A remote
    /// terminal receipt, rather than elapsed time, settles the request.
    func armTimeout(for pendingId: String, placeholderId: UUID) {
        pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
        let timeoutNs = iCloudReplyTimeoutSeconds * 1_000_000_000
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard !Task.isCancelled, let self else { return }
            self.fireTimeout(pendingId: pendingId, placeholderId: placeholderId)
        }
        pendingTimeouts[pendingId] = task
    }

    /// Catch up transport while replies remain outstanding.
    static let iCloudReplyNudgeFloorSeconds: TimeInterval = 8
    /// Snapshot reads backstop push delivery at a slower cadence.
    static let iCloudReplySnapshotBackstopSeconds: TimeInterval = 30
    static let iCloudReplyPollingHintAfterSeconds: TimeInterval = 10

    func armReplyPoll(client: MacBridgeClient) {
        guard replyCatchUpTask == nil, !pendingICloudPlaceholders.isEmpty else { return }
        replyCatchUpTask = Task { [weak self, weak client] in
            let startedAt = Date()
            var nextSnapshotPollAt = startedAt.addingTimeInterval(Self.iCloudReplySnapshotBackstopSeconds)

            while !Task.isCancelled {
                // A stalled drain must not hold up per-exchange silence deadlines.
                Task { await client?.pollICloudRepliesNow() }
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.iCloudReplyNudgeFloorSeconds * 1_000_000_000)
                )

                guard !Task.isCancelled, let self else { return }
                if self.pendingICloudPlaceholders.isEmpty {
                    self.isPollingFallback = false
                    self.replyCatchUpTask = nil
                    return
                }

                let now = Date()
                if now.timeIntervalSince(startedAt) >= Self.iCloudReplyPollingHintAfterSeconds {
                    self.isPollingFallback = true
                    for correlationID in self.pendingICloudPlaceholders.keys {
                        self.showWaitStatus(correlationID: correlationID)
                    }
                }

                if now >= nextSnapshotPollAt, let client {
                    nextSnapshotPollAt = now.addingTimeInterval(Self.iCloudReplySnapshotBackstopSeconds)

                    await self.forceRefresh(using: client)
                }
            }
        }
    }

    // MARK: - iCloud Snapshot Force Refresh

    /// Like `refresh(using:)` but bypasses the 2-second throttle. Intended only for
    /// active-send polling — not for user-driven or scenePhase refreshes.
    /// Updates `lastRefreshAt` so throttled callers are debounced afterwards.
    func forceRefresh(using client: MacBridgeClient) async {
        lastRefreshAt = Date()
        let sessionID = Self.cleanSessionID(selectedSessionID ?? mainSessionID)
        let generation = sessionSwitchGeneration
        let read = await client.readChatTranscript(sessionID: sessionID)
        guard !Task.isCancelled,
              generation == sessionSwitchGeneration,
              sessionID == Self.cleanSessionID(selectedSessionID ?? mainSessionID) else { return }
        applyMacTranscriptRead(read, sessionID: sessionID)
    }

    /// Silence changes status while preserving the partial answer and observation of the original request.
    private func fireTimeout(pendingId: String, placeholderId: UUID) {
        guard pendingICloudPlaceholders[pendingId] != nil else { return }
        notePendingExchangeSilent(correlationID: pendingId)
        // Release the composer — the person can say something else while this
        // request keeps being watched — but keep the bubble waiting.
        releaseLoading(for: placeholderId)
    }

    private func failPendingReply(
        pendingId: String,
        placeholderId: UUID,
        placeholderText: String,
        banner: String,
        awaitingMacTranscript: Bool = false
    ) {
        pendingICloudPlaceholders.removeValue(forKey: pendingId)
        cancelReplyWaits(for: pendingId)
        isPollingFallback = false
        timedOutPendingIds[pendingId] = placeholderId
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        // Failure retires the placeholder and its sequence tracker, excluding straggler deltas.
        maxDeltaSeqByCorrelation.removeValue(forKey: pendingId)
        endPlaceholder(id: placeholderId, lifecycle: placeholderText, state: "failed", awaitingMacTranscript: awaitingMacTranscript)
        errorBanner = banner
        releaseLoading(for: placeholderId)
    }

    func markICloudReplyResolved(_ pendingId: String, discardRetainedSend: Bool = true) {
        resolvedICloudReplyIds.insert(pendingId)
        if discardRetainedSend { queuedSends.removeAll { $0.id.uuidString == pendingId } }
        let placeholders = [pendingICloudPlaceholders.removeValue(forKey: pendingId),
                            timedOutPendingIds.removeValue(forKey: pendingId)]
        for id in placeholders.compactMap({ $0 }) {
            streamingHintsByMessageId.removeValue(forKey: id)
            releaseLoading(for: id)
        }
        cancelReplyWaits(for: pendingId)
        maxDeltaSeqByCorrelation.removeValue(forKey: pendingId)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            _ = self?.resolvedICloudReplyIds.remove(pendingId)
        }
    }

    func failPlaceholder(id placeholderId: UUID, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        var updated = messages[idx]
        updated.text = text
        updated.attachments = []
        updated.isStreaming = false
        updated.awaitingMacTranscript = false
        updated.completionState = "failed"
        messages[idx] = updated
    }

    /// Ends a bubble the Mac did not finish. Her words stay exactly as they
    /// arrived; what stopped or failed it is lifecycle evidence beside them,
    /// as the Mac's own transcript keeps it.
    func endPlaceholder(id placeholderId: UUID, lifecycle: String, state: String, awaitingMacTranscript: Bool = false) {
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        var updated = messages[idx]
        updated.isStreaming = false
        updated.awaitingMacTranscript = awaitingMacTranscript
        Self.end(&updated, lifecycle: lifecycle, state: state)
        messages[idx] = updated
    }

    /// A bubble with no words yet has only the evidence to show.
    static func end(_ message: inout ChatMessage, lifecycle: String, state: String) {
        message.completionState = state
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.text = lifecycle
        } else {
            message.failureDetail = lifecycle
        }
    }

    static func errorExplanation(_ msg: BridgeMessage) -> String {
        let detail = msg.metadata?["errorDetail"] ?? msg.text
        let explanation = detail.isEmpty ? msg.text : detail
        return explanation.isEmpty ? "(I hit an error answering that message)" : String(explanation.prefix(600))
    }

}
