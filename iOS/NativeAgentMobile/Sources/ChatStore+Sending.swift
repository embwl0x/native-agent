// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

/// Captures the queue control the user saw. The queue strip must not reread
/// `isLoading` when its action fires: a state change between rendering and tap
/// must not turn a visible Send into a cancellation-backed Steer (or reverse).
enum QueuedSendStripAction: Equatable {
    case steer(UUID)
    case send(UUID)

    static func resolve(id: UUID, isLoading: Bool) -> Self {
        isLoading ? .steer(id) : .send(id)
    }

    var primaryTitle: String {
        switch self {
        case .steer: "Steer"
        case .send: "Send"
        }
    }

    func menuTitle(position: Int, preview: String) -> String {
        switch self {
        case .steer: "Steer \(position) now: \(preview)"
        case .send: "Send \(position) now: \(preview)"
        }
    }

    func apply(onSteer: (UUID) -> Void, onSend: (UUID) -> Void) {
        switch self {
        case .steer(let id): onSteer(id)
        case .send(let id): onSend(id)
        }
    }
}

extension ChatStore {
    @discardableResult
    func send(
        text: String,
        client: MacBridgeClient,
        controls: ChatRuntimeControls = .defaults,
        appendUser: Bool = true,
        attachments: [MultimodalAttachment] = [],
        reusePlaceholderId: UUID? = nil,
        suppressRemoteUserAppend: Bool = false,
        replacementAssistantMessageID: UUID? = nil,
        onFailure: (() -> Void)? = nil,
        emitHaptic: Bool = true
    ) -> ChatSendDisposition {
        guard (!text.isEmpty || !attachments.isEmpty), !isSwitchingSession else { return .rejected }
        if isLoading {
            guard appendUser else { return .rejected }
            guard queuedSendsForSelectedSession.count < QueuedChatSend.maxPerSession else {
                errorBanner = "Send-next queue is full (20 messages)"
                return .rejected
            }
            let queued = QueuedChatSend(
                id: UUID(),
                sessionID: selectedSessionID,
                text: text,
                controls: controls,
                attachments: attachments,
                createdAt: Date()
            )
            queuedSends.append(queued)
            if emitHaptic { Haptics.send() }
            return .queued(queued.id)
        }
        // phase 6: haptic fires only on an ACCEPTED, USER-initiated send.
        // gpt-5.5 r1: call-site tap could accompany a no-op send; r2: internal
        // replays (HMAC self-heal/resync) pass appendUser=false and must not
        // tap — the user didn't do anything.
        if appendUser && emitHaptic {
            Haptics.send()
        }
        var appendedUserId: UUID?
        if appendUser {
            let summaries = attachments.map {
                ChatAttachmentSummary(
                    id: $0.id,
                    name: $0.name ?? ($0.type == "image" ? "Photo" : "Attachment"),
                    type: $0.type,
                    mime: $0.mime,
                    base64: $0.base64,
                    byteSize: $0.byteSize
                )
            }
            let userMsg = ChatMessage(role: .user, text: text, attachments: summaries)
            // phase 6: the append seam is the only place entrance animates —
            // wholesale replaces (snapshot merge, session switch) stay instant.
            withAnimation(AppMotion.entranceSystem) {
                messages.append(userMsg)
            }
            appendedUserId = userMsg.id
        }
        isLoading = true
        let placeholderId: UUID
        if let reuse = reusePlaceholderId,
           let idx = messages.firstIndex(where: { $0.id == reuse }) {
            // B1 retry: replay through the SAME placeholder bubble that timed
            // out instead of appending a fresh one. Reset it to a clean
            // streaming state so stale text / tool events don't linger.
            cancelTypewriter(reuse)
            var reused = messages[idx]
            reused.text = ""
            reused.isStreaming = true
            reused.toolEvents = []
            messages[idx] = reused
            placeholderId = reuse
        } else {
            let placeholder = ChatMessage(role: .assistant, text: "", isStreaming: true)
            withAnimation(AppMotion.entranceSystem) {
                messages.append(placeholder)
            }
            placeholderId = placeholder.id
        }
        streamingHintsByMessageId[placeholderId] = reusePlaceholderId == nil ? "Sending" : "Retrying"
        let targetSessionID = selectedSessionID
        // 2026-09-06: mint the correlation id HERE, before the transport await.
        // It used to be learned only from the send's return value, so a Stop
        // pressed while the send was still crossing to the Mac carried no run
        // id at all and the Mac treated it as a legacy unscoped cancel.
        let correlationID = UUID().uuidString

        sendTask?.cancel()
        inFlightSendIDs.insert(correlationID)
        // 2026-09-06: install the correlation → placeholder mapping BEFORE the
        // transport await. The Mac can answer while `sendMessage` is still
        // crossing; a reply that found no mapping was appended as a second
        // bubble and left the placeholder streaming forever.
        let pendingArgs = PendingSendArgs(
            text: text,
            sessionID: targetSessionID,
            controls: controls,
            attachments: attachments,
            appendedUserId: appendedUserId
        )
        pendingICloudPlaceholders[correlationID] = placeholderId
        pendingSendArgs[correlationID] = pendingArgs
        canceledPendingIds.remove(correlationID)
        timedOutPendingIds.removeValue(forKey: correlationID)
        sendTask = Task {
            defer { inFlightSendIDs.remove(correlationID) }
            do {
                let result = try await client.sendMessage(
                    text,
                    sessionID: targetSessionID,
                    controls: controls,
                    attachments: attachments,
                    suppressRemoteUserAppend: suppressRemoteUserAppend,
                    replacementAssistantMessageID: replacementAssistantMessageID,
                    messageID: correlationID
                )
                guard !Task.isCancelled else { return }
                switch result {
                case .queuedMessageId(let messageId):
                    // 2026-09-06: the mapping is installed before the transport
                    // await precisely because the Mac can answer first — and
                    // when it does, the reply path removes it, finishes the
                    // bubble and drops `isLoading`. Reinstalling it here made
                    // that finished turn pending again and armed a timeout that
                    // later failed a reply the user had already read. Only a
                    // correlation still waiting is re-armed.
                    guard pendingICloudPlaceholders[correlationID] != nil,
                          !resolvedICloudReplyIds.contains(messageId) else { return }
                    if messageId != correlationID {
                        // The transport named the run something else: move the
                        // pre-installed mapping rather than leaving two.
                        pendingICloudPlaceholders.removeValue(forKey: correlationID)
                        pendingSendArgs.removeValue(forKey: correlationID)
                    }
                    pendingICloudPlaceholders[messageId] = placeholderId
                    streamingHintsByMessageId[placeholderId] = "Sending"
                    canceledPendingIds.remove(messageId)
                    timedOutPendingIds.removeValue(forKey: messageId)
                    pendingSendArgs[messageId] = pendingArgs
                    armTimeout(for: messageId, placeholderId: placeholderId)
                    armReplyPoll(for: messageId, client: client)
                case .reply(let reply, let responseSessionID):
                    pendingICloudPlaceholders.removeValue(forKey: correlationID)
                    pendingSendArgs.removeValue(forKey: correlationID)
                    if let responseSessionID, !responseSessionID.isEmpty {
                        if targetSessionID == nil {
                            migrateQueuedSends(from: nil, to: responseSessionID)
                        }
                        setSelectedSessionID(responseSessionID)
                        if targetSessionID == nil {
                            rememberMainSessionIDIfNeeded(responseSessionID)
                        }
                    }
                    finishPlaceholder(id: placeholderId, text: reply)
                    isLoading = false
                    onReply?(reply)
                }
            } catch {
                pendingICloudPlaceholders.removeValue(forKey: correlationID)
                pendingSendArgs.removeValue(forKey: correlationID)
                // 2026-09-06: a cancelled send no longer owns `isLoading` —
                // whoever cancelled it (Stop, Steer, a newer send) does. This
                // used to clear the loading state of the turn that replaced it,
                // which also drained the queue on top of a live turn.
                guard !Task.isCancelled else { return }
                if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                    // A reused (retry) bubble is the user's surviving context —
                    // never delete it on a failed replay; retry()'s onFailure
                    // restores its timed-out state + Retry affordance instead
                    // (review finding 2).
                    if reusePlaceholderId == nil {
                        messages.remove(at: idx)
                        if let appendedUserId, let userIdx = messages.firstIndex(where: { $0.id == appendedUserId }) {
                            messages.remove(at: userIdx)
                        }
                    }
                    errorBanner = "Send failed: \(error.localizedDescription)"
                    onFailure?()
                }
                isLoading = false
            }
        }
        return .started
    }

    func stop(client: MacBridgeClient) {
        if !queuedSendsForSelectedSession.isEmpty {
            pausedQueueSessionKeys.insert(queueSessionKey(selectedSessionID))
        }
        // 2026-09-06: name the runs being stopped and freeze the session id
        // BEFORE the local state is cleared. The cancel is asynchronous and a
        // fresh send is admissible the moment isLoading drops; without both,
        // that new turn could be the one the Mac cancels.
        let stoppedSessionID = selectedSessionID
        // 2026-09-06: a send whose transport call has not returned yet is a run
        // the Mac may already be executing. Name it too, or this Stop goes out
        // unscoped and cancels whatever holds the session.
        let stoppedRunIDs = Array(Set(pendingICloudPlaceholders.keys).union(inFlightSendIDs))
        cancelActiveSendLocally()
        isLoading = false
        Task {
            do {
                try await client.cancelChat(sessionID: stoppedSessionID, runIDs: stoppedRunIDs)
            } catch {
                await MainActor.run {
                    errorBanner = "Stop requested, but the Mac did not confirm cancellation: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelActiveSendLocally() {
        sendTask?.cancel()
        sendTask = nil
        inFlightSendIDs.removeAll()
        for pendingId in pendingICloudPlaceholders.keys {
            canceledPendingIds.insert(pendingId)
            // Retire the old correlation immediately. A late cancel/error/final
            // must not flip isLoading or overwrite the new turn after Steer.
            markICloudReplyResolved(pendingId)
        }
        pendingICloudPlaceholders.removeAll()
        pendingSendArgs.removeAll()
        retriedSignatureCorrelations.removeAll()
        timedOutPendingIds.removeAll()
        pendingTimeouts.values.forEach { $0.cancel() }
        pendingTimeouts.removeAll()
        pendingPolls.values.forEach { $0.cancel() }
        pendingPolls.removeAll()
        streamingHintsByMessageId.removeAll()
        // PATCH-2026-05-30: stop() cancels in-flight turns; clear the text_delta
        // seq map alongside the other in-flight state.
        maxDeltaSeqByCorrelation.removeAll()
        cancelAllTypewriters()
        isPollingFallback = false
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            finishPlaceholder(id: messages[idx].id, text: "(stopped)")
        }
    }

    func removeQueuedSend(_ id: UUID) {
        queuedSends.removeAll { $0.id == id }
        let key = queueSessionKey(selectedSessionID)
        if queuedSendsForSelectedSession.isEmpty { pausedQueueSessionKeys.remove(key) }
    }

    func sendQueuedNow(_ id: UUID, client: MacBridgeClient) {
        guard promoteQueuedSend(id) else { return }
        let key = queueSessionKey(selectedSessionID)
        if !isLoading {
            pausedQueueSessionKeys.remove(key)
            scheduleQueuedSendDrain()
            return
        }

        // Hold the queue paused until the signed Mac cancellation action is
        // confirmed. This prevents the steered message from racing the old
        // provider turn through the independent iCloud chat data plane.
        pausedQueueSessionKeys.insert(key)
        let steeredSessionID = selectedSessionID
        // Same window as Stop: a send still crossing to the Mac is a run this
        // steer is replacing, so it belongs in the scope.
        let steeredRunIDs = Array(Set(pendingICloudPlaceholders.keys).union(inFlightSendIDs))
        cancelActiveSendLocally()
        Task { @MainActor [weak self, weak client] in
            guard let self, let client else { return }
            do {
                try await client.cancelChat(sessionID: steeredSessionID, runIDs: steeredRunIDs)
                pausedQueueSessionKeys.remove(key)
                isLoading = false
                scheduleQueuedSendDrain()
            } catch {
                isLoading = false
                errorBanner = "Could not steer because the Mac did not confirm cancellation: \(error.localizedDescription)"
            }
        }
    }

    func resumeQueuedSends(startingWith id: UUID? = nil) {
        if let id { _ = promoteQueuedSend(id) }
        pausedQueueSessionKeys.remove(queueSessionKey(selectedSessionID))
        scheduleQueuedSendDrain()
    }

    @discardableResult
    func promoteQueuedSend(_ id: UUID) -> Bool {
        guard let index = queuedSends.firstIndex(where: { $0.id == id }) else { return false }
        let selected = queuedSends.remove(at: index)
        let key = queueSessionKey(selected.sessionID)
        let insertion = queuedSends.firstIndex { queueSessionKey($0.sessionID) == key } ?? queuedSends.endIndex
        queuedSends.insert(selected, at: insertion)
        return true
    }

    func migrateQueuedSends(from oldSessionID: String?, to newSessionID: String) {
        let oldKey = queueSessionKey(oldSessionID)
        let newKey = queueSessionKey(newSessionID)
        guard oldKey != newKey else { return }
        for index in queuedSends.indices where queueSessionKey(queuedSends[index].sessionID) == oldKey {
            queuedSends[index].sessionID = newSessionID
        }
        if pausedQueueSessionKeys.remove(oldKey) != nil {
            pausedQueueSessionKeys.insert(newKey)
        }
    }

    func scheduleQueuedSendDrain() {
        guard !isLoading, !isSwitchingSession, !isSelectedQueuePaused,
              !queuedSendsForSelectedSession.isEmpty,
              pendingRetryClient != nil
        else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.drainNextQueuedSendIfPossible()
        }
    }

    private func drainNextQueuedSendIfPossible() {
        guard !isLoading, !isSwitchingSession, !isSelectedQueuePaused,
              let client = pendingRetryClient,
              let next = queuedSendsForSelectedSession.first,
              let index = queuedSends.firstIndex(where: { $0.id == next.id })
        else { return }
        queuedSends.remove(at: index)
        let disposition = send(
            text: next.text,
            client: client,
            controls: next.controls,
            appendUser: true,
            attachments: next.attachments,
            onFailure: { [weak self] in
                guard let self else { return }
                self.queuedSends.insert(next, at: min(index, self.queuedSends.count))
                self.pausedQueueSessionKeys.insert(self.queueSessionKey(next.sessionID))
            },
            emitHaptic: false
        )
        if disposition == .rejected {
            queuedSends.insert(next, at: min(index, queuedSends.count))
            pausedQueueSessionKeys.insert(queueSessionKey(next.sessionID))
        }
    }

    /// 2026-09-06: regenerate names the row the Mac must replace, and the Mac
    /// requires that id to match exactly one persisted message. A reply
    /// resolved over the bridge keeps the phone's placeholder UUID
    /// (finishPlaceholder), which the Mac has never seen — regenerating on one
    /// deleted the answer here and failed there. Only an id carried by a Mac
    /// transcript snapshot can name the row, so the control waits for it.
    var canRegenerateLast: Bool {
        guard !isLoading, !isSwitchingSession,
              let assistantIndex = messages.lastIndex(where: { $0.role == .assistant }),
              let user = messages[..<assistantIndex].last(where: { $0.role == .user }),
              !user.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return macPublishedMessageIDs.contains(messages[assistantIndex].id)
    }

    func regenerateLast(client: MacBridgeClient, controls: ChatRuntimeControls = .defaults) {
        guard canRegenerateLast,
              let assistantIndex = messages.lastIndex(where: { $0.role == .assistant }),
              let user = messages[..<assistantIndex].last(where: { $0.role == .user })
        else { return }
        let prompt = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let replaced = messages.remove(at: assistantIndex)
        // 2026-09-06: this answer is deliberately absent locally until the
        // Mac's replacement lands, which is exactly what
        // newestMacAssistantReply's fallback reads as "the reply we are
        // waiting for". Without naming it, a snapshot built before the
        // regeneration completed the turn with the answer being replaced and
        // the real one was dropped as a straggler. One regenerate can be in
        // flight at a time, so the set holds at most this id.
        regeneratedAwayAssistantIDs = [replaced.id]
        let disposition = send(
            text: prompt,
            client: client,
            controls: controls,
            appendUser: false,
            suppressRemoteUserAppend: true,
            replacementAssistantMessageID: replaced.id,
            onFailure: { [weak self] in
                guard let self else { return }
                self.regeneratedAwayAssistantIDs.remove(replaced.id)
                guard self.messages.contains(where: { $0.id == replaced.id }) == false else { return }
                self.messages.insert(replaced, at: min(assistantIndex, self.messages.count))
            }
        )
        if disposition == .rejected {
            regeneratedAwayAssistantIDs.remove(replaced.id)
            if messages.contains(where: { $0.id == replaced.id }) == false {
                messages.insert(replaced, at: min(assistantIndex, messages.count))
            }
        }
    }

    /// Resume observing a timed-out signed device event.
    ///
    /// A successful `sendMessage` already committed one signed `BridgeMessage`
    /// to iCloud. The local reply timeout proves only that this phone stopped
    /// waiting; it does not prove the Mac failed to receive or execute the turn.
    /// Re-sending the prompt under a new message id can therefore run Agent
    /// twice. Keep the original message id as both event identity and reply
    /// correlation, and merely re-arm observation of that same event.
    func retry(messageId placeholderId: UUID, client: MacBridgeClient) {
        guard let pendingId = resumeTimedOutReply(messageId: placeholderId) else { return }
        armTimeout(for: pendingId, placeholderId: placeholderId)
        armReplyPoll(for: pendingId, client: client)
    }

    /// State-only half of `retry`, split out so the one-event invariant can be
    /// regression-tested without starting iCloud polling.
    @discardableResult
    func resumeTimedOutReply(messageId placeholderId: UUID) -> String? {
        guard !isLoading, !isSwitchingSession,
              let pendingId = timedOutPendingIds.first(where: { $0.value == placeholderId })?.key,
              pendingSendArgs[pendingId] != nil,
              let index = messages.firstIndex(where: { $0.id == placeholderId })
        else { return nil }

        timedOutPendingIds.removeValue(forKey: pendingId)
        pendingICloudPlaceholders[pendingId] = placeholderId

        cancelTypewriter(placeholderId)
        var bubble = messages[index]
        bubble.text = ""
        bubble.isStreaming = true
        messages[index] = bubble
        streamingHintsByMessageId[placeholderId] = "Still working on the Mac"

        errorBanner = nil
        isLoading = true
        return pendingId
    }
}
