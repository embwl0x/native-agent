import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    // N5 fix (R18): called by ChatView when an iCloud reply arrives.
    // Finds the matching placeholder (by sent message ID in correlationId or
    // by taking the oldest pending placeholder) and updates it.
    func receiveICloudReply(_ msg: BridgeMessage) {
        guard msg.sender == "mac" else { return }  // only accept Mac replies
        if let correlation = msg.correlationID,
           let placeholder = pendingICloudPlaceholders[correlation] ?? timedOutPendingIds[correlation],
           let index = messages.firstIndex(where: { $0.id == placeholder }) {
            messages[index].runId = correlation
        }
        // The bridge records receipts as seen before dispatch. Settle offscreen
        // exchanges before the session-switch guards can drop their only receipt.
        if let correlationID = msg.correlationID,
           let record = pendingExchanges[correlationID],
           record.sessionID != Self.cleanSessionID(selectedSessionID) {
            let kind = msg.metadata?["kind"]
            if kind == nil || kind == "reply" || kind == "final" || kind == "error" || kind == "cancelled" {
                var cached = loadCachedMessages(for: record.sessionID)
                let text: String
                if kind == "cancelled" {
                    text = "(stopped)"
                } else if kind == "error" {
                    let detail = msg.metadata?["errorDetail"] ?? msg.text
                    let explanation = detail.isEmpty ? msg.text : detail
                    text = explanation.isEmpty ? "(I hit an error answering that message)" : String(explanation.prefix(600))
                } else {
                    text = msg.text
                }
                var reply = ChatMessage(
                    id: record.placeholderID,
                    role: .assistant,
                    text: text,
                    attachments: attachmentSummaries(from: msg.attachments),
                    awaitingMacTranscript: true
                )
                reply.runId = correlationID
                reply.completionState = kind == "error" ? "failed" : kind == "cancelled" ? nil : "completed"
                if let index = cached.firstIndex(where: { $0.id == record.placeholderID }) {
                    cached[index] = reply
                } else {
                    cached.append(reply)
                }
                let envelope = CachedTranscript(
                    schemaVersion: 2,
                    sessionID: record.sessionID,
                    messages: cachedTranscriptRows(cached),
                    appliedTranscriptGeneration: record.sessionID.flatMap { appliedTranscriptGenerations[$0] }
                )
                do {
                    let data = try JSONEncoder().encode(envelope)
                    defaults.set(data, forKey: transcriptStorageKey(for: record.sessionID))
                } catch {
                    errorBanner = error.localizedDescription
                    return
                }
                cancelReplyWaits(for: correlationID)
                markICloudReplyResolved(correlationID)
                return
            }
        }
        if msg.metadata?["kind"] == "rejection",
           let correlationID = msg.correlationID,
           let record = pendingExchanges[correlationID],
           record.sessionID != Self.cleanSessionID(selectedSessionID) {
            let rejection = ICloudBridgeRejectedMessage(
                messageID: msg.id,
                correlationID: correlationID,
                reason: msg.metadata?["reason"] ?? msg.text
            )
            if rejection.isExpiredRequest, let args = resendArgs(for: correlationID) {
                markPendingExchangeExpired(
                    correlationID: correlationID,
                    placeholderID: record.placeholderID,
                    message: rejection.userMessage,
                    args: args
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
        // Session ownership is checked before dispatching ANY event kind. New
        // Chat selects a fresh client-owned session immediately; a late delta,
        // final, error, progress, or cancellation from the previous session
        // must neither mutate that transcript nor replace its session id.
        if let incomingSessionID = Self.cleanSessionID(msg.sessionID),
           let selectedSessionID = Self.cleanSessionID(selectedSessionID),
           incomingSessionID != selectedSessionID {
            return
        }
        // Any signed Mac event carrying the new session id proves the locally
        // created identity has crossed the bridge and is safe to reconcile
        // against published snapshots from here forward.
        acknowledgePublishedSession(msg.sessionID)
        if msg.metadata?["live"] == "true" {
            receiveLiveTurn(msg)
            return
        }
        if msg.metadata?["kind"] == "progress" {
            receiveICloudProgress(msg)
            return
        }
        // 2026-09-06: in-turn notices (provider reconnect, context compaction)
        // arrive on their own key with their kind intact. They drive the same
        // status line as progress — the text is already the sentence to show,
        // exactly as Telegram renders provider_retry and context_compaction.
        if msg.metadata?["kind"] == "notice" {
            receiveICloudProgress(msg)
            return
        }
        // PATCH-2026-05-30: in-flight text streaming. text_delta events carry
        // accumulated text-so-far; iOS updates the placeholder bubble in place
        // without finalizing. Final reply still arrives as a plain BridgeMessage
        // (or kind:"final") and goes through the normal finishPlaceholder path.
        if msg.metadata?["kind"] == "text_delta" {
            receiveICloudTextDelta(msg)
            return
        }
        if msg.metadata?["kind"] == "rejection" {
            receiveICloudRejection(ICloudBridgeRejectedMessage(
                messageID: msg.id,
                correlationID: msg.correlationID,
                reason: msg.metadata?["reason"] ?? msg.text
            ))
            return
        }
        // F7 P1: explicit stream-error kind. Don't fold accumulated text as a
        // normal final reply — fail the placeholder and show a banner.
        if msg.metadata?["kind"] == "error" {
            let detail = msg.metadata?["errorDetail"] ?? msg.text
            if let correlationID = msg.correlationID,
               let placeholderId = pendingICloudPlaceholders[correlationID] {
                markICloudReplyResolved(correlationID)
                // 2026-09-13 (first-failure pass): the Mac already normalized
                // this into the one sentence it shows in its own transcript —
                // cause and next move. Keep THAT in the bubble, where it stays
                // with the exchange, instead of a generic line plus a banner
                // the next tap dismisses. The banner still carries it for the
                // moment it lands.
                let explanation = detail.isEmpty ? msg.text : detail
                failPendingReply(
                    pendingId: correlationID,
                    placeholderId: placeholderId,
                    placeholderText: explanation.isEmpty
                        ? "(I hit an error answering that message)"
                        : String(explanation.prefix(600)),
                    banner: explanation,
                    awaitingMacTranscript: true
                )
            } else {
                errorBanner = detail.isEmpty ? msg.text : detail
            }
            return
        }
        // F7 P0 #3: explicit cancelled kind. Resolve the placeholder, clear
        // the spinner, but don't surface an error banner.
        if msg.metadata?["kind"] == "cancelled" {
            if let correlationID = msg.correlationID,
               let placeholderId = pendingICloudPlaceholders.removeValue(forKey: correlationID) {
                cancelReplyWaits(for: correlationID)
                streamingHintsByMessageId.removeValue(forKey: placeholderId)
                markICloudReplyResolved(correlationID)
                if messages.contains(where: { $0.id == placeholderId }) {
                    finishPlaceholder(id: placeholderId, text: "(stopped)", awaitingMacTranscript: true)
                }
                releaseLoading(for: placeholderId)
            }
            return
        }
        // F7 P2: tool events are progress-style; route to the existing
        // progress handler so the typing hint stays alive but the bubble
        // doesn't get overwritten with raw tool names.
        if msg.metadata?["kind"] == "tool_use" || msg.metadata?["kind"] == "tool_result" {
            receiveICloudProgress(msg)
            return
        }
        let replyAttachments = attachmentSummaries(from: msg.attachments)
        // 2026-05-09: latch onto the Mac-assigned sessionId from the first
        // reply so all subsequent iOS messages stay in the same session.
        // Without this, sessionID stayed nil forever and every send started
        // a fresh session.
        if let incoming = Self.cleanSessionID(msg.sessionID), selectedSessionID == nil {
            migrateQueuedSends(from: nil, to: incoming)
            setSelectedSessionID(incoming)
            if mainSessionID == nil {
                rememberMainSessionIDIfNeeded(incoming)
            }
        }
        if let correlationID = msg.correlationID, canceledPendingIds.contains(correlationID) {
            let placeholderId = pendingICloudPlaceholders[correlationID]
            canceledPendingIds.remove(correlationID)
            pendingICloudPlaceholders.removeValue(forKey: correlationID)
            cancelReplyWaits(for: correlationID)
            if let placeholderId {
                streamingHintsByMessageId.removeValue(forKey: placeholderId)
            }
            // PATCH-2026-05-30: also mark resolved on the cancel-late path so
            // any in-flight text_delta stragglers for this correlation get
            // dropped at the dispatcher.
            markICloudReplyResolved(correlationID)
            return
        }
        if let correlationID = msg.correlationID, let placeholderId = timedOutPendingIds.removeValue(forKey: correlationID) {
            cancelReplyWaits(for: correlationID)
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            // PATCH-2026-05-30: timeout-then-late-reply finalize path. Same
            // resolve-tracking as the normal final path so the seq tracker
            // gets cleared and late deltas get dropped at the dispatcher.
            insertPendingUserIfNeeded(pendingId: correlationID, before: placeholderId)
            markICloudReplyResolved(correlationID)
            if messages.contains(where: { $0.id == placeholderId }) {
                // finishPlaceholder plays the soft "reply landed" haptic here.
                finishPlaceholder(id: placeholderId, text: msg.text, attachments: replyAttachments, awaitingMacTranscript: true)
            } else {
                messages.append(ChatMessage(role: .assistant, text: msg.text, attachments: replyAttachments, awaitingMacTranscript: true))
                Haptics.replyFinalized()
            }
            onReply?(msg.text)
            // B2: this reply landed AFTER its bubble had timed out. If the user
            // scrolled away they'd never see it silently arrive — force a scroll
            // to the bottom and surface a toast so the late answer is noticed.
            requestScrollToBottom()
            iOSSystemToastCenter.shared.push(info: "Reply arrived")
            releaseLoading(for: placeholderId)
            return
        }
        guard !pendingICloudPlaceholders.isEmpty else {
            messages.append(ChatMessage(role: .assistant, text: msg.text, attachments: replyAttachments, awaitingMacTranscript: true))
            onReply?(msg.text)
            isLoading = false
            return
        }
        let match: (String, UUID)?
        if let correlationID = msg.correlationID, !correlationID.isEmpty {
            if let placeholderId = pendingICloudPlaceholders[correlationID] {
                match = (correlationID, placeholderId)
            } else {
                messages.append(ChatMessage(role: .assistant, text: msg.text, attachments: replyAttachments, awaitingMacTranscript: true))
                onReply?(msg.text)
                if pendingICloudPlaceholders.isEmpty {
                    isLoading = false
                }
                return
            }
        } else {
            match = pendingICloudPlaceholders.first
        }
        if let (pendingId, placeholderId) = match {
            if canceledPendingIds.remove(pendingId) != nil {
                pendingICloudPlaceholders.removeValue(forKey: pendingId)
                cancelReplyWaits(for: pendingId)
                streamingHintsByMessageId.removeValue(forKey: placeholderId)
                return
            }
            pendingICloudPlaceholders.removeValue(forKey: pendingId)
            // Phase 14e-iCloud: retire both reply waits — the reply landed.
            cancelReplyWaits(for: pendingId)
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            // PATCH-2026-05-30: caught by gpt-5.5 retroactive review. The
            // resolvedICloudReplyIds guard at the top of receiveICloudReply
            // is supposed to drop straggler text_delta messages that arrive
            // after the final reply has been processed — but ONLY works if
            // the final-reply path actually records the correlation as
            // resolved. The previous code relied on pendingICloudPlaceholders
            // being cleared (so the dispatcher's `guard let placeholderId`
            // fails) which is fine in the happy case but leaks the
            // maxDeltaSeqByCorrelation entry forever AND means a late
            // text_delta could theoretically still be parsed before the
            // guard catches it. Marking resolved here is both the correctness
            // fix (drop at dispatch) and the cleanup fix (clear seq tracker).
            insertPendingUserIfNeeded(pendingId: pendingId, before: placeholderId)
            markICloudReplyResolved(pendingId)
            if messages.contains(where: { $0.id == placeholderId }) {
                finishPlaceholder(id: placeholderId, text: msg.text, attachments: replyAttachments, awaitingMacTranscript: true)
                onReply?(msg.text)
            }
            releaseLoading(for: placeholderId)
        }
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
            guard seq > (maxDeltaSeqByCorrelation[runId] ?? -1) else { return }
            maxDeltaSeqByCorrelation[runId] = seq
            if let id = existingBubble, let index = messages.firstIndex(where: { $0.id == id }) {
                liveTurnBubbles[runId] = id
                messages[index].text = msg.text
            } else {
                let bubble = ChatMessage(role: .assistant, text: msg.text, awaitingMacTranscript: true, runId: runId)
                liveTurnBubbles[runId] = bubble.id
                messages.append(bubble)
            }
            return
        }
        markICloudReplyResolved(runId)
        if kind == "cancelled" { errorBanner = "Stopped. Any partial reply has been kept." }
        let bubble = liveTurnBubbles.removeValue(forKey: runId) ?? existingBubble
        let answer = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unfinished turn keeps its saved text and says why it stopped.
        let failure = kind == "error" ? msg.metadata?["errorDetail"] ?? msg.text : msg.metadata?["status"]
        let state = kind == "error" ? "failed" : kind == "incomplete" || kind == "cancelled" ? "incomplete" : "completed"
        if kind == "error", let failure { errorBanner = "Interrupted. \(failure)" }
        // A snapshot that landed first already carries the saved row; it still
        // takes this turn's terminal status.
        let saved = messages.firstIndex {
            $0.runId == runId && ($0.isTerminalReply || $0.completionState == "failed") && macPublishedMessageIDs.contains($0.id)
        }
        if let saved, let failure {
            messages[saved].failureDetail = failure
            messages[saved].completionState = state
        }
        if saved != nil || (answer.isEmpty && failure == nil) {
            // Only a bubble of our own: a Mac row it became stays.
            if let bubble, !macPublishedMessageIDs.contains(bubble) { messages.removeAll { $0.id == bubble } }
        } else if let bubble, let index = messages.firstIndex(where: { $0.id == bubble }) {
            // Failure keeps the partial reply and its cause in this same bubble.
            messages[index].text = msg.text
            messages[index].failureDetail = failure
            messages[index].completionState = state
        } else {
            var reply = ChatMessage(role: .assistant, text: msg.text, awaitingMacTranscript: true,
                runId: runId, failureDetail: failure)
            reply.completionState = state
            messages.append(reply)
        }
        persistMessages()
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
        guard let session = Self.cleanSessionID(selectedSessionID), !isLoadingHistory,
              let oldest = messages.first(where: { macPublishedMessageIDs.contains($0.id) || pagedHistoryIDs.contains($0.id) })
        else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await iCloudSyncEngine.shared.chatHistoryPage(sessionID: session, beforeID: oldest.id.uuidString)
            guard Self.cleanSessionID(selectedSessionID) == session,
                  let at = messages.firstIndex(where: { $0.id == oldest.id }) else { return }
            let older = page.messages.filter { row in !messages.contains { $0.id == row.id } }
            pagedHistoryIDs.formUnion(older.map(\.id))
            messages.insert(contentsOf: older, at: at)
            if !page.hasOlder { historyExhaustedSessionIDs.insert(session) }
            persistMessages()
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
            let page = try await iCloudSyncEngine.shared.chatHistoryPage(sessionID: session, throughID: id.uuidString, limit: 1)
            guard let whole = page.messages.first(where: { $0.id == id }),
                  let index = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[index].text = whole.text
            persistMessages()
        } catch {
            errorBanner = "The whole message did not load: \(error.localizedDescription)"
        }
    }

    func receiveICloudRejection(_ rejection: ICloudBridgeRejectedMessage) {
        // Reply authentication failure says nothing about request execution.
        // Keep observing the original identity; even its correlation is untrusted.
        if rejection.reason.contains("signature") {
            // 2026-09-08 (User): an unverifiable record stays eligible and is
            // re-rejected on every poll, so the banner came back after every
            // dismissal. Surface each offending message once; the record is
            // still retried quietly. Bounded so a long session cannot grow it.
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

        // 2026-09-13 (first-failure pass): an expired request is not a pairing
        // fault and not a clock fault — it is a Mac that was asleep when the
        // request arrived. The signed rejection is proof the turn never
        // started, which is exactly what makes a fresh send safe. Keep the
        // retained request, say plainly that it wasn't started, and wait: the
        // phone never resends on its own.
        // The args come from the durable record when the in-memory map has
        // been wiped (session switch, relaunch); without that fallback a late
        // expiry for a restored exchange fell into the generic rejection path
        // below, which closes the record and loses "Send now".
        if rejection.isExpiredRequest, let args = resendArgs(for: pendingId) {
            pendingSendArgs[pendingId] = args
            // The retained request has to outlive the in-memory maps: a
            // session switch clears expiredPendingIds and pendingSendArgs, and
            // a relaunch loses both. Write the expiry onto the durable record
            // first, so restore renders "wasn't started · Send now" rather
            // than a streaming placeholder for a correlation the Mac refused.
            failPendingReply(
                pendingId: pendingId,
                placeholderId: placeholderId,
                placeholderText: rejection.userMessage,
                banner: rejection.userMessage
            )
            // AFTER the failure cleanup, not before: failPendingReply ends in
            // cancelReplyWaits, and a terminal receipt closes the durable
            // record. Writing the expiry first meant it was deleted moments
            // later and "Send now" survived only in memory.
            markPendingExchangeExpired(
                correlationID: pendingId,
                placeholderID: placeholderId,
                message: rejection.userMessage,
                args: args
            )
            timedOutPendingIds.removeValue(forKey: pendingId)
            expiredPendingIds[pendingId] = placeholderId
            return
        }
        failPendingReply(
            pendingId: pendingId,
            placeholderId: placeholderId,
            placeholderText: "(Mac reply rejected — re-pair this iPhone with the Mac)",
            banner: rejection.userMessage
        )
        pendingSendArgs.removeValue(forKey: pendingId)
        // Terminal and unresumable — the retained request is gone above — so
        // the durable record closes too. Left open it would come back after a
        // session switch as a streaming placeholder that can never finish.
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
            if let eventIndex = messages[idx].toolEvents.firstIndex(where: { $0.seq == seq }) {
                if let activity { messages[idx].toolEvents[eventIndex].activity = activity }
            } else {
                messages[idx].toolEvents.append(ToolEvent(name: clean, seq: seq, activity: activity))
                messages[idx].toolEvents.sort { $0.seq < $1.seq }
            }
            if kind == "tool_result", let eventIndex = messages[idx].toolEvents.firstIndex(where: { $0.seq == seq }) {
                messages[idx].toolEvents[eventIndex].outcome = msg.metadata?["outcome"]
                messages[idx].toolEvents[eventIndex].resultDetail = msg.metadata?["resultDetail"]
            }
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

    /// PATCH-2026-05-30: handle in-flight text streaming over iCloud.
    /// The Mac side publishes batched text_delta BridgeMessages during a chat
    /// turn — each one carries the FULL accumulated text-so-far (not the
    /// incremental characters), plus a monotonic `seq` per correlation. iOS
    /// keeps the highest seq it has seen and replaces the bubble text with
    /// the larger snapshot, so out-of-order delivery from iCloud Drive is
    /// recoverable. The placeholder stays in `isStreaming=true` until the
    /// final reply (a plain BridgeMessage or `kind:"final"`) lands and runs
    /// the existing finishPlaceholder path. Late deltas arriving after the
    /// final are dropped on the receiveICloudReply dispatcher because the
    /// correlationID is already in resolvedICloudReplyIds.
    private func receiveICloudTextDelta(_ msg: BridgeMessage) {
        guard let correlationID = msg.correlationID,
              let placeholderId = pendingICloudPlaceholders[correlationID],
              let idx = messages.firstIndex(where: { $0.id == placeholderId })
        else { return }
        // PATCH-2026-05-30: caught by gpt-5.5 review — strict seq parsing.
        // Require an explicit, parseable seq. Missing/unparseable means the
        // message is malformed or from a buggy producer; drop it rather
        // than letting it fall back to seq=0 (where an unrelated malformed
        // late message could overwrite a legit accumulated snapshot). Also
        // use `<=` so an equal-seq malformed retry cannot replace what's
        // on screen with potentially-stale text.
        guard let seqText = msg.metadata?["seq"], let seq = Int(seqText) else {
            return
        }
        let previousSeq = maxDeltaSeqByCorrelation[correlationID] ?? -1
        if seq <= previousSeq {
            return  // straggler or duplicate — newer snapshot already on screen
        }
        maxDeltaSeqByCorrelation[correlationID] = seq
        _ = idx
        // Chunks arrive ~1s apart (iCloud transport batch). The bubble's
        // paced reveal plays each one out at about 80 words a second; the
        // store only publishes the accumulated text, without a transcript
        // persist per chunk (finalize writes the durable copy).
        // The partial answer is durable from here: a phone closed mid-answer
        // must come back to the words it already had, not an empty bubble.
        noteEvidencedActivity(correlationID: correlationID, activity: nil, partialText: msg.text)
        setStreamingText(placeholderId, msg.text)
        // Once content is flowing, the static "Typing" hint is misleading —
        // clear it so the bubble's own text drives the UX.
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        // Keep the timeout fresh — visible progress proves the turn is alive.
        pendingTimeouts.removeValue(forKey: correlationID)?.cancel()
        armTimeout(for: correlationID, placeholderId: placeholderId)
    }

    private func setStreamingText(_ placeholderId: UUID, _ text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        suppressMessagePersistence = true
        var updated = messages[idx]
        updated.text = text
        updated.isStreaming = true
        messages[idx] = updated
        suppressMessagePersistence = false
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
        pendingPolls.removeValue(forKey: pendingId)?.cancel()
        // Every caller of this is a terminal receipt, and a terminal receipt is
        // the ONLY thing that closes the durable unfinished-exchange record.
        closePendingExchange(pendingId)
    }

    /// Phase 14e-iCloud: arm a per-message timeout. If no reply arrives by the
    /// timeout, surface an error banner, mark the placeholder as failed, and
    /// unblock the input.  Cancelled when receiveICloudReply lands the reply.
    func armTimeout(for pendingId: String, placeholderId: UUID) {
        pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
        let timeoutNs = iCloudReplyTimeoutSeconds * 1_000_000_000
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.fireTimeout(pendingId: pendingId, placeholderId: placeholderId) }
        }
        pendingTimeouts[pendingId] = task
    }

    /// E1 (upgrade-sweep 2026-08): the reply nudge floor while a reply is
    /// outstanding. Was 500ms for the first 20 attempts, then 1.2s.
    static let iCloudReplyNudgeFloorSeconds: TimeInterval = 8
    /// The transcript snapshot re-read is the slow safety net, not the
    /// transport. Was every 5s for the first 60s.
    static let iCloudReplySnapshotBackstopSeconds: TimeInterval = 30
    /// 2026-09-13: the snapshot backstop used to stop after 120s and hand the
    /// outcome to a local timeout that failed the bubble. Nothing replaces
    /// observation now, so it keeps reading for as long as the request is
    /// outstanding — that is the whole point of pocketing the phone.
    static let iCloudReplySnapshotBackstopWindowSeconds: TimeInterval = 120
    static let iCloudReplyPollingHintAfterSeconds: TimeInterval = 10

    func armReplyPoll(for pendingId: String, client: MacBridgeClient) {
        pendingPolls.removeValue(forKey: pendingId)?.cancel()
        // E1: push-first. CloudKit delivers the reply on a silent push that
        // drains the transport and resolves the placeholder, so this loop is a
        // backstop rather than the transport. The hot path drains incoming only
        // at the 8s floor; the heavier transcript-snapshot re-read moves to a
        // 30s cadence over a 120s window.
        let task = Task { [weak self, weak client] in
            let startedAt = Date()
            var nextSnapshotPollAt = startedAt.addingTimeInterval(Self.iCloudReplySnapshotBackstopSeconds)

            while !Task.isCancelled {
                // --- incoming drain (hot path) ---
                // Detached so one stalled iCloud scan cannot wedge the
                // pending-reply watchdog behind it.
                Task { await client?.pollICloudRepliesNow() }
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.iCloudReplyNudgeFloorSeconds * 1_000_000_000)
                )

                guard let self else { return }

                // Check if the iCloud path already resolved it.
                let stillPending = await MainActor.run {
                    self.pendingICloudPlaceholders[pendingId] != nil
                }
                if !stillPending {
                    await MainActor.run { self.isPollingFallback = false }
                    return
                }

                let now = Date()
                // 2026-09-13: each tick re-states the SAME waiting line rather
                // than escalating it — what the Mac last evidenced and how old
                // that is. Elapsed local time is never itself an event.
                if now.timeIntervalSince(startedAt) >= Self.iCloudReplyPollingHintAfterSeconds {
                    await MainActor.run {
                        self.isPollingFallback = true
                        self.showWaitStatus(correlationID: pendingId)
                    }
                }

                // --- iCloud snapshot refresh leg (slow backstop) ---
                if now >= nextSnapshotPollAt, let client {
                    nextSnapshotPollAt = now.addingTimeInterval(Self.iCloudReplySnapshotBackstopSeconds)

                    // Force-refresh bypasses the 2s throttle.
                    await self.forceRefresh(using: client, fallbackMessages: nil)

                    // Re-check: forceRefresh may have resolved the pending reply.
                    let stillPendingAfterSnapshot = await MainActor.run {
                        self.pendingICloudPlaceholders[pendingId] != nil
                    }
                    if !stillPendingAfterSnapshot {
                        await MainActor.run { self.isPollingFallback = false }
                        return
                    }
                }
            }
        }
        pendingPolls[pendingId] = task
    }

    // MARK: - iCloud Snapshot Force Refresh

    /// Like `refresh(using:)` but bypasses the 2-second throttle. Intended only for
    /// active-send polling — not for user-driven or scenePhase refreshes.
    /// Updates `lastRefreshAt` so throttled callers are debounced afterwards.
    func forceRefresh(using client: MacBridgeClient, fallbackMessages: [ChatMessage]?) async {
        await forceRefresh(
            loadTranscript: { await client.readChatTranscript(sessionID: $0) },
            fallbackMessages: fallbackMessages
        )
    }

    /// The pre-2026-09-06 array-shaped loader: nil is an unavailable read and
    /// an empty array carries no transcript version, so it can never clear.
    func forceRefresh(
        loadHistory: (String?) async -> [ChatMessage]?,
        fallbackMessages: [ChatMessage]?
    ) async {
        await forceRefresh(
            loadTranscript: { sessionID in
                guard let messages = await loadHistory(sessionID) else { return .unavailable }
                return .published(messages, generation: nil)
            },
            fallbackMessages: fallbackMessages
        )
    }

    func forceRefresh(
        loadTranscript: (String?) async -> MacTranscriptRead,
        fallbackMessages: [ChatMessage]?
    ) async {
        lastRefreshAt = Date()
        let sessionID = Self.cleanSessionID(selectedSessionID ?? mainSessionID)
        let generation = sessionSwitchGeneration
        let read = await loadTranscript(sessionID)
        guard !Task.isCancelled,
              generation == sessionSwitchGeneration,
              sessionID == Self.cleanSessionID(selectedSessionID ?? mainSessionID) else { return }
        guard read != .unavailable else {
            if messages.isEmpty, let fallbackMessages, !fallbackMessages.isEmpty {
                messages = fallbackMessages
            }
            return
        }
        // Push, foreground refresh, and missed-reply recovery share one merge
        // owner, including same-ID text updates and timed-out reply recovery.
        applyMacTranscriptRead(read, sessionID: sessionID)
    }

    /// 2026-09-13: a local clock running out is not a failure of the Mac, and
    /// it is certainly not abandonment of the request. Nothing is replaced,
    /// nothing is retired, nothing is re-sent: any partial answer stays on
    /// screen, observation of the original signed request continues, and the
    /// only thing that changes is the status word.
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
        cancelReplyWaits(for: pendingId)
        pendingICloudPlaceholders.removeValue(forKey: pendingId)
        isPollingFallback = false
        timedOutPendingIds[pendingId] = placeholderId
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        // PATCH-2026-05-30: caught by gpt-5.5 review — failure paths also
        // need to clear the text_delta seq tracker so the map stays bounded
        // and any straggler deltas for this correlation get dropped.
        maxDeltaSeqByCorrelation.removeValue(forKey: pendingId)
        finishPlaceholder(id: placeholderId, text: placeholderText, success: false, awaitingMacTranscript: awaitingMacTranscript)
        errorBanner = banner
        releaseLoading(for: placeholderId)
    }

    func markICloudReplyResolved(_ pendingId: String, discardRetainedSend: Bool = true) {
        resolvedICloudReplyIds.insert(pendingId)
        if discardRetainedSend { queuedSends.removeAll { $0.id.uuidString == pendingId } }
        // PATCH-2026-05-30: this correlation's stream is over — drop its
        // text_delta seq tracker so the map stays bounded across long
        // sessions. Late deltas for it will be dropped on the dispatcher.
        maxDeltaSeqByCorrelation.removeValue(forKey: pendingId)
        // Phase 14e-iCloud HMAC self-heal: drop the retry record once the
        // turn is done so the dictionary doesn't grow unbounded.
        pendingSendArgs.removeValue(forKey: pendingId)
        retriedSignatureCorrelations.remove(pendingId)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            await MainActor.run {
                _ = self?.resolvedICloudReplyIds.remove(pendingId)
            }
        }
    }

    func finishPlaceholder(
        id placeholderId: UUID,
        text: String,
        attachments: [ChatAttachmentSummary] = [],
        success: Bool = true,
        awaitingMacTranscript: Bool = false
    ) {
        // Final text wins instantly — never make the user wait on the
        // paced reveal to catch up to an already-complete reply.
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        var updated = messages[idx]
        updated.text = text
        updated.attachments = attachments
        updated.isStreaming = false
        updated.awaitingMacTranscript = awaitingMacTranscript
        updated.completionState = text == "(stopped)" ? nil : success ? "completed" : "failed"
        messages[idx] = updated
        // phase 6: soft confirmation tap once the reply lands — one per turn,
        // never per streamed chunk (this is the single finalize site). Only
        // genuine success: failure paths (failPendingReply: timeouts, stream
        // errors, rejections) pass success=false, and the user-stop sentinel
        // is skipped — a "success" tap on either would lie (gpt-5.5 r2 catch).
        if success && text != "(stopped)" {
            // A dispatch receipt only means the phone handed the request to
            // transport. Clear prior failure context only once a final reply
            // is actually rendered for this turn.
            errorBanner = nil
            Haptics.replyFinalized()
        }
        // Arrival stamps record FIRST appearance; a turn that streamed longer
        // than the preserve window would finalize already-stale and a stale
        // snapshot right after could drop the just-arrived reply. Resolution
        // is the arrival that matters for the stale-snapshot guard.
        localArrivalDates[placeholderId] = Date()
    }

    private func attachmentSummaries(from attachments: [MultimodalAttachment]?) -> [ChatAttachmentSummary] {
        (attachments ?? []).map {
            ChatAttachmentSummary(
                id: $0.id,
                name: $0.name ?? ($0.type == "image" ? "Image" : "Attachment"),
                type: $0.type,
                mime: $0.mime,
                base64: $0.base64,
                byteSize: $0.byteSize
            )
        }
    }
}
