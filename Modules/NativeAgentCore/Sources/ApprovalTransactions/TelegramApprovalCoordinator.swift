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
// Blueprint: | `TelegramApprovalCoordinator.swift` | Prompt transactions retain unknown sends; returned message receipts accept the matter's Telegram door |

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

    public typealias PromptSender = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ approval: ApprovalRecord,
        _ toolName: String,
        _ payload: JSONValue
    ) async throws -> Int
    public typealias ApprovalResolver = @Sendable (
        _ id: String,
        _ decision: ApprovalDecision,
        _ provenance: ApprovalResolutionProvenance
    ) async throws -> Void

    private let dataRoot: URL
    private let token: String
    private let promptSender: PromptSender
    private let approvalResolver: ApprovalResolver

    public typealias CardSender = @Sendable (
        _ token: String, _ destination: TelegramDestination, _ text: String, _ replyMarkup: JSONValue
    ) async throws -> Int
    private let cardSender: CardSender

    public init(
        dataRoot: URL,
        token: String,
        promptSender: @escaping PromptSender,
        approvalResolver: @escaping ApprovalResolver,
        cardSender: @escaping CardSender = TelegramPollLoop.defaultSendMessageWithReplyMarkupReturningId
    ) {
        self.dataRoot = dataRoot
        self.token = token
        self.promptSender = promptSender
        self.approvalResolver = approvalResolver
        self.cardSender = cardSender
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
                result = .success(try await createAndPrompt(metadata: metadata, toolName: toolName,
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

    private func createAndPrompt(metadata: JSONValue, toolName: String,
                                 reason: String, chatId: Int, turn: Turn) async throws -> String {
        let record = try await settle { [dataRoot, turn] in
            do {
                return Result<ApprovalRecord, Error>.success(try await NativeAgentChatApprovalFiler(dataRoot: dataRoot)
                    .fileRequest(metadata, reason: reason, turn: turn))
            } catch { return .failure(error) }
        }.get()
        do {
            guard case .object(let request) = metadata, let payload = request["input"] else {
                preconditionFailure("Invalid chat approval request")
            }
            // The person is talking to the agent in this Telegram turn; its answerable prompt is not an unattended quiet-hours interruption.
            try await deliverPrompt(record, chatId: chatId, toolName: toolName, payload: payload)
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

    public func resolveTelegramApproval(
        id: String,
        decision: TelegramApprovalDecision,
        choice: Int?,
        chatId: Int,
        fromUserId: Int?
    ) async throws -> TelegramApprovalResolution {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let pending: ApprovalRecord
        do {
            pending = try await inbox.get(id)
        } catch ApprovalInboxError.notFound {
            // Not an approval: a mirrored inline card's button, answered on its original.
            guard let answer = try await ApprovalChatCards.answerInteractionFromTelegram(
                id: id, choice: choice, decline: decision == .denied,
                chatId: chatId, fromUserId: fromUserId, dataRoot: dataRoot) else {
                throw ApprovalInboxError.notFound(id)
            }
            return TelegramApprovalResolution(acknowledgement: answer)
        }
        let nativeDecision: ApprovalDecision = decision == .approved ? .approved : .denied
        // The shared owner may still hold a returned result whose receipt failed to save. A matching late tap reaches its receipt-only repair; a settled
        // request reports the canonical decision or expiry.
        if pending.status != "pending", Self.answers(pending, chatId: chatId) {
            if pending.status == "resolved", pending.decision == nativeDecision.rawValue {
                try validateTelegramDecision(record: pending, chatId: chatId, expectedStatus: "resolved")
                guard let fromUserId else { throw TelegramApprovalError.missingUserIdentity }
                do {
                    try await approvalResolver(id, nativeDecision,
                        .telegram(chatID: String(chatId), userID: String(fromUserId)))
                    return TelegramApprovalResolution(acknowledgement: "Saved the execution receipt for \(pending.action); the action was not run again.")
                } catch ApprovalInboxError.alreadyResolved {
                    // Nothing remains with the execution owner to repair.
                }
            }
            let approval = ApprovalRequest(id: pending.id, title: pending.title, action: pending.action,
                risk: pending.risk, status: pending.status, decision: pending.decision)
            let message = approval.expirationGuidance(agentName: PersonaCompiler.agentDisplayName(dataRoot: dataRoot))
                .map { approval.decisionSummary + ". " + $0 }
                ?? (approval.decisionSummary + " — nothing changed.")
            return TelegramApprovalResolution(acknowledgement: message)
        }
        try validateTelegramDecision(record: pending, chatId: chatId)
        guard let fromUserId else {
            throw TelegramApprovalError.missingUserIdentity
        }

        try await approvalResolver(
            id,
            nativeDecision,
            .telegram(chatID: String(chatId), userID: String(fromUserId))
        )

        // The shared resolver owns execution, receipts and reporting on every surface. Telegram carries the decision and acknowledges its tap.
        return TelegramApprovalResolution(acknowledgement: decision == .approved
            ? "Approved \(pending.action)." : ToolNotRunStatus.personDenied.sentence())
    }

    private func validateTelegramDecision(record: ApprovalRecord, chatId: Int, expectedStatus: String = "pending") throws {
        guard record.status == expectedStatus else {
            throw TelegramApprovalError.notPending(record.status)
        }
        guard !record.requiresExecutableReview else { throw TelegramApprovalError.notRemoteResolvable }
        // The bound owner DM has paired-phone authority, including local-only cards; other chats remain remote-safe only.
        guard Self.cardChat(record) == String(chatId) || (record.remoteResolvable && !record.localOnly) else {
            throw TelegramApprovalError.notRemoteResolvable
        }
        guard Self.answers(record, chatId: chatId) else {
            throw TelegramApprovalError.chatMismatch
        }
        // Both first decisions and receipt repair preserve the recorded route.
        if case .malformed(let why) = Self.recordedTopic(record.payload) {
            throw NSError(
                domain: "TelegramApprovalFiler", code: -3,
                userInfo: [NSLocalizedDescriptionKey:
                    "approval \(record.id) records an unreadable topic id (\(why)); refusing to resume it into General"]
            )
        }
    }

    /// Retain both the originating chat and the delivered owner-DM binding so either can answer the same approval.
    private static func answers(_ record: ApprovalRecord, chatId: Int) -> Bool {
        telegramChatId(record.payload) == String(chatId) || cardChat(record) == String(chatId)
    }

    private static func cardChat(_ record: ApprovalRecord) -> String? {
        guard case .object(let card)? = record.chatCard, case .string(let chat)? = card["telegramChatId"] else { return nil }
        return chat
    }

    /// A durable per-destination receipt retires prompt delivery into the owner DM.
    public func promptChatCard(_ approval: ApprovalRecord, chatId: Int, payload: JSONValue) async throws {
        guard acceptingPassiveDelivery else { throw CancellationError() }
        try Task.checkCancellation()
        try await deliverPrompt(approval, chatId: chatId, toolName: approval.action, payload: payload)
    }

    private func deliverPrompt(_ approval: ApprovalRecord, chatId: Int, toolName: String, payload: JSONValue) async throws {
        try Task.checkCancellation()
        let key = "\(approval.id):\(chatId)"
        if let delivery = promptDeliveries[key] { return try await delivery.value }
        let delivery = Task {
            try await settle { [self] in
                await sendPrompt(approval, chatId: chatId, toolName: toolName, payload: payload)
            }.get()
        }
        promptDeliveries[key] = delivery
        try await delivery.value
    }

    private func sendPrompt(_ approval: ApprovalRecord, chatId: Int, toolName: String,
                            payload: JSONValue) async -> Result<Void, Error> {
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
            // Once dispatched, Stop ends further admission, never this send's response or receipt.
            var mark: [String: JSONValue] = [receipt: .bool(true)]
            if chatId == owner {
                mark["telegramPromptedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                if !approval.requiresExecutableReview { mark["telegramChatId"] = .string(String(chatId)) }
            }
            let receiptFields = mark
            try await deliverOnce(key: "approval:\(approval.id):\(chatId)", send: {
                let message = try await self.promptSender(self.token, chatId, approval, toolName, payload)
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

    private static func preview(_ value: JSONValue) -> String {
        let redacted = NativeAppSecretRedactor.redactArguments(value).mapStrings(TurnSecretRedactor.redactText)
        let raw = (try? redacted.serialize(pretty: false)) ?? String(describing: redacted)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1400 else { return trimmed }
        return String(trimmed.prefix(1400)) + "..."
    }

    static func approvalPromptText(
        approval: ApprovalRecord,
        toolName: String,
        payload: JSONValue
    ) -> String {
        let heading = approval.title.isEmpty || approval.title == "Approve \(toolName)"
            ? "Approval required: \(ToolActivityPresentation.title(toolName))" : approval.title
        func redacted(_ text: String) -> String { TurnSecretRedactor.redactText(NativeAppSecretRedactor.redactText(text)) }
        let reason = ToolActivityPresentation.approvalText(approval.reason, tool: toolName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve a filer's readable review text; tool approvals still expose their arguments.
        let readable = redacted(approval.readableAsk)
        let body = approval.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !readable.isEmpty
            ? (readable.count > 1400 ? String(readable.prefix(1400)) + "..." : readable)
            : Self.preview(payload)
        var lines = [redacted(heading), "ID: \(approval.id)"]
        if !reason.isEmpty { lines.append("Reason: \(redacted(reason))") }
        lines += ["", body, "", "You can also reply with /approve \(approval.id) or /deny \(approval.id)."]
        return lines.joined(separator: "\n")
    }

    public static func sendTelegramApprovalPrompt(
        token: String,
        chatId: Int,
        approval: ApprovalRecord,
        toolName: String,
        payload: JSONValue,
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
        let text = approvalPromptText(approval: approval, toolName: toolName, payload: payload)
        let replyMarkup: JSONValue = .object([
            "inline_keyboard": .array([
                .array([
                    .object([
                        "text": .string("Approve"),
                        "callback_data": .string("na_approval:approve:\(approval.id)"),
                    ]),
                    .object([
                        "text": .string("Deny"),
                        "callback_data": .string("na_approval:deny:\(approval.id)"),
                    ]),
                ]),
            ]),
        ])
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
    case notPending(String)
    case notRemoteResolvable
    case missingUserIdentity
    case chatMismatch

    var errorDescription: String? {
        switch self {
        case .missingChatId:
            return "Telegram approval could not determine the verified chat id."
        case .notPending(let status):
            return "Approval is not pending (status: \(status))."
        case .notRemoteResolvable:
            return "Approval is local-only and cannot be resolved from Telegram."
        case .missingUserIdentity:
            return "Telegram approval could not determine the verified user identity."
        case .chatMismatch:
            return "Approval belongs to a different Telegram chat."
        }
    }
}
