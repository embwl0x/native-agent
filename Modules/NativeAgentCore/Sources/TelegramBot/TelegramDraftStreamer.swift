import Foundation

// Telegram has no token stream. The native streaming idiom is the growing
// draft: send the first chunk as a real message early, then editMessageText
// with the accumulated text on a throttle until the final edit completes it.
actor TelegramDraftStreamer {
    /// What this streamer knows about the one draft message it owns.
    ///
    /// 2026-09-06: `outcomeUnknown` exists because Telegram has no idempotency
    /// key. When a send crosses the wire and its response is lost, whether the
    /// message exists can never be settled from here — and every later send
    /// would be a second visible message, not a retry.
    private enum DraftState: Equatable {
        case none
        case live(id: Int)
        /// The creating send whose response was lost, and the exact text it
        /// carried. 2026-09-06: the text is kept because finalize must never
        /// send that chunk a second time.
        case outcomeUnknown(sentText: String)
    }

    private let token: String
    private let destination: TelegramDestination
    private let sendReturningId: @Sendable (_ token: String, _ destination: TelegramDestination, _ text: String) async throws -> Int
    private let editMessage: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void
    private let editIntervalSeconds: TimeInterval
    private var state: DraftState = .none
    private var lastEditAt = Date.distantPast
    private var lastText = ""

    init(
        token: String,
        destination: TelegramDestination,
        editIntervalSeconds: TimeInterval = 2.0,
        sendReturningId: @escaping @Sendable (String, TelegramDestination, String) async throws -> Int,
        editMessage: @escaping @Sendable (String, Int, Int, String) async throws -> Void
    ) {
        self.token = token
        self.destination = destination
        self.editIntervalSeconds = editIntervalSeconds
        self.sendReturningId = sendReturningId
        self.editMessage = editMessage
    }

    /// Throttled draft update. The visible draft is the first Telegram-safe
    /// chunk of the accumulated text; overflow rolls into continuation
    /// messages at finalize, not mid-stream.
    func onDelta(_ accumulated: String) async {
        // 2026-09-06: an ambiguous first send stops the stream. Sending again
        // would post one extra message per delta for a draft that may already
        // exist; finalize settles the turn with a single send instead.
        if case .outcomeUnknown = state { return }
        let now = Date()
        guard now.timeIntervalSince(lastEditAt) >= editIntervalSeconds else { return }
        guard let visible = TelegramPollLoop._tgChunkMessage(accumulated, limit: 4000).first,
              !visible.isEmpty, visible != lastText else { return }
        do {
            switch state {
            case .live(let id):
                try await editMessage(token, destination.chatId, id, visible)
            case .none:
                let sentId = try await sendReturningId(token, destination, visible)
                state = .live(id: sentId)
            case .outcomeUnknown:
                return
            }
            lastText = visible
        } catch {
            FileHandle.standardError.write(
                Data("TelegramDraftStreamer: draft update failed for chat \(destination.chatId): \(TelegramPollLoop._tgRedactToken(String(describing: error)))\n".utf8)
            )
            // Only the CREATING send can leave an unknown message behind. An
            // edit is idempotent, so an ambiguous edit keeps the live draft.
            if state == .none, TelegramTurnReplyDeliveryFailure.isAmbiguous(error) {
                state = .outcomeUnknown(sentText: visible)
            }
        }
        // Advance the throttle clock even on failure so errors back off too.
        lastEditAt = now
    }

    /// Complete the draft with the final reply. Returns the exact chunks the
    /// caller still needs to send via sendMessage.
    func finalize(reply: String) async -> [String] {
        let id: Int
        switch state {
        case .none:
            // No draft exists. This is the single send that delivers the answer.
            return [reply]
        case .outcomeUnknown(let sentText):
            // 2026-09-06: the creating send may already be on screen holding
            // `sentText`; nothing here can settle that. Returning the whole
            // reply showed that text twice whenever the send HAD landed, which
            // is exactly the duplicate the outcome-unknown state was added to
            // prevent. Send only the continuation past the ambiguous chunk —
            // and if the reply ended inside it, send nothing at all and let
            // the work card report the outcome as unknown. One possibly
            // missing message beats two visible ones.
            guard reply.hasPrefix(sentText) else {
                // Not a continuation of what was sent, so nothing would be
                // duplicated verbatim and the answer still has to arrive.
                return [reply]
            }
            let remainder = String(reply.dropFirst(sentText.count))
            guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }
            return TelegramPollLoop._tgChunkMessage(remainder, limit: 4000)
        case .live(let liveId):
            id = liveId
        }
        let chunks = TelegramPollLoop._tgChunkMessage(reply, limit: 4000)
        guard let first = chunks.first else { return [] }
        do {
            if first != lastText {
                try await editMessage(token, destination.chatId, id, first)
                lastText = first
            }
            return Array(chunks.dropFirst())
        } catch {
            FileHandle.standardError.write(
                Data("TelegramDraftStreamer: final edit failed for chat \(destination.chatId): \(TelegramPollLoop._tgRedactToken(String(describing: error)))\n".utf8)
            )
            // 2026-07-21 audit: a failed final edit leaves a STALE partial
            // draft on screen next to the full re-send below. Retry the edit
            // once; if it still fails, convert the dangling draft to an
            // honest notice before falling back to plain sends.
            do {
                try await editMessage(token, destination.chatId, id, first)
                lastText = first
                return Array(chunks.dropFirst())
            } catch {
                // 2026-09-06: an ambiguous edit may already have landed, so
                // the draft may hold the whole first chunk. Re-sending the
                // reply would show it twice; one possibly-stale message beats
                // two. Continuation chunks are new messages either way.
                if TelegramTurnReplyDeliveryFailure.isAmbiguous(error) {
                    FileHandle.standardError.write(
                        Data("TelegramDraftStreamer: final edit outcome unknown for chat \(destination.chatId); not resending the reply\n".utf8)
                    )
                    // 2026-09-06: record the ambiguity the same way an
                    // ambiguous creating send does. Without it the streamer
                    // still read as `.live`, the driver's hasUnknownOutcome
                    // check saw false, and a reply of one chunk sent NOTHING
                    // while the work card claimed a clean delivery.
                    state = .outcomeUnknown(sentText: first)
                    return Array(chunks.dropFirst())
                }
                _ = await abortDelivering(
                    notice: "(draft update failed — the full reply follows as new messages)"
                )
                return [reply]
            }
        }
    }

    /// 2026-09-06: true once a creating send crossed the wire without a
    /// response. What the user can see is not knowable from here, so the
    /// caller must report the turn's outcome as unknown rather than delivered.
    var hasUnknownOutcome: Bool {
        if case .outcomeUnknown = state { return true }
        return false
    }

    /// Turn ended without a deliverable reply. Edit the partial draft to the
    /// honest notice so the user is not left with a stale fragment.
    func abortDelivering(notice: String) async -> Bool {
        guard case .live(let id) = state, !notice.isEmpty else { return false }
        do {
            try await editMessage(token, destination.chatId, id, notice)
            return true
        } catch {
            FileHandle.standardError.write(
                Data("TelegramDraftStreamer: abort edit failed for chat \(destination.chatId): \(TelegramPollLoop._tgRedactToken(String(describing: error)))\n".utf8)
            )
            return false
        }
    }
}
