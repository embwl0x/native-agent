import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import ApprovalInbox
import Experiences
import PersistenceCore
import Privacy
import TelegramBot
// Blueprint: | `ApprovalChatCards+Interactions.swift` | Conversation mirrors and Telegram receipts read the matter's doors; every answer settles the origin |

extension ApprovalChatCards {
    public static let interactionMirrorKind = "interaction_mirror"

    /// An open request is mirrored into the person's conversation through the one mirror approvals use.
    @discardableResult
    public static func postInteraction(_ card: InlineInteraction, sessionID: String, dataRoot: URL) async -> Outcome {
        guard card.state.isOpen, !Task.isCancelled else { return .skipped }
        let rowID = "interaction-mirror-" + card.id
        return await mirror("interaction:" + card.id, rowID: rowID, dataRoot: dataRoot) { anchor in
            .object([
                "id": .string(rowID), "sessionId": .string(anchor), "role": .string("tool"),
                "content": .string([card.title, card.why].map(NativeAppSecretRedactor.redactText).filter { !$0.isEmpty }.joined(separator: "\n")),
                "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                "source": .string("interaction"), "runId": .string(rowID),
                "metadata": .object(["kind": .string(interactionMirrorKind), "toolName": .string("request_interaction"),
                    "interactionId": .string(card.id), "interactionSessionId": .string(sessionID)]),
            ])
        }
    }

    /// The router calls the same prompt transaction as recovery; a Telegram door gets one prompt, never a second text alert. The card is
    /// its matter's Inbox row: its buttons are that row's actions the Telegram door runs, and a row that offers Telegram none (a key's
    /// card, a Mac-only control) is never sent there; its Telegram door is let go.
    public static func deliverInteractionAttentionPrompt(id: String, chatId: Int, dataRoot: URL) async -> NotificationDeliveryOutcome {
        do {
            guard let matter = try await interactionMatter(id, dataRoot: dataRoot),
                  let session = interactionSession(matter),
                  let owed = matter.owes[Door.telegram(chat: "", thread: nil).key],
                  let door = Door(address: owed.to), case .telegram(let chat, let topic) = door, chat == String(chatId),
                  let card = try await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: dataRoot) else {
                return .notDelivered(reason: "The request has no matching Telegram door or transcript card")
            }
            if owed.phase == .accepted { return .delivered }
            guard card.state.isOpen else { return .notDelivered(reason: "The request is no longer open") }
            guard let telegram = runningTelegram else { return .notDelivered(reason: "The Telegram approval sender is not running") }
            let keyboard = try await TelegramApprovalFiler.buttons(telegram.cardRow(matter.id), dataRoot: dataRoot)
            guard !keyboard.isEmpty else {
                try await ForPerson.at(dataRoot).letGo(matter.id, door, .cancelled)
                return .suppressed(preference: "This request is answered on the Mac or the phone")
            }
            guard let face = matter.face, let row = face.row else {
                return .notDelivered(reason: "The request's canonical consent face is unavailable; no answer was offered")
            }
            let text = [row.title, face.words].map(NativeAppSecretRedactor.redactText).filter { !$0.isEmpty }.joined(separator: "\n\n")
            try await telegram.deliverChatCard(id: id, sessionID: session, dataRoot: dataRoot,
                text: text, chatId: chatId, threadId: topic, markup: .object(["inline_keyboard": .array(keyboard)]))
            let fresh = try await interactionMatter(id, dataRoot: dataRoot)
            return fresh?.owes[door.key]?.phase == .accepted ? .delivered
                : .unknown(sent: true, reason: "The prompt has no saved receipt; recover its returned send result")
        } catch {
            if let failure = error as? NotificationDeliveryFailure { return failure.outcome }
            if TelegramAPIFailure.isKnownNotDelivered(error) { return .notDelivered(reason: error.localizedDescription) }
            return .unknown(sent: true, reason: error.localizedDescription)
        }
    }

    static func promptPendingInteractions(dataRoot: URL, telegram: TelegramApprovalFiler) async {
        do {
            for matter in try await ForPerson.at(dataRoot).matters() where matter.face?.from == InlineInteractionDelivery.source {
                guard !Task.isCancelled else { return }
                guard let ref = matter.evidence.first(where: { $0.source.hasPrefix(Matter.conversations) }),
                      let session = interactionSession(matter) else { continue }
                do {
                    try await telegram.recoverInteractionReceipt(id: ref.id, dataRoot: dataRoot)
                    _ = await telegram.enqueueInteractionSettlement(id: ref.id, sessionID: session, dataRoot: dataRoot)
                } catch { nativeLog("[approval-chat-card] pending receipt unavailable: %@", error.localizedDescription) }
            }
        } catch { nativeLog("[approval-chat-card] pending matters unavailable: %@", error.localizedDescription) }
    }

    static func isMirroredToUser(_ id: String, dataRoot: URL) async throws -> Bool {
        try await interactionMatter(id, dataRoot: dataRoot)?.owes[Door.conversation("").key] != nil
    }

    static func interactionMatter(_ id: String, dataRoot: URL) async throws -> Experience? {
        try await ForPerson.at(dataRoot).matter("interaction:" + id)
    }

    static func interactionSession(_ matter: Experience) -> String? {
        matter.evidence.first { $0.source.hasPrefix(Matter.conversations) }
            .map { String($0.source.dropFirst(Matter.conversations.count)) }
    }

    private static let telegramFiler = Mutex<TelegramApprovalFiler?>(nil)
    public static var runningTelegram: TelegramApprovalFiler? { telegramFiler.withLock { $0 } }
    public static func useTelegram(_ filer: TelegramApprovalFiler?) {
        telegramFiler.withLock { $0 = filer }
        // While Telegram runs, every ask reaches the one owner's private chat too.
        let read: PersonsTelegram.Read = { root in
            guard let owner = try ownerDM(dataRoot: root) else { return nil }
            return Door.telegram(chat: String(owner), thread: nil)
        }
        PersonsTelegram.use(filer == nil ? nil : read)
    }
    static func stopTelegram(_ filer: TelegramApprovalFiler) {
        let stopped = telegramFiler.withLock { current -> Bool in
            guard current === filer else { return false }
            current = nil
            return true
        }
        if stopped { PersonsTelegram.use(nil) }
    }

    /// Button edits name the accepted message; the record's claim is the edit receipt, never a second card-status flag.
    static func settleTelegramCopy(id: String, sessionID: String, dataRoot: URL, filer: TelegramApprovalFiler) async {
        do {
            try await filer.recoverInteractionReceipt(id: id, dataRoot: dataRoot)
            guard let matter = try await interactionMatter(id, dataRoot: dataRoot),
                  let owed = matter.owes[Door.telegram(chat: "", thread: nil).key], let receipt = owed.evidence,
                  !matter.claims.contains(where: { $0.claim == "telegram_settled" && $0.evidence.contains(receipt) }),
                  let door = Door(address: owed.to), case .telegram(let chat, _) = door,
                  let chatId = Int(chat), let messageId = Int(receipt.id),
                  let card = try await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
                  !card.state.isOpen else { return }
            let summary = card.state.outcome?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = String((NativeAppSecretRedactor.redactText(card.title) + "\n\n"
                + (summary.isEmpty ? "Closed." : "✓ " + NativeAppSecretRedactor.redactText(summary))).prefix(3500))
            try await filer.settleChatCard(chatId: chatId, messageId: messageId, text: text)
            await ExperienceStore.record(dataRoot, matter.id) { store in
                try await store.append([.claim(.init(claim: "telegram_settled", evidence: [receipt]))], to: matter.id)
            }.value
        } catch { nativeLog("[approval-chat-card] Telegram settle failed: %@", error.localizedDescription) }
    }

    static func publishInteractionChange(id: String, sessionID: String, dataRoot: URL) async {
        if let filer = runningTelegram { _ = await filer.enqueueInteractionSettlement(id: id, sessionID: sessionID, dataRoot: dataRoot) }
        var sessions: Set<String> = [sessionID]
        do {
            if let owed = try await interactionMatter(id, dataRoot: dataRoot)?.owes[Door.conversation("").key],
               let door = Door(address: owed.to), case .conversation(let mirror) = door,
               NativeAgentChatSessionID.normalizedPathComponent(mirror) == mirror { sessions.insert(mirror) }
        } catch { nativeLog("[approval-chat-card] mirror publication unavailable: %@", error.localizedDescription) }
        await publishTranscriptChanges(sessionIDs: sessions, dataRoot: dataRoot)
    }
}
