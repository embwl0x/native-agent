import AuthoredCapabilities
import Foundation
import ApprovalInbox
import ChatTurnContracts
import AgentConversations
import ChatToolParsing
import MacControl
import NotificationInbox
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import Privacy
import TurnTrace
import TelegramBot
import TrustCenter
// Blueprint: | `TelegramApprovalCoordinator.swift` | `TelegramApprovalFiler` actor; Stop closes prompt admission and drains accepted units through `settle`; approval and inline sends own their response and receipt, independently of transcript mirrors and cancelled callers; recovery covers pending prompts and delivered inline cards missing settlement receipts, honoring resident-wake quiet holds for new inline prompts; matching terminal taps reach the shared resolver for receipt-only repair after identity/routing checks; per-card edits retain their receipts; nonblocking filing leaves resolution and execution to the canonical inbox; expiry guidance names from PersonaEngine |

public actor TelegramApprovalFiler: NonBlockingApprovalFiler, TelegramApprovalHandling {
    /// Telegram prompt deliveries by this process, per approval and chat. Row
    /// creation and prompt delivery are separate steps; a reused pending row
    /// whose prompt never went out is prompted again. A duplicate caller awaits the delivery in flight
    /// and gets its result; durable receipts replace completed delivery tasks.
    private var promptDeliveries: [String: Task<Void, Error>] = [:]
    private var promptFlights: [(id: UUID, metadata: JSONValue, task: Task<String, Error>)] = []
    private var acceptingPassiveDelivery = true
    private var recoveryStarted = false
    private var recoveryID: UUID?
    private var recoveryTask: Task<Void, Never>?

    public func startApprovalDelivery() {
        // A stopped tick carries cancellation across this actor hop and can
        // never reopen admission; a new scheduler lifecycle can start again.
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

    /// Admission precedes the note read and edit. The filer retains accepted
    /// delivery through its receipt; callers publishing a card never join it.
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
    ) async throws -> Void
    public typealias ApprovalResolver = @Sendable (
        _ id: String,
        _ decision: ApprovalDecision,
        _ provenance: ApprovalResolutionProvenance
    ) async throws -> Void

    private let dataRoot: URL
    private let token: String
    private let promptSender: PromptSender
    private let approvalResolver: ApprovalResolver

    /// A plain message with its own keyboard (a mirrored inline card).
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

    /// One admitted send owns its response and durable receipt independently
    /// of the observer that requested it. Transcript delivery is a separate unit.
    func deliverChatCard(id: String, sessionID: String, dataRoot: URL,
                         text: String, title: String, chatId: Int, markup: JSONValue) async throws {
        guard acceptingPassiveDelivery else { throw CancellationError() }
        try Task.checkCancellation()
        let key = "interaction:" + id
        if let delivery = promptDeliveries[key] { return try await delivery.value }
        let delivery = Task {
            try await settle { [self] in
                await sendInteraction(id: id, sessionID: sessionID, dataRoot: dataRoot,
                                      text: text, title: title, chatId: chatId, markup: markup)
            }.get()
        }
        promptDeliveries[key] = delivery
        try await delivery.value
    }

    private func sendInteraction(id: String, sessionID: String, dataRoot: URL,
                                 text: String, title: String, chatId: Int, markup: JSONValue) async -> Result<Void, Error> {
        defer { promptDeliveries["interaction:" + id] = nil }
        do {
            guard let note = await ApprovalChatCards.mirrorNote(id, dataRoot: dataRoot),
                  note["telegram_message_id"] == nil,
                  let card = await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot),
                  card.state.isOpen else { return .success(()) }
            guard acceptingPassiveDelivery else { return .success(()) }
            let messageID = try await cardSender(token, TelegramDestination(chatId: chatId, threadId: nil), text, markup)
            let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
            _ = try await inbox.patch(id: "interaction:" + id, unlessPresent: "telegram_message_id", [
                "telegram_chat_id": .string(String(chatId)), "telegram_message_id": .string(String(messageID)),
                "telegram_card_title": .string(title),
            ])
            await enqueueInteractionSettlement(id: id, sessionID: sessionID, dataRoot: dataRoot).value
            return .success(())
        } catch { return .failure(error) }
    }

    /// A mirrored card answered anywhere: its Telegram copy loses its buttons and says so.
    public func settleChatCard(chatId: Int, messageId: Int, text: String) async throws {
        try await TelegramPollLoop.defaultEditMessageTextWithReplyMarkup(
            token, chatId, messageId, text, .object(["inline_keyboard": .array([])]))
    }

    public func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        guard acceptingPassiveDelivery else { throw CancellationError() }
        try Task.checkCancellation()
        let envelope = TurnEnvelope.current(surface: surface)
        guard let chatIdString = envelope.verifiedChatId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let chatId = Int(chatIdString) else {
            throw TelegramApprovalError.missingChatId
        }
        let sessionId = ChatToolSessionContext.verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = NativeAgentChatApprovalFiler.requestPayload(
            toolName: toolName, surface: surface, payload: payload,
            telegram: .object([
                "chatId": .string(chatIdString),
                "threadId": Self.nonEmptyStringValue(envelope.replyRoute.threadId),
                "sessionId": Self.nonEmptyStringValue(sessionId),
            ]))
        // Reserve the complete request before the first suspension, including
        // inbox creation. Every duplicate awaits the same delivery or failure.
        if let flight = promptFlights.first(where: { NativeAgentChatApprovalFiler.isSameRequest($0.metadata, metadata) }) {
            return try await flight.task.value
        }
        let flightID = UUID()
        let task = Task {
            let result: Result<String, Error>
            do {
                result = .success(try await createAndPrompt(metadata: metadata, toolName: toolName,
                                                           reason: reason, chatId: chatId))
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
                                 reason: String, chatId: Int) async throws -> String {
        let record = try await settle { [dataRoot] in
            do {
                return Result<ApprovalRecord, Error>.success(try await NativeAgentChatApprovalFiler(dataRoot: dataRoot)
                    .fileRequest(metadata, reason: reason))
            } catch { return .failure(error) }
        }.get()
        do {
            guard case .object(let request) = metadata, let payload = request["input"] else {
                preconditionFailure("Invalid chat approval request")
            }
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
        reason: String
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
        // The shared owner may still hold a returned result whose receipt
        // failed to save. A matching late tap reaches its receipt-only repair;
        // a settled request reports the canonical decision or expiry.
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

        // The shared resolver owns execution, receipts and reporting on every
        // surface. Telegram carries the decision and acknowledges its tap.
        return TelegramApprovalResolution(acknowledgement: decision == .approved
            ? "Approved \(pending.action)." : ToolNotRunStatus.personDenied.sentence())
    }

    private func validateTelegramDecision(record: ApprovalRecord, chatId: Int, expectedStatus: String = "pending") throws {
        guard record.status == expectedStatus else {
            throw TelegramApprovalError.notPending(record.status)
        }
        guard !record.requiresExecutableReview else { throw TelegramApprovalError.notRemoteResolvable }
        // User's own DM (its chat card's) decides local-only too, as the signed
        // phone does (User, 10-07). Any other chat, remote-safe requests only.
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

    /// The Telegram chats an approval answers to: the one its turn ran in, and
    /// the DM its chat card was posted into (`ApprovalChatCards`).
    private static func answers(_ record: ApprovalRecord, chatId: Int) -> Bool {
        telegramChatId(record.payload) == String(chatId) || cardChat(record) == String(chatId)
    }

    private static func cardChat(_ record: ApprovalRecord) -> String? {
        guard case .object(let card)? = record.chatCard, case .string(let chat)? = card["telegramChatId"] else { return nil }
        return chat
    }

    /// Post the Approve/Deny prompt for an approval raised outside this chat
    /// into User's DM. A durable per-destination receipt retires its delivery task.
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
            guard current.status == "pending" else { return .success(()) }
            if case .object(let card)? = current.chatCard,
               card[receipt] == .bool(true) || (card["telegramPromptedAt"] != nil
                    && chatId == ApprovalChatCards.ownerDM(dataRoot: dataRoot)) { return .success(()) }
            guard acceptingPassiveDelivery else { return .success(()) }
            // Once dispatched, Stop ends further admission, never this send's
            // response or receipt.
            try await promptSender(token, chatId, approval, toolName, payload)
            var mark: [String: JSONValue] = [receipt: .bool(true)]
            if chatId == ApprovalChatCards.ownerDM(dataRoot: dataRoot) {
                mark["telegramPromptedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
                if !approval.requiresExecutableReview { mark["telegramChatId"] = .string(String(chatId)) }
            }
            try await inbox.markChatCard(approval.id, mark)
            return .success(())
        } catch { return .failure(error) }
    }

    /// Missing/null/blank means General; numeric or string topic ids must convert exactly to Int or stay malformed.
    enum RecordedTopic: Equatable {
        case absent
        case topic(Int)
        case malformed(String)
    }

    static func recordedTopic(_ payload: JSONValue) -> RecordedTopic {
        guard case .object(let obj) = payload,
              case .object(let telegram)? = obj["telegram"] else { return .absent }
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
        guard case .object(let obj) = payload,
              case .object(let telegram)? = obj["telegram"] else { return nil }
        switch telegram["chatId"] {
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
        // A card raised elsewhere keeps its own heading: who asked, or what for.
        let heading = approval.title.isEmpty || approval.title == "Approve \(toolName)"
            ? "Approval required: \(ToolActivityPresentation.title(toolName))" : approval.title
        func redacted(_ text: String) -> String { TurnSecretRedactor.redactText(NativeAppSecretRedactor.redactText(text)) }
        let reason = ToolActivityPresentation.approvalText(approval.reason, tool: toolName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A card whose filer wrote readable words (a REM lesson) shows them,
        // not its payload as JSON; a tool's card still shows its arguments.
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
        send: @Sendable (String, TelegramDestination, String, JSONValue) async throws -> Void
    ) async throws {
        // Executable code is decided where the whole saved review shows.
        if approval.requiresExecutableReview {
            try await send(token, TelegramDestination(chatId: chatId, threadId: nil),
                           "\(TurnSecretRedactor.redactText(NativeAppSecretRedactor.redactText(approval.title))) Review and approve it on the Mac or phone, where the whole script shows.",
                           .object(["inline_keyboard": .array([])]))
            return
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
        try await send(
            token,
            // The origin's topic belongs to the origin chat only; a mirror
            // into User's DM is sent unthreaded (a group topic id there fails
            // or lands in the wrong topic).
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
