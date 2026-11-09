import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `ChatStore+ICloudReplies.swift` | Signed delivery evidence before early exits; shared terminal/snapshot settlement preserves partial words |

/// Chat and cold intent waits must interpret signed endings identically.
enum MobileChatTerminal: Equatable {
    case completed, failed, stopped, incomplete

    static func classify(_ kind: String?) -> Self? {
        switch kind {
        case "reply", "final": .completed
        case "error": .failed
        case "cancelled": .stopped
        case nil, "incomplete": .incomplete
        default: nil
        }
    }
}

extension ChatStore {
    func receiveICloudReply(_ msg: BridgeMessage) async {
        await restorationTask?.value
        guard msg.sender == "mac" else { return }
        if msg.metadata?["kind"] == "notice", msg.metadata?["steering"] == "true",
           let index = queuedSends.firstIndex(where: { $0.id.uuidString == msg.correlationID }) {
            let queued = queuedSends[index]
            steeringQueuedIDs.remove(queued.id)
            pausedQueueSessionKeys.insert(queueSessionKey(queued.sessionID))
            if queued.steeringFailure != msg.text { queuedSends[index].steeringFailure = msg.text }
            if queueSessionKey(queued.sessionID) == queueSessionKey(selectedSessionID) { errorBanner = msg.text }
            return
        }
        if let kind = msg.metadata?["kind"], kind == "steered" || kind == "steer_returned",
           let queued = queuedSends.first(where: { $0.id.uuidString == msg.correlationID }) {
            steeringQueuedIDs.remove(queued.id)
            if kind == "steer_returned" {
                if let client = pendingRetryClient {
                    sendAsOwnMessage(queued.id, client: client)
                }
                return
            }
            queuedSends.removeAll { $0.id == queued.id }
            // A different conversation's turn carries its own transcript; do not insert it here.
            guard queueSessionKey(queued.sessionID) == queueSessionKey(selectedSessionID) else { return }
            var note = ChatMessage(role: .assistant, text: msg.text, awaitingMacTranscript: true, runId: msg.correlationID)
            note.completionState = "completed"
            messages.append(contentsOf: [ChatMessage(id: queued.id, role: .user, text: queued.text, awaitingMacTranscript: true, runId: msg.correlationID),
                note])
            return
        }
        // Apply bridge verification evidence before terminal, offscreen or sequence early returns can skip it.
        if let correlationID = msg.correlationID {
            noteEvidencedActivity(correlationID: correlationID, activity: nil)
        }
        let kind = msg.metadata?["kind"]
        if msg.metadata?["live"] != "true",
           MobileChatTerminal.classify(kind) != nil {
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
            if rejection.isExpiredRequest {
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
        // Saved terminal evidence prevents replayed live records from reopening a completed turn.
        let live = msg.metadata?["live"] == "true"
        let elsewhere = Self.cleanSessionID(msg.sessionID).map { incoming in
            Self.cleanSessionID(selectedSessionID).map { $0 != incoming } ?? false
        } ?? false
        if elsewhere || (live && liveIsHistory(msg)) {
            // The phone's own send that this live message ended still settles in its conversation, adding nothing.
            if live, MobileChatTerminal.classify(kind) != nil, let run = msg.correlationID, let record = pendingExchanges[run] {
                settlePendingReply(run, placeholderId: record.placeholderID)
                receiveTerminalReply(msg, runID: run, placeholderID: record.placeholderID, sessionID: record.sessionID,
                                     visibleEffects: false, live: true)
            }
            return
        }
        acknowledgePublishedSession(msg.sessionID)
        if live {
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

    /// Settle each correlation once even when its conversation is detached.
    private func receiveTerminalReply(_ msg: BridgeMessage) {
        let kind = msg.metadata?["kind"]
        let terminal = MobileChatTerminal.classify(kind) ?? .incomplete
        let failed = terminal == .failed
        let stopped = terminal == .stopped
        let incomplete = terminal == .incomplete
        guard let correlationID = msg.correlationID, !correlationID.isEmpty else {
            errorBanner = """
                A Mac reply has no request identity, so it could not be matched. Pending exchanges are retained. Refresh this conversation to read the Mac's \
                transcript.
                """
            return
        }
        let pendingId: String? = correlationID
        let record = pendingId.flatMap { pendingExchanges[$0] }
        let offscreen = record.map { $0.sessionID != Self.cleanSessionID(selectedSessionID) } ?? false
        let placeholderId = pendingId.flatMap {
            pendingICloudPlaceholders[$0] ?? retiredPendingPlaceholders[$0] ?? record?.placeholderID
        }
        let wasLate = pendingId.map { retiredPendingPlaceholders[$0] != nil } ?? false
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
            if let pendingId {
                onTalkReply?(pendingId, msg.text, true, failed ? Self.errorExplanation(msg) : stopped ? "Reply stopped. Listening to you." : incomplete
                    ? msg.metadata?["status"] ?? "Reply ending is unconfirmed." : nil)
            }
            if failed { errorBanner = msg.metadata?["errorDetail"].flatMap { $0.isEmpty ? nil : $0 } ?? msg.text }
            if stopped { errorBanner = "Stopped. Any partial reply has been kept." }
            if incomplete { errorBanner = msg.metadata?["status"] ?? "Reply ending is unconfirmed." }
            if !failed && !stopped && !incomplete {
                onReply?(msg.text, pendingId)
                // A late reply is news, never a move: a reader away from the end sees Latest.
                if wasLate { SystemToastCenter.shared.push(info: "Reply arrived") }
            }
        }
    }

    /// Mutate an admitted run once; visible effects belong only to its visible door.
    private func receiveTerminalReply(_ msg: BridgeMessage, runID: String?, placeholderID: UUID?,
                                      sessionID: String?, visibleEffects: Bool, live: Bool) {
        let kind = msg.metadata?["kind"]
        let terminal = MobileChatTerminal.classify(kind) ?? .incomplete
        let failed = terminal == .failed, stopped = terminal == .stopped
        let incomplete = terminal == .incomplete
        let hasPartialReply = msg.metadata?["partialReply"] == "true"
            && !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let key = sessionID ?? Self.nilQueueSessionKey
        var transcript = iCloudSyncEngine.shared.chatTranscripts[key]
            ?? .init(records: [], messages: [], generation: nil)
        var rows = visibleEffects ? messages : transcript.messages
        let failure = failed ? msg.metadata?["errorDetail"] ?? msg.text
            : incomplete ? msg.metadata?["status"] ?? "Reply ending is unconfirmed." : live ? msg.metadata?["status"] : nil
        let state = failed ? "failed" : stopped || incomplete ? "incomplete" : "completed"
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
        } else if placeholderID != nil || live || (!failed && !stopped) || hasPartialReply {
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
            } else if failed || stopped || incomplete {
                // Apply terminal words before retiring the correlation: the terminal can precede every streamed snapshot.
                if hasPartialReply || incomplete { reply.text = msg.text }
                Self.end(&reply, lifecycle: failed ? Self.errorExplanation(msg) : stopped ? "Stopped" : failure ?? "Reply ending is unconfirmed.", state: state)
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
            if !live && !failed && !stopped && !incomplete && placeholderID != nil {
                errorBanner = nil
                Haptics.replyFinalized()
            }
        } else {
            transcript.messages = rows
            iCloudSyncEngine.shared.chatTranscripts[key] = transcript
        }
    }

    func settlePendingReply(_ pendingId: String, placeholderId: UUID?) {
        noteDeliveryAccepted(pendingId)
        markICloudReplyResolved(pendingId)
        closePendingExchange(pendingId)
        if let placeholderId {
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            releaseLoading(for: placeholderId)
        }
        showsReplyWaitHint = false
    }

    /// A saved terminal reply, never elapsed time, establishes that a live turn is history.
    private func liveIsHistory(_ msg: BridgeMessage) -> Bool {
        guard let run = msg.correlationID, liveTurnBubbles[run] == nil, pendingICloudPlaceholders[run] == nil else { return false }
        guard let session = Self.cleanSessionID(msg.sessionID) else { return false }
        return iCloudSyncEngine.shared.chatTranscripts[session]?.messages.contains { $0.runId == run && $0.isTerminalReply } ?? false
    }

    /// Other doors stream by run ID; retain their bubble until the Mac transcript settles it into the saved row.
    private func receiveLiveTurn(_ msg: BridgeMessage) {
        guard let runId = msg.correlationID, !runId.isEmpty else { return }
        let kind = msg.metadata?["kind"]
        let existingBubble = liveTurnBubbles[runId] ?? messages.last {
            $0.role == .assistant && $0.runId == runId && $0.matter == nil
        }?.id
        if kind == "text_delta" {
            guard let rawSequence = msg.metadata?["seq"], let seq = Int(rawSequence), seq >= 0 else {
                errorBanner = "The Mac live reply has no valid sequence. Its saved transcript remains available through Refresh."
                return
            }
            setStreamingText(existingBubble, msg.text, correlationID: runId, sequence: seq, live: true)
            return
        }
        if kind == "writing" {
            // The agent's movement while a call's input streams is the bubble's live line until its words arrive.
            let line = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            let bubble = existingBubble ?? {
                let reply = ChatMessage(role: .assistant, text: "", awaitingMacTranscript: true, runId: runId)
                messages.append(reply)
                liveTurnBubbles[runId] = reply.id
                return reply.id
            }()
            streamingHintsByMessageId[bubble] = line
            return
        }
        // Only an ending ends the turn; a kind this build does not know is a newer Mac's movement.
        guard MobileChatTerminal.classify(kind) != nil else { return }
        settlePendingReply(runId, placeholderId: existingBubble)
        if kind == "cancelled" { errorBanner = "Stopped. Any partial reply has been kept." }
        let failure = kind == "error" ? msg.metadata?["errorDetail"] ?? msg.text : msg.metadata?["status"]
        if kind == "error", let failure { errorBanner = "Interrupted. \(failure)" }
        receiveTerminalReply(msg, runID: runId, placeholderID: liveTurnBubbles.removeValue(forKey: runId) ?? existingBubble,
                             sessionID: selectedSessionID, visibleEffects: true, live: true)
    }

    /// Only the Mac can establish that history exists before the snapshot window.
    var canLoadOlderHistory: Bool {
        guard let session = Self.cleanSessionID(selectedSessionID) else { return false }
        return (iCloudSyncEngine.shared.chatTranscripts[session]?.hasOlder ?? pagedSessionsWithOlder.contains(session))
            && !historyExhaustedSessionIDs.contains(session)
    }

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
        // An unverified reply proves nothing about execution: the bridge retries it when pairing changes, never the person's banner.
        if rejection.reason.contains("signature") { return }
        guard !pendingICloudPlaceholders.isEmpty else {
            errorBanner = rejection.userMessage
            return
        }

        let match: (String, UUID)?
        if let correlationID = rejection.correlationID, !correlationID.isEmpty {
            match = pendingICloudPlaceholders[correlationID].map { (correlationID, $0) }
        } else {
            errorBanner = "A Mac rejection has no request identity. Pending exchanges are retained; refresh the conversation and check pairing."
            return
        }

        guard let (pendingId, placeholderId) = match else {
            errorBanner = rejection.userMessage
            return
        }

        // A signed expiry proves the request never started; retain it for "Send now".
        if rejection.isExpiredRequest, pendingExchanges[pendingId] != nil {
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
            retiredPendingPlaceholders.removeValue(forKey: pendingId)
            return
        }
        failPendingReply(
            pendingId: pendingId,
            placeholderId: placeholderId,
            placeholderText: "(Mac reply rejected — re-pair this iPhone with the Mac)",
            banner: rejection.userMessage
        )
        closePendingExchange(pendingId)
    }

    /// A durably replaced KVS key permits unsigned resync observation only; never create a request, session or placeholder.
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
            // The live line is the newest movement: this tool now, a later writing line after it.
            streamingHintsByMessageId[placeholderId] = activity ?? ToolActivityPresentation.title(clean)
        } else {
            // Age the waiting line from evidenced Mac activity rather than inferring activity from the local clock.
            noteEvidencedActivity(correlationID: correlationID, activity: clean)
            streamingHintsByMessageId[placeholderId] = clean
        }
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
            onTalkReply?(correlationID, text, false, nil)
            noteEvidencedActivity(correlationID: correlationID, activity: nil, partialText: text)
            streamingHintsByMessageId.removeValue(forKey: reply.id)
        }
    }

    func streamingHint(for message: ChatMessage) -> String {
        if let hint = streamingHintsByMessageId[message.id], !hint.isEmpty {
            return hint
        }
        if showsReplyWaitHint {
            // Without evidenced activity, report only what this phone knows.
            return ChatWaitStatusPresentation.unacknowledged
        }
        return "Typing"
    }

    func armReplyStatus() {
        guard !pendingICloudPlaceholders.isEmpty else { return }
        showsReplyWaitHint = true
        for correlationID in pendingICloudPlaceholders.keys { showWaitStatus(correlationID: correlationID) }
    }

    private func failPendingReply(
        pendingId: String,
        placeholderId: UUID,
        placeholderText: String,
        banner: String,
        awaitingMacTranscript: Bool = false
    ) {
        pendingICloudPlaceholders.removeValue(forKey: pendingId)
        showsReplyWaitHint = false
        retiredPendingPlaceholders[pendingId] = placeholderId
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        // Failure retires the placeholder and its sequence tracker, excluding straggler deltas.
        maxDeltaSeqByCorrelation.removeValue(forKey: pendingId)
        endPlaceholder(id: placeholderId, lifecycle: placeholderText, state: "failed", awaitingMacTranscript: awaitingMacTranscript)
        errorBanner = banner
        onTalkReply?(pendingId, "", true, banner)
        releaseLoading(for: placeholderId)
    }

    func markICloudReplyResolved(_ pendingId: String, discardRetainedSend: Bool = true) {
        resolvedICloudReplyIds.insert(pendingId)
        if discardRetainedSend { queuedSends.removeAll { $0.id.uuidString == pendingId } }
        let placeholders = [pendingICloudPlaceholders.removeValue(forKey: pendingId),
                            retiredPendingPlaceholders.removeValue(forKey: pendingId)]
        for id in placeholders.compactMap({ $0 }) {
            streamingHintsByMessageId.removeValue(forKey: id)
            releaseLoading(for: id)
        }
        maxDeltaSeqByCorrelation.removeValue(forKey: pendingId)
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

    /// Preserve partial words exactly; show Stop/failure as adjacent lifecycle evidence, matching the Mac transcript.
    func endPlaceholder(id placeholderId: UUID, lifecycle: String, state: String, awaitingMacTranscript: Bool = false) {
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        var updated = messages[idx]
        updated.isStreaming = false
        updated.awaitingMacTranscript = awaitingMacTranscript
        Self.end(&updated, lifecycle: lifecycle, state: state)
        messages[idx] = updated
    }

    /// An empty bubble can show lifecycle evidence only; do not invent reply text.
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
