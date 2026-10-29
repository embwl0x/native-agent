import Foundation
import NativeAgentShared

/// Waiting repeats only evidenced Mac activity and its age; silence is not failure.
enum ChatWaitStatusPresentation {
    static let unacknowledged = "Waiting for your Mac to receive this"
    static let silent = "No update yet"

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
    /// Retained request arguments; nil only for records written before this
    /// field existed.
    var request: RetainedRequest? = nil
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

    var isExpired: Bool { expiredRequest != nil }

    private enum CodingKeys: String, CodingKey {
        case correlationID, sessionID, placeholderID, request, partialText, activity
        case updatedAt, acknowledged, isSilent, expiredRequest
    }

    func statusLine(now: Date = Date()) -> String {
        ChatWaitStatusPresentation.line(
            activity: acknowledged ? (activity ?? "Mac received it") : nil,
            age: now.timeIntervalSince(updatedAt),
            isSilent: isSilent
        )
    }
}

extension ChatPendingExchange {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        correlationID = try values.decode(String.self, forKey: .correlationID)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        placeholderID = try values.decode(UUID.self, forKey: .placeholderID)
        request = try values.decodeIfPresent(RetainedRequest.self, forKey: .request)
        expiredRequest = try values.decodeIfPresent(ExpiredRequest.self, forKey: .expiredRequest)
        // Older expired records kept the only request inside the refusal.
        if request == nil, expiredRequest != nil {
            request = try values.decode(RetainedRequest.self, forKey: .expiredRequest)
        }
        partialText = try values.decode(String.self, forKey: .partialText)
        activity = try values.decodeIfPresent(String.self, forKey: .activity)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        acknowledged = try values.decode(Bool.self, forKey: .acknowledged)
        isSilent = try values.decode(Bool.self, forKey: .isSilent)
    }
}

@MainActor
extension ChatStore {
    // MARK: - Durability

    func persistPendingExchanges() {
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
        return Set(handedOver).union(pendingICloudPlaceholders.keys).union(inFlightSendIDs).union(live)
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
            guard let userID = record.request?.appendedUserId else { return transcript.endIndex }
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
        armReplyPoll(client: client)
    }
}
