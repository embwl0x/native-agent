import Foundation
import Testing
@testable import TelegramBot
import PersistenceCore

// MARK: - Coverage ledger: telegram.allowlist.approvalCallbackGate
//                         telegram.allowlist.turnControlCallbackGate
//
// Both inline-keyboard callbacks are dispatched BEFORE the message-path
// allowlist (TelegramPollLoop.swift:415-427), so each one carries its OWN
// perimeter. The suite drove only the ALLOWED path, which is exactly the shape
// that makes a dead control invisible: delete the gate and every existing test
// still passes while a forged/stale button resolves an approval or stops
// someone else's turn.
//
// Envelope asserted (never exact copy): the injected handler is not reached,
// a blocked row with the fail-closed reason exists, and the callback is
// ANSWERED (Telegram's spinner is released) — plus a positive control on the
// allowlisted path so removing the gate entirely cannot make the file pass.

private actor CallbackGateCapture {
    private(set) var answers: [(id: String, text: String)] = []
    private(set) var plain: [String] = []

    func answer(_ id: String, _ text: String) { answers.append((id: id, text: text)) }
    func plainMessage(_ text: String) { plain.append(text) }
    func answerTexts() -> [String] { answers.map(\.text) }
}

private actor CountingApprovalHandler: TelegramApprovalHandling {
    private(set) var resolved: [String] = []

    func resolveTelegramApproval(
        id: String,
        decision: TelegramApprovalDecision,
        chatId: Int,
        fromUserId: Int?
    ) async throws -> TelegramApprovalResolution {
        resolved.append("\(id):\(decision.rawValue):\(chatId)")
        return TelegramApprovalResolution(acknowledgement: "Approved \(id)")
    }

    func resolvedCount() -> Int { resolved.count }
}

private func makeGateLoop(
    root: URL,
    allowedChatIds: Set<Int64>,
    allowedUserIds: Set<Int64> = [],
    capture: CallbackGateCapture,
    handler: CountingApprovalHandler?
) -> TelegramPollLoop {
    TelegramPollLoop(
        interval: 60,
        token: "callback-gate-token",
        allowedChatIds: allowedChatIds,
        allowedUserIds: allowedUserIds,
        dataRoot: root,
        offsetURL: root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json"),
        sendMessage: { _, _, text in await capture.plainMessage(text) },
        answerCallbackQuery: { _, id, text in await capture.answer(id, text) },
        editMessageTextWithReplyMarkup: { _, _, _, _, _ in },
        approvalHandler: handler,
        turnCoordinator: TelegramTurnCoordinator()
    )
}

private func approvalCallback(
    id: String,
    chatId: Int,
    fromUserId: Int,
    approvalId: String = "pending-approval-1"
) -> JSONValue {
    .object([
        "id": .string(id),
        "from": .object(["id": .int(Int64(fromUserId))]),
        "message": .object([
            "message_id": .int(700),
            "chat": .object(["id": .int(Int64(chatId))]),
        ]),
        "data": .string("na_approval:approve:\(approvalId)"),
    ])
}

private func turnControlCallback(
    id: String,
    chatId: Int,
    fromUserId: Int,
    turnId: UUID
) -> JSONValue {
    .object([
        "id": .string(id),
        "from": .object(["id": .int(Int64(fromUserId))]),
        "message": .object([
            "message_id": .int(900),
            "chat": .object(["id": .int(Int64(chatId))]),
        ]),
        "data": .string(
            "na_turn:\(TelegramTurnControlAction.stop.rawValue):\(turnId.uuidString.lowercased())"
        ),
    ])
}

@Suite(.serialized)
struct TelegramCallbackAllowlistGateTests {

    // MARK: approval callback

    @Test func approvalCallback_withEmptyAllowlist_failsClosedAndNeverResolves() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CallbackGateCapture()
        let handler = CountingApprovalHandler()
        let loop = makeGateLoop(root: root, allowedChatIds: [], capture: capture, handler: handler)
        let callback = approvalCallback(id: "cb-empty", chatId: 77, fromUserId: 11)

        let consumed = await loop.handleApprovalCallback(
            update: TelegramUpdate(updateId: 501, callbackQuery: callback),
            callback: callback
        )

        #expect(consumed)
        #expect(await handler.resolvedCount() == 0)
        let blocked = await telegramFeedRows(root: root, "blocked")
        #expect(telegramFeedStrings(blocked, "reason") == ["allowlist_empty_fail_closed"])
        // The spinner must be released, or the user sees a hung button.
        #expect(await capture.answerTexts().count == 1)
        #expect(await capture.answerTexts().allSatisfy { !$0.isEmpty })
        // Never a continuation turn: nothing was sent into the chat.
        #expect(await capture.plain.isEmpty)
    }

    @Test func approvalCallback_fromNonAllowlistedChat_isBlockedAndNeverResolves() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CallbackGateCapture()
        let handler = CountingApprovalHandler()
        let loop = makeGateLoop(root: root, allowedChatIds: [77], capture: capture, handler: handler)
        let callback = approvalCallback(id: "cb-stranger", chatId: 999, fromUserId: 999)

        let consumed = await loop.handleApprovalCallback(
            update: TelegramUpdate(updateId: 502, callbackQuery: callback),
            callback: callback
        )

        #expect(consumed)
        #expect(await handler.resolvedCount() == 0)
        let blocked = await telegramFeedRows(root: root, "blocked")
        #expect(telegramFeedStrings(blocked, "reason") == ["not_allowlisted"])
        #expect(await capture.answerTexts().count == 1)
    }

    /// Positive control. Without this, deleting the gate outright would leave
    /// the two deny tests as the only witnesses — and they would fail, but a
    /// gate that blocks EVERYTHING would pass them. This pins the other side.
    @Test func approvalCallback_fromAllowlistedChat_resolvesAndWritesNoBlockedRow() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CallbackGateCapture()
        let handler = CountingApprovalHandler()
        let loop = makeGateLoop(root: root, allowedChatIds: [77], capture: capture, handler: handler)
        let callback = approvalCallback(id: "cb-allowed", chatId: 77, fromUserId: 11)

        let consumed = await loop.handleApprovalCallback(
            update: TelegramUpdate(updateId: 503, callbackQuery: callback),
            callback: callback
        )

        #expect(consumed)
        #expect(await handler.resolvedCount() == 1)
        #expect(await telegramFeedRows(root: root, "blocked").isEmpty)
    }

    /// The user-id lane is a SEPARATE admission rule (chat.id OR from.id); a
    /// regression that only consults chat ids locks every DM out silently.
    @Test func approvalCallback_allowlistedByUserId_resolves() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CallbackGateCapture()
        let handler = CountingApprovalHandler()
        let loop = makeGateLoop(
            root: root,
            allowedChatIds: [],
            allowedUserIds: [11],
            capture: capture,
            handler: handler
        )
        let callback = approvalCallback(id: "cb-byuser", chatId: 4242, fromUserId: 11)

        _ = await loop.handleApprovalCallback(
            update: TelegramUpdate(updateId: 504, callbackQuery: callback),
            callback: callback
        )

        #expect(await handler.resolvedCount() == 1)
        #expect(await telegramFeedRows(root: root, "blocked").isEmpty)
    }

    // MARK: turn-control callback

    @Test func turnControlCallback_fromNonAllowlistedSender_isBlockedBeforeAnyCardWork() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CallbackGateCapture()
        let loop = makeGateLoop(root: root, allowedChatIds: [77], capture: capture, handler: nil)
        let turnId = UUID()
        let callback = turnControlCallback(id: "tc-stranger", chatId: 999, fromUserId: 999, turnId: turnId)

        let consumed = await loop.handleTurnControlCallback(
            update: TelegramUpdate(updateId: 601, callbackQuery: callback),
            callback: callback
        )

        #expect(consumed)
        let blocked = await telegramFeedRows(root: root, "blocked")
        #expect(telegramFeedStrings(blocked, "reason") == ["not_allowlisted"])
        #expect(await capture.answerTexts().count == 1)
    }

    @Test func turnControlCallback_withEmptyAllowlist_failsClosed() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CallbackGateCapture()
        let loop = makeGateLoop(root: root, allowedChatIds: [], capture: capture, handler: nil)
        let callback = turnControlCallback(id: "tc-empty", chatId: 77, fromUserId: 11, turnId: UUID())

        _ = await loop.handleTurnControlCallback(
            update: TelegramUpdate(updateId: 602, callbackQuery: callback),
            callback: callback
        )

        let blocked = await telegramFeedRows(root: root, "blocked")
        #expect(telegramFeedStrings(blocked, "reason") == ["allowlist_empty_fail_closed"])
    }

    /// Positive control for the control gate: an ALLOWLISTED presser gets past
    /// the perimeter (and lands on the no-such-card branch, since no card was
    /// registered) — proving the deny path above is the gate talking and not a
    /// blanket refusal. The two answers must differ, or the gate is invisible
    /// to the user pressing the button.
    @Test func turnControlCallback_fromAllowlistedSender_passesGateWithNoBlockedRow() async throws {
        let root = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CallbackGateCapture()
        let loop = makeGateLoop(root: root, allowedChatIds: [77], capture: capture, handler: nil)
        let callback = turnControlCallback(id: "tc-allowed", chatId: 77, fromUserId: 11, turnId: UUID())

        let consumed = await loop.handleTurnControlCallback(
            update: TelegramUpdate(updateId: 603, callbackQuery: callback),
            callback: callback
        )

        #expect(consumed)
        #expect(await telegramFeedRows(root: root, "blocked").isEmpty)

        let deniedRoot = hermeticTelegramDataRoot()
        defer { try? FileManager.default.removeItem(at: deniedRoot) }
        let deniedCapture = CallbackGateCapture()
        let deniedLoop = makeGateLoop(
            root: deniedRoot, allowedChatIds: [77], capture: deniedCapture, handler: nil
        )
        let deniedCallback = turnControlCallback(
            id: "tc-denied", chatId: 999, fromUserId: 999, turnId: UUID()
        )
        _ = await deniedLoop.handleTurnControlCallback(
            update: TelegramUpdate(updateId: 604, callbackQuery: deniedCallback),
            callback: deniedCallback
        )

        let allowedText = await capture.answerTexts().first
        let deniedText = await deniedCapture.answerTexts().first
        #expect(allowedText != nil)
        #expect(deniedText != nil)
        #expect(allowedText != deniedText)
    }
}
