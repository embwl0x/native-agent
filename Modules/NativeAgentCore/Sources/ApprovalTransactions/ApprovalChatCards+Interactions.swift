import Foundation
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import Privacy
import TelegramBot

// Blueprint: | `ApprovalChatCards+Interactions.swift` | `ApprovalChatCards`: mirrors inline interactions into the person's conversation and Telegram while answers retain the origin card's identity and settlement |

/// User, 10-03: an inline card she raises in a thread he never opens (an agent
/// contact's, her wake) waited there unseen. The same rule as approvals: one
/// mirror in the conversation he is in, bound to the card's id. The card stays
/// where it was raised — its revision, verification and continuation are the
/// origin's — and every surface answers THAT card, so both places settle as one.
///
/// The claim is the card's inbox note (`interaction:<id>`, filed by the app's
/// delivery): the destination is retained until its deduplicated row is durable,
/// then `chat_mirror_delivered` marks completion under the inbox lock.
extension ApprovalChatCards {
    /// Transcript kind of the mirror row. It carries no `interaction`, so no
    /// resolver (and no `card.answer`) ever reads it as a card of its own.
    public static let interactionMirrorKind = "interaction_mirror"

    /// Kinds whose answer is a key or token typed into the card: never sent to
    /// Telegram. Kinds answered by a pick get buttons there; the rest a line.
    static func telegramReach(_ card: InlineInteraction) -> (send: Bool, buttons: Bool) {
        switch card.kind {
        case .choose, .modelChoice: return (true, true)
        case .permission, .capability: return (true, false)
        case .connector, .apiKey, .unknown: return (false, false)
        }
    }

    /// Mirror an open card raised in `sessionID` into User's conversation.
    @discardableResult
    public static func postInteraction(
        _ card: InlineInteraction,
        sessionID: String,
        dataRoot: URL,
        telegram: TelegramApprovalFiler? = nil,
        quiet: Bool = false
    ) async -> Outcome {
        guard card.state.isOpen, !Task.isCancelled else { return .skipped }
        let savedNote = await mirrorNote(card.id, dataRoot: dataRoot)
        let savedAnchor: String? = if case .string(let value)? = savedNote?["chat_session_id"] { value } else { nil }
        guard let proposedAnchor = savedAnchor ?? usersConversation(unless: sessionID, dataRoot: dataRoot),
              NativeAgentChatSessionID.normalizedPathComponent(proposedAnchor) == proposedAnchor else { return .skipped }
        let reach = telegramReach(card)
        let picks = card.options.enumerated().filter { !isControlOption($0.element.id) }
        let buttons = reach.buttons && !picks.isEmpty
        let title = NativeAppSecretRedactor.redactText(card.title)
        let why = NativeAppSecretRedactor.redactText(card.why)
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
        let noteID = "interaction:\(card.id)"
        guard !Task.isCancelled else { return .skipped }
        // One transcript row and its receipt settle together. Telegram owns
        // another receipt; a completed transcript never retires an unsent DM.
        let mirror = await settle {
            do {
                try await inbox.patch(id: noteID, unlessPresent: "chat_session_id",
                                      ["chat_session_id": .string(proposedAnchor)])
                guard let note = await mirrorNote(card.id, dataRoot: dataRoot),
                      case .string(let anchor)? = note["chat_session_id"],
                      NativeAgentChatSessionID.normalizedPathComponent(anchor) == anchor else {
                    return Result<String?, Error>.success(nil)
                }
                if note["chat_mirror_delivered"] != .bool(true) {
                    let row: JSONValue = .object([
                        "id": .string("interaction-mirror-\(card.id)"), "sessionId": .string(anchor),
                        "role": .string("tool"), "content": .string([title, why].filter { !$0.isEmpty }.joined(separator: "\n")),
                        "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                        "source": .string("interaction"), "runId": .string("interaction-mirror-\(card.id)"),
                        "metadata": .object(["kind": .string(interactionMirrorKind),
                            "toolName": .string("request_interaction"), "interactionId": .string(card.id),
                            "interactionSessionId": .string(sessionID)]),
                    ])
                    try await appendRow(row, sessionID: anchor, dataRoot: dataRoot, uniqueRunID: "interaction-mirror-\(card.id)")
                    _ = try await inbox.patch(id: noteID, unlessPresent: "chat_mirror_delivered",
                                              ["chat_mirror_delivered": .bool(true)])
                }
                return .success(anchor)
            } catch { return .failure(error) }
        }
        let anchor: String
        do {
            guard let saved = try mirror.get() else { return .skipped }
            anchor = saved
        } catch {
            nativeLog("[approval-chat-card] mirror write failed: %@", error.localizedDescription)
            return .failed
        }
        let ownerChat = telegram == nil || !reach.send ? nil : await ownerDM(boundTo: anchor, dataRoot: dataRoot)
        if let telegram, let ownerChat, !quiet, !Task.isCancelled {
            var keyboard: [JSONValue] = []
            if buttons {
                keyboard = picks.prefix(8).map { index, option in
                    .array([.object(["text": .string(NativeAppSecretRedactor.redactText(option.label)),
                                     "callback_data": .string("na_approval:c\(index):\(card.id)")])])
                }
                keyboard.append(.array([.object(["text": .string("Not now"),
                                                 "callback_data": .string("na_approval:deny:\(card.id)")])]))
            }
            let guidance = card.kind == .modelChoice
                ? "Choose the model in Providers on the Mac." : "Answer it on the Mac."
            let text = [title, why, buttons ? "" : guidance].filter { !$0.isEmpty }.joined(separator: "\n\n")
            do {
                try await telegram.deliverChatCard(id: card.id, sessionID: sessionID, dataRoot: dataRoot,
                    text: text, title: title, chatId: ownerChat, markup: .object(["inline_keyboard": .array(keyboard)]))
            } catch {
                nativeLog("[approval-chat-card] Telegram card failed: %@", error.localizedDescription)
            }
        }
        return savedNote?["chat_mirror_delivered"] == .bool(true) ? .skipped : .posted(anchor)
    }

    static func promptPendingInteractions(dataRoot: URL, telegram: TelegramApprovalFiler) async {
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
        guard let notes = try? await inbox.rows() else { return }
        for case .object(let note) in notes {
            guard !Task.isCancelled else { return }
            guard note["source"] == .string("interaction"),
                  case .string(let id)? = note["interaction_id"],
                  case .string(let session)? = note["interaction_session_id"] else { continue }
            if note["telegram_message_id"] != nil {
                // A card answered while Telegram was stopped still owes its
                // delivered copy an edit, owned by the same settlement filer.
                if note["telegram_card_settled"] != .bool(true) {
                    _ = await telegram.enqueueInteractionSettlement(id: id, sessionID: session, dataRoot: dataRoot)
                }
                continue
            }
            guard let card = await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: dataRoot),
                  card.state.isOpen else { continue }
            let held = await MainActor.run {
                InlineInteractionResolver.platform.residentWakeHeld(sessionID: session, dataRoot: dataRoot)
            }
            await postInteraction(card, sessionID: session, dataRoot: dataRoot, telegram: telegram, quiet: held)
        }
    }

    /// An option id that is a control, not an answer (the registry spells
    /// those `__like_this__`).
    static func isControlOption(_ id: String) -> Bool { id.hasPrefix("__") }

    /// The card's inbox note says it was mirrored to User: his to answer.
    static func isMirroredToUser(_ id: String, dataRoot: URL) async -> Bool {
        guard let held = await mirrorNote(id, dataRoot: dataRoot)?["chat_session_id"] else { return false }
        return held != .null
    }

    static func mirrorNote(_ id: String, dataRoot: URL) async -> [String: JSONValue]? {
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
        guard let rows = try? await inbox.rows(),
              case .object(let note)? = rows.last(where: {
                  guard case .object(let row) = $0 else { return false }
                  return row["id"] == .string("interaction:\(id)")
              }) else { return nil }
        return note
    }

    /// The running Telegram filer, set by the app when Telegram starts.
    nonisolated(unsafe) private static var telegramFiler: TelegramApprovalFiler?
    private static let telegramFilerLock = NSLock()
    public static func useTelegram(_ filer: TelegramApprovalFiler?) { telegramFilerLock.withLock { telegramFiler = filer } }
    static func stopTelegram(_ filer: TelegramApprovalFiler) {
        telegramFilerLock.withLock {
            if telegramFiler === filer { telegramFiler = nil }
        }
    }

    /// Once a mirrored card is settled (answered on any surface, withdrawn or
    /// expired), its Telegram copy's buttons go away and it says how it ended.
    static func settleTelegramCopy(id: String, sessionID: String, dataRoot: URL, filer: TelegramApprovalFiler) async {
        guard let note = await mirrorNote(id, dataRoot: dataRoot),
              note["telegram_card_settled"] != .bool(true),
              case .string(let chat)? = note["telegram_chat_id"], let chatId = Int(chat),
              case .string(let message)? = note["telegram_message_id"], let messageId = Int(message),
              let card = await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
              !card.state.isOpen else { return }
        let title: String = if case .string(let saved)? = note["telegram_card_title"] { saved } else { NativeAppSecretRedactor.redactText(card.title) }
        let summary = card.state.outcome?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Telegram caps a message at 4096 characters.
        let text = String((title + "\n\n" + (summary.isEmpty ? "Closed." : "✓ " + NativeAppSecretRedactor.redactText(summary))).prefix(3500))
        // Settled on Telegram's receipt only: a failed edit stays outstanding,
        // and the card's next change tries it again.
        do {
            try await filer.settleChatCard(chatId: chatId, messageId: messageId, text: text)
            let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
            _ = try await inbox.patch(id: "interaction:\(id)", unlessPresent: "telegram_card_settled", ["telegram_card_settled": .bool(true)])
        } catch {
            nativeLog("[approval-chat-card] Telegram settle failed: %@", error.localizedDescription)
        }
    }

    static func publishInteractionChange(id: String, sessionID: String, dataRoot: URL) async {
        // Off the UI path: the app's own views never wait on Telegram.
        if let filer = telegramFilerLock.withLock({ telegramFiler }) {
            _ = await filer.enqueueInteractionSettlement(id: id, sessionID: sessionID, dataRoot: dataRoot)
        }
        var sessions: Set<String> = [sessionID]
        if case .string(let mirror)? = await mirrorNote(id, dataRoot: dataRoot)?["chat_session_id"],
           NativeAgentChatSessionID.normalizedPathComponent(mirror) == mirror {
            sessions.insert(mirror)
        }
        await publishTranscriptChanges(sessionIDs: sessions, dataRoot: dataRoot)
    }

    /// A tap on a mirrored card's Telegram button: only the owner, in his own
    /// DM, answers the ORIGINAL card, which resumes the turn that raised it.
    /// Nil when `id` is no mirrored card (the caller then reports not found).
    static func answerInteractionFromTelegram(
        id: String, choice: Int?, decline: Bool, chatId: Int, fromUserId: Int?, dataRoot: URL
    ) async throws -> String? {
        guard let note = await mirrorNote(id, dataRoot: dataRoot),
              case .string(let session)? = note["interaction_session_id"] else { return nil }
        guard note["telegram_chat_id"] == .string(String(chatId)), fromUserId == chatId else {
            throw NSError(domain: "ApprovalChatCards", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "That card is answered by its owner in his own chat."])
        }
        guard let card = await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: dataRoot),
              card.state.isOpen else { return "Already answered — nothing changed." }
        if decline {
            _ = try await InlineInteractionResolver.decline(id: id, sessionID: session,
                                                            expectedRevision: card.revision, dataRoot: dataRoot)
            return "Not now — \(card.declineConsequence)"
        }
        guard let choice, card.options.indices.contains(choice),
              !isControlOption(card.options[choice].id) else {
            return "Pick one of the card's buttons."
        }
        let picked = card.options[choice].id
        let settled = card.kind == .modelChoice
            ? try await InlineInteractionResolver.answerModelChoice(card, sessionID: session, picked: picked,
                scope: card.primaryScope, attribution: "Owner on Telegram",
                controls: { @MainActor in InlineInteractionResolver.platform.interactionControls() }, dataRoot: dataRoot)
            : try await InlineInteractionResolver.complete(id: id, sessionID: session, selection: picked,
                expectedRevision: card.revision, attribution: "Owner on Telegram", dataRoot: dataRoot)
        return settled.state.failureReason ?? "Chose: \(card.options[choice].label)."
    }
}
