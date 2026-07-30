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
    private func pendingUserMessage(for pendingId: String) -> ChatMessage? {
        guard let args = pendingSendArgs[pendingId],
              let appendedUserId = args.appendedUserId else {
            return nil
        }
        let summaries = args.attachments.map {
            ChatAttachmentSummary(
                id: $0.id,
                name: $0.name ?? ($0.type == "image" ? "Photo" : "Attachment"),
                type: $0.type,
                mime: $0.mime,
                base64: $0.base64,
                byteSize: $0.byteSize
            )
        }
        return ChatMessage(
            id: appendedUserId,
            role: .user,
            text: args.text,
            attachments: summaries
        )
    }

    func insertPendingUserIfNeeded(pendingId: String, before placeholderId: UUID?) {
        guard let user = pendingUserMessage(for: pendingId) else { return }
        guard !messages.contains(where: { $0.id == user.id }) else { return }
        guard !macContainsEquivalentUser(user, in: messages) else { return }
        if let placeholderId,
           let placeholderIndex = messages.firstIndex(where: { $0.id == placeholderId }) {
            messages.insert(user, at: placeholderIndex)
        } else {
            messages.append(user)
        }
    }

    private func optimisticMessagesToPreserve(
        macMessages: [ChatMessage],
        replyArrived: Bool
    ) -> [ChatMessage] {
        var preserved: [ChatMessage] = []
        for pendingId in pendingSendArgs.keys.sorted() {
            // Occurrence-aware containment: with repeated identical user texts,
            // a stale snapshot holding only an EARLIER occurrence must not
            // suppress the pending one (it would vanish while in flight).
            if let user = pendingUserMessage(for: pendingId),
               !macMessages.contains(where: { $0.id == user.id }),
               indexOfUserOccurrence(user, in: macMessages) == nil {
                preserved.append(user)
            }
            if !replyArrived,
               let placeholderId = pendingICloudPlaceholders[pendingId],
               let placeholder = messages.first(where: { $0.id == placeholderId }),
               !macMessages.contains(where: { $0.id == placeholder.id }) {
                preserved.append(placeholder)
            }
        }

        if preserved.isEmpty, isLoading {
            let tail = messages.suffix(2)
            preserved = tail.filter { candidate in
                if candidate.isStreaming { return !replyArrived }
                if candidate.role == .user {
                    return self.indexOfUserOccurrence(candidate, in: macMessages) == nil
                }
                return false
            }
        }
        return preserved
    }

    // Stale-snapshot guard (2026-06-11, ledger ff7b6657): an iCloud snapshot can be
    // built BEFORE recently-resolved turns sync back from the Mac. Replacing the
    // list with such a snapshot makes live messages vanish until the next snapshot
    // catches up. Three realities shape the merge:
    //   1. Bridge-resolved replies keep their LOCAL placeholder UUID forever
    //      (finishPlaceholder), so snapshot ids never match them — equivalence
    //      falls back to content.
    //   2. Mac snapshots are a suffix(80) window with content truncated at 6,000
    //      chars + a marker (MacSyncEngine.compactTranscriptMessages), so local
    //      history can legitimately be longer than the snapshot, and long
    //      messages only prefix-match.
    //   3. There are no tombstones, so "missing from snapshot" is ambiguous
    //      between "not synced yet" and "aged out / cleared on the Mac" — only
    //      RECENTLY arrived local messages are preserved (the stale window is
    //      seconds to minutes); older ones defer to the snapshot, which matches
    //      the pre-fix replace semantics.

    /// When each message id first appeared locally. Maintained from the messages
    /// didSet so every append path (send, bridge resolve, snapshot apply, cache
    /// load) is covered without instrumenting each call site. Internal for tests.

    func noteMessageArrivals(previous: [ChatMessage], current: [ChatMessage]) {
        let previousIds = Set(previous.map(\.id))
        let currentIds = Set(current.map(\.id))
        let now = Date()
        for id in currentIds.subtracting(previousIds) {
            localArrivalDates[id] = now
        }
        for id in previousIds.subtracting(currentIds) {
            localArrivalDates.removeValue(forKey: id)
        }
    }

    /// Content equivalence between a snapshot row and a local message of the same
    /// role. Exact trimmed match, or — when the Mac truncated the snapshot copy —
    /// the snapshot text (sans marker) as a prefix of the fuller local text.
    private func snapshotTextMatches(_ snapshot: ChatMessage, local: ChatMessage) -> Bool {
        let localText = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localText.isEmpty else { return false }
        var snapText = snapshot.text
        if snapText.hasSuffix(Self.snapshotTruncationMarker) {
            snapText = String(snapText.dropLast(Self.snapshotTruncationMarker.count))
            let snapTrimmed = snapText.trimmingCharacters(in: .whitespacesAndNewlines)
            return !snapTrimmed.isEmpty && localText.hasPrefix(snapTrimmed)
        }
        return snapText.trimmingCharacters(in: .whitespacesAndNewlines) == localText
    }

    private func snapshotMessageMatches(_ snapshot: ChatMessage, local: ChatMessage) -> Bool {
        if snapshot.id == local.id { return true }
        guard snapshot.role == local.role else { return false }
        if local.role == .user, !local.attachments.isEmpty {
            guard snapshot.attachments == local.attachments else { return false }
            // Attachment-only sends may carry empty text — attachments equality
            // IS the match then (snapshotTextMatches rejects empty text).
            if local.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return snapshotTextMatches(snapshot, local: local)
    }

    // Internal (not private) so ChatStoreMergeTests can pin the stale-snapshot
    // guard semantics directly.
    func mergedMacMessagesPreservingPending(
        _ macMessages: [ChatMessage],
        replyArrived: Bool
    ) -> [ChatMessage] {
        let pendingPlaceholderIds = Set(pendingICloudPlaceholders.values)
        let pendingUserIds = Set(pendingSendArgs.keys.compactMap { pendingUserMessage(for: $0)?.id })
        let preserveFloor = Date().addingTimeInterval(-Self.resolvedPreserveWindowSeconds)

        // Ordered anchor walk: advance through the snapshot as local messages
        // match (snapshot row authoritative, but a truncated snapshot copy never
        // overwrites the fuller local text); keep RECENT unmatched resolved local
        // turns at their local position; older unmatched locals defer to the
        // snapshot. Positional matching also stops a repeated short reply ("ok")
        // from binding to the wrong snapshot row.
        var merged: [ChatMessage] = []
        var cursor = macMessages.startIndex
        // Snapshot rows flushed past without matching a local message. A later
        // local twin of one of these (order inversion) must CONSUME it rather
        // than duplicate — but consumption-tracking means a SECOND identical
        // recent local ("ok" twice) is still preserved, because the first
        // occurrence already consumed the only snapshot twin.
        var unconsumedFlushedIds = Set<UUID>()
        for local in messages {
            if local.isStreaming { continue }                  // pending machinery owns these
            if pendingPlaceholderIds.contains(local.id) { continue }
            if pendingUserIds.contains(local.id) { continue }
            if let j = macMessages[cursor...].firstIndex(where: { snapshotMessageMatches($0, local: local) }) {
                for flushed in macMessages[cursor..<j] {
                    merged.append(flushed)
                    unconsumedFlushedIds.insert(flushed.id)
                }
                var matched = macMessages[j]
                if matched.text.hasSuffix(Self.snapshotTruncationMarker) {
                    matched.text = local.text
                }
                merged.append(matched)
                cursor = macMessages.index(after: j)
            } else if (localArrivalDates[local.id] ?? .distantPast) >= preserveFloor {
                if let twinId = merged.first(where: {
                    unconsumedFlushedIds.contains($0.id) && snapshotMessageMatches($0, local: local)
                })?.id {
                    unconsumedFlushedIds.remove(twinId)        // local is that row's twin
                } else if !merged.contains(where: { $0.id == local.id }) {
                    merged.append(local)
                }
            }
            // else: not in the snapshot and not recent — the snapshot is
            // authoritative (aged out of its window, or removed on the Mac).
        }
        merged.append(contentsOf: macMessages[cursor...])

        for candidate in optimisticMessagesToPreserve(macMessages: macMessages, replyArrived: replyArrived) {
            if merged.contains(where: { $0.id == candidate.id }) { continue }
            if candidate.role == .user,
               indexOfUserOccurrence(candidate, in: merged) != nil {
                continue
            }
            if candidate.role == .user,
               replyArrived,
               let reply = newestMacAssistantReply(merged),
               let replyIndex = merged.firstIndex(where: { $0.id == reply.id }) {
                merged.insert(candidate, at: replyIndex)
            } else {
                merged.append(candidate)
            }
        }
        return carryForwardToolEvents(into: merged)
    }

    /// The Mac transcript carries no per-tool events (tools aren't modeled as
    /// iOS messages), so a snapshot refresh would wipe the locally-tracked
    /// toolEvents. Re-attach them by id ONLY — a deterministic match that can
    /// never lend a turn's events to the wrong message. The placeholder→Mac
    /// reply handoff (where the ids differ) is done at the finalize points that
    /// actually know that mapping (resolvePendingReplyFromMac / refresh),
    /// not guessed by text here.
    private func carryForwardToolEvents(into merged: [ChatMessage]) -> [ChatMessage] {
        let byId = Dictionary(
            messages.filter { !$0.toolEvents.isEmpty }.map { ($0.id, $0.toolEvents) },
            uniquingKeysWith: { first, _ in first })
        guard !byId.isEmpty else { return merged }
        var result = merged
        for i in result.indices where result[i].toolEvents.isEmpty {
            if let ev = byId[result[i].id] { result[i].toolEvents = ev }
        }
        return result
    }

    /// Move the events that accumulated on a streaming placeholder onto whatever
    /// message becomes the durable reply for that turn. Called at the snapshot
    /// finalize points, where the placeholder→reply pairing is known exactly, so
    /// the collapsed "N tools used" box survives the Mac-id swap without any
    /// text guessing. No-op if there were no events or the target already has them.
    func stampToolEvents(_ events: [ToolEvent], onMessageWithId id: UUID) {
        guard !events.isEmpty,
              let i = messages.firstIndex(where: { $0.id == id }),
              messages[i].toolEvents.isEmpty
        else { return }
        messages[i].toolEvents = events
    }


    private func macContainsEquivalentUser(_ candidate: ChatMessage, in macMessages: [ChatMessage]) -> Bool {
        let candidateText = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return macMessages.contains { macMessage in
            if macMessage.id == candidate.id { return true }
            guard macMessage.role == .user else { return false }
            guard macMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == candidateText else {
                return false
            }
            if !candidate.attachments.isEmpty {
                return macMessage.attachments == candidate.attachments
            }
            return true
        }
    }

    func macAssistantReplyArrived(_ macMessages: [ChatMessage]) -> Bool {
        guard isLoading, !pendingICloudPlaceholders.isEmpty else { return false }
        return newestMacAssistantReply(macMessages) != nil
    }

    /// Occurrence-aware anchor for a locally-appended user message inside a
    /// snapshot. With repeated identical user texts ("ping" twice), a plain
    /// last-equivalent match lets a stale snapshot containing only the FIRST
    /// occurrence anchor the SECOND pending send (and the old reply after it
    /// mis-resolves the new turn). Instead: the candidate is the Nth equivalent
    /// user occurrence locally → it can only be the Nth equivalent occurrence
    /// in the snapshot; fewer than N occurrences means the snapshot predates
    /// the send. Internal for tests.
    func indexOfUserOccurrence(_ candidate: ChatMessage, in macMessages: [ChatMessage]) -> Int? {
        if let idIdx = macMessages.lastIndex(where: { $0.id == candidate.id }) { return idIdx }
        // SYMMETRIC truncation-aware equivalence class: both the local ranking
        // and the snapshot scan compare on the trimmed 6,000-char prefix (the
        // Mac truncates snapshot rows there). An asymmetric matcher (exact
        // locally, prefix against the snapshot) mis-anchored two long sends
        // sharing the same prefix but differing past the truncation point —
        // collapsing them into one class on both sides keeps ranks consistent;
        // over-merging distinct-after-6,000 sends is the benign direction.
        func occurrenceClassText(_ m: ChatMessage) -> String {
            var t = m.text
            if t.hasSuffix(Self.snapshotTruncationMarker) {
                t = String(t.dropLast(Self.snapshotTruncationMarker.count))
            }
            return String(t.prefix(6_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let candidateClass = occurrenceClassText(candidate)
        func isEquivalent(_ m: ChatMessage) -> Bool {
            guard m.role == .user else { return false }
            if m.id == candidate.id { return true }
            guard occurrenceClassText(m) == candidateClass else { return false }
            if candidateClass.isEmpty || !candidate.attachments.isEmpty {
                return m.attachments == candidate.attachments
            }
            return true
        }
        // Head-anchored occurrence rank. Known tradeoff: an aged identical local
        // row outside the snapshot's suffix(80) window inflates N, so a fresh
        // snapshot can look stale — worst case a transient duplicate pending row
        // that self-heals at resolution (the positional walk dedups it once the
        // pending machinery clears). Tail-anchored ranking would instead re-open
        // the previous-reply misresolve (permanent reply drop). Benign beats
        // catastrophic.
        var n = 0
        for local in messages where local.role == .user {
            if isEquivalent(local) { n += 1 }
            if local.id == candidate.id { break }
        }
        if n == 0 { n = 1 }   // candidate not (yet) in messages — first occurrence
        var seen = 0
        for (i, m) in macMessages.enumerated() where isEquivalent(m) {
            seen += 1
            if seen == n { return i }
        }
        return nil
    }

    func newestMacAssistantReply(_ macMessages: [ChatMessage]) -> ChatMessage? {
        // Positional containment gate: a reply to the pending send can only sit
        // AFTER the pending user message in the snapshot (the Mac transcript is
        // append-ordered). A stale snapshot either lacks the pending user
        // message entirely (→ nil) or contains it with no assistant after it
        // yet (→ nil). Without this, the snapshot's copy of the PREVIOUS reply
        // (under its Mac id, unknown locally because bridge-resolved replies
        // keep their placeholder UUID) mis-resolved the CURRENT pending send —
        // and the real reply was then dropped by the resolvedICloudReplyIds
        // guard. Anchoring on position (not content-suppression of known reply
        // texts) keeps legitimately repeated replies ("ok") resolvable.
        let localAssistantIDs = Set(messages.filter { $0.role == .assistant && !$0.isStreaming }.map(\.id))
        if let pendingId = pendingICloudPlaceholders.keys.first,
           let pendingUser = pendingUserMessage(for: pendingId) {
            guard let userIndex = indexOfUserOccurrence(pendingUser, in: macMessages) else {
                return nil
            }
            let tail = macMessages[macMessages.index(after: userIndex)...]
            return tail.last(where: { $0.role == .assistant && !localAssistantIDs.contains($0.id) })
        }
        // No pending-user info (e.g. appendUser:false regenerate/retry sends):
        // pre-existing last-assistant heuristic, unchanged scope.
        if let lastUserIndex = macMessages.lastIndex(where: { $0.role == .user }) {
            let tail = macMessages[macMessages.index(after: lastUserIndex)...]
            if let reply = tail.last(where: { $0.role == .assistant && !localAssistantIDs.contains($0.id) }) {
                return reply
            }
        }
        return macMessages.last(where: { $0.role == .assistant && !localAssistantIDs.contains($0.id) })
    }

    func resolvePendingReplyFromMac(_ macMessages: [ChatMessage]) -> Bool {
        guard let pendingId = pendingICloudPlaceholders.keys.first,
              let reply = newestMacAssistantReply(macMessages) else {
            return false
        }
        let placeholderId = pendingICloudPlaceholders[pendingId]
        // Capture the placeholder's tool events BEFORE the merge replaces it with
        // the Mac-id reply, so the collapsed box carries over to the new id.
        let carriedEvents = placeholderId
            .flatMap { id in messages.first(where: { $0.id == id })?.toolEvents } ?? []
        let merged = mergedMacMessagesPreservingPending(macMessages, replyArrived: true)
        if merged.map(\.id) != messages.map(\.id) {
            messages = merged
        }
        markICloudReplyResolved(pendingId)
        pendingICloudPlaceholders.removeValue(forKey: pendingId)
        pendingTimeouts.removeValue(forKey: pendingId)?.cancel()
        pendingPolls.removeValue(forKey: pendingId)?.cancel()
        if let placeholderId {
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
        }
        isPollingFallback = false
        if let placeholderId, messages.contains(where: { $0.id == placeholderId }) {
            finishPlaceholder(id: placeholderId, text: reply.text)
            stampToolEvents(carriedEvents, onMessageWithId: placeholderId)
        } else if !messages.contains(where: { $0.id == reply.id }) {
            var finalReply = reply
            if finalReply.toolEvents.isEmpty { finalReply.toolEvents = carriedEvents }
            messages.append(finalReply)
        } else {
            stampToolEvents(carriedEvents, onMessageWithId: reply.id)
        }
        if pendingICloudPlaceholders.isEmpty {
            isLoading = false
        }
        onReply?(reply.text)
        persistMessages()
        return true
    }
}
