import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import MacNerves
import SenseCore
import PersistenceCore
// Blueprint: | `ApprovalChatCards+Interactions.swift` | Conversation mirrors and Telegram receipts read the matter's doors; every answer settles the origin |

extension SwiftNativeApprovalInbox {
    public init(root: URL) {
        self.init(root: root, partBinding: { try NativeAgentEngine.forRoot(root).partBinding($0, $1) },
                  telegramDoor: { try NativeAgentEngine.forRoot(root).interactions.telegramDoor() })
    }
}

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
    /// its matter's Inbox row: its buttons are that row's actions the Telegram door runs. A row whose only Telegram button would be Not
    /// now (a key's card, a Mac-only control) is sent as one plain line saying it is answered on the Mac, and settles like any card.
    public static func deliverInteractionAttentionPrompt(id: String, chatId: Int, interactions: InlineInteractionCoordinator) async -> NotificationDeliveryOutcome {
        let dataRoot = interactions.dataRoot
        do {
            guard let matter = try await interactionMatter(id, dataRoot: dataRoot),
                  let session = interactionSession(matter),
                  let owed = matter.owes[Door.telegram(chat: "", thread: nil).key],
                  let door = Door(address: owed.to), case .telegram(let chat, let topic) = door, chat == String(chatId),
                  let card = try await interactions.interaction(id: id, sessionID: session) else {
                return .notDelivered(reason: "The request has no matching Telegram door or transcript card")
            }
            if owed.phase == .accepted { return .delivered }
            guard card.state.isOpen else { return .notDelivered(reason: "The request is no longer open") }
            guard let telegram = runningTelegram(for: dataRoot) else { return .notDelivered(reason: "The Telegram approval sender is not running") }
            let keyboard = try await telegramKeyboard(telegram.cardRow(matter.id), dataRoot: dataRoot)
            let answers = !keyboard.isEmpty
            guard let face = matter.face, let row = face.row else {
                return .notDelivered(reason: "The request's canonical consent face is unavailable; no answer was offered")
            }
            let title = NativeAppSecretRedactor.redactText(row.title)
            let text = answers
                ? [title, NativeAppSecretRedactor.redactText(face.words)].filter { !$0.isEmpty }.joined(separator: "\n\n")
                : title + " \u{2014} answer this on your Mac."
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

    /// Declining and the Inbox's housekeeping are no answer: a card whose Telegram buttons would be only these reads as a line.
    private static let noAnswer: Set<String> = ["card.not_now", "inbox.not_now", "inbox.mark_read", "inbox.archive", "inbox.acknowledge",
                                                "inbox.dismiss", "inbox.open_on_mac"]

    /// The row's Telegram buttons while it holds an answer Telegram runs; none otherwise, and its card reads as a line.
    static func telegramKeyboard(_ row: PartFace.Row?, dataRoot: URL) throws -> [JSONValue] {
        guard let row else { return [] }
        var answering = row
        answering.actions = row.actions?.filter { $0.aside != true && !noAnswer.contains($0.call?.action ?? "") }
        guard try !TelegramApprovalFiler.buttons(answering, dataRoot: dataRoot).isEmpty else { return [] }
        return try TelegramApprovalFiler.buttons(row, dataRoot: dataRoot)
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

    static func runningTelegram(for root: URL) -> TelegramApprovalFiler? {
        NativeAgentEngine.forRoot(root).interactions.telegramFiler.withLock { $0 }
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
                  let card = try await filer.interactions.interaction(id: id, sessionID: sessionID),
                  !card.state.isOpen else { return }
            // The receipt line every door reads. A closed card offers no answer (the Inbox row may not have caught up yet); only a
            // retryable failure keeps a button, its Try again where Telegram runs it, and settles once it is done.
            let model = InlineCards.model(card, descriptor: await InlineInteractionCoordinator.descriptor(for: card, dataRoot: dataRoot))
            let outcome = model.outcome ?? ""
            let text = String(([card.title, outcome].map(NativeAppSecretRedactor.redactText).filter { !$0.isEmpty })
                .joined(separator: "\n\n").prefix(3500))
            var retry: PartFace.Row?
            if model.needsAttention { retry = try await filer.inbox.row(matter.id) }
            if var row = retry { row.actions = row.actions?.filter { $0.call?.action == "card.try_again" }; retry = row }
            let keyboard = try retry.map { try TelegramApprovalFiler.buttons($0, dataRoot: dataRoot) } ?? []
            try await filer.settleChatCard(chatId: chatId, messageId: messageId, text: text, keyboard: keyboard)
            guard !model.needsAttention else { return }
            await ExperienceStore.record(dataRoot, matter.id) { store in
                try await store.append([.claim(.init(claim: "telegram_settled", evidence: [receipt]))], to: matter.id)
            }.value
        } catch { nativeLog("[approval-chat-card] Telegram settle failed: %@", error.localizedDescription) }
    }

    static func publishInteractionChange(id: String, sessionID: String, dataRoot: URL) async {
        if let filer = runningTelegram(for: dataRoot) {
            _ = await filer.enqueueInteractionSettlement(id: id, sessionID: sessionID, dataRoot: dataRoot)
        }
        var sessions: Set<String> = [sessionID]
        do {
            if let owed = try await interactionMatter(id, dataRoot: dataRoot)?.owes[Door.conversation("").key],
               let door = Door(address: owed.to), case .conversation(let mirror) = door,
               NativeAgentChatSessionID.normalizedPathComponent(mirror) == mirror { sessions.insert(mirror) }
        } catch { nativeLog("[approval-chat-card] mirror publication unavailable: %@", error.localizedDescription) }
        await publishTranscriptChanges(sessionIDs: sessions, dataRoot: dataRoot)
    }
}
