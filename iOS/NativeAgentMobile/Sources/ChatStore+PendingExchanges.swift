import Foundation
import NativeAgentShared

/// The sentence shown under a bubble that is still waiting for the Mac.
///
/// 2026-09-13: the old line was elapsed-time theater — ten seconds of local
/// clock produced "Still working on the Mac", which the phone had no evidence
/// for, and a local timeout then replaced the bubble with failure text. Silence
/// is allowed to change the STATUS word; it is never allowed to impersonate
/// progress, and it is never allowed to read as abandonment. So:
///
/// - before the Mac has acknowledged anything, say only what is true: this
///   phone is waiting for the Mac to receive the request;
/// - after acknowledgement, repeat the last activity the Mac actually
///   evidenced, with its age, so the age is the claim and not the activity;
/// - when nothing has arrived for a long while, say there is no update — and
///   keep the last evidenced activity beside it, because "no update" about a
///   running turn is not the same thing as a failed one.
enum ChatWaitStatusPresentation {
    static let unacknowledged = "Waiting for your Mac to receive this"
    static let silent = "No update yet"

    static func ageText(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 { return "just now" }
        let minutes = Int(clamped / 60)
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

/// One unfinished exchange: a request this phone handed to the Mac and has not
/// yet seen a terminal result for. It is durable, so closing the app — or
/// opening another conversation — does not erase the fact that something is
/// still outstanding. It carries only what is needed to keep OBSERVING that
/// same signed request: its correlation, where its bubble is, the partial
/// answer already received and the last stage the Mac acknowledged. It is never
/// a resend queue; nothing in here is ever sent again.
struct ChatPendingExchange: Codable, Equatable, Sendable {
    /// 2026-09-13: what an exchange becomes when the Mac signs a refusal
    /// because the request aged out unread. The turn provably never started,
    /// so this record stops being an observation and becomes the retained
    /// request behind "Send now" — durable, because the in-memory maps that
    /// used to hold it are wiped by a session switch and by relaunch, and a
    /// record left in the observing state came back as a streaming
    /// placeholder polling a correlation that can never finish.
    struct ExpiredRequest: Codable, Equatable, Sendable {
        let text: String
        let controls: ChatRuntimeControls
        let attachments: [MultimodalAttachment]
        let appendedUserId: UUID?
        /// The sentence the Mac's signed refusal put in the bubble.
        let message: String
    }

    /// What a resend would need, kept FROM THE MOMENT THE EXCHANGE OPENED.
    /// 2026-09-13: this used to be written only when an expiry arrived, out of
    /// `pendingSendArgs` — an in-memory map a session switch and a relaunch
    /// both wipe. A restored ordinary exchange therefore had no args, so a late
    /// expiry fell through to the generic rejection path, which closes the
    /// record: the request was proven never started and "Send now" was gone
    /// anyway. Durable from the start, it survives both.
    struct RetainedRequest: Codable, Equatable, Sendable {
        let text: String
        let controls: ChatRuntimeControls
        let attachments: [MultimodalAttachment]
        let appendedUserId: UUID?
    }

    let correlationID: String
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

    func statusLine(now: Date = Date()) -> String {
        ChatWaitStatusPresentation.line(
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
        if pendingExchanges.isEmpty {
            defaults.removeObject(forKey: Self.pendingExchangesKey)
            return
        }
        if let data = try? JSONEncoder().encode(Array(pendingExchanges.values)) {
            defaults.set(data, forKey: Self.pendingExchangesKey)
        }
    }

    static func restoredPendingExchanges(from defaults: UserDefaults) -> [String: ChatPendingExchange] {
        guard let data = defaults.data(forKey: Self.pendingExchangesKey),
              let rows = try? JSONDecoder().decode([ChatPendingExchange].self, from: data)
        else { return [:] }
        return Dictionary(rows.map { ($0.correlationID, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    // MARK: - Lifecycle

    /// Opens the durable record the moment a request leaves the composer.
    func openPendingExchange(
        correlationID: String,
        sessionID: String?,
        placeholderID: UUID,
        args: ChatStore.PendingSendArgs
    ) {
        pendingExchanges[correlationID] = ChatPendingExchange(
            correlationID: correlationID,
            sessionID: Self.cleanSessionID(sessionID),
            placeholderID: placeholderID,
            request: ChatPendingExchange.RetainedRequest(
                text: args.text,
                controls: args.controls,
                attachments: args.attachments,
                appendedUserId: args.appendedUserId
            ),
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
        record = ChatPendingExchange(
            correlationID: newID,
            sessionID: record.sessionID,
            placeholderID: record.placeholderID,
            request: record.request,
            partialText: record.partialText,
            activity: record.activity,
            updatedAt: record.updatedAt,
            acknowledged: record.acknowledged,
            isSilent: record.isSilent,
            expiredRequest: record.expiredRequest
        )
        pendingExchanges[newID] = record
    }

    /// The Mac signed a refusal because the request aged out unread. Record
    /// that durably, with the retained request, so a session switch or a cold
    /// launch still restores the "wasn't started · Send now" bubble instead of
    /// resurrecting a streaming placeholder for a dead correlation.
    func markPendingExchangeExpired(
        correlationID: String,
        placeholderID: UUID,
        message: String,
        args: ChatStore.PendingSendArgs
    ) {
        var record = pendingExchanges[correlationID] ?? ChatPendingExchange(
            correlationID: correlationID,
            sessionID: Self.cleanSessionID(args.sessionID),
            placeholderID: placeholderID,
            partialText: "",
            activity: nil,
            updatedAt: Date(),
            acknowledged: true,
            isSilent: false
        )
        record.expiredRequest = ChatPendingExchange.ExpiredRequest(
            text: args.text,
            controls: args.controls,
            attachments: args.attachments,
            appendedUserId: args.appendedUserId,
            message: message
        )
        record.isSilent = false
        record.updatedAt = Date()
        pendingExchanges[correlationID] = record
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

    /// The arguments a "Send now" would replay for this correlation. The
    /// in-memory `pendingSendArgs` is authoritative while it has them; the
    /// durable record is the fallback after a session switch or a relaunch.
    func resendArgs(for correlationID: String) -> ChatStore.PendingSendArgs? {
        if let args = pendingSendArgs[correlationID] { return args }
        guard let record = pendingExchanges[correlationID] else { return nil }
        if let retained = record.request {
            return ChatStore.PendingSendArgs(
                text: retained.text,
                sessionID: record.sessionID,
                controls: retained.controls,
                attachments: retained.attachments,
                appendedUserId: retained.appendedUserId
            )
        }
        guard let expired = record.expiredRequest else { return nil }
        return ChatStore.PendingSendArgs(
            text: expired.text,
            sessionID: record.sessionID,
            controls: expired.controls,
            attachments: expired.attachments,
            appendedUserId: expired.appendedUserId
        )
    }

    /// A terminal result — reply, error, cancel or session retirement — closes
    /// the record. Nothing else does.
    func closePendingExchange(_ correlationID: String) {
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

    /// Re-attaches the unfinished exchanges of the session now on screen: the
    /// bubble goes back to waiting with whatever partial answer it had, the
    /// correlation is observable again, and the durable record is untouched.
    /// This starts no work on the Mac — it resumes watching work already sent.
    @discardableResult
    func restorePendingExchanges(for sessionID: String?) -> [String] {
        let session = Self.cleanSessionID(sessionID)
        var restored: [String] = []
        for record in pendingExchanges.values where record.sessionID == session {
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
                // 2026-09-13: the bubble being absent is NOT evidence the turn
                // ended. persistMessages() drops every streaming row, so the
                // placeholder of an unfinished exchange is never in the cache
                // it is restored from — the old code deleted the durable record
                // here, and the partial answer plus the observation went with
                // it. Re-create the bubble from the record instead: same
                // placeholder id, whatever partial text had arrived, still
                // streaming. Only a terminal receipt closes an exchange.
                messages.append(
                    ChatMessage(
                        id: record.placeholderID,
                        role: .assistant,
                        text: record.partialText,
                        isStreaming: true
                    )
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
            messages.append(
                ChatMessage(
                    id: record.placeholderID,
                    role: .assistant,
                    text: retained.message,
                    isStreaming: false
                )
            )
        }
        pendingICloudPlaceholders.removeValue(forKey: record.correlationID)
        streamingHintsByMessageId.removeValue(forKey: record.placeholderID)
        timedOutPendingIds.removeValue(forKey: record.correlationID)
        pendingSendArgs[record.correlationID] = ChatStore.PendingSendArgs(
            text: retained.text,
            sessionID: record.sessionID,
            controls: retained.controls,
            attachments: retained.attachments,
            appendedUserId: retained.appendedUserId
        )
        expiredPendingIds[record.correlationID] = record.placeholderID
    }

    /// Resumes observation of restored exchanges. Observation only: the signed
    /// request already crossed the bridge and is never sent a second time.
    func resumeObservingPendingExchanges(using client: MacBridgeClient) {
        for correlationID in restorePendingExchanges(for: selectedSessionID) {
            guard pendingPolls[correlationID] == nil else { continue }
            armReplyPoll(for: correlationID, client: client)
        }
    }
}
