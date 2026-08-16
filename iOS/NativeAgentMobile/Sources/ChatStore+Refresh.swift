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
            guard let macMessages = await client.refreshChatHistory(sessionID: requestedSessionID) else {
                guard Self.cleanSessionID(self.selectedSessionID ?? self.mainSessionID) == requestedSessionID else {
                    return
                }
                if self.messages.isEmpty, let fallbackMessages, !fallbackMessages.isEmpty {
                    self.messages = fallbackMessages
                }
                return
            }
            self.applyMacTranscriptSnapshot(macMessages, sessionID: requestedSessionID)
        }
    }

    /// Applies a Mac-owned transcript projection to the currently visible
    /// session. This is also the event-driven iCloud publication consumer, so
    /// it intentionally merges when messages are already visible. The existing
    /// pending machinery remains authoritative for local streams and inputs.
    func applyMacTranscriptSnapshot(_ macMessages: [ChatMessage], sessionID: String?) {
        let requestedSessionID = Self.cleanSessionID(sessionID)
        guard requestedSessionID == Self.cleanSessionID(selectedSessionID ?? mainSessionID),
              !macMessages.isEmpty else { return }

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
        guard merged != messages || hasPendingReply else { return }
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
            messages: Array(capped)
        )
        if let data = try? JSONEncoder().encode(envelope) {
            defaults.set(data, forKey: transcriptStorageKey(for: ownerSessionID))
        }
    }
}
