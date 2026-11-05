import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import Experiences
import PersistenceCore
import Privacy
import TelegramBot
// Blueprint: | `ApprovalChatCards+Interactions.swift` | Conversation mirrors and Telegram receipts read the matter's doors; every answer settles the origin |

extension ApprovalChatCards {
    public static let interactionMirrorKind = "interaction_mirror"

    /// Keys and tokens stay on encrypted controls; a pick can have Telegram buttons, other controls have guidance.
    static func telegramReach(_ card: InlineInteraction) -> (send: Bool, buttons: Bool) {
        switch card.kind {
        case .choose, .modelChoice: (true, true)
        case .permission, .capability: (true, false)
        case .connector, .apiKey, .unknown: (false, false)
        }
    }

    @discardableResult
    public static func postInteraction(_ card: InlineInteraction, sessionID: String, dataRoot: URL) async -> Outcome {
        guard card.state.isOpen, !Task.isCancelled else { return .skipped }
        do {
            let forPerson = ForPerson.at(dataRoot)
            guard let matter = try await interactionMatter(card.id, dataRoot: dataRoot),
                  let owed = matter.owes[Door.conversation("").key], !owed.phase.isSettled,
                  let door = Door(address: owed.to), case .conversation(let anchor) = door,
                  NativeAgentChatSessionID.normalizedPathComponent(anchor) == anchor else { return .skipped }
            let rowID = "interaction-mirror-" + card.id
            let row: JSONValue = .object([
                "id": .string(rowID), "sessionId": .string(anchor), "role": .string("tool"),
                "content": .string([card.title, card.why].map(NativeAppSecretRedactor.redactText).filter { !$0.isEmpty }.joined(separator: "\n")),
                "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                "source": .string("interaction"), "runId": .string(rowID),
                "metadata": .object(["kind": .string(interactionMirrorKind), "toolName": .string("request_interaction"),
                    "interactionId": .string(card.id), "interactionSessionId": .string(sessionID)]),
            ])
            let written: Result<Void, Error> = await settle {
                do {
                    try await appendRow(row, sessionID: anchor, dataRoot: dataRoot, uniqueRunID: rowID)
                    try await forPerson.accepted(matter.id, door, evidence: .init(source: Matter.messages(anchor), id: rowID))
                    return .success(())
                } catch { return .failure(error) }
            }
            try written.get()
            return .posted(anchor)
        } catch {
            nativeLog("[approval-chat-card] mirror write failed: %@", error.localizedDescription)
            return .failed
        }
    }

    /// The router calls the same prompt transaction as recovery; a Telegram door gets one prompt, never a second text alert.
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
            let reach = telegramReach(card)
            guard reach.send else {
                try await ForPerson.at(dataRoot).letGo(matter.id, door, .cancelled)
                return .suppressed(preference: "This request uses encrypted Mac or phone controls")
            }
            guard let telegram = runningTelegram else { return .notDelivered(reason: "The Telegram approval sender is not running") }
            let picks = card.options.enumerated().filter { !isControlOption($0.element.id) }
            let buttons = reach.buttons && !picks.isEmpty
            var keyboard: [JSONValue] = buttons ? picks.prefix(8).map { index, option in
                .array([.object(["text": .string(NativeAppSecretRedactor.redactText(option.label)),
                    "callback_data": .string("na_approval:c\(index):\(card.id)")])])
            } : []
            if buttons {
                keyboard.append(.array([.object(["text": .string("Not now"), "callback_data": .string("na_approval:deny:\(card.id)")])]))
            }
            let title = NativeAppSecretRedactor.redactText(card.title)
            let guidance = card.kind == .modelChoice ? "Choose the model in Providers on the Mac." : "Answer it on the Mac."
            let text = [title, NativeAppSecretRedactor.redactText(card.why), buttons ? "" : guidance]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
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

    static func isControlOption(_ id: String) -> Bool { id.hasPrefix("__") }

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
    public static func useTelegram(_ filer: TelegramApprovalFiler?) { telegramFiler.withLock { $0 = filer } }
    static func stopTelegram(_ filer: TelegramApprovalFiler) { telegramFiler.withLock { if $0 === filer { $0 = nil } } }

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

    static func answerInteractionFromTelegram(id: String, choice: Int?, decline: Bool, chatId: Int,
        fromUserId: Int?, dataRoot: URL) async throws -> String? {
        guard let matter = try await interactionMatter(id, dataRoot: dataRoot), let session = interactionSession(matter) else { return nil }
        let origin = try await InlineInteractionResolver.originEnvelope(of: id, sessionID: session, dataRoot: dataRoot)
        guard let owed = matter.owes[Door.telegram(chat: "", thread: nil).key],
              let door = Door(address: owed.to), case .telegram(let chat, _) = door,
              chat == String(chatId), let fromUserId, origin?.verifiedUserId == String(fromUserId) else {
            throw NSError(domain: "ApprovalChatCards", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "That card is answered by its owner in the owner's own chat."])
        }
        guard let card = try await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: dataRoot) else {
            throw InlineInteractionResolver.ResolveError.notFound
        }
        guard card.state.isOpen else { return "Already answered — nothing changed." }
        if decline {
            _ = try await InlineInteractionResolver.decline(id: id, sessionID: session,
                expectedRevision: card.revision, turn: nil, dataRoot: dataRoot)
            return "Not now — \(card.declineConsequence)"
        }
        guard let choice, card.options.indices.contains(choice), !isControlOption(card.options[choice].id) else {
            return "Pick one of the card's buttons."
        }
        let picked = card.options[choice].id
        let settled = card.kind == .modelChoice
            ? try await InlineInteractionResolver.answerModelChoice(card, sessionID: session, picked: picked,
                scope: card.primaryScope, attribution: "Owner on Telegram",
                controls: { @MainActor in InlineInteractionResolver.platform.interactionControls() }, dataRoot: dataRoot)
            : try await InlineInteractionResolver.complete(id: id, sessionID: session, selection: picked,
                expectedRevision: card.revision, attribution: "Owner on Telegram", turn: nil, dataRoot: dataRoot)
        return settled.state.failureReason ?? "Chose: \(card.options[choice].label)."
    }
}
