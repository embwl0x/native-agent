import SwiftUI
import UIKit
import NativeAgentShared

/// Capture the rendered queue control so a state change before the tap cannot turn Send into Steer or the reverse.
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
    func enqueueSend(_ queued: QueuedChatSend) -> Bool {
        guard admitChatMutation() else { return false }
        let sessionKey = queueSessionKey(queued.sessionID)
        guard queuedSends.filter({ queueSessionKey($0.sessionID) == sessionKey
            && !inFlightSendIDs.contains($0.id.uuidString) }).count < QueuedChatSend.maxPerSession else {
            errorBanner = "Send-next queue is full (20 messages)"
            return false
        }
        queuedSends.append(queued)
        return true
    }

    @discardableResult
    func send(
        text: String,
        client: MacBridgeClient,
        controls: ChatRuntimeControls = .defaults,
        appendUser: Bool = true,
        attachments: [MultimodalAttachment] = [],
        reusePlaceholderId: UUID? = nil,
        retainedUserMessageID: UUID? = nil,
        suppressRemoteUserAppend: Bool = false,
        replacementAssistantMessageID: UUID? = nil,
        onFailure: (() -> Void)? = nil,
        emitHaptic: Bool = true,
        queuedSendID: UUID? = nil,
        steer: Bool = false
    ) -> Bool {
        guard (!text.isEmpty || !attachments.isEmpty), !isSwitchingSession, admitChatMutation() else { return false }
        guard let pairing = AgentNameCache.fingerprint(client.pairingStore?.iCloudPairingSecret) else {
            errorBanner = "Connect this iPhone to a Mac before submitting."
            return false
        }
        if let queuedSendID,
           queuedSends.first(where: { $0.id == queuedSendID })?.pairingFingerprint != pairing {
            errorBanner = "This saved message belongs to another pairing. Submit it as a new message to send it here."
            return false
        }
        let attachments = ChatAttachmentTypeResolver.submittingSpeech(attachments, text: text)
        if isLoading, !steer {
            guard appendUser else { return false }
            let queued = QueuedChatSend(
                id: UUID(),
                sessionID: selectedSessionID,
                text: text,
                controls: controls,
                attachments: attachments,
                createdAt: Date(), pairingFingerprint: pairing
            )
            guard enqueueSend(queued) else { return false }
            if emitHaptic { Haptics.send() }
            return true
        }
        // Every send, including Regenerate, retains its payload before admission.
        var queuedSendID = queuedSendID
        if queuedSendID == nil {
            let retained = QueuedChatSend(
                id: UUID(), sessionID: selectedSessionID, text: text,
                controls: controls, attachments: attachments, createdAt: Date(), pairingFingerprint: pairing,
                suppressRemoteUserAppend: suppressRemoteUserAppend,
                replacementAssistantMessageID: replacementAssistantMessageID
            )
            guard enqueueSend(retained) else { return false }
            queuedSendID = retained.id
        }
        if appendUser && emitHaptic {
            Haptics.send()
        }
        var appendedUserId = retainedUserMessageID
        if appendUser {
            let summaries = attachments.map {
                ChatAttachmentSummary($0, fallbackName: $0.type == "image" ? "Photo" : "Attachment")
            }
            let userMsg = ChatMessage(
                id: queuedSendID ?? UUID(), role: .user, text: text, attachments: summaries)
            // Animate send appends only; session/transcript replacement must remain instant.
            withAnimation(AppMotion.entranceSystem) {
                if !messages.contains(where: { $0.id == userMsg.id }) {
                    messages.append(userMsg)
                }
            }
            appendedUserId = userMsg.id
        }
        let placeholderId: UUID
        if let reuse = reusePlaceholderId,
           let idx = messages.firstIndex(where: { $0.id == reuse }) {
            var reused = messages[idx]
            reused.text = ""
            reused.isStreaming = true
            reused.completionState = nil
            reused.failureDetail = nil
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
        // A Steer rides beside the working turn; it never takes its place.
        if !steer {
            loadingPlaceholderID = placeholderId
            isLoading = true
        }
        // Waiting status reports only activity evidenced by the Mac.
        streamingHintsByMessageId[placeholderId] = ChatWaitStatusPresentation.unacknowledged
        if let index = queuedSends.firstIndex(where: { $0.id == queuedSendID }) {
            queuedSends[index].placeholderID = placeholderId
        }
        let targetSessionID = selectedSessionID
        // Mint the run identity before transport awaits so Stop can name this send.
        let correlationID = queuedSendID?.uuidString ?? UUID().uuidString
        for index in messages.indices where messages[index].id == appendedUserId || messages[index].id == placeholderId {
            messages[index].runId = correlationID
            messages[index].awaitingMacTranscript = true
        }
        let preparedMessage = queuedSends.first { $0.id == queuedSendID }?.preparedMessage

        if !steer { sendTask?.cancel() }
        inFlightSendIDs.insert(correlationID)
        // Install the correlation's placeholder before transport awaits; the Mac can answer first.
        let pendingArgs = ChatPendingExchange.RetainedRequest(
            text: text,
            controls: controls,
            attachments: attachments,
            appendedUserId: appendedUserId
        )
        pendingICloudPlaceholders[correlationID] = placeholderId
        // Persist when leaving the composer so closing the app restores the same unfinished exchange.
        openPendingExchange(
            correlationID: correlationID,
            sessionID: targetSessionID,
            placeholderID: placeholderId,
            args: pendingArgs
        )
        timedOutPendingIds.removeValue(forKey: correlationID)
        let transport = Task {
            defer {
                inFlightSendIDs.remove(correlationID)
                // Rearm durable confirmation after releasing the in-flight guard so restoration cannot race a cancelled task's exit.
                resumeDeliveryConfirmations()
            }
            do {
                let messageId = try await client.sendMessage(
                    text,
                    sessionID: targetSessionID,
                    controls: controls,
                    attachments: attachments,
                    suppressRemoteUserAppend: suppressRemoteUserAppend,
                    replacementAssistantMessageID: replacementAssistantMessageID,
                    messageID: correlationID,
                    preparedMessage: preparedMessage,
                    expectedPairing: pairing,
                    onPrepared: { [self] message in
                        if iCloudBridge.shared.usesCloudKitDeviceTransport,
                           var record = pendingExchanges[correlationID] {
                            // Budget for upload, the first five-second proof read and the 60-second transport window.
                            record.deliveryConfirmationDeadline = Date().addingTimeInterval(
                                try CloudKitDeviceTransport.sendTimeoutSeconds(for: message) + 65)
                            pendingExchanges[correlationID] = record
                            showWaitStatus(correlationID: correlationID)
                        }
                        try await storage.flush()
                        guard let queuedSendID else { return }
                        guard let index = queuedSends.firstIndex(where: { $0.id == queuedSendID }) else {
                            throw CancellationError()
                        }
                        queuedSends[index].preparedMessage = message
                        queuedSends[index].placeholderID = placeholderId
                        // Flush the exact envelope before the transport may accept it.
                        try await checkpointQueuedSend(queuedSendID)
                    }
                )
                noteDeliveryAccepted(correlationID)
                guard !Task.isCancelled else { return }
                guard sendCompletionOwnsReply(correlationID, placeholderId: placeholderId) else { return }
                // Transport completion rearms only correlations the reply owner still leaves pending.
                guard pendingICloudPlaceholders[correlationID] != nil,
                      !resolvedICloudReplyIds.contains(messageId) else { return }
                if messageId != correlationID {
                    // Move the preinstalled mapping if transport renames the run; never leave two mappings.
                    pendingICloudPlaceholders.removeValue(forKey: correlationID)
                    for index in messages.indices where messages[index].runId == correlationID {
                        messages[index].runId = messageId
                    }
                }
                pendingICloudPlaceholders[messageId] = placeholderId
                renamePendingExchange(from: correlationID, to: messageId)
                if messageId != correlationID { onTalkRunRenamed?(correlationID, messageId) }
                showWaitStatus(correlationID: messageId)
                timedOutPendingIds.removeValue(forKey: messageId)
                armTimeout(for: messageId, placeholderId: placeholderId)
                armReplyStatus()
            } catch {
                guard !Task.isCancelled else { return }
                guard sendCompletionOwnsReply(correlationID, placeholderId: placeholderId) else { return }
                // Mac progress can beat the transport return; late transport errors or silence cannot contradict it.
                if pendingExchanges[correlationID]?.acknowledged == true { return }
                if error is DeviceSyncSendOutcomeUnknown {
                    markDeliveryUnconfirmed(correlationID)
                    armReplyStatus()
                    return
                }
                pendingICloudPlaceholders.removeValue(forKey: correlationID)
                closePendingExchange(correlationID)
                // A cancelled send leaves loading cleanup to its cancellation owner.
                guard !Task.isCancelled else { return }
                if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                    // Failed sends preserve reused bubbles and their retained retry context.
                    if queuedSendID != nil {
                        // Retry retains the transcript, full attachments and exact signed handoff.
                        transportPausedQueueSessionKeys.insert(queueSessionKey(targetSessionID))
                        failPlaceholder(id: placeholderId, text: "Send failed — retry when ready.")
                    } else if reusePlaceholderId == nil {
                        messages.remove(at: idx)
                        if let appendedUserId, let userIdx = messages.firstIndex(where: { $0.id == appendedUserId }) {
                            messages.remove(at: userIdx)
                        }
                    }
                    errorBanner = "Send failed: \(error.localizedDescription)"
                    onFailure?()
                }
                releaseLoading(for: placeholderId)
                onTalkReply?(correlationID, "", true, "Send failed: \(error.localizedDescription). The message remains in Chat for review.")
            }
        }
        if !steer { sendTask = transport }
        return true
    }

    /// Transport completion cannot override a terminal or replacement run; timeout retains original observation arguments.
    func sendCompletionOwnsReply(_ correlationID: String, placeholderId: UUID) -> Bool {
        if resolvedICloudReplyIds.contains(correlationID) {
            return false
        }
        return pendingExchanges[correlationID] != nil
            && (pendingICloudPlaceholders[correlationID] == placeholderId
                || timedOutPendingIds[correlationID] == placeholderId)
    }

    /// Stop names every open run here; release the composer now, but settle only on Mac cancellation or terminal transcript evidence.
    func stop(client: MacBridgeClient) {
        if !queuedSendsForSelectedSession.isEmpty {
            pausedQueueSessionKeys.insert(queueSessionKey(selectedSessionID))
        }
        let stoppedSessionID = selectedSessionID
        let stoppedRunIDs = Array(activeTurnRunIDs)
        guard !stoppedRunIDs.isEmpty else { return }
        pausedQueueSessionKeys.insert(queueSessionKey(stoppedSessionID))
        // Missing Stop acknowledgment proves no nonreceipt; retain evidence until the Mac settles this named request.
        for run in stoppedRunIDs {
            if let placeholder = pendingICloudPlaceholders[run] ?? pendingExchanges[run]?.placeholderID {
                releaseLoading(for: placeholder)
            }
        }
        errorBanner = "Stop requested. Waiting for your Mac to confirm."
        Task {
            do {
                try await client.cancelChat(sessionID: stoppedSessionID, runIDs: stoppedRunIDs)
            } catch {
                // Terminal evidence outranks a late Stop ACK timeout because the terminal can arrive during the action wait.
                guard stoppedRunIDs.contains(where: {
                    (pendingExchanges[$0].map { !$0.isExpired } ?? false) || liveTurnBubbles[$0] != nil
                }) else { return }
                errorBanner = "Stop is unconfirmed: \(error.localizedDescription). Still watching the original request."
            }
        }
    }

    func removeQueuedSend(_ id: UUID) {
        queuedSends.removeAll { $0.id == id }
        let key = queueSessionKey(selectedSessionID)
        if queuedSendsForSelectedSession.isEmpty {
            pausedQueueSessionKeys.remove(key)
            transportPausedQueueSessionKeys.remove(key)
        }
    }

    /// Steer reaches the current Mac turn without cancellation; absent a turn it runs normally, while attachments wait their turn.
    func sendQueuedNow(_ id: UUID, client: MacBridgeClient) {
        guard let queued = queuedSends.first(where: { $0.id == id }), canDeliverQueuedSend(queued) else { return }
        if pendingExchanges[id.uuidString]?.deliveryUnconfirmed == true {
            // Explicit Retry replays this envelope; it must never become Steer.
            sendAsOwnMessage(id, client: client)
            return
        }
        guard promoteQueuedSend(id) else { return }
        let key = queueSessionKey(selectedSessionID)
        pausedQueueSessionKeys.remove(key)
        transportPausedQueueSessionKeys.remove(key)
        guard isLoading, let next = queuedSends.first(where: { $0.id == id }), next.attachments.isEmpty,
              let session = Self.cleanSessionID(selectedSessionID), steeringQueuedIDs.insert(id).inserted else {
            scheduleQueuedSendDrain()
            return
        }
        Task { @MainActor in
            do {
                if try await client.steerChat(sessionID: session, runID: id.uuidString, text: next.text) { return }
            } catch {
                steeringQueuedIDs.remove(id)
                errorBanner = "Steer didn't reach the Mac: \(error.localizedDescription)"
                return
            }
            steeringQueuedIDs.remove(id)
            sendAsOwnMessage(id, client: client)
        }
    }

    /// Queued sends belong only to their own conversation; another conversation's queue waits for its drain.
    func sendAsOwnMessage(_ id: UUID, client: MacBridgeClient) {
        guard let next = queuedSends.first(where: { $0.id == id }),
              queueSessionKey(next.sessionID) == queueSessionKey(selectedSessionID) else { return }
        _ = send(text: next.text, client: client, controls: next.controls,
                 appendUser: next.userMessageID == nil && !next.suppressRemoteUserAppend,
                 attachments: next.attachments, reusePlaceholderId: next.placeholderID,
                 retainedUserMessageID: next.userMessageID,
                 suppressRemoteUserAppend: next.suppressRemoteUserAppend,
                 replacementAssistantMessageID: next.replacementAssistantMessageID,
                 emitHaptic: false, queuedSendID: next.id, steer: true)
    }

    func resumeQueuedSends(startingWith id: UUID? = nil) {
        if let id, pendingExchanges[id.uuidString]?.deliveryUnconfirmed == true {
            if let client = pendingRetryClient { sendQueuedNow(id, client: client) }
            return
        }
        if let id { _ = promoteQueuedSend(id) }
        pausedQueueSessionKeys.remove(queueSessionKey(selectedSessionID))
        transportPausedQueueSessionKeys.remove(queueSessionKey(selectedSessionID))
        scheduleQueuedSendDrain()
    }

    /// Explicitly resubmitted held work gets a fresh identity/session; never reuse the old peer's signed request.
    func submitSavedSendToCurrentPairing(_ id: UUID, client: MacBridgeClient) {
        guard let saved = queuedSends.first(where: { $0.id == id }), !canDeliverQueuedSend(saved) else { return }
        if send(text: saved.text, client: client, controls: saved.controls, attachments: saved.attachments) {
            removeQueuedSend(id)
        }
    }

    func recoverQueuedSendTransport() {
        guard !transportPausedQueueSessionKeys.isEmpty else { return }
        transportPausedQueueSessionKeys.removeAll()
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
        if transportPausedQueueSessionKeys.remove(oldKey) != nil {
            transportPausedQueueSessionKeys.insert(newKey)
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
              let next = queuedSendsForSelectedSession.first(where: {
                  canDeliverQueuedSend($0) && !steeringQueuedIDs.contains($0.id)
                      && pendingExchanges[$0.id.uuidString]?.deliveryUnconfirmed != true
              })
        else { return }
        let accepted = send(
            text: next.text,
            client: client,
            controls: next.controls,
            appendUser: next.userMessageID == nil && !next.suppressRemoteUserAppend,
            attachments: next.attachments,
            reusePlaceholderId: next.placeholderID,
            retainedUserMessageID: next.userMessageID,
            suppressRemoteUserAppend: next.suppressRemoteUserAppend,
            replacementAssistantMessageID: next.replacementAssistantMessageID,
            onFailure: { [weak self] in
                guard let self else { return }
                self.transportPausedQueueSessionKeys.insert(self.queueSessionKey(next.sessionID))
            },
            emitHaptic: false,
            queuedSendID: next.id
        )
        if !accepted {
            pausedQueueSessionKeys.insert(queueSessionKey(next.sessionID))
        }
    }

    /// Regeneration waits for a Mac-published message ID naming exactly one persisted replacement row.
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
        // Keep the saved answer until the Mac publishes the replacement; settle against the new run's identity.
        let replaced = messages[assistantIndex]
        send(
            text: prompt,
            client: client,
            controls: controls,
            appendUser: false,
            suppressRemoteUserAppend: true,
            replacementAssistantMessageID: replaced.id
        )
    }

    /// Only signed unread expiry authorizes fresh user-requested Send now; uncertainty replays the exact Retry event instead.
    func sendNow(messageId placeholderId: UUID, client: MacBridgeClient) {
        guard !isLoading, !isSwitchingSession,
              let record = expiredExchange(for: placeholderId),
              let pairing = AgentNameCache.fingerprint(client.pairingStore?.iCloudPairingSecret)
        else { return }
        let args = record.request
        let pendingId = record.correlationID
        // Reserve durable replacement arguments before consuming expiry so refused admission preserves Send now and transport failure preserves the queue.
        let retained = QueuedChatSend(
            id: UUID(),
            sessionID: selectedSessionID,
            text: args.text,
            controls: args.controls,
            attachments: args.attachments,
            createdAt: Date(),
            placeholderID: placeholderId,
            userMessageID: args.appendedUserId,
            pairingFingerprint: pairing
        )
        guard enqueueSend(retained) else { return }
        let retainedID = retained.id
        timedOutPendingIds.removeValue(forKey: pendingId)
        closePendingExchange(pendingId)
        errorBanner = nil
        send(
            text: args.text,
            client: client,
            controls: args.controls,
            // Reuse the user's existing transcript row because resending does not create a second question.
            appendUser: false,
            attachments: args.attachments,
            reusePlaceholderId: placeholderId,
            retainedUserMessageID: args.appendedUserId,
            queuedSendID: retainedID
        )
    }

}
