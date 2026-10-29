import SwiftUI
import UIKit
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
    func enqueueSend(_ queued: QueuedChatSend) -> Bool {
        let sessionKey = queueSessionKey(queued.sessionID)
        guard queuedSends.filter({ queueSessionKey($0.sessionID) == sessionKey && !inFlightSendIDs.contains($0.id.uuidString) }).count < QueuedChatSend.maxPerSession else {
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
        guard (!text.isEmpty || !attachments.isEmpty), !isSwitchingSession else { return false }
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
        // Accepted composer sends retain their payload in the durable queue before transport admission.
        var queuedSendID = queuedSendID
        if appendUser && queuedSendID == nil {
            let retained = QueuedChatSend(
                id: UUID(), sessionID: selectedSessionID, text: text,
                controls: controls, attachments: attachments, createdAt: Date(), pairingFingerprint: pairing
            )
            guard enqueueSend(retained) else { return false }
            queuedSendID = retained.id
        }
        // Accepted user sends alone tap here; internal sends set appendUser=false.
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
            // Only send's append transactions animate; transcript and session replacements stay instant.
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
            // Reuse the same placeholder with cleared text and tool events for the new send.
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
        // Durable from the moment it leaves the composer: an app closed here
        // must come back to the same unfinished exchange, not a blank chat.
        openPendingExchange(
            correlationID: correlationID,
            sessionID: targetSessionID,
            placeholderID: placeholderId,
            args: pendingArgs
        )
        timedOutPendingIds.removeValue(forKey: correlationID)
        let transport = Task {
            defer { inFlightSendIDs.remove(correlationID) }
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
                if let queuedSendID { queuedSends.removeAll { $0.id == queuedSendID } }
                guard !Task.isCancelled else { return }
                guard sendCompletionOwnsReply(correlationID, placeholderId: placeholderId) else { return }
                // Transport completion rearms only correlations the reply owner still leaves pending.
                guard pendingICloudPlaceholders[correlationID] != nil,
                      !resolvedICloudReplyIds.contains(messageId) else { return }
                if messageId != correlationID {
                    // The transport named the run something else: move the
                    // pre-installed mapping rather than leaving two.
                    pendingICloudPlaceholders.removeValue(forKey: correlationID)
                    for index in messages.indices where messages[index].runId == correlationID {
                        messages[index].runId = messageId
                    }
                }
                pendingICloudPlaceholders[messageId] = placeholderId
                renamePendingExchange(from: correlationID, to: messageId)
                showWaitStatus(correlationID: messageId)
                timedOutPendingIds.removeValue(forKey: messageId)
                armTimeout(for: messageId, placeholderId: placeholderId)
                armReplyPoll(client: client)
            } catch {
                guard !Task.isCancelled else { return }
                guard sendCompletionOwnsReply(correlationID, placeholderId: placeholderId) else { return }
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
            }
        }
        if !steer { sendTask = transport }
        return true
    }

    /// A transport completion cannot contradict a terminal reply or take over
    /// a replacement run. Timeout keeps the original arguments for observation.
    func sendCompletionOwnsReply(_ correlationID: String, placeholderId: UUID) -> Bool {
        if resolvedICloudReplyIds.contains(correlationID) {
            return false
        }
        return pendingExchanges[correlationID]?.request != nil
            && (pendingICloudPlaceholders[correlationID] == placeholderId
                || timedOutPendingIds[correlationID] == placeholderId)
    }

    /// The Mac's own Stop, scoped to every open run here: a send still
    /// crossing, a request gone silent, and a live turn another door started.
    /// Nothing changes on the phone until the Mac says how each run ended
    /// (its cancelled event or its transcript); a Stop it could not make says
    /// why.
    func stop(client: MacBridgeClient) {
        if !queuedSendsForSelectedSession.isEmpty {
            pausedQueueSessionKeys.insert(queueSessionKey(selectedSessionID))
        }
        let stoppedSessionID = selectedSessionID
        let stoppedRunIDs = Array(activeTurnRunIDs)
        Task {
            do {
                try await client.cancelChat(sessionID: stoppedSessionID, runIDs: stoppedRunIDs)
            } catch {
                errorBanner = "The Mac did not stop it: \(error.localizedDescription)"
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

    /// Steer, as on the Mac: the queued message goes, on the Mac's control
    /// lane, to the turn already working there, which reads it at its next
    /// step. Nothing is cancelled. With no turn working there it is sent as
    /// its own message at once; one with files waits for its turn.
    func sendQueuedNow(_ id: UUID, client: MacBridgeClient) {
        guard let queued = queuedSends.first(where: { $0.id == id }), canDeliverQueuedSend(queued) else { return }
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

    /// A queued message sent beside whatever the phone shows as working, only
    /// into its own conversation; another one's waits in that queue for its drain.
    func sendAsOwnMessage(_ id: UUID, client: MacBridgeClient, rowWritten: Bool = false) {
        guard let next = queuedSends.first(where: { $0.id == id }),
              queueSessionKey(next.sessionID) == queueSessionKey(selectedSessionID) else { return }
        _ = send(text: next.text, client: client, controls: next.controls, appendUser: next.userMessageID == nil,
                 attachments: next.attachments, reusePlaceholderId: next.placeholderID,
                 retainedUserMessageID: next.userMessageID, suppressRemoteUserAppend: rowWritten,
                 emitHaptic: false, queuedSendID: next.id, steer: true)
    }

    func resumeQueuedSends(startingWith id: UUID? = nil) {
        if let id { _ = promoteQueuedSend(id) }
        pausedQueueSessionKeys.remove(queueSessionKey(selectedSessionID))
        transportPausedQueueSessionKeys.remove(queueSessionKey(selectedSessionID))
        scheduleQueuedSendDrain()
    }

    /// A person explicitly submits a held copy to this peer as new work.
    /// It receives a new identity/session; the old signed request is never reused.
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
              let next = queuedSendsForSelectedSession.first(where: { canDeliverQueuedSend($0) && !steeringQueuedIDs.contains($0.id) })
        else { return }
        let accepted = send(
            text: next.text,
            client: client,
            controls: next.controls,
            appendUser: next.userMessageID == nil,
            attachments: next.attachments,
            reusePlaceholderId: next.placeholderID,
            retainedUserMessageID: next.userMessageID,
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
        // Keep the saved answer until the Mac publishes its replacement.
        // Snapshot settlement matches the new run, never this answer's run.
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

    /// "Send now": the person's explicit resend of a request the Mac signed a
    /// refusal for because it aged out unread.
    ///
    /// This is the ONE place a phone-side resend is safe, and only because the
    /// signed rejection proves the turn never started — elapsed waiting alone
    /// never earns it. It
    /// mints a fresh event through the ordinary send path, reusing the same
    /// bubble, and never runs by itself.
    func sendNow(messageId placeholderId: UUID, client: MacBridgeClient) {
        guard !isLoading, !isSwitchingSession,
              let record = expiredExchange(for: placeholderId),
              let args = record.request
        else { return }
        let pendingId = record.correlationID
        // Reserve durable replacement arguments before consuming expiry; refused admission preserves Send now.
        // send retains this queue entry and its exact envelope on transport failure.
        let retained = QueuedChatSend(
            id: UUID(),
            sessionID: selectedSessionID,
            text: args.text,
            controls: args.controls,
            attachments: args.attachments,
            createdAt: Date(),
            placeholderID: placeholderId,
            userMessageID: args.appendedUserId,
            pairingFingerprint: AgentNameCache.fingerprint(client.pairingStore?.iCloudPairingSecret)
        )
        guard enqueueSend(retained) else { return }
        let retainedID = retained.id
        timedOutPendingIds.removeValue(forKey: pendingId)
        // The expired record has done its job: the person chose to send, and
        // the ordinary send path below opens a fresh exchange of its own.
        closePendingExchange(pendingId)
        errorBanner = nil
        send(
            text: args.text,
            client: client,
            controls: args.controls,
            // The person's own row is already in this transcript; this is the
            // same question going out again, not a second question.
            appendUser: false,
            attachments: args.attachments,
            reusePlaceholderId: placeholderId,
            retainedUserMessageID: args.appendedUserId,
            queuedSendID: retainedID
        )
    }

}
