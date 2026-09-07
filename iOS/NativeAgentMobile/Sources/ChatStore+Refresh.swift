import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    // MARK: - Foreground history refresh (PATCH-2026-05-11: foreground-refresh)

    /// Timestamp of the last successful (or in-progress) refresh attempt.
    /// Used as a throttle guard — skips if a refresh happened within 2 seconds.

    /// Throttle interval (seconds). Refreshes closer together than this are skipped.

    /// Pull the full chat transcript from the iCloud snapshot and merge it into local state.
    /// - Best-effort: errors and nil returns are silently ignored.
    /// - Throttled: no-ops if called again within `refreshThrottleSeconds`.
    /// - Merge: snapshot is authoritative; in-flight optimistic messages (isStreaming or
    ///   the last user message with no paired assistant reply yet during an active send)
    ///   are kept visible until the snapshot contains the equivalent user turn.
    func refresh(using client: MacBridgeClient, fallbackMessages: [ChatMessage]?) {
        guard Date().timeIntervalSince(lastRefreshAt) >= refreshThrottleSeconds else { return }
        lastRefreshAt = Date()
        let requestedSessionID = Self.cleanSessionID(selectedSessionID ?? mainSessionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let read = await client.readChatTranscript(sessionID: requestedSessionID)
            guard read != .unavailable else {
                guard Self.cleanSessionID(self.selectedSessionID ?? self.mainSessionID) == requestedSessionID else {
                    return
                }
                if self.messages.isEmpty, let fallbackMessages, !fallbackMessages.isEmpty {
                    self.messages = fallbackMessages
                }
                return
            }
            self.applyMacTranscriptRead(read, sessionID: requestedSessionID)
        }
    }

    /// Applies a Mac-owned transcript projection to the currently visible
    /// session. This is also the event-driven iCloud publication consumer, so
    /// it intentionally merges when messages are already visible. The existing
    /// pending machinery remains authoritative for local streams and inputs.
    func applyMacTranscriptSnapshot(_ macMessages: [ChatMessage], sessionID: String?) {
        applyMacTranscriptRead(.published(macMessages, generation: nil), sessionID: sessionID)
    }

    /// 2026-09-06: same merge owner, now told whether an empty transcript is
    /// the Mac's statement about this session or merely nothing to read.
    func applyMacTranscriptRead(_ read: MacTranscriptRead, sessionID: String?) {
        let requestedSessionID = Self.cleanSessionID(sessionID)
        guard requestedSessionID == Self.cleanSessionID(selectedSessionID ?? mainSessionID),
              case .published(let macMessages, let generation) = read else { return }
        guard !macMessages.isEmpty else {
            applyAuthoritativeEmptyTranscript(generation: generation, sessionID: requestedSessionID)
            return
        }
        // 2026-09-06: a non-empty snapshot BUILT BEFORE the watermark is stale,
        // and applying it resurrects exactly the rows a newer empty just
        // cleared — permanently, because the Mac has no reason to publish that
        // session again. The empty path already refuses an older generation;
        // this is the same rule for the rows. A snapshot with no generation
        // (legacy publisher) proves nothing either way and still applies.
        if let generation, let requestedSessionID,
           let applied = appliedTranscriptGenerations[requestedSessionID],
           generation < applied {
            return
        }
        let generationAdvanced = noteAppliedTranscriptGeneration(generation, for: requestedSessionID)
        noteMacPublishedMessageIDs(macMessages)

        // Preserve any in-flight optimistic messages (streaming placeholder +
        // the user message that triggered it) so an external completion cannot
        // clobber the local stream.
        let replyArrived = macAssistantReplyArrived(macMessages)
        if replyArrived, resolvePendingReplyFromMac(macMessages) {
            return
        }

        // Capture the pending placeholder's tool events before the merge swaps
        // it for the Mac-id reply, so the collapsed box survives.
        let carriedEvents: [ToolEvent] = pendingICloudPlaceholders.values.first
            .flatMap { id in messages.first(where: { $0.id == id })?.toolEvents } ?? []
        let timedOutUserCandidates: [String: ChatMessage] = Dictionary(
            uniqueKeysWithValues: timedOutPendingIds.keys.compactMap { pendingId -> (String, ChatMessage)? in
                guard let uid = pendingSendArgs[pendingId]?.appendedUserId,
                      let msg = messages.first(where: { $0.id == uid }) else { return nil }
                return (pendingId, msg)
            }
        )
        let merged = mergedMacMessagesPreservingPending(macMessages, replyArrived: replyArrived)
        let hasPendingReply = replyArrived && !pendingICloudPlaceholders.isEmpty
        guard merged != messages || hasPendingReply else {
            // 2026-09-06: the rows did not change but the watermark did, and
            // the watermark only reaches disk through persistMessages. Without
            // this the relaunched app restores the OLDER generation, and a
            // delayed empty N+1 built before this publication then looks newer
            // than everything and wipes real rows.
            if generationAdvanced { persistMessages() }
            return
        }
        if merged != messages {
            messages = merged
        }
        if replyArrived, let pendingId = pendingICloudPlaceholders.keys.first {
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
            if let lastAssistant = newestMacAssistantReply(macMessages) {
                stampToolEvents(carriedEvents, onMessageWithId: lastAssistant.id)
                onReply?(lastAssistant.text)
            }
        }

        // A late reply can arrive via the snapshot after its bubble timed out.
        // Require positive user-anchor + following-assistant evidence.
        var resolvedBySnapshot: [(pendingId: String, placeholderId: UUID)] = []
        var stateOnlyGC: [(pendingId: String, placeholderId: UUID)] = []
        for (pendingId, placeholderId) in timedOutPendingIds {
            if let userMsg = timedOutUserCandidates[pendingId],
               let anchor = indexOfUserOccurrence(userMsg, in: macMessages),
               macMessages[(anchor + 1)...].contains(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                resolvedBySnapshot.append((pendingId, placeholderId))
            } else if !messages.contains(where: { $0.id == placeholderId }) {
                stateOnlyGC.append((pendingId, placeholderId))
            }
        }
        for (pendingId, placeholderId) in resolvedBySnapshot + stateOnlyGC {
            timedOutPendingIds.removeValue(forKey: pendingId)
            pendingSendArgs.removeValue(forKey: pendingId)
            retriedSignatureCorrelations.remove(pendingId)
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            markICloudReplyResolved(pendingId)
        }
        if !resolvedBySnapshot.isEmpty {
            for (_, placeholderId) in resolvedBySnapshot {
                if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                    messages.remove(at: idx)
                }
            }
            requestScrollToBottom()
            iOSSystemToastCenter.shared.push(info: "Reply arrived")
        }
        if !(resolvedBySnapshot.isEmpty && stateOnlyGC.isEmpty),
           pendingICloudPlaceholders.isEmpty, timedOutPendingIds.isEmpty {
            isLoading = false
        }
        persistMessages()
    }

    /// 2026-09-06: the Mac says this session's transcript is empty. Acting on
    /// that word is the point — a chat cleared on the Mac has to clear here —
    /// but a wrongly-applied empty destroys a real conversation, so it counts
    /// only for the visible session and only when its transcript version is
    /// strictly greater than the last one applied for that session. A version
    /// the Mac never wrote (nil) proves nothing and clears nothing. Rows the
    /// pending machinery still owns (an in-flight user message and its
    /// streaming placeholder) were never in the Mac's transcript to begin with
    /// and stay. Returns whether the empty was applied.
    @discardableResult
    func applyAuthoritativeEmptyTranscript(generation: Int?, sessionID: String?) -> Bool {
        guard noteAppliedTranscriptGeneration(generation, for: sessionID) else { return false }
        noteMacPublishedMessageIDs([])
        let pendingPlaceholderIDs = Set(pendingICloudPlaceholders.values)
        let pendingUserIDs = Set(pendingSendArgs.values.compactMap(\.appendedUserId))
        let retainedIDs = retainedSendMessageIDs
        let kept = messages.filter {
            $0.isStreaming || pendingPlaceholderIDs.contains($0.id) || pendingUserIDs.contains($0.id) || retainedIDs.contains($0.id)
        }
        guard kept != messages else {
            // Nothing to remove, but the watermark moved — persist it so the
            // relaunched app still refuses an older empty.
            persistMessages()
            return true
        }
        messages = kept
        persistMessages()
        return true
    }

    /// Record the version of a transcript actually adopted, so a later empty
    /// read built BEFORE it cannot claim to be newer. Persisted with the rows.
    /// Returns whether the watermark actually moved, so a caller that changes
    /// nothing else still knows it owes the cache a write.
    @discardableResult
    func noteAppliedTranscriptGeneration(_ generation: Int?, for sessionID: String?) -> Bool {
        guard let sessionID, let generation else { return false }
        if let applied = appliedTranscriptGenerations[sessionID], generation <= applied { return false }
        appliedTranscriptGenerations[sessionID] = generation
        return true
    }

    /// 2026-09-06: remember exactly which ids the newest Mac snapshot carries.
    /// Replaced, not accumulated: the snapshot is a suffix window and the only
    /// consumer (regenerate) names the transcript tail.
    func noteMacPublishedMessageIDs(_ macMessages: [ChatMessage]) {
        macPublishedMessageIDs = Set(macMessages.map(\.id))
    }

    func persistMessages() {
        guard !suppressMessagePersistence else { return }
        let capped = messages.filter { !$0.isStreaming }.suffix(200).map { msg in
            var copy = msg
            copy.isStreaming = false
            return copy
        }
        let ownerSessionID = Self.cleanSessionID(selectedSessionID ?? mainSessionID)
        let envelope = CachedTranscript(
            schemaVersion: 2,
            sessionID: ownerSessionID,
            messages: Array(capped),
            // 2026-09-06: the watermark is written with the rows it describes,
            // so a relaunch still knows which published transcripts these rows
            // have already answered for.
            appliedTranscriptGeneration: ownerSessionID.flatMap { appliedTranscriptGenerations[$0] }
        )
        if let data = try? JSONEncoder().encode(envelope) {
            defaults.set(data, forKey: transcriptStorageKey(for: ownerSessionID))
        }
    }
}
