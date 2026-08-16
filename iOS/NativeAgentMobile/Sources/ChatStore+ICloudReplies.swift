// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

extension ChatStore {
    // N5 fix (R18): called by ChatView when an iCloud reply arrives.
    // Finds the matching placeholder (by sent message ID in correlationId or
    // by taking the oldest pending placeholder) and updates it.
    func receiveICloudReply(_ msg: BridgeMessage) {
        guard msg.sender == "mac" else { return }  // only accept Mac replies
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
        if msg.metadata?["kind"] == "progress" {
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
                failPendingReply(
                    pendingId: correlationID,
                    placeholderId: placeholderId,
                    placeholderText: "(NativeAgent hit an error answering that message)",
                    banner: detail.isEmpty ? msg.text : detail
                )
            } else {
                errorBanner = detail.isEmpty ? msg.text : detail
            }
            return
        }
        // F7 P0 #3: explicit cancelled kind. Resolve the placeholder, clear
        // the spinner, but don't surface an error banner.
        if msg.metadata?["kind"] == "cancelled" {
            var matchedActivePlaceholder = false
            if let correlationID = msg.correlationID,
               let placeholderId = pendingICloudPlaceholders.removeValue(forKey: correlationID) {
                matchedActivePlaceholder = true
                pendingTimeouts.removeValue(forKey: correlationID)?.cancel()
                pendingPolls.removeValue(forKey: correlationID)?.cancel()
                streamingHintsByMessageId.removeValue(forKey: placeholderId)
                markICloudReplyResolved(correlationID)
                if messages.contains(where: { $0.id == placeholderId }) {
                    finishPlaceholder(id: placeholderId, text: "(stopped)")
                }
            }
            if matchedActivePlaceholder && pendingICloudPlaceholders.isEmpty { isLoading = false }
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
            pendingTimeouts.removeValue(forKey: correlationID)?.cancel()
            pendingPolls.removeValue(forKey: correlationID)?.cancel()
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
            pendingTimeouts.removeValue(forKey: correlationID)?.cancel()
            pendingPolls.removeValue(forKey: correlationID)?.cancel()
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            // PATCH-2026-05-30: timeout-then-late-reply finalize path. Same
            // resolve-tracking as the normal final path so the seq tracker
            // gets cleared and late deltas get dropped at the dispatcher.
            insertPendingUserIfNeeded(pendingId: correlationID, before: placeholderId)
            markICloudReplyResolved(correlationID)
            if messages.contains(where: { $0.id == placeholderId }) {
                // finishPlaceholder plays the soft "reply landed" haptic here.
                finishPlaceholder(id: placeholderId, text: msg.text, attachments: replyAttachments)
            } else {
                messages.append(ChatMessage(role: .assistant, text: msg.text, attachments: replyAttachments))
                Haptics.replyFinalized()
            }
            onReply?(msg.text)
            // B2: this reply landed AFTER its bubble had timed out. If the user
            // scrolled away they'd never see it silently arrive — force a scroll
            // to the bottom and surface a toast so the late answer is noticed.
            requestScrollToBottom()
            iOSSystemToastCenter.shared.push(info: "Reply arrived")
            if pendingICloudPlaceholders.isEmpty && timedOutPendingIds.isEmpty {
                isLoading = false
            }
            return
        }
        guard !pendingICloudPlaceholders.isEmpty else {
            messages.append(ChatMessage(role: .assistant, text: msg.text, attachments: replyAttachments))
            onReply?(msg.text)
            isLoading = false
            return
        }
        let match: (String, UUID)?
        if let correlationID = msg.correlationID, !correlationID.isEmpty {
            if let placeholderId = pendingICloudPlaceholders[correlationID] {
                match = (correlationID, placeholderId)
            } else {
                messages.append(ChatMessage(role: .assistant, text: msg.text, attachments: replyAttachments))
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
                pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
                pendingPolls.removeValue(forKey: pendingId)?.cancel()
                streamingHintsByMessageId.removeValue(forKey: placeholderId)
                return
            }
            pendingICloudPlaceholders.removeValue(forKey: pendingId)
            // Phase 14e-iCloud: cancel the timeout — the reply landed.
            pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
            pendingPolls.removeValue(forKey: pendingId)?.cancel()
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
                finishPlaceholder(id: placeholderId, text: msg.text, attachments: replyAttachments)
                onReply?(msg.text)
            }
            // If this was the last pending placeholder, clear the loading spinner.
            if pendingICloudPlaceholders.isEmpty {
                isLoading = false
            }
        }
    }

    func receiveICloudRejection(_ rejection: ICloudBridgeRejectedMessage) {
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

        // Phase 14e-iCloud HMAC self-heal: attempt ONE silent refresh + retry
        // before surfacing the rejection. The action channel already does this
        // for signature_invalid; mirror to chat so a single stale-secret event
        // self-heals instead of permanently dropping the send.
        let isSignatureFailure = rejection.reason.contains("signature")
        if isSignatureFailure,
           let args = pendingSendArgs[pendingId],
           !retriedSignatureCorrelations.contains(pendingId),
           let client = pendingRetryClient {
            // Reserve the one refresh attempt before suspension so repeated
            // forged/duplicate rejection envelopes cannot queue replay tasks.
            retriedSignatureCorrelations.insert(pendingId)
            Task {
                guard await pairingStoreRef?.refreshFromKVS() == true else {
                    failPendingReply(
                        pendingId: pendingId,
                        placeholderId: placeholderId,
                        placeholderText: "(Mac reply rejected — re-pair this iPhone with the Mac)",
                        banner: "Pairing out of sync — re-pair?"
                    )
                    pendingSendArgs.removeValue(forKey: pendingId)
                    return
                }
                pendingSendArgs.removeValue(forKey: pendingId)
                pendingICloudPlaceholders.removeValue(forKey: pendingId)
                pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
                pendingPolls.removeValue(forKey: pendingId)?.cancel()
                streamingHintsByMessageId.removeValue(forKey: placeholderId)
                if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                    messages.remove(at: idx)
                }
                isLoading = false
                errorBanner = nil
                send(
                    text: args.text,
                    client: client,
                    controls: args.controls,
                    appendUser: false,
                    attachments: args.attachments
                )
            }
            return
        }

        failPendingReply(
            pendingId: pendingId,
            placeholderId: placeholderId,
            placeholderText: "(Mac reply rejected — re-pair this iPhone with the Mac)",
            banner: isSignatureFailure
                ? "Pairing out of sync — re-pair?"
                : rejection.userMessage
        )
        pendingSendArgs.removeValue(forKey: pendingId)
    }

    /// An unsigned resync envelope is only delivered here after the bridge
    /// durably installed a different KVS key. Never trust its attacker-controlled
    /// correlation metadata; retry the locally-owned pending send instead.
    func receiveICloudResyncHint(_ hint: BridgeMessage, client: MacBridgeClient) {
        _ = hint
        guard let rejectedId = pendingSendArgs.keys.first(where: {
                  pendingICloudPlaceholders[$0] != nil
                    && !retriedSignatureCorrelations.contains($0)
              }),
              let args = pendingSendArgs[rejectedId],
              let placeholderId = pendingICloudPlaceholders[rejectedId]
        else { return }
        retriedSignatureCorrelations.insert(rejectedId)
        pendingSendArgs.removeValue(forKey: rejectedId)
        pendingICloudPlaceholders.removeValue(forKey: rejectedId)
        pendingTimeouts.removeValue(forKey: rejectedId)?.cancel()
        pendingPolls.removeValue(forKey: rejectedId)?.cancel()
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
            messages.remove(at: idx)
        }
        isLoading = false
        send(
            text: args.text,
            client: client,
            controls: args.controls,
            appendUser: false,
            attachments: args.attachments
        )
    }


    private func receiveICloudProgress(_ msg: BridgeMessage) {
        guard let correlationID = msg.correlationID,
              let placeholderId = pendingICloudPlaceholders[correlationID],
              let idx = messages.firstIndex(where: { $0.id == placeholderId })
        else { return }
        let clean = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let kind = msg.metadata?["kind"]
        if kind == "tool_use" {
            // F7 P2 + flip-box: each tool firing becomes a ToolEvent on the
            // placeholder message. The flip-box renders the latest; the
            // collapsed summary shows the running count. tool_result events are
            // ignored here (the flip-box already reflects the tool); generic
            // progress (no kind) still drives the typing hint below.
            let seq = Int(msg.metadata?["toolSeq"] ?? "")
                ?? ((messages[idx].toolEvents.map(\.seq).max() ?? 0) + 1)
            if !messages[idx].toolEvents.contains(where: { $0.seq == seq }) {
                messages[idx].toolEvents.append(ToolEvent(name: clean, seq: seq))
            }
            // A tool firing is real progress — clear any stale "Typing"/waiting
            // hint so the flip-box, not the hint line, drives the UI.
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
        } else if kind != "tool_result" {
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
        // chat-smoothness phase 2: chunks arrive ~1.5s apart (iCloud transport
        // batch). Play each one out progressively (~70ms word steps) instead
        // of slamming the accumulated text in — and stop paying a full
        // transcript persist per chunk (typewriter ticks suppress persistence;
        // finalize writes the durable copy).
        typewriterAdvance(placeholderId: placeholderId, target: msg.text)
        // Once content is flowing, the static "Typing" hint is misleading —
        // clear it so the bubble's own text drives the UX.
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        // Keep the timeout fresh — visible progress proves the turn is alive.
        pendingTimeouts.removeValue(forKey: correlationID)?.cancel()
        armTimeout(for: correlationID, placeholderId: placeholderId)
    }

    /// Phase 14e-iCloud: arm a per-message timeout. If no reply arrives by the
    /// timeout, surface an error banner, mark the placeholder as failed, and
    /// unblock the input.  Cancelled when receiveICloudReply lands the reply.
    func armTimeout(for pendingId: String, placeholderId: UUID) {
        let timeoutNs = iCloudReplyTimeoutSeconds * 1_000_000_000
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.fireTimeout(pendingId: pendingId, placeholderId: placeholderId) }
        }
        pendingTimeouts[pendingId] = task
    }

    func armReplyPoll(for pendingId: String, client: MacBridgeClient) {
        pendingPolls[pendingId]?.cancel()
        // Runs two iCloud-only wait paths in parallel:
        //   1. Fast iCloud nudge loop: 500ms early, then 1.2s — prods NSMetadataQuery.
        //   2. Snapshot refresh every 5s, cap 60s (12 polls max):
        //      calls forceRefresh(using:) which bypasses the 2s throttle and
        //      reads the iCloud-backed transcript snapshot. If a reply landed
        //      there first, the placeholder updates and isLoading clears.
        //      Also sets isPollingFallback=true after 10s so the UI can show a hint.
        let task = Task { [weak self, weak client] in
            var iCloudAttempt = 0
            var snapshotAttempt = 0
            var nextSnapshotPollAt = Date().addingTimeInterval(5)
            let maxSnapshotPolls = 12            // 12 x 5s = 60s cap
            let snapshotHintAfter: TimeInterval = 10  // show hint after 10s

            while !Task.isCancelled {
                // --- iCloud Drive nudge ---
                // Keep the pending-reply watchdog moving even if one iCloud
                // Drive scan stalls while downloading or coordinating files.
                Task { await client?.pollICloudRepliesNow() }
                iCloudAttempt += 1
                let nudgeIntervalNs: UInt64 = iCloudAttempt < 20 ? 500_000_000 : 1_200_000_000
                try? await Task.sleep(nanoseconds: nudgeIntervalNs)

                guard let self else { return }

                // Check if the iCloud path already resolved it.
                let stillPending = await MainActor.run {
                    self.pendingICloudPlaceholders[pendingId] != nil
                }
                if !stillPending {
                    await MainActor.run { self.isPollingFallback = false }
                    return
                }

                // --- iCloud snapshot refresh leg ---
                let now = Date()
                if now >= nextSnapshotPollAt, snapshotAttempt < maxSnapshotPolls, let client {
                    snapshotAttempt += 1
                    nextSnapshotPollAt = now.addingTimeInterval(5)

                    // Enable "still waiting…" hint after 10s (2nd snapshot poll = attempt 2).
                    if Double(snapshotAttempt) * 5 >= snapshotHintAfter {
                        await MainActor.run {
                            self.isPollingFallback = true
                            if let placeholderId = self.pendingICloudPlaceholders[pendingId] {
                                self.streamingHintsByMessageId[placeholderId] = "Still working on the Mac"
                            }
                        }
                    }

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
        lastRefreshAt = Date()
        guard let macMessages = await client.refreshChatHistory(sessionID: selectedSessionID) else {
            if messages.isEmpty, let fallbackMessages, !fallbackMessages.isEmpty {
                messages = fallbackMessages
            }
            return
        }
        guard !macMessages.isEmpty else { return }

        let replyArrived = macAssistantReplyArrived(macMessages)
        if replyArrived, resolvePendingReplyFromMac(macMessages) {
            return
        }

        // Capture the pending placeholder's tool events before the merge swaps
        // it for the Mac-id reply, so the collapsed box survives the swap.
        let carriedEvents: [ToolEvent] = pendingICloudPlaceholders.values.first
            .flatMap { id in messages.first(where: { $0.id == id })?.toolEvents } ?? []
        let merged = mergedMacMessagesPreservingPending(macMessages, replyArrived: replyArrived)
        let hasPendingReply = replyArrived && !pendingICloudPlaceholders.isEmpty
        guard merged.map(\.id) != messages.map(\.id) || hasPendingReply else { return }

        if merged.map(\.id) != messages.map(\.id) {
            messages = merged
            persistMessages()
        }

        if replyArrived, let pendingId = pendingICloudPlaceholders.keys.first {
            // The iCloud snapshot found a reply the file listener missed.
            // Resolve the placeholder; the merge above already kept local pending sends.
            let placeholderId = pendingICloudPlaceholders[pendingId]
            markICloudReplyResolved(pendingId)
            pendingICloudPlaceholders.removeValue(forKey: pendingId)
            pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
            pendingPolls.removeValue(forKey: pendingId)?.cancel()
            if let placeholderId {
                streamingHintsByMessageId.removeValue(forKey: placeholderId)
            }
            isPollingFallback = false
            if pendingICloudPlaceholders.isEmpty {
                isLoading = false
            }
            // Speak the reply if TTS is wired up.
            if let lastAssistant = newestMacAssistantReply(macMessages) {
                stampToolEvents(carriedEvents, onMessageWithId: lastAssistant.id)
                onReply?(lastAssistant.text)
            }
        }
    }

    private func fireTimeout(pendingId: String, placeholderId: UUID) {
        // If the reply already landed (e.g. race), the placeholder map will
        // no longer contain pendingId — bail.
        guard pendingICloudPlaceholders[pendingId] != nil else { return }
        failPendingReply(
            pendingId: pendingId,
            placeholderId: placeholderId,
            placeholderText: "(reply timed out — Mac may be offline or iCloud sync is delayed)",
            banner: "Reply timed out after \(iCloudReplyTimeoutSeconds)s. Check the Mac is awake and signed into the same iCloud account."
        )
    }

    private func failPendingReply(
        pendingId: String,
        placeholderId: UUID,
        placeholderText: String,
        banner: String
    ) {
        pendingTimeouts.removeValue(forKey: pendingId)
        pendingPolls.removeValue(forKey: pendingId)?.cancel()
        pendingICloudPlaceholders.removeValue(forKey: pendingId)
        isPollingFallback = false
        timedOutPendingIds[pendingId] = placeholderId
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        // PATCH-2026-05-30: caught by gpt-5.5 review — failure paths also
        // need to clear the text_delta seq tracker so the map stays bounded
        // and any straggler deltas for this correlation get dropped.
        maxDeltaSeqByCorrelation.removeValue(forKey: pendingId)
        finishPlaceholder(id: placeholderId, text: placeholderText, success: false)
        errorBanner = banner
        isLoading = false
    }

    func markICloudReplyResolved(_ pendingId: String) {
        resolvedICloudReplyIds.insert(pendingId)
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
        success: Bool = true
    ) {
        // Final text wins instantly — never make the user wait on the
        // typewriter to catch up to an already-complete reply.
        cancelTypewriter(placeholderId)
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        streamingHintsByMessageId.removeValue(forKey: placeholderId)
        var updated = messages[idx]
        updated.text = text
        updated.attachments = attachments
        updated.isStreaming = false
        messages[idx] = updated
        // phase 6: soft confirmation tap once the reply lands — one per turn,
        // never per typewriter tick (this is the single finalize site). Only
        // genuine success: failure paths (failPendingReply: timeouts, stream
        // errors, rejections) pass success=false, and the user-stop sentinel
        // is skipped — a "success" tap on either would lie (gpt-5.5 r2 catch).
        if success && text != "(stopped)" {
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
