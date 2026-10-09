import SwiftUI
import UIKit
import NativeAgentShared

extension ChatStore {
    private func publishedAttachmentsMatch(_ left: [ChatAttachmentSummary], _ right: [ChatAttachmentSummary]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy {
            $0.id == $1.id && $0.name == $1.name && $0.type == $1.type
                && $0.mime == $1.mime && $0.byteSize == $1.byteSize
        }
    }

    func pendingUserMessage(for pendingId: String) -> ChatMessage? {
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
        macMessages: [ChatMessage]
    ) -> [ChatMessage] {
        var preserved: [ChatMessage] = []
        func position(_ pendingId: String) -> Int {
            let messageId = pendingSendArgs[pendingId]?.appendedUserId ?? pendingICloudPlaceholders[pendingId]
            return messages.firstIndex(where: { $0.id == messageId }) ?? messages.endIndex
        }
        let pendingIds = Set(pendingSendArgs.keys).union(pendingICloudPlaceholders.keys).sorted {
            let left = position($0), right = position($1)
            return left == right ? $0 < $1 : left < right
        }
        for pendingId in pendingIds {
            // Occurrence-aware containment: with repeated identical user texts,
            // a stale snapshot holding only an EARLIER occurrence must not
            // suppress the pending one (it would vanish while in flight).
            if let user = pendingUserMessage(for: pendingId),
               !macMessages.contains(where: { $0.id == user.id }),
               indexOfUserOccurrence(user, in: macMessages) == nil {
                preserved.append(user)
            }
            if let placeholderId = pendingICloudPlaceholders[pendingId],
               let placeholder = messages.first(where: { $0.id == placeholderId }),
               !macMessages.contains(where: { $0.id == placeholder.id }) {
                preserved.append(placeholder)
            }
        }

        if preserved.isEmpty, isLoading {
            let tail = messages.suffix(2)
            preserved = tail.filter { candidate in
                if candidate.isStreaming { return true }
                if candidate.role == .user {
                    return self.indexOfUserOccurrence(candidate, in: macMessages) == nil
                }
                return false
            }
        }
        return preserved
    }

    // Receipts keep their placeholder UUID until the snapshot publishes the
    // same terminal run. Preserve them across older snapshots and truncated
    // windows; equal answer text is not turn identity.

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
        if local.role == .assistant {
            return local.interaction == nil && local.interactionDescriptor == nil
                && snapshot.interaction == nil && snapshot.interactionDescriptor == nil
                && ((snapshot.isTerminalReply && local.isTerminalReply)
                    || (snapshot.completionState == "failed" && local.completionState == "failed"))
                && local.runId != nil && snapshot.runId == local.runId
        }
        if local.role == .user {
            guard publishedAttachmentsMatch(snapshot.attachments, local.attachments) else { return false }
            // Attachment-only sends may carry empty text — attachments equality
            // IS the match then (snapshotTextMatches rejects empty text).
            if local.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return snapshotTextMatches(snapshot, local: local)
    }

    /// Keep local detail when the ordered merge replaces a matched message's id.
    /// Snapshot attachments retain authority; only bytes for the same id carry over.
    private func preservingLocalDetails(_ local: ChatMessage, in snapshot: ChatMessage) -> ChatMessage {
        var matched = snapshot
        if snapshot.id == local.id || (local.runId != nil && local.runId == snapshot.runId) {
            matched.toolEvents = local.toolEvents
        }
        // A matching Mac row completes the receipt's publication handoff.
        matched.awaitingMacTranscript = false
        // A live turn still streaming keeps streaming into the row that
        // replaced its bubble (a long reply matches its truncated snapshot copy).
        if snapshot.id != local.id, let run = liveTurnBubbles.first(where: { $0.value == local.id })?.key {
            liveTurnBubbles[run] = snapshot.id
        }
        if matched.text.hasSuffix(Self.snapshotTruncationMarker) {
            let prefix = String(matched.text.dropLast(Self.snapshotTruncationMarker.count))
            if local.text.count > prefix.count, local.text.hasPrefix(prefix) {
                matched.text = local.text
            }
        }
        matched.failureDetail = snapshot.failureDetail ?? local.failureDetail
        for index in matched.attachments.indices where matched.attachments[index].base64 == nil {
            let id = matched.attachments[index].id
            matched.attachments[index].base64 = local.attachments.first(where: { $0.id == id })?.base64
        }
        return matched
    }

    // Internal (not private) so ChatStoreMergeTests can pin the stale-snapshot
    // guard semantics directly.
    func mergedMacMessagesPreservingPending(
        _ macMessages: [ChatMessage]
    ) -> [ChatMessage] {
        // 2026-09-06: reply SELECTION already refuses a regenerated-away row,
        // but the merge did not: the anchor walk appends every unmatched
        // snapshot row verbatim, so a snapshot taken before the regeneration
        // landed put the answer being replaced straight back into the
        // transcript. The Mac deletes that row and appends the replacement
        // under a new id, so the id can never legitimately come back.
        let macMessages = regeneratedAwayAssistantIDs.isEmpty
            ? macMessages
            : macMessages.filter { !regeneratedAwayAssistantIDs.contains($0.id) }
        let pendingPlaceholderIds = Set(pendingICloudPlaceholders.values)
        let pendingUserIds = Set(pendingSendArgs.keys.compactMap { pendingUserMessage(for: $0)?.id })
        let preserveFloor = Date().addingTimeInterval(-Self.resolvedPreserveWindowSeconds)
        let retainedIDs = retainedSendMessageIDs

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
            // A paged row is the Mac's own row: it matches by id, never by
            // text, so an old "OK" cannot bind to a newer one.
            let paged = pagedHistoryIDs.contains(local.id)
            func matches(_ row: ChatMessage) -> Bool {
                paged ? row.id == local.id : snapshotMessageMatches(row, local: local)
            }
            if let j = macMessages[cursor...].firstIndex(where: matches) {
                for flushed in macMessages[cursor..<j] {
                    merged.append(flushed)
                    unconsumedFlushedIds.insert(flushed.id)
                }
                merged.append(preservingLocalDetails(local, in: macMessages[j]))
                cursor = macMessages.index(after: j)
            } else if local.awaitingMacTranscript || retainedIDs.contains(local.id) || paged
                        || (localArrivalDates[local.id] ?? .distantPast) >= preserveFloor {
                if let twinIndex = merged.firstIndex(where: {
                    unconsumedFlushedIds.contains($0.id) && matches($0)
                }) {
                    unconsumedFlushedIds.remove(merged[twinIndex].id) // local is that row's twin
                    merged[twinIndex] = preservingLocalDetails(local, in: merged[twinIndex])
                } else if !merged.contains(where: { $0.id == local.id }) {
                    merged.append(local)
                }
            }
            // else: not in the snapshot and not recent — the snapshot is
            // authoritative (aged out of its window, or removed on the Mac).
        }
        merged.append(contentsOf: macMessages[cursor...])

        for candidate in optimisticMessagesToPreserve(macMessages: macMessages) {
            if merged.contains(where: { $0.id == candidate.id }) { continue }
            if candidate.role == .user,
               indexOfUserOccurrence(candidate, in: merged) != nil {
                continue
            }
            merged.append(candidate)
        }
        return merged
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
            return publishedAttachmentsMatch(macMessage.attachments, candidate.attachments)
        }
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
            return publishedAttachmentsMatch(m.attachments, candidate.attachments)
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

    private func macAssistantReply(for pendingId: String, in macMessages: [ChatMessage]) -> ChatMessage? {
        macMessages.last {
            $0.runId == pendingId && $0.isTerminalReply && !regeneratedAwayAssistantIDs.contains($0.id)
        }
    }

    func resolvePendingReplyFromMac(_ macMessages: [ChatMessage]) -> Bool {
        let matches = Set(pendingICloudPlaceholders.keys).union(timedOutPendingIds.keys).sorted().compactMap { pendingId -> (String, UUID, ChatMessage, [ToolEvent])? in
            guard let placeholderId = pendingICloudPlaceholders[pendingId] ?? timedOutPendingIds[pendingId],
                  let reply = macAssistantReply(for: pendingId, in: macMessages) else { return nil }
            let events = messages.first(where: { $0.id == placeholderId })?.toolEvents ?? []
            return (pendingId, placeholderId, reply, events)
        }
        guard !matches.isEmpty else { return false }
        // Retire only matched exchanges before merging. Every other bubble
        // remains owned by its pending record, even if this snapshot has replies.
        for (pendingId, placeholderId, _, _) in matches {
            markICloudReplyResolved(pendingId)
            pendingICloudPlaceholders.removeValue(forKey: pendingId)
            timedOutPendingIds.removeValue(forKey: pendingId)
            cancelReplyWaits(for: pendingId)
            streamingHintsByMessageId.removeValue(forKey: placeholderId)
            messages.removeAll { $0.id == placeholderId }
        }
        messages = mergedMacMessagesPreservingPending(macMessages)
        for (_, placeholderId, reply, events) in matches {
            stampToolEvents(events, onMessageWithId: reply.id)
            releaseLoading(for: placeholderId)
            onReply?(reply.text)
        }
        isPollingFallback = false
        persistMessages()
        return true
    }
}
