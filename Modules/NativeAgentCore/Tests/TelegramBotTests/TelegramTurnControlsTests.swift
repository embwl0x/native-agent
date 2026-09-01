import Foundation
import Testing
@testable import TelegramBot
import NativeAgentTestSupport
import PersistenceCore

private final class TelegramTurnControlsURLProtocol: ConfigurableURLProtocolStub {}

private final class TelegramTurnControlsResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var response = Data(#"{"ok":true,"result":[]}"#.utf8)

    func setUpdate(_ update: String) {
        lock.lock()
        response = Data("{\"ok\":true,\"result\":[\(update)]}".utf8)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}

private actor TelegramTurnControlsCapture {
    struct CardSend: Sendable {
        let text: String
        let markup: JSONValue
    }

    struct CardEdit: Sendable {
        let text: String
        let markup: JSONValue?
    }

    private(set) var handlerStarts: [String] = []
    private(set) var handlerCanceled = false
    private(set) var cardSends: [CardSend] = []
    private(set) var cardEdits: [CardEdit] = []
    private(set) var cardEditMessageIds: [Int] = []
    private(set) var plainMessages: [String] = []
    private(set) var callbackAnswers: [(String, String)] = []

    func startHandler(_ text: String) { handlerStarts.append(text) }
    func cancelHandler() { handlerCanceled = true }

    func waitUntilHandlerStarts() async {
        while handlerStarts.isEmpty { await Task.yield() }
    }

    func waitUntilHandlerStartCount(_ count: Int) async -> Bool {
        for _ in 0..<2_000 where handlerStarts.count < count {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return handlerStarts.count >= count
    }

    func sendCard(text: String, markup: JSONValue) -> Int {
        cardSends.append(CardSend(text: text, markup: markup))
        return 499 + cardSends.count
    }

    func editCard(messageId: Int, text: String, markup: JSONValue?) {
        cardEditMessageIds.append(messageId)
        cardEdits.append(CardEdit(text: text, markup: markup))
    }

    func sendPlain(_ text: String) { plainMessages.append(text) }

    func answer(_ callbackId: String, text: String) {
        callbackAnswers.append((callbackId, text))
    }

    func snapshot() -> (
        handlerCanceled: Bool,
        handlerStarts: [String],
        cardSends: [CardSend],
        cardEdits: [CardEdit],
        plainMessages: [String],
        callbackAnswers: [(String, String)]
    ) {
        (handlerCanceled, handlerStarts, cardSends, cardEdits, plainMessages, callbackAnswers)
    }
}

private actor TelegramExpiredApprovalHandler: TelegramApprovalHandling {
    private(set) var calls = 0

    func resolveTelegramApproval(
        id: String,
        decision: TelegramApprovalDecision,
        chatId: Int,
        fromUserId: Int?
    ) async throws -> TelegramApprovalResolution {
        calls += 1
        throw TelegramBotError.underlying("approval expired")
    }
}

private actor TelegramQueuedTurnOrderCapture {
    private(set) var starts: [String] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    func run(_ label: String, waitsForRelease: Bool) async {
        starts.append(label)
        guard waitsForRelease else { return }
        await withCheckedContinuation { continuation in
            firstRelease = continuation
        }
    }

    func waitForStarts(_ count: Int) async {
        while starts.count < count { await Task.yield() }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }
}

private actor TelegramSteerGenerationCapture {
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var firstReleased = false
    private(set) var secondStarted = false
    private(set) var secondCanceled = false

    func runFirst() async {
        // Under parallel test execution the turn task can be scheduled AFTER
        // the test's releaseFirst() call; a bare continuation then waits on a
        // resume that already happened, and waitForSecond() spins forever.
        guard !firstReleased else { return }
        await withCheckedContinuation { continuation in
            firstRelease = continuation
        }
    }

    func releaseFirst() {
        firstReleased = true
        firstRelease?.resume()
        firstRelease = nil
    }

    func runSecond() async {
        secondStarted = true
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            secondCanceled = true
        } catch {}
    }

    func waitForSecond() async {
        while !secondStarted { await Task.yield() }
    }
}

private func telegramTurnControlsSession(
    responses: TelegramTurnControlsResponses
) -> URLSession {
    TelegramTurnControlsURLProtocol.makeSession { request in
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!,
            responses.data()
        )
    }
}

private func telegramMessageUpdate(
    updateId: Int,
    messageId: Int,
    text: String
) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    {"update_id":\(updateId),"message":{"message_id":\(messageId),"chat":{"id":77,"type":"private"},"from":{"id":11},"text":"\(escaped)","date":1}}
    """
}

private func telegramCallbackUpdate(
    updateId: Int,
    callbackId: String,
    data: String,
    messageId: Int = 500
) -> String {
    """
    {"update_id":\(updateId),"callback_query":{"id":"\(callbackId)","from":{"id":11},"message":{"message_id":\(messageId),"chat":{"id":77,"type":"private"}},"data":"\(data)"}}
    """
}

private func callbackData(
    action: TelegramTurnControlAction,
    in markup: JSONValue
) -> String? {
    guard case .object(let root) = markup,
          case .array(let rows)? = root["inline_keyboard"] else { return nil }
    for case .array(let buttons) in rows {
        for case .object(let button) in buttons {
            guard case .string(let data)? = button["callback_data"] else { continue }
            if data.contains("na_turn:\(action.rawValue):") { return data }
        }
    }
    return nil
}

private func queuedCallbackData(
    action: TelegramQueuedTurnControlAction,
    in markup: JSONValue
) -> String? {
    guard case .object(let root) = markup,
          case .array(let rows)? = root["inline_keyboard"] else { return nil }
    for case .array(let buttons) in rows {
        for case .object(let button) in buttons {
            guard case .string(let data)? = button["callback_data"] else { continue }
            if data.contains("na_queue:\(action.rawValue):") { return data }
        }
    }
    return nil
}

private func makeResponsiveTurnLoop(
    root: URL,
    responses: TelegramTurnControlsResponses,
    capture: TelegramTurnControlsCapture,
    coordinator: TelegramTurnCoordinator,
    token: String,
    callbackFailureId: String? = nil
) -> TelegramPollLoop {
    TelegramPollLoop(
        interval: 60,
        token: token,
        allowedChatIds: [77],
        session: telegramTurnControlsSession(responses: responses),
        dataRoot: root,
        offsetURL: root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json"),
        sendMessage: { _, _, text in await capture.sendPlain(text) },
        sendChatAction: { _, _, _ in },
        answerCallbackQuery: { _, callbackId, text in
            await capture.answer(callbackId, text: text)
            if callbackId == callbackFailureId {
                throw TelegramAPIFailure(
                    kind: .rejected,
                    operation: "answerCallbackQuery",
                    httpStatus: 200,
                    errorCode: 400,
                    telegramDescription: "ok:false at /bot\(token)/answerCallbackQuery"
                )
            }
        },
        sendMessageReturningId: { _, _, _ in 900 },
        sendMessageWithReplyMarkupReturningId: { _, _, text, markup in
            await capture.sendCard(text: text, markup: markup)
        },
        editMessageText: { _, _, _, _ in },
        editMessageTextWithReplyMarkup: { _, _, messageId, text, markup in
            await capture.editCard(messageId: messageId, text: text, markup: markup)
        },
        draftEditIntervalSeconds: 0,
        turnCardMinimumEditIntervalSeconds: 0,
        turnCardHeartbeatNanoseconds: 0,
        turnCardSleeper: { try await Task.sleep(nanoseconds: $0) },
        turnStopConfirmationNanoseconds: 1_000_000_000,
        progressChatHandler: { _, text, progress, _ in
            await capture.startHandler(text)
            await progress(.toolUse(
                name: "invoke_claude",
                input: .object([
                    "token": .string(token),
                    "hidden_reasoning": .string("must never render"),
                ])
            ))
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "unexpected late reply"
            } catch is CancellationError {
                await capture.cancelHandler()
                throw CancellationError()
            }
        },
        typingRefreshNanoseconds: 0,
        turnCoordinator: coordinator
    )
}

@Suite("Telegram responsive turn controls", .serialized)
struct TelegramTurnControlsTests {
    @Test func steerStopBoundToOldGenerationCannotCancelPromotedSuccessor() async throws {
        let coordinator = TelegramTurnCoordinator()
        let capture = TelegramSteerGenerationCapture()
        let first = await coordinator.startTrackedTurn(chatId: 77, text: "first") { _ in
            await capture.runFirst()
        }
        #expect(first != nil)
        #expect(await coordinator.enqueueTrackedTurn(
            updateId: 2,
            chatId: 77,
            text: "steer here",
            acknowledgementMessageId: 501,
            operation: { _ in await capture.runSecond() },
            onStart: { _ in }
        ) == 1)

        let interrupted = try #require(await coordinator.activeTurnID(chatId: 77))
        #expect(await coordinator.promoteQueuedTurn(chatId: 77, updateId: 2) != nil)
        await capture.releaseFirst()
        await capture.waitForSecond()

        let outcome = await coordinator.requestStop(
            chatId: 77,
            turnId: interrupted,
            confirmationTimeoutNanoseconds: 0,
            sleeper: { _ in }
        )
        #expect(outcome == .notRunning)
        #expect(await coordinator.snapshot(chatId: 77).promptPreview == "steer here")
        #expect(await capture.secondCanceled == false)
        await coordinator.shutdown()
    }

    @Test func queuedAcknowledgementCardSurvivesCoordinatorRestart() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_queue_card_restart_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let offsetURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("last_offset.json")
        let update = TelegramUpdate(
            updateId: 40,
            message: TelegramMessage(
                messageId: 40,
                chatId: 77,
                chatType: "private",
                fromUserId: 11,
                text: "resume after restart",
                date: 1
            )
        )
        let inbox = TelegramUpdateInbox(offsetURL: offsetURL)
        _ = try await inbox.ensurePending(update)
        _ = try await inbox.transition(updateId: 40, from: [.pending], to: .processing)
        _ = try await inbox.transition(updateId: 40, from: [.processing], to: .queued)
        _ = try await inbox.recordQueueAcknowledgement(updateId: 40, messageId: 777)

        let responses = TelegramTurnControlsResponses()
        let capture = TelegramTurnControlsCapture()
        let coordinator = TelegramTurnCoordinator()
        let loop = makeResponsiveTurnLoop(
            root: root,
            responses: responses,
            capture: capture,
            coordinator: coordinator,
            token: "123456:RESTART_QUEUE_SECRET"
        )

        _ = await loop.tickOutcome()
        await capture.waitUntilHandlerStarts()
        let captured = await capture.snapshot()
        #expect(captured.cardSends.count == 1,
                "restart must reuse the durable queued card instead of sending a replacement")
        #expect(await capture.cardEditMessageIds.contains(777))
        #expect(captured.cardEdits.contains { $0.text.hasPrefix("Running now ·") })
        #expect(try await inbox.snapshots().first?.phase == .completed)

        await loop.shutdown()
    }

    @Test func queuedTurnsDrainInFIFOOrderAfterNaturalCompletion() async {
        let coordinator = TelegramTurnCoordinator()
        let capture = TelegramQueuedTurnOrderCapture()

        _ = await coordinator.startTrackedTurn(chatId: 77, text: "first") { _ in
            await capture.run("first", waitsForRelease: true)
        }
        await capture.waitForStarts(1)
        #expect(await coordinator.enqueueTrackedTurn(
            updateId: 2,
            chatId: 77,
            text: "second",
            acknowledgementMessageId: 501,
            operation: { _ in await capture.run("second", waitsForRelease: false) },
            onStart: { _ in }
        ) == 1)
        #expect(await coordinator.enqueueTrackedTurn(
            updateId: 3,
            chatId: 77,
            text: "third",
            acknowledgementMessageId: 502,
            operation: { _ in await capture.run("third", waitsForRelease: false) },
            onStart: { _ in }
        ) == 2)
        #expect(await capture.starts == ["first"])

        await capture.releaseFirst()
        await capture.waitForStarts(3)
        await coordinator.waitUntilAllIdle()
        #expect(await capture.starts == ["first", "second", "third"])
    }

    @Test func approvalContinuationWaitsForActiveTurnThenRunsBeforeOrdinaryQueue() async {
        let coordinator = TelegramTurnCoordinator()
        let capture = TelegramQueuedTurnOrderCapture()

        _ = await coordinator.startTrackedTurn(chatId: 77, text: "active") { _ in
            await capture.run("active", waitsForRelease: true)
        }
        await capture.waitForStarts(1)
        #expect(await coordinator.enqueueTrackedTurn(
            updateId: 2,
            chatId: 77,
            text: "ordinary queued message",
            acknowledgementMessageId: 501,
            operation: { _ in await capture.run("ordinary", waitsForRelease: false) },
            onStart: { _ in }
        ) == 1)

        #expect(await coordinator.enqueueApprovalContinuation(
            chatId: 77,
            text: "verified approval continuation",
            operation: { _ in await capture.run("approval", waitsForRelease: false) }
        ) == 1)
        #expect(await capture.starts == ["active"])

        await capture.releaseFirst()
        await capture.waitForStarts(3)
        await coordinator.waitUntilAllIdle()
        #expect(await capture.starts == ["active", "approval", "ordinary"])
    }

    @Test func callbacksAndStatusStayResponsiveWhileOrdinaryTurnsRemainSerialized() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_turn_controls_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "123456:TOP_SECRET_TOKEN"
        let responses = TelegramTurnControlsResponses()
        let capture = TelegramTurnControlsCapture()
        let coordinator = TelegramTurnCoordinator()
        let loop = makeResponsiveTurnLoop(
            root: root,
            responses: responses,
            capture: capture,
            coordinator: coordinator,
            token: token,
            callbackFailureId: "cb-status-ok-false"
        )

        responses.setUpdate(telegramMessageUpdate(updateId: 1, messageId: 1, text: "do long work"))
        _ = await loop.tickOutcome()
        await capture.waitUntilHandlerStarts()
        #expect(await coordinator.snapshot(chatId: 77).isRunning)

        let initial = await capture.snapshot()
        #expect(initial.cardSends.count == 1)
        let markup = try #require(initial.cardSends.first?.markup)
        let statusData = try #require(callbackData(action: .status, in: markup))
        let detailsData = try #require(callbackData(action: .details, in: markup))

        // Slash status is handled by the live card and produces no standalone
        // status message while the provider turn remains suspended.
        responses.setUpdate(telegramMessageUpdate(updateId: 2, messageId: 2, text: "/status"))
        _ = await loop.tickOutcome()

        // A second ordinary turn queues by default and cannot race the first.
        responses.setUpdate(telegramMessageUpdate(updateId: 3, messageId: 3, text: "race this"))
        _ = await loop.tickOutcome()

        // The queue acknowledgement carries explicit steer/remove controls,
        // while the durable inbox retains ownership until the queued turn runs.
        #expect(await coordinator.snapshot(chatId: 77).isRunning)
        #expect(await coordinator.lastUserMessage(chatId: 77)?.text == "race this")
        let queuedSnapshot = try #require(await coordinator.queuedTurn(chatId: 77, updateId: 3))
        #expect(queuedSnapshot.position == 1)
        #expect(queuedSnapshot.acknowledgementMessageId == 501)
        let afterQueue = await capture.snapshot()
        #expect(afterQueue.cardSends.count == 2)
        let queuedMarkup = afterQueue.cardSends[1].markup
        let steerData = try #require(queuedCallbackData(action: .steer, in: queuedMarkup))
        #expect(queuedCallbackData(action: .remove, in: queuedMarkup) != nil)
        let queuedReceipts = await telegramFeedRows(root: root, "receipts").filter { row in
            row["kind"] == .string("queued_notice")
        }
        #expect(queuedReceipts.count == 1)
        #expect(queuedReceipts.first?["textPreview"] == .string("race this"))

        responses.setUpdate(telegramCallbackUpdate(
            updateId: 4,
            callbackId: "cb-details",
            data: detailsData
        ))
        _ = await loop.tickOutcome()

        // Replaying the same callback id is answered but never re-executes.
        let editCountBeforeDuplicate = await capture.snapshot().cardEdits.count
        responses.setUpdate(telegramCallbackUpdate(
            updateId: 5,
            callbackId: "cb-details",
            data: detailsData
        ))
        _ = await loop.tickOutcome()
        #expect(await capture.snapshot().cardEdits.count == editCountBeforeDuplicate)

        // A valid turn id bound to the wrong message is stale.
        responses.setUpdate(telegramCallbackUpdate(
            updateId: 6,
            callbackId: "cb-stale",
            data: statusData,
            messageId: 999
        ))
        _ = await loop.tickOutcome()

        // HTTP 200 + ok:false from answerCallbackQuery is recorded, while the
        // idempotent card refresh still proceeds and the turn stays alive.
        responses.setUpdate(telegramCallbackUpdate(
            updateId: 7,
            callbackId: "cb-status-ok-false",
            data: statusData
        ))
        _ = await loop.tickOutcome()
        #expect(await coordinator.snapshot(chatId: 77).isRunning)

        responses.setUpdate(telegramCallbackUpdate(
            updateId: 8,
            callbackId: "cb-steer",
            data: steerData,
            messageId: 501
        ))
        _ = await loop.tickOutcome()
        #expect(await capture.waitUntilHandlerStartCount(2))

        let captured = await capture.snapshot()
        #expect(captured.handlerCanceled)
        #expect(captured.handlerStarts == ["do long work", "race this"])
        let steeredSnapshot = await coordinator.snapshot(chatId: 77)
        #expect(steeredSnapshot.isRunning)
        #expect(steeredSnapshot.promptPreview == "race this")
        #expect(captured.cardSends.count == 3)
        #expect(captured.plainMessages.isEmpty)
        #expect(captured.cardEdits.contains { $0.text.hasPrefix("Work details") })
        #expect(captured.cardEdits.contains { $0.text.hasPrefix("Running now ·") })
        #expect(captured.callbackAnswers.contains { $0.0 == "cb-steer" })

        let renderedSurface = (captured.cardSends.map(\.text)
            + captured.cardEdits.map(\.text)
            + captured.plainMessages
            + captured.callbackAnswers.map(\.1))
            .joined(separator: "\n")
        #expect(!renderedSurface.contains(token))
        #expect(!renderedSurface.contains("hidden_reasoning"))
        #expect(!renderedSurface.contains("must never render"))

        let errorURL = root
            .appendingPathComponent("telegram", isDirectory: true)
            .appendingPathComponent("errors.jsonl")
        let errors = try String(contentsOf: errorURL, encoding: .utf8)
        #expect(errors.contains("turn_control_callback_answer"))
        #expect(errors.contains("ok:false"))
        #expect(!errors.contains(token))

        await loop.shutdown()
        let shutdownSnapshot = await coordinator.snapshot(chatId: 77)
        #expect(!shutdownSnapshot.isRunning)
    }

    @Test func slashStopUsesTheSameConfirmedCancellationPathDuringWork() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_slash_stop_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramTurnControlsResponses()
        let capture = TelegramTurnControlsCapture()
        let coordinator = TelegramTurnCoordinator()
        let loop = makeResponsiveTurnLoop(
            root: root,
            responses: responses,
            capture: capture,
            coordinator: coordinator,
            token: "123456:SLASH_STOP_SECRET"
        )

        responses.setUpdate(telegramMessageUpdate(updateId: 11, messageId: 11, text: "keep working"))
        _ = await loop.tickOutcome()
        await capture.waitUntilHandlerStarts()

        responses.setUpdate(telegramMessageUpdate(updateId: 12, messageId: 12, text: "/stop"))
        _ = await loop.tickOutcome()

        let captured = await capture.snapshot()
        #expect(captured.handlerCanceled)
        let stoppedSnapshot = await coordinator.snapshot(chatId: 77)
        #expect(!stoppedSnapshot.isRunning)
        #expect(captured.cardSends.count == 1)
        #expect(captured.cardEdits.last?.text.hasPrefix("Canceled ·") == true)
        #expect(captured.plainMessages.isEmpty)

        await loop.shutdown()
        let shutdownSnapshot = await coordinator.snapshot(chatId: 77)
        #expect(!shutdownSnapshot.isRunning)
    }

    @Test func unconfirmedCancellationTerminalizesAsOutcomeUnknownAndAbsorbsLateEvents() async {
        let coordinator = TelegramTurnCoordinator()
        let task = Task<Void, Never> {
            // Deliberately ignores cancellation long enough for the injected
            // timeout branch to win.
            for _ in 0..<1_000 { await Task.yield() }
        }
        let activeId = await coordinator.beginTurn(
            chatId: 77,
            text: "ignore cancellation",
            task: task
        )!
        let card = TelegramTurnProgressCardDriver(
            token: "token",
            chatId: 77,
            turnId: activeId,
            heartbeatNanoseconds: 0,
            sleeper: { _ in },
            sendCard: { _, _, _, _ in 500 },
            editCard: { _, _, _, _, _ in }
        )
        await card.start()
        #expect(await coordinator.attachCard(card, chatId: 77, turnId: activeId))

        let outcome = await coordinator.requestStop(
            chatId: 77,
            confirmationTimeoutNanoseconds: 0,
            sleeper: { _ in }
        )
        #expect(outcome == .outcomeUnknown)
        #expect(await card.snapshot().state.phase == .outcomeUnknown)

        await card.transition(.canceled(reason: "late cancellation"))
        #expect(await card.snapshot().state.phase == .outcomeUnknown)
        await task.value
        await coordinator.finishTurn(chatId: 77, turnId: activeId)
        await coordinator.shutdown()
        let shutdownSnapshot = await coordinator.snapshot(chatId: 77)
        #expect(!shutdownSnapshot.isRunning)
    }

    @Test func approvalExpiryRemovesActionableKeyboardAndDuplicateCannotResolveTwice() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_expired_approval_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = TelegramTurnControlsCapture()
        let handler = TelegramExpiredApprovalHandler()
        let loop = TelegramPollLoop(
            token: "approval-token",
            allowedChatIds: [77],
            dataRoot: root,
            sendMessage: { _, _, text in await capture.sendPlain(text) },
            answerCallbackQuery: { _, callbackId, text in
                await capture.answer(callbackId, text: text)
            },
            editMessageTextWithReplyMarkup: { _, _, messageId, text, markup in
                await capture.editCard(messageId: messageId, text: text, markup: markup)
            },
            approvalHandler: handler
        )
        let callback: JSONValue = .object([
            "id": .string("approval-expired-callback"),
            "from": .object(["id": .int(11)]),
            "message": .object([
                "message_id": .int(700),
                "chat": .object(["id": .int(77)]),
            ]),
            "data": .string("na_approval:approve:expired-approval"),
        ])
        let update = TelegramUpdate(updateId: 90, callbackQuery: callback)

        #expect(await loop.handleApprovalCallback(update: update, callback: callback))
        #expect(await loop.handleApprovalCallback(update: update, callback: callback))

        let captured = await capture.snapshot()
        #expect(await handler.calls == 1)
        #expect(captured.cardEdits.count == 1)
        #expect(captured.cardEdits.first?.text.contains("approval expired") == true)
        #expect(captured.cardEdits.first?.markup == TelegramTurnControlCallback.clearedReplyMarkup)
        #expect(captured.plainMessages.isEmpty)
        #expect(captured.callbackAnswers.count == 2)
    }

    @Test func shutdownCancelsAndDrainsTheOwnedTurnWithoutAnOrphan() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_turn_shutdown_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = TelegramTurnControlsResponses()
        let capture = TelegramTurnControlsCapture()
        let coordinator = TelegramTurnCoordinator()
        let loop = makeResponsiveTurnLoop(
            root: root,
            responses: responses,
            capture: capture,
            coordinator: coordinator,
            token: "123456:SHUTDOWN_SECRET"
        )

        responses.setUpdate(telegramMessageUpdate(updateId: 100, messageId: 100, text: "stay active"))
        _ = await loop.tickOutcome()
        await capture.waitUntilHandlerStarts()
        #expect(await coordinator.snapshot(chatId: 77).isRunning)

        await loop.shutdown()

        let captured = await capture.snapshot()
        let snapshot = await coordinator.snapshot(chatId: 77)
        #expect(captured.handlerCanceled)
        #expect(!snapshot.isRunning)
        #expect(captured.cardEdits.last?.text.hasPrefix("Canceled ·") == true)
    }
}
