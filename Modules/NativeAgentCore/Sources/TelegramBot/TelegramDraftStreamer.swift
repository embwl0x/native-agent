import Foundation

// Telegram has no token stream. The native streaming idiom is the growing
// draft: send the first chunk as a real message early, then editMessageText
// with the accumulated text on a throttle until the final edit completes it.
actor TelegramDraftStreamer {
    private let token: String
    private let chatId: Int
    private let sendReturningId: @Sendable (_ token: String, _ chatId: Int, _ text: String) async throws -> Int
    private let editMessage: @Sendable (_ token: String, _ chatId: Int, _ messageId: Int, _ text: String) async throws -> Void
    private let editIntervalSeconds: TimeInterval
    private var draftMessageId: Int?
    private var lastEditAt = Date.distantPast
    private var lastText = ""

    init(
        token: String,
        chatId: Int,
        editIntervalSeconds: TimeInterval = 2.0,
        sendReturningId: @escaping @Sendable (String, Int, String) async throws -> Int,
        editMessage: @escaping @Sendable (String, Int, Int, String) async throws -> Void
    ) {
        self.token = token
        self.chatId = chatId
        self.editIntervalSeconds = editIntervalSeconds
        self.sendReturningId = sendReturningId
        self.editMessage = editMessage
    }

    /// Throttled draft update. The visible draft is the first Telegram-safe
    /// chunk of the accumulated text; overflow rolls into continuation
    /// messages at finalize, not mid-stream.
    func onDelta(_ accumulated: String) async {
        let now = Date()
        guard now.timeIntervalSince(lastEditAt) >= editIntervalSeconds else { return }
        guard let visible = TelegramPollLoop._tgChunkMessage(accumulated, limit: 4000).first,
              !visible.isEmpty, visible != lastText else { return }
        do {
            if let id = draftMessageId {
                try await editMessage(token, chatId, id, visible)
            } else {
                draftMessageId = try await sendReturningId(token, chatId, visible)
            }
            lastText = visible
        } catch {
            FileHandle.standardError.write(
                Data("TelegramDraftStreamer: draft update failed for chat \(chatId): \(TelegramPollLoop._tgRedactToken(String(describing: error)))\n".utf8)
            )
        }
        // Advance the throttle clock even on failure so errors back off too.
        lastEditAt = now
    }

    /// Complete the draft with the final reply. Returns the exact chunks the
    /// caller still needs to send via sendMessage.
    func finalize(reply: String) async -> [String] {
        guard let id = draftMessageId else { return [reply] }
        let chunks = TelegramPollLoop._tgChunkMessage(reply, limit: 4000)
        guard let first = chunks.first else { return [] }
        do {
            if first != lastText {
                try await editMessage(token, chatId, id, first)
            }
            return Array(chunks.dropFirst())
        } catch {
            FileHandle.standardError.write(
                Data("TelegramDraftStreamer: final edit failed for chat \(chatId): \(TelegramPollLoop._tgRedactToken(String(describing: error)))\n".utf8)
            )
            // 2026-07-21 audit: a failed final edit leaves a STALE partial
            // draft on screen next to the full re-send below. Retry the edit
            // once; if it still fails, convert the dangling draft to an
            // honest notice before falling back to plain sends.
            do {
                try await editMessage(token, chatId, id, first)
                lastText = first
                return Array(chunks.dropFirst())
            } catch {
                _ = await abortDelivering(
                    notice: "(draft update failed — the full reply follows as new messages)"
                )
                return [reply]
            }
        }
    }

    /// Turn ended without a deliverable reply. Edit the partial draft to the
    /// honest notice so the user is not left with a stale fragment.
    func abortDelivering(notice: String) async -> Bool {
        guard let id = draftMessageId, !notice.isEmpty else { return false }
        do {
            try await editMessage(token, chatId, id, notice)
            return true
        } catch {
            FileHandle.standardError.write(
                Data("TelegramDraftStreamer: abort edit failed for chat \(chatId): \(TelegramPollLoop._tgRedactToken(String(describing: error)))\n".utf8)
            )
            return false
        }
    }
}
