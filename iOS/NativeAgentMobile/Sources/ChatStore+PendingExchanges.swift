import Foundation
import NativeAgentShared
// Blueprint: | `ChatStore+PendingExchanges.swift` | Durable reply observation and bounded send confirmation across session cancellation/relaunch; unknown delivery retains explicit Retry and late Chat/Talk replies, server/Mac evidence retires queued envelopes |

/// Waiting repeats only evidenced Mac activity and its age; silence is not failure.
enum ChatWaitStatusPresentation {
    static let unacknowledged = "Waiting for your Mac to receive this"
    static let silent = "No update yet"
    static let stillSending = "Still sending…"
    static let deliveryUnconfirmed = "Couldn't confirm it arrived — Retry"
    static let deliveryUnconfirmedWithoutRetry = "Couldn't confirm it arrived. Still watching for a reply."

    static func ageText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, let minutes = Int(exactly: (max(0, seconds) / 60).rounded(.towardZero)) else { return "age unavailable" }
        let clamped = max(0, seconds)
        if clamped < 60 { return "just now" }
        if minutes < 60 { return minutes == 1 ? "1 min ago" : "\(minutes) min ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hr ago" : "\(hours) hr ago"
    }

    static func line(activity: String?, age: TimeInterval, isSilent: Bool) -> String {
        let clean = (activity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return isSilent ? silent : unacknowledged
        }
        if isSilent { return "\(silent) · \(clean) \(ageText(age))" }
        return "\(clean) · \(ageText(age))"
    }
}

/// Durable observation and request arguments; only a signed expiry permits "Send now".
struct ChatPendingExchange: Codable, Equatable, Sendable {
    struct ExpiredRequest: Codable, Equatable, Sendable {
        /// The sentence the Mac's signed refusal put in the bubble.
        let message: String
    }

    struct RetainedRequest: Codable, Equatable, Sendable {
        let text: String
        let controls: ChatRuntimeControls
        let attachments: [MultimodalAttachment]
        let appendedUserId: UUID?
    }

    var correlationID: String
    let sessionID: String?
    let placeholderID: UUID
    /// Every admitted exchange retains its original request arguments.
    var request: RetainedRequest
    var partialText: String
    /// The last activity the Mac evidenced ("Mac received it", "…is thinking").
    var activity: String?
    var updatedAt: Date
    /// True once any signed event for this correlation has crossed the bridge.
    var acknowledged: Bool
    /// True when this phone stopped hearing anything for longer than the wait
    /// window. A status word — not a verdict about the Mac.
    var isSilent: Bool
    /// Non-nil once the Mac signed an expiry refusal for this request: the
    /// exchange is no longer observable, and this is everything "Send now"
    /// needs. Nothing here is ever sent without the person asking.
    var expiredRequest: ExpiredRequest? = nil
    /// Persist the observation limit before dispatch. Relaunch observes the
    /// retained envelope within this limit; it never starts a fresh upload.
    var deliveryConfirmationDeadline: Date? = nil
    var deliveryUnconfirmed: Bool = false
    /// Positive transport evidence; independent of Mac execution/reply.
    var deliveryAccepted: Bool = false

    var isExpired: Bool { expiredRequest != nil }

    func statusLine(now: Date = Date()) -> String {
        if deliveryUnconfirmed { return ChatWaitStatusPresentation.deliveryUnconfirmed }
        if deliveryConfirmationDeadline != nil, !acknowledged { return ChatWaitStatusPresentation.stillSending }
        return ChatWaitStatusPresentation.line(
            activity: acknowledged ? (activity ?? "Mac received it") : nil,
            age: now.timeIntervalSince(updatedAt),
            isSilent: isSilent
        )
    }
}

@MainActor
extension ChatStore {
    // MARK: - Durability

    func persistPendingExchanges() {
        guard storageErrors[Self.pendingExchangesKey] == nil else { return }
        if pendingExchanges.isEmpty {
            storage.remove(key: Self.pendingExchangesKey)
            return
        }
        let rows = pendingExchanges
        storage.save(key: Self.pendingExchangesKey, value: { Array(rows.values) }) { [weak self] error in
            Task { @MainActor in self?.errorBanner = "Pending chat could not be saved: \(error.localizedDescription)" }
        }
    }

    // MARK: - The Mac's turn here

    /// Unfinished runs in this conversation, across doors, drive Stop and the header.
    var activeTurnRunIDs: Set<String> {
        let session = Self.cleanSessionID(selectedSessionID)
        let handedOver = pendingExchanges.values.filter { $0.sessionID == session && !$0.isExpired }.map(\.correlationID)
        let messageIDs = Set(messages.map(\.id))
        let live = liveTurnBubbles.filter { messageIDs.contains($0.value) }.keys
        let queued = queuedSends.filter { Self.cleanSessionID($0.sessionID) == session && inFlightSendIDs.contains($0.id.uuidString) }.map { $0.id.uuidString }
        let visible = pendingICloudPlaceholders.filter { messageIDs.contains($0.value) }.keys
        return Set(handedOver).union(visible).union(queued).union(live)
    }

    /// Nil when no turn is open; false while the Mac has not yet signed any
    /// event for the phone's request.
    var activeTurnHeardByMac: Bool? {
        let runs = activeTurnRunIDs
        guard !runs.isEmpty else { return nil }
        return runs.contains { liveTurnBubbles[$0] != nil || pendingExchanges[$0]?.acknowledged == true }
    }

    // MARK: - Lifecycle

    /// Opens the durable record the moment a request leaves the composer.
    func openPendingExchange(
        correlationID: String,
        sessionID: String?,
        placeholderID: UUID,
        args: ChatPendingExchange.RetainedRequest
    ) {
        if pendingExchanges[correlationID]?.deliveryUnconfirmed == true,
           errorBanner == ChatWaitStatusPresentation.deliveryUnconfirmed
            || errorBanner == ChatWaitStatusPresentation.deliveryUnconfirmedWithoutRetry {
            errorBanner = nil
        }
        pendingExchanges[correlationID] = ChatPendingExchange(
            correlationID: correlationID,
            sessionID: Self.cleanSessionID(sessionID),
            placeholderID: placeholderID,
            request: args,
            partialText: "",
            activity: nil,
            updatedAt: Date(),
            acknowledged: false,
            isSilent: false
        )
        showWaitStatus(correlationID: correlationID)
    }

    /// The transport may name the run something other than the id this phone
    /// minted. Move the record rather than leaving two.
    func renamePendingExchange(from oldID: String, to newID: String) {
        guard oldID != newID, var record = pendingExchanges.removeValue(forKey: oldID) else { return }
        record.correlationID = newID
        pendingExchanges[newID] = record
    }

    /// The Mac signed a refusal because the request aged out unread. Record
    /// that durably, with the retained request, so a session switch or a cold
    /// launch still restores the "wasn't started · Send now" bubble instead of
    /// resurrecting a streaming placeholder for a dead correlation.
    func markPendingExchangeExpired(
        correlationID: String,
        message: String
    ) {
        iCloudBridge.shared.stopDeliveryNudges(for: correlationID)
        guard var record = pendingExchanges[correlationID] else { return }
        record.expiredRequest = ChatPendingExchange.ExpiredRequest(message: message)
        record.isSilent = false
        record.updatedAt = Date()
        pendingExchanges[correlationID] = record
    }

    /// Only a signed expiry for a bubble in this transcript authorizes "Send now".
    func expiredExchange(for placeholderID: UUID) -> ChatPendingExchange? {
        pendingExchanges.values.first { $0.isExpired && $0.placeholderID == placeholderID && messages.contains(where: { $0.id == placeholderID }) }
    }

    /// Any signed event for this correlation is evidence the Mac has it.
    func noteEvidencedActivity(correlationID: String, activity: String?, partialText: String? = nil) {
        noteDeliveryAccepted(correlationID)
        guard var record = pendingExchanges[correlationID] else { return }
        record.acknowledged = true
        record.isSilent = false
        record.updatedAt = Date()
        if let activity = activity?.trimmingCharacters(in: .whitespacesAndNewlines), !activity.isEmpty {
            record.activity = activity
        }
        if let partialText { record.partialText = partialText }
        pendingExchanges[correlationID] = record
    }

    /// Server acceptance and Mac receipt both retire the unsent queue copy;
    /// the reply owner remains open until a terminal reply actually arrives.
    func noteDeliveryAccepted(_ correlationID: String) {
        queuedSends.removeAll { $0.id.uuidString == correlationID }
        guard var record = pendingExchanges[correlationID] else { return }
        let wasUnconfirmed = record.deliveryUnconfirmed
        record.deliveryConfirmationDeadline = nil
        record.deliveryUnconfirmed = false
        record.deliveryAccepted = true
        pendingExchanges[correlationID] = record
        if wasUnconfirmed {
            if errorBanner == ChatWaitStatusPresentation.deliveryUnconfirmed
                || errorBanner == ChatWaitStatusPresentation.deliveryUnconfirmedWithoutRetry { errorBanner = nil }
            if let index = messages.firstIndex(where: { $0.id == record.placeholderID }) {
                messages[index].text = record.partialText
                messages[index].isStreaming = true
                messages[index].completionState = nil
            }
        }
    }

    /// Exhausting the observation window is uncertainty, never a failed send.
    /// Retain both the exact retry envelope and the late-reply observation.
    func markDeliveryUnconfirmed(_ correlationID: String) {
        guard var record = pendingExchanges[correlationID], !record.acknowledged, !record.deliveryAccepted, !record.isExpired else { return }
        record.deliveryUnconfirmed = true
        pendingExchanges[correlationID] = record
        let canRetry = queuedSends.contains { $0.id.uuidString == correlationID && $0.preparedMessage != nil }
        let status = canRetry ? ChatWaitStatusPresentation.deliveryUnconfirmed
            : ChatWaitStatusPresentation.deliveryUnconfirmedWithoutRetry
        // Automatic drains consult this exchange's durable uncertainty, not
        // the transport-recovery pause that a successful inbox read clears.
        iCloudBridge.shared.stopDeliveryNudges(for: correlationID)
        if let index = messages.firstIndex(where: { $0.id == record.placeholderID }) {
            messages[index].text = status
            messages[index].isStreaming = false
            messages[index].completionState = "delivery_unconfirmed"
        }
        streamingHintsByMessageId.removeValue(forKey: record.placeholderID)
        if record.sessionID == Self.cleanSessionID(selectedSessionID) {
            errorBanner = status
        }
        releaseLoading(for: record.placeholderID)
        // No terminal Talk callback: uncertainty leaves this run open to its
        // eventual delta/reply, just as it leaves Chat's observation open.
    }

    /// Silence changes the status word. The partial answer, the bubble and the
    /// observation all stay exactly where they are.
    func notePendingExchangeSilent(correlationID: String) {
        guard var record = pendingExchanges[correlationID] else { return }
        record.isSilent = true
        pendingExchanges[correlationID] = record
        showWaitStatus(correlationID: correlationID)
    }

    /// A terminal result — reply, error, cancel or session retirement — closes
    /// the record. Nothing else does.
    func closePendingExchange(_ correlationID: String) {
        iCloudBridge.shared.stopDeliveryNudges(for: correlationID)
        pendingExchanges.removeValue(forKey: correlationID)
    }

    /// Writes the current waiting sentence into the live hint line. Called on
    /// each observation tick so the age in it stays honest.
    func showWaitStatus(correlationID: String) {
        guard let record = pendingExchanges[correlationID],
              let placeholderId = pendingICloudPlaceholders[correlationID]
        else { return }
        streamingHintsByMessageId[placeholderId] = record.statusLine()
    }

    // MARK: - Restore

    /// Reattach unfinished exchanges with their partial answers and resume observation.
    @discardableResult
    func restorePendingExchanges(for sessionID: String?) -> [String] {
        let session = Self.cleanSessionID(sessionID)
        var restored: [String] = []
        let transcript = messages
        let firstPositions = Dictionary(transcript.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        let firstUserPositions: [String: Int] = Dictionary(transcript.enumerated().compactMap { index, message in
            message.role == .user ? message.runId.map { ($0, index) } : nil
        }, uniquingKeysWith: min)
        func position(_ record: ChatPendingExchange) -> Int {
            guard let userID = record.request.appendedUserId else { return transcript.endIndex }
            return min(firstPositions[userID] ?? transcript.endIndex, firstUserPositions[record.correlationID] ?? transcript.endIndex)
        }
        let ordered = pendingExchanges.values.filter { $0.sessionID == session }.sorted {
            let left = position($0), right = position($1)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.correlationID < $1.correlationID
        }
        for record in ordered {
            if let retained = record.expiredRequest {
                restoreExpiredExchange(record, retained: retained)
                continue
            }
            if record.deliveryUnconfirmed {
                insertPendingUserIfNeeded(pendingId: record.correlationID, before: record.placeholderID)
                if !messages.contains(where: { $0.id == record.placeholderID }) {
                    insertRestoredPlaceholder(ChatMessage(id: record.placeholderID, role: .assistant, text: "", runId: record.correlationID), for: record)
                }
                pendingICloudPlaceholders[record.correlationID] = record.placeholderID
                resolvedICloudReplyIds.remove(record.correlationID)
                timedOutPendingIds.removeValue(forKey: record.correlationID)
                markDeliveryUnconfirmed(record.correlationID)
                restored.append(record.correlationID)
                continue
            }
            if let index = messages.firstIndex(where: { $0.id == record.placeholderID }) {
                var bubble = messages[index]
                if !record.partialText.isEmpty, bubble.text.isEmpty {
                    bubble.text = record.partialText
                }
                bubble.isStreaming = true
                messages[index] = bubble
            } else {
                // An unfinished exchange owns its partial reply until settlement.
                insertRestoredPlaceholder(
                    ChatMessage(
                        id: record.placeholderID,
                        role: .assistant,
                        text: record.partialText,
                        isStreaming: true,
                        runId: record.correlationID
                    ), for: record
                )
            }
            pendingICloudPlaceholders[record.correlationID] = record.placeholderID
            // The record's own existence is the proof this turn never reached a
            // terminal state, so a live reply for it is welcome again.
            resolvedICloudReplyIds.remove(record.correlationID)
            timedOutPendingIds.removeValue(forKey: record.correlationID)
            showWaitStatus(correlationID: record.correlationID)
            restored.append(record.correlationID)
        }
        return restored
    }

    private func insertRestoredPlaceholder(_ bubble: ChatMessage, for record: ChatPendingExchange) {
        insertPendingUserIfNeeded(pendingId: record.correlationID, before: nil)
        if let user = pendingUserMessage(for: record.correlationID),
           let index = messages.firstIndex(where: { $0.id == user.id || ($0.role == .user && $0.runId == record.correlationID) }) {
            messages.insert(bubble, at: messages.index(after: index))
        } else {
            messages.append(bubble)
        }
    }

    /// An expired exchange is restored as what it actually is: a finished
    /// bubble saying the request wasn't started, with the retained request put
    /// back where "Send now" looks for it. Never streaming, never polled —
    /// the correlation it names was refused and can never complete.
    private func restoreExpiredExchange(
        _ record: ChatPendingExchange,
        retained: ChatPendingExchange.ExpiredRequest
    ) {
        if let index = messages.firstIndex(where: { $0.id == record.placeholderID }) {
            var bubble = messages[index]
            bubble.isStreaming = false
            if bubble.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bubble.text = retained.message
            }
            messages[index] = bubble
        } else {
            insertRestoredPlaceholder(
                ChatMessage(
                    id: record.placeholderID,
                    role: .assistant,
                    text: retained.message,
                    isStreaming: false
                ), for: record
            )
        }
        pendingICloudPlaceholders.removeValue(forKey: record.correlationID)
        streamingHintsByMessageId.removeValue(forKey: record.placeholderID)
        timedOutPendingIds.removeValue(forKey: record.correlationID)
    }

    /// Resumes observation of restored exchanges. Observation only: the signed
    /// request already crossed the bridge and is never sent a second time.
    func resumeObservingPendingExchanges(using client: MacBridgeClient) {
        restorePendingExchanges(for: selectedSessionID)
        armReplyStatus()
        resumeDeliveryConfirmations()
    }

    func resumeDeliveryConfirmations() {
        for record in pendingExchanges.values where record.deliveryConfirmationDeadline != nil && !record.deliveryUnconfirmed && !record.isExpired {
            guard !inFlightSendIDs.contains(record.correlationID),
                  let deadline = record.deliveryConfirmationDeadline else { continue }
            let queued = queuedSends.first(where: { $0.id.uuidString == record.correlationID })
            // A different pairing cannot inspect the original peer's record,
            // but its absence must not suspend the saved deadline forever.
            let message = queued.flatMap { canDeliverQueuedSend($0) ? $0.preparedMessage : nil }
            let correlation = record.correlationID
            inFlightSendIDs.insert(correlation)
            Task { [self] in
                defer { inFlightSendIDs.remove(correlation) }
                let confirmed: Bool
                if let message {
                    confirmed = await iCloudBridge.shared.confirmMessageDelivery(message, until: deadline) {
                        self.pendingExchanges[correlation]?.acknowledged == true
                    }
                } else {
                    // Missing local bytes cannot prove rejection or authorize
                    // another write. Keep the original bounded observation.
                    do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                    catch { return }
                    confirmed = pendingExchanges[correlation]?.acknowledged == true
                }
                guard !Task.isCancelled, pendingExchanges[correlation] != nil else { return }
                if confirmed { noteDeliveryAccepted(correlation); showWaitStatus(correlationID: correlation) }
                else { markDeliveryUnconfirmed(correlation) }
            }
        }
    }
}
