import Foundation
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import Privacy
import TelegramBot

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
        case .choose: return (true, true)
        case .modelChoice: return (true, card.primaryScope == .thisRequestOnly)
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
        guard card.state.isOpen else { return .skipped }
        let savedNote = await mirrorNote(card.id, dataRoot: dataRoot)
        guard savedNote?["chat_mirror_delivered"] != .bool(true) else { return .skipped }
        let savedAnchor: String? = if case .string(let value)? = savedNote?["chat_session_id"] { value } else { nil }
        guard let proposedAnchor = savedAnchor ?? usersConversation(unless: sessionID, dataRoot: dataRoot),
              NativeAgentChatSessionID.normalizedPathComponent(proposedAnchor) == proposedAnchor else { return .skipped }
        let reach = telegramReach(card)
        // Only real options become buttons: a control value (`__save_for_group__`,
        // a permanent save) stays on the Mac, where its page is.
        let picks = card.options.enumerated().filter { !isControlOption($0.element.id) }
        let buttons = reach.buttons && !picks.isEmpty
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
        let noteID = "interaction:\(card.id)"
        let anchor: String
        do {
            try await inbox.patch(id: noteID, unlessPresent: "chat_session_id",
                                  ["chat_session_id": .string(proposedAnchor)])
            guard let note = await mirrorNote(card.id, dataRoot: dataRoot),
                  note["chat_mirror_delivered"] != .bool(true),
                  case .string(let destination)? = note["chat_session_id"],
                  NativeAgentChatSessionID.normalizedPathComponent(destination) == destination else { return .skipped }
            anchor = destination
        } catch {
            nativeLog("[approval-chat-card] mirror claim failed: %@", error.localizedDescription)
            return .failed
        }
        let ownerChat = telegram == nil || !reach.send ? nil : await ownerDM(boundTo: anchor, dataRoot: dataRoot)
        let title = NativeAppSecretRedactor.redactText(card.title)
        let why = NativeAppSecretRedactor.redactText(card.why)
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "sessionId": .string(anchor),
            "role": .string("tool"),
            "content": .string([title, why].filter { !$0.isEmpty }.joined(separator: "\n")),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string("interaction"),
            "runId": .string("interaction-mirror-\(card.id)"),
            "metadata": .object([
                "kind": .string(interactionMirrorKind),
                "toolName": .string("request_interaction"),
                "interactionId": .string(card.id),
                "interactionSessionId": .string(sessionID),
            ]),
        ])
        do {
            try await appendRow(row, sessionID: anchor, dataRoot: dataRoot, uniqueRunID: "interaction-mirror-\(card.id)")
            var completion: [String: JSONValue] = ["chat_mirror_delivered": .bool(true)]
            if buttons, let ownerChat { completion["telegram_chat_id"] = .string(String(ownerChat)) }
            guard try await inbox.patch(id: noteID, unlessPresent: "chat_mirror_delivered", completion) else { return .skipped }
        } catch {
            nativeLog("[approval-chat-card] mirror write failed: %@", error.localizedDescription)
            return .failed
        }
        if let telegram, let ownerChat, !quiet {
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
                let messageId = try await telegram.sendChatCard(text: text, chatId: ownerChat,
                                                markup: .object(["inline_keyboard": .array(keyboard)]))
                // Kept so an answer on the Mac or phone can clear these buttons too.
                _ = try? await inbox.patch(id: noteID, unlessPresent: "telegram_message_id",
                    ["telegram_message_id": .string(String(messageId)), "telegram_card_title": .string(title)])
            } catch {
                nativeLog("[approval-chat-card] Telegram card failed: %@", error.localizedDescription)
            }
        }
        return .posted(anchor)
    }

    /// An option id that is a control, not an answer (the registry spells
    /// those `__like_this__`).
    static func isControlOption(_ id: String) -> Bool { id.hasPrefix("__") }

    /// The card's inbox note says it was mirrored to User: his to answer.
    static func isMirroredToUser(_ id: String, dataRoot: URL) async -> Bool {
        guard let held = await mirrorNote(id, dataRoot: dataRoot)?["chat_session_id"] else { return false }
        return held != .null
    }

    private static func mirrorNote(_ id: String, dataRoot: URL) async -> [String: JSONValue]? {
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

    /// Once a mirrored card is settled (answered on any surface, withdrawn or
    /// expired), its Telegram copy's buttons go away and it says how it ended.
    static func settleTelegramCopy(id: String, sessionID: String, dataRoot: URL) async {
        guard let note = await mirrorNote(id, dataRoot: dataRoot),
              note["telegram_card_settled"] != .bool(true),
              case .string(let chat)? = note["telegram_chat_id"], let chatId = Int(chat),
              case .string(let message)? = note["telegram_message_id"], let messageId = Int(message),
              let filer = telegramFilerLock.withLock({ telegramFiler }),
              let card = await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
              !card.state.isOpen else { return }
        let title: String = if case .string(let saved)? = note["telegram_card_title"] { saved } else { NativeAppSecretRedactor.redactText(card.title) }
        let summary = card.state.outcome?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = title + "\n\n✓ " + (summary.isEmpty ? "Answered." : NativeAppSecretRedactor.redactText(summary))
        do {
            try await filer.settleChatCard(chatId: chatId, messageId: messageId, text: text)
            let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
            _ = try? await inbox.patch(id: "interaction:\(id)", unlessPresent: "telegram_card_settled", ["telegram_card_settled": .bool(true)])
        } catch {
            nativeLog("[approval-chat-card] Telegram settle failed: %@", error.localizedDescription)
        }
    }

    static func publishInteractionChange(id: String, sessionID: String, dataRoot: URL) async {
        await settleTelegramCopy(id: id, sessionID: sessionID, dataRoot: dataRoot)
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
        if card.kind == .modelChoice, card.primaryScope != .thisRequestOnly {
            return "Choose the model in Providers on the Mac."
        }
        guard let choice, card.options.indices.contains(choice),
              !isControlOption(card.options[choice].id) else {
            return "Pick one of the card's buttons."
        }
        let settled = try await InlineInteractionResolver.complete(
            id: id, sessionID: session, selection: card.options[choice].id,
            scope: card.kind == .modelChoice ? .thisRequestOnly : nil,
            expectedRevision: card.revision, attribution: "User on Telegram", dataRoot: dataRoot)
        return settled.state.failureReason ?? "Chose: \(card.options[choice].label)."
    }
}
