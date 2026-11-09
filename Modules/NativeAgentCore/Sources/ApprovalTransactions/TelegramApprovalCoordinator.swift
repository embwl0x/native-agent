import AuthoredCapabilities
import Foundation
import ApprovalInbox
import ChatTurnContracts
import AgentConversations
import ChatToolParsing
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import Privacy
import TurnTrace
import TelegramBot
import TrustCenter
import Experiences
// Blueprint: | `TelegramApprovalCoordinator.swift` | Telegram prompt transactions and the Inbox row's buttons, answers and delivery receipts. |

/// The Inbox face as Telegram reaches it. `row` is a matter's row as the Inbox draws it now: nil when the face drew and holds no such row,
/// thrown when the face could not be read. `act` is the person's tap on one of that row's actions, through the person's Telegram door as
/// the verified sender (`sender`) in the verified chat (`chat`); it returns the act's words or throws its refusal.
public struct TelegramInboxDoor: Sendable {
    public let row: @Sendable (_ matter: String) async throws -> PartFace.Row?
    public let act: @Sendable (_ matter: String, _ action: String, _ chat: String, _ sender: String) async throws -> String?

    public init(row: @escaping @Sendable (_ matter: String) async throws -> PartFace.Row?,
                act: @escaping @Sendable (_ matter: String, _ action: String, _ chat: String, _ sender: String) async throws -> String?) {
        self.row = row
        self.act = act
    }
}

public actor TelegramApprovalFiler: NonBlockingApprovalFiler, TelegramApprovalHandling {
    /// Row creation and delivery are separate: duplicate callers share in-flight delivery, then durable receipts retire the task.
    private var promptDeliveries: [String: Task<Void, Error>] = [:]
    private struct Delivery: Codable, Sendable {
        enum State: String, Codable, Sendable { case dispatching, sent, settled }
        var state: State
        var receipt: [String: JSONValue]?
    }
    /// Returned sends survive failed local receipts. The durable dispatch row fences the process-loss window: an unknown send is never sent again.
    private var returnedDeliveries: [String: Delivery] = [:]

    private var deliveriesPath: URL {
        dataRoot.appendingPathComponent("workflows/approvals/telegram-deliveries.json")
    }

    private nonisolated static func readDeliveries(at path: URL) throws -> [String: Delivery] {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch CocoaError.fileReadNoSuchFile { return [:] }
        let rows = try JSONDecoder().decode([String: Delivery].self, from: data)
        for (key, row) in rows where row.state != .dispatching && row.receipt == nil {
            throw NSError(domain: "TelegramApprovalDelivery", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Telegram delivery \(key) has no returned receipt; repair its delivery ledger before continuing."
            ])
        }
        return rows
    }

    private func saveDelivery(_ row: Delivery, key: String) async throws {
        let path = deliveriesPath
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var rows = try Self.readDeliveries(at: path)
            rows[key] = row
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(rows), to: path)
        }
    }

    private func removeDelivery(key: String) async throws {
        let path = deliveriesPath
        try await SwiftNativePersistenceCore.withFileLock(path) {
            var rows = try Self.readDeliveries(at: path)
            rows.removeValue(forKey: key)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(rows), to: path)
        }
    }

    /// Both prompt kinds use the same send/receipt transaction. Receipt failures repair only the receipt, including after relaunch.
    private func deliverOnce(key: String,
        send: () async throws -> [String: JSONValue],
        saveReceipt: ([String: JSONValue]) async throws -> Void
    ) async throws {
        do {
        let saved: Delivery?
        if let returned = returnedDeliveries[key] { saved = returned }
        else { saved = try Self.readDeliveries(at: deliveriesPath)[key] }
        let receipt: [String: JSONValue]
        if let saved {
            guard saved.state != .dispatching, let returned = saved.receipt else {
                throw NSError(domain: "TelegramApprovalDelivery", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: """
                        Telegram delivery \(key) was dispatched but its outcome is unknown. Check the destination before resolving this delivery; \
                        automatic resend is refused.
                        """
                ])
            }
            if saved.state == .settled { return }
            receipt = returned
        } else {
            try await saveDelivery(.init(state: .dispatching), key: key)
            do { receipt = try await send() }
            catch where TelegramAPIFailure.isKnownNotDelivered(error) {
                // Nothing reached Telegram: the fence lifts and a later send may try again.
                try await removeDelivery(key: key)
                throw error
            }
            returnedDeliveries[key] = .init(state: .sent, receipt: receipt)
        }
        try await saveDelivery(.init(state: .sent, receipt: receipt), key: key)
        try await saveReceipt(receipt)
        try await saveDelivery(.init(state: .settled, receipt: receipt), key: key)
        returnedDeliveries[key] = nil
        await RepairOwed.settle(dataRoot, operation: "telegram.delivery:" + key,
            evidence: .init(source: "workflows/approvals/telegram-deliveries.json", id: key)).value
        } catch {
            await RepairOwed.owe(dataRoot, id: "telegram.delivery:" + key, kind: .act,
                operation: "telegram.delivery:" + key, owner: "TelegramApprovalFiler",
                words: error.localizedDescription,
                lever: """
                    Repair delivery storage, then recover this send's receipt without resending. A dispatch without a returned result requires \
                    destination inspection.
                    """).value
            throw error
        }
    }

    private func saveInteractionReceipt(_ fields: [String: JSONValue], id: String, dataRoot: URL) async throws {
        guard let chat = fields["telegram_chat_id"]?.stringValue, let message = fields["telegram_message_id"]?.stringValue,
              let matter = try await ApprovalChatCards.interactionMatter(id, dataRoot: dataRoot),
              let owed = matter.owes[Door.telegram(chat: "", thread: nil).key],
              let door = Door(address: owed.to), case .telegram(let destination, _) = door, destination == chat else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try await acceptPrompt(matter.id, door: door, message: message, dataRoot: dataRoot)
    }

    private func acceptPrompt(_ id: String, door: Door, message: String, dataRoot: URL) async throws {
        let forPerson = ForPerson.at(dataRoot)
        let evidence = Experience.Ref(source: door.address, id: message)
        try await forPerson.accepted(id, door, evidence: evidence)
        guard try await forPerson.matter(id)?.owes[door.key]?.evidence == evidence else {
            let words = "The prompt returned, but its door did not retain the receipt. Recover the returned result; do not resend."
            throw NotificationDeliveryFailure(.unknown(sent: true, reason: words), words)
        }
    }

    /// A performed send owns its identity even after the source card closes. This path only consumes returned results; it cannot send a new prompt.
    func recoverInteractionReceipt(id: String, dataRoot: URL) async throws {
        var rows = try Self.readDeliveries(at: deliveriesPath)
        rows.merge(returnedDeliveries) { _, returned in returned }
        for (key, row) in rows where key.hasPrefix("interaction:" + id + ":") && row.state != .settled {
            try await deliverOnce(key: key, send: {
                throw NSError(domain: "TelegramApprovalDelivery", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: "Receipt recovery has no returned send result; no prompt was sent."
                ])
            }, saveReceipt: { fields in
                try await self.saveInteractionReceipt(fields, id: id, dataRoot: dataRoot)
            })
        }
    }
    private var promptFlights: [(id: UUID, metadata: JSONValue, task: Task<String, Error>)] = []
    private var acceptingPassiveDelivery = true
    private var recoveryStarted = false
    private var recoveryID: UUID?
    private var recoveryTask: Task<Void, Never>?

    public func startApprovalDelivery() {
        // A stopped tick carries cancellation across this actor hop and can never reopen admission; a new scheduler lifecycle can start again.
        guard !recoveryStarted, !Task.isCancelled else { return }
        recoveryStarted = true
        acceptingPassiveDelivery = true
        ApprovalChatCards.useTelegram(self)
        let previous = recoveryTask
        let identity = UUID()
        recoveryID = identity
        recoveryTask = Task {
            await previous?.value
            if !Task.isCancelled { await ApprovalChatCards.promptPending(dataRoot: dataRoot, telegram: self) }
            await settle { [self] in await retireRecovery(identity) }
        }
    }

    private func retireRecovery(_ id: UUID) {
        if recoveryID == id { recoveryTask = nil; recoveryID = nil }
    }

    public func stopApprovalDelivery() async {
        acceptingPassiveDelivery = false
        recoveryStarted = false
        recoveryTask?.cancel()
        ApprovalChatCards.stopTelegram(self)
        let recovery = recoveryTask
        let flights = promptFlights.map(\.task)
        let deliveries = Array(promptDeliveries.values)
        await settle { [self] in
            await recovery?.value
            for flight in flights { _ = await flight.result }
            for delivery in deliveries { _ = await delivery.result }
            await drainInteractionSettlements()
        }
    }

    private func drainInteractionSettlements() async {
        for delivery in interactionSettlements.values { await delivery.value }
    }
    private var interactionSettlements: [String: Task<Void, Never>] = [:]
    private var changedInteractionSettlements: Set<String> = []

    /// Admission precedes the note read and edit. The filer retains accepted delivery through its receipt; callers publishing a card never join it.
    func enqueueInteractionSettlement(id: String, sessionID: String, dataRoot: URL) -> Task<Void, Never> {
        let key = dataRoot.standardizedFileURL.path + ":" + id
        if let delivery = interactionSettlements[key] {
            changedInteractionSettlements.insert(key)
            return delivery
        }
        let delivery = Task {
            await settle { [self] in
                await finishInteractionSettlement(key: key, id: id, sessionID: sessionID, dataRoot: dataRoot)
            }
        }
        interactionSettlements[key] = delivery
        return delivery
    }

    private func finishInteractionSettlement(key: String, id: String, sessionID: String, dataRoot: URL) async {
        defer {
            interactionSettlements[key] = nil
            changedInteractionSettlements.remove(key)
        }
        repeat {
            changedInteractionSettlements.remove(key)
            await ApprovalChatCards.settleTelegramCopy(id: id, sessionID: sessionID, dataRoot: dataRoot, filer: self)
        } while changedInteractionSettlements.contains(key)
    }

    /// Sends an approval's prompt with its card's buttons (`buttons`, rows of an inline keyboard).
    public typealias PromptSender = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ approval: ApprovalRecord,
        _ buttons: [JSONValue]
    ) async throws -> Int

    private let dataRoot: URL
    private let token: String
    private let promptSender: PromptSender
    /// The Inbox face, where every card's buttons come from and every answer goes.
    nonisolated let inbox: TelegramInboxDoor

    public typealias CardSender = @Sendable (
        _ token: String, _ destination: TelegramDestination, _ text: String, _ replyMarkup: JSONValue
    ) async throws -> Int
    private let cardSender: CardSender

    public init(
        dataRoot: URL,
        token: String,
        promptSender: @escaping PromptSender,
        inbox: TelegramInboxDoor,
        cardSender: @escaping CardSender = TelegramPollLoop.defaultSendConsentWithReplyMarkupReturningId
    ) {
        self.dataRoot = dataRoot
        self.token = token
        self.promptSender = promptSender
        self.inbox = inbox
        self.cardSender = cardSender
    }

    /// The Telegram door among the person's doors: an action whose `doors` leave it out is neither drawn on Telegram nor accepted from it.
    public static let door = "telegram"

    /// Telegram offers its owner's row actions, one per line; oversized callback ids are reported and omitted.
    static func buttons(_ row: PartFace.Row, dataRoot: URL) throws -> [JSONValue] {
        guard try ApprovalChatCards.ownerDM(dataRoot: dataRoot) != nil else { return [] }
        return (row.actions ?? []).filter { $0.call != nil && $0.runs(from: door) }.compactMap { action in
            let data = TelegramApprovalCommand.callbackPrefix + action.id
            guard data.utf8.count <= TelegramApprovalCommand.callbackLimit else {
                nativeLog("[telegram-card] %@ on %@ is too long for a Telegram button; not offered there", action.id, row.id)
                return nil
            }
            return .array([.object(["text": .string(NativeAppSecretRedactor.redactText(action.label)), "callback_data": .string(data)])])
        }
    }

    /// The matter's row as the Inbox draws it now; a face that drew without it leaves nothing to send.
    nonisolated func cardRow(_ matter: String) async throws -> PartFace.Row {
        let read: PartFace.Row?
        do { read = try await inbox.row(matter) } catch {
            let words = "The Inbox could not be read (\(error.localizedDescription)); no Telegram card was sent."
            throw NotificationDeliveryFailure(.notDelivered(reason: words), words)
        }
        guard let row = read else {
            let words = "The Inbox has no row for \(matter); no Telegram card was sent."
            throw NotificationDeliveryFailure(.notDelivered(reason: words), words)
        }
        return row
    }

    /// The person's answer from an allowlisted sender, in a chat the card was sent to: a button answers the matter whose card is that very
    /// message (its Telegram door's accepted receipt), a slash command the matter it names when its Telegram door is this chat. The row's
    /// action then runs through the person's Telegram door as that sender, in that chat; the card's owner verifies the sender for its own
    /// decision. The answer reports whether the row offers anything more on Telegram.
    public func act(_ command: TelegramApprovalCommand, chatId: Int, messageId: Int?, fromUserId: Int?) async -> TelegramApprovalResolution {
        let chat = String(chatId)
        let key = Door.telegram(chat: "", thread: nil).key
        func sentHere(_ matter: Experience) -> Bool {
            guard let owed = matter.owes[key], let door = Door(address: owed.to), case .telegram(let destination, _) = door,
                  destination == chat else { return false }
            guard let messageId else { return true }
            return owed.evidence == Experience.Ref(source: door.address, id: String(messageId))
        }
        let found: Experience?
        do {
            let forPerson = ForPerson.at(dataRoot)
            if let id = command.matter { found = try await forPerson.matter(id).flatMap { sentHere($0) ? $0 : nil } }
            else { found = try await forPerson.matters().first(where: sentHere) }
        } catch {
            return .init(acknowledgement: "The card's matter could not be read: \(error.localizedDescription) Nothing changed.", settled: nil)
        }
        guard let matter = found else {
            return .init(acknowledgement: "No card here answers that; nothing changed.", settled: nil)
        }
        guard let fromUserId else {
            return .init(acknowledgement: TelegramApprovalError.missingUserIdentity.localizedDescription, settled: nil)
        }
        let words: String
        do { words = try await inbox.act(matter.id, command.action, chat, String(fromUserId)) ?? "Done." }
        catch { words = error.localizedDescription }
        do {
            guard let row = try await inbox.row(matter.id) else { return .init(acknowledgement: words, settled: true) }
            return .init(acknowledgement: words, settled: try Self.buttons(row, dataRoot: dataRoot).isEmpty)
        } catch {
            return .init(acknowledgement: words, settled: nil)
        }
    }

    /// One admitted send owns its response and durable receipt independently of the observer that requested it. Transcript delivery is a separate unit.
    func deliverChatCard(id: String, sessionID: String, dataRoot: URL,
                         text: String, chatId: Int, threadId: String?, markup: JSONValue) async throws {
        guard acceptingPassiveDelivery else { throw CancellationError() }
        try Task.checkCancellation()
        let key = "interaction:" + id
        if let delivery = promptDeliveries[key] { return try await delivery.value }
        let delivery = Task {
            try await settle { [self] in
                await sendInteraction(id: id, sessionID: sessionID, dataRoot: dataRoot,
                                      text: text, chatId: chatId, threadId: threadId, markup: markup)
            }.get()
        }
        promptDeliveries[key] = delivery
        try await delivery.value
    }

    private func sendInteraction(id: String, sessionID: String, dataRoot: URL,
                                 text: String, chatId: Int, threadId: String?, markup: JSONValue) async -> Result<Void, Error> {
        defer { promptDeliveries["interaction:" + id] = nil }
        do {
            try await recoverInteractionReceipt(id: id, dataRoot: dataRoot)
            guard let matter = try await ApprovalChatCards.interactionMatter(id, dataRoot: dataRoot),
                  matter.owes[Door.telegram(chat: "", thread: nil).key]?.phase != .accepted,
                  let card = try await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
                  card.state.isOpen else { return .success(()) }
            guard acceptingPassiveDelivery else { return .success(()) }
            let topic = threadId.flatMap(Int.init)
            guard threadId == nil || topic != nil else {
                throw NotificationDeliveryFailure(.notDelivered(reason: "The request has an invalid Telegram topic"),
                    "The request has an invalid Telegram topic; no prompt was sent into General.")
            }
            try await deliverOnce(key: "interaction:\(id):\(chatId)", send: {
                let messageID = try await self.cardSender(self.token, TelegramDestination(chatId: chatId, threadId: topic), text, markup)
                return ["telegram_chat_id": .string(String(chatId)), "telegram_message_id": .string(String(messageID))]
            }, saveReceipt: { fields in
                try await self.saveInteractionReceipt(fields, id: id, dataRoot: dataRoot)
            })
            await enqueueInteractionSettlement(id: id, sessionID: sessionID, dataRoot: dataRoot).value
            return .success(())
        } catch { return .failure(error) }
    }

    public func settleChatCard(chatId: Int, messageId: Int, text: String) async throws {
        try await TelegramPollLoop.defaultEditMessageTextWithReplyMarkup(
            token, chatId, messageId, text, .object(["inline_keyboard": .array([])]))
    }

    public func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String,
        turn: Turn
    ) async throws -> String {
        guard acceptingPassiveDelivery else { throw CancellationError() }
        try Task.checkCancellation()
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        guard let chatIdString = envelope.verifiedChatId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let chatId = Int(chatIdString) else {
            throw TelegramApprovalError.missingChatId
        }
        let sessionId = turn.verifiedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = NativeAgentChatApprovalFiler.requestPayload(
            toolName: toolName, surface: surface, payload: payload, turn: turn,
            telegram: .object([
                "chatId": .string(chatIdString),
                "threadId": Self.nonEmptyStringValue(envelope.replyRoute.threadId),
                "sessionId": Self.nonEmptyStringValue(sessionId),
            ]))
        // Reserve the complete request before the first suspension, including inbox creation. Every duplicate awaits the same delivery or failure.
        if let flight = promptFlights.first(where: { NativeAgentChatApprovalFiler.isSameRequest($0.metadata, metadata) }) {
            return try await flight.task.value
        }
        let flightID = UUID()
        let task = Task { [turn] in
            let result: Result<String, Error>
            do {
                result = .success(try await createAndPrompt(metadata: metadata,
                                                           reason: reason, chatId: chatId, turn: turn))
            } catch { result = .failure(error) }
            await settle { [self] in await retireFlight(flightID) }
            return try result.get()
        }
        promptFlights.append((flightID, metadata, task))
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func retireFlight(_ id: UUID) { promptFlights.removeAll { $0.id == id } }

    private func createAndPrompt(metadata: JSONValue,
                                 reason: String, chatId: Int, turn: Turn) async throws -> String {
        let record = try await settle { [dataRoot, turn] in
            do {
                return Result<ApprovalRecord, Error>.success(try await NativeAgentChatApprovalFiler(dataRoot: dataRoot)
                    .fileRequest(metadata, reason: reason, turn: turn))
            } catch { return .failure(error) }
        }.get()
        do {
            // The person is talking to the agent in this Telegram turn; its answerable prompt is not an unattended quiet-hours interruption.
            try await deliverPrompt(record, chatId: chatId)
        } catch {
            throw AutonomyGateError.notRun(.approvalDeliveryFailed)
        }
        return record.id
    }

    public func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String,
        turn: Turn
    ) async -> JSONValue {
        ToolNotRunStatus.approvalFiled.reporting(.object([
            "status": .string("waiting_approval"),
            "approvalId": .string(id),
            "tool": .string(toolName),
            "surface": .string(surface),
            "reason": .string(reason),
        ]), location: "Telegram")
    }

    /// A durable per-destination receipt retires prompt delivery into the owner DM.
    public func promptChatCard(_ approval: ApprovalRecord, chatId: Int) async throws {
        guard acceptingPassiveDelivery else { throw CancellationError() }
        try Task.checkCancellation()
        try await deliverPrompt(approval, chatId: chatId)
    }

    private func deliverPrompt(_ approval: ApprovalRecord, chatId: Int) async throws {
        try Task.checkCancellation()
        let key = "\(approval.id):\(chatId)"
        if let delivery = promptDeliveries[key] { return try await delivery.value }
        let delivery = Task {
            try await settle { [self] in
                await sendPrompt(approval, chatId: chatId)
            }.get()
        }
        promptDeliveries[key] = delivery
        try await delivery.value
    }

    private func sendPrompt(_ approval: ApprovalRecord, chatId: Int) async -> Result<Void, Error> {
        defer { promptDeliveries["\(approval.id):\(chatId)"] = nil }
        do {
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            let current = try await inbox.get(approval.id)
            let receipt = "telegram_prompt_delivered:\(chatId)"
            let owner = try ApprovalChatCards.ownerDM(dataRoot: dataRoot)
            guard current.status == "pending" else { return .success(()) }
            let forPerson = ForPerson.at(dataRoot)
            guard let matter = try await forPerson.matter(approval.id),
                  let owed = matter.owes[Door.telegram(chat: "", thread: nil).key],
                  let door = Door(address: owed.to), case .telegram(let destination, _) = door,
                  destination == String(chatId) else {
                throw NotificationDeliveryFailure(.notDelivered(reason: "The approval has no matching Telegram door"),
                    "The approval has no matching Telegram door; no prompt was sent.")
            }
            if owed.phase == .accepted { return .success(()) }
            guard acceptingPassiveDelivery else { return .success(()) }
            if Self.telegramChatId(current.payload) == String(chatId), case .malformed(let detail) = Self.recordedTopic(current.payload) {
                let words = "The approval's Telegram topic is unreadable (\(detail)); no prompt was sent into General."
                throw NotificationDeliveryFailure(.notDelivered(reason: words), words)
            }
            // The card's buttons are its Inbox row's: the approval's matter is the approval's own id.
            let buttons = try await Self.buttons(cardRow(approval.id), dataRoot: dataRoot)
            // Once dispatched, Stop ends further admission, never this send's response or receipt.
            var mark: [String: JSONValue] = [receipt: .bool(true)]
            if chatId == owner {
                mark["telegramPromptedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                if !approval.requiresExecutableReview { mark["telegramChatId"] = .string(String(chatId)) }
            }
            let receiptFields = mark
            try await deliverOnce(key: "approval:\(approval.id):\(chatId)", send: {
                let message = try await self.promptSender(self.token, chatId, approval, buttons)
                return receiptFields.merging(["messageId": .string(String(message))]) { _, new in new }
            }, saveReceipt: { fields in
                guard let message = fields["messageId"]?.stringValue else { throw CocoaError(.fileReadCorruptFile) }
                try await self.acceptPrompt(approval.id, door: door, message: message, dataRoot: self.dataRoot)
                try await inbox.markChatCard(approval.id, fields)
            })
            return .success(())
        } catch { return .failure(error) }
    }

    /// Missing/null/blank means General; numeric or string topic ids must convert exactly to Int or stay malformed.
    enum RecordedTopic: Equatable {
        case absent
        case topic(Int)
        case malformed(String)
    }

    /// Chat-tool prompts keep their Telegram envelope; live ACP questions keep the originating turn's route.
    private static func promptOrigin(_ payload: JSONValue) -> [String: JSONValue]? {
        guard let fields = payload.objectValue else { return nil }
        guard fields["kind"] == .string("agent_acp_live_approval") else { return fields["telegram"]?.objectValue }
        // A live ACP question's origin is a Telegram route only when its turn came from Telegram (a Slack thread is not a Telegram topic).
        guard let origin = fields["origin"]?.objectValue, origin["surface"] == .string("telegram") else { return nil }
        return origin
    }

    static func recordedTopic(_ payload: JSONValue) -> RecordedTopic {
        guard let telegram = promptOrigin(payload) else { return .absent }
        switch telegram["threadId"] {
        case .none, .null?: return .absent
        case .int(let value)?:
            if let topic = Int(exactly: value) { return .topic(topic) }
            return .malformed("integer outside Int")
        case .double(let value)?:
            if value.isFinite, value.rounded(.towardZero) == value, let topic = Int(exactly: value) {
                return .topic(topic)
            }
            return .malformed("non-integral or out-of-range number")
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .absent }
            if let topic = Int(trimmed) { return .topic(topic) }
            return .malformed("non-numeric string")
        case .bool?, .array?, .object?: return .malformed("wrong JSON type")
        }
    }

    private static func telegramThreadId(_ payload: JSONValue) -> Int? {
        if case .topic(let topic) = recordedTopic(payload) { return topic }
        return nil
    }

    private static func telegramChatId(_ payload: JSONValue) -> String? {
        guard let telegram = promptOrigin(payload) else { return nil }
        let key = payload.objectValue?["kind"] == .string("agent_acp_live_approval") ? "destinationId" : "chatId"
        switch telegram[key] {
        case .string(let value)?: return value
        case .int(let value)?: return String(value)
        case .double(let value)?: return Int(exactly: value.rounded(.towardZero)).map { String($0) }
        default: return nil
        }
    }

    /// The card's words on Telegram are its matter's: the act, why it asks, and what will happen, never the call's envelope.
    static func approvalPromptText(approval: ApprovalRecord) -> String {
        func redacted(_ text: String) -> String {
            TurnSecretRedactor.redactText(NativeAppSecretRedactor.redactText(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let matter = approval.matter
        let why = redacted(matter.summary), says = redacted(matter.words)
        let card = [redacted(matter.title), why, says == why ? "" : says].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return card + "\n\nYou can also reply with /approve \(approval.id) or /deny \(approval.id)."
    }

    public static func sendTelegramApprovalPrompt(
        token: String,
        chatId: Int,
        approval: ApprovalRecord,
        buttons: [JSONValue],
        send: @Sendable (String, TelegramDestination, String, JSONValue) async throws -> Int
    ) async throws -> Int {
        // Executable code is decided where the whole saved review shows.
        if approval.requiresExecutableReview {
            return try await send(token, TelegramDestination(chatId: chatId, threadId: nil),
                           """
                               \(TurnSecretRedactor.redactText(NativeAppSecretRedactor.redactText(approval.title))) Review and approve it on the Mac \
                               or phone, where the whole script shows.
                               """,
                           .object(["inline_keyboard": .array([])]))
        }
        let text = approvalPromptText(approval: approval)
        // The card's buttons are its matter's Inbox row actions (`buttons`), each answered through that row.
        let replyMarkup: JSONValue = .object(["inline_keyboard": .array(buttons)])
        return try await send(
            token,
            // Topic ids belong only to their origin chat; owner-DM mirrors must be unthreaded.
            TelegramDestination(
                chatId: chatId,
                threadId: telegramChatId(approval.payload) == String(chatId)
                    ? Self.telegramThreadId(approval.payload) : nil
            ),
            text,
            replyMarkup
        )
    }

    private static func nonEmptyStringValue(_ raw: String?) -> JSONValue {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return .null
        }
        return .string(trimmed)
    }

}

private enum TelegramApprovalError: LocalizedError {
    case missingChatId
    case missingUserIdentity

    var errorDescription: String? {
        switch self {
        case .missingChatId:
            return "Telegram approval could not determine the verified chat id."
        case .missingUserIdentity:
            return "Telegram approval could not determine the verified user identity."
        }
    }
}
