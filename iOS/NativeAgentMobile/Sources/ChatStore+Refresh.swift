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
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let macMessages = await client.refreshChatHistory(sessionID: self.selectedSessionID) else {
                if self.messages.isEmpty, let fallbackMessages, !fallbackMessages.isEmpty {
                    self.messages = fallbackMessages
                }
                return
            }
            guard !macMessages.isEmpty else { return }

            // Preserve any in-flight optimistic messages (streaming placeholder + the
            // user message that triggered it) so they aren't lost during the merge.
            let replyArrived = self.macAssistantReplyArrived(macMessages)
            if replyArrived, self.resolvePendingReplyFromMac(macMessages) {
                return
            }

            // Replace transcript with snapshot state, then re-attach pending local sends.
            // Capture the pending placeholder's tool events before the merge
            // swaps it for the Mac-id reply, so the collapsed box survives.
            let carriedEvents: [ToolEvent] = self.pendingICloudPlaceholders.values.first
                .flatMap { id in self.messages.first(where: { $0.id == id })?.toolEvents } ?? []
            // R24 round-3: capture the timed-out sends' LOCAL user bubbles
            // BEFORE the merge — the merge may swap them for Mac-generated
            // snapshot rows with different ids, and the late-reply GC below
            // anchors on the local candidate.
            let timedOutUserCandidates: [String: ChatMessage] = Dictionary(
                uniqueKeysWithValues: self.timedOutPendingIds.keys.compactMap { pendingId -> (String, ChatMessage)? in
                    guard let uid = self.pendingSendArgs[pendingId]?.appendedUserId,
                          let msg = self.messages.first(where: { $0.id == uid }) else { return nil }
                    return (pendingId, msg)
                }
            )
            let merged = self.mergedMacMessagesPreservingPending(macMessages, replyArrived: replyArrived)
            // Only update if there's a meaningful change to avoid spurious re-renders.
            let hasPendingReply = replyArrived && !self.pendingICloudPlaceholders.isEmpty
            guard merged.map(\.id) != self.messages.map(\.id) || hasPendingReply else { return }
            if merged.map(\.id) != self.messages.map(\.id) {
                self.messages = merged
            }
            if replyArrived, let pendingId = self.pendingICloudPlaceholders.keys.first {
                let placeholderId = self.pendingICloudPlaceholders[pendingId]
                self.markICloudReplyResolved(pendingId)
                self.pendingICloudPlaceholders.removeValue(forKey: pendingId)
                self.pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
                self.pendingPolls.removeValue(forKey: pendingId)?.cancel()
                if let placeholderId {
                    self.streamingHintsByMessageId.removeValue(forKey: placeholderId)
                }
                self.isPollingFallback = false
                if self.pendingICloudPlaceholders.isEmpty {
                    self.isLoading = false
                }
                if let lastAssistant = self.newestMacAssistantReply(macMessages) {
                    self.stampToolEvents(carriedEvents, onMessageWithId: lastAssistant.id)
                    self.onReply?(lastAssistant.text)
                }
            }
            // R24 review round-2: a late reply can arrive via the SNAPSHOT
            // merge (not receiveICloudReply) after its bubble timed out.
            // Placeholder DISAPPEARANCE is the wrong signal — the merge
            // preserves recent local bubbles (real reply lands beside the
            // timed-out one with no cleanup) and later ages them out (false
            // "Reply arrived" with no reply). POSITIVE evidence instead: the
            // send's own user message anchors in the snapshot (occurrence-
            // aware) AND a Mac assistant reply follows it.
            var resolvedBySnapshot: [(pendingId: String, placeholderId: UUID)] = []
            var stateOnlyGC: [(pendingId: String, placeholderId: UUID)] = []
            for (pendingId, placeholderId) in self.timedOutPendingIds {
                if let userMsg = timedOutUserCandidates[pendingId],
                   let anchor = self.indexOfUserOccurrence(userMsg, in: macMessages),
                   macMessages[(anchor + 1)...].contains(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                    resolvedBySnapshot.append((pendingId, placeholderId))
                } else if !self.messages.contains(where: { $0.id == placeholderId }) {
                    // Bubble gone without reply evidence — GC the retry state
                    // silently (state-lifecycle), no "Reply arrived" claim.
                    stateOnlyGC.append((pendingId, placeholderId))
                }
            }
            for (pendingId, placeholderId) in resolvedBySnapshot + stateOnlyGC {
                self.timedOutPendingIds.removeValue(forKey: pendingId)
                self.pendingSendArgs.removeValue(forKey: pendingId)
                self.retriedSignatureCorrelations.remove(pendingId)
                self.streamingHintsByMessageId.removeValue(forKey: placeholderId)
                self.markICloudReplyResolved(pendingId)
            }
            if !resolvedBySnapshot.isEmpty {
                // The snapshot carries the REAL reply — the timed-out bubble
                // is a stale duplicate now; drop it explicitly.
                for (_, placeholderId) in resolvedBySnapshot {
                    if let idx = self.messages.firstIndex(where: { $0.id == placeholderId }) {
                        self.messages.remove(at: idx)
                    }
                }
                self.requestScrollToBottom()
                iOSSystemToastCenter.shared.push(info: "Reply arrived")
            }
            if !(resolvedBySnapshot.isEmpty && stateOnlyGC.isEmpty),
               self.pendingICloudPlaceholders.isEmpty, self.timedOutPendingIds.isEmpty {
                self.isLoading = false
            }
            // Also update UserDefaults cache so next cold start is fresh.
            self.persistMessages()
        }
    }

    func persistMessages() {
        guard !suppressMessagePersistence else { return }
        let capped = messages.filter { !$0.isStreaming }.suffix(200).map { msg in
            var copy = msg
            copy.isStreaming = false
            return copy
        }
        if let data = try? JSONEncoder().encode(Array(capped)) {
            let key = transcriptStorageKey(for: selectedSessionID ?? mainSessionID)
            UserDefaults.standard.set(data, forKey: key)
            if key == transcriptKey {
                UserDefaults.standard.set(data, forKey: transcriptKey)
            }
        }
    }
}
