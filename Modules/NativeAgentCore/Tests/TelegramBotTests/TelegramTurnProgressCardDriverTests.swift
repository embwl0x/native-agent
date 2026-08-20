import Foundation
import Testing
@testable import TelegramBot

private final class TurnCardTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ seconds: TimeInterval = 0) {
        instant = Date(timeIntervalSince1970: seconds)
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func set(_ seconds: TimeInterval) {
        lock.lock()
        instant = Date(timeIntervalSince1970: seconds)
        lock.unlock()
    }
}

private struct TurnCardTestError: Error, CustomStringConvertible, Sendable {
    let description: String
}

private actor TurnCardTransportSpy {
    private(set) var sends: [String] = []
    private(set) var edits: [(Int, String)] = []
    var sendFailure: String?
    var remainingEditFailures = 0
    var editFailure = "edit unavailable"

    func send(_ text: String) throws -> Int {
        sends.append(text)
        if let sendFailure {
            throw TurnCardTestError(description: sendFailure)
        }
        return 4242
    }

    func edit(messageId: Int, text: String) throws {
        edits.append((messageId, text))
        if remainingEditFailures > 0 {
            remainingEditFailures -= 1
            throw TurnCardTestError(description: editFailure)
        }
    }

    func configureEditFailures(_ count: Int, error: String) {
        remainingEditFailures = count
        editFailure = error
    }

    func configureSendFailure(_ error: String) {
        sendFailure = error
    }

    func snapshot() -> (sends: [String], edits: [(Int, String)]) {
        (sends, edits)
    }
}

private actor TurnCardFailureCapture {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor TurnCardControlledSleeper {
    private var permits = 0
    private var calls = 0

    func sleep() async throws {
        calls += 1
        while permits == 0 {
            if Task.isCancelled { throw CancellationError() }
            await Task.yield()
        }
        permits -= 1
    }

    func waitUntilSleeping() async {
        while calls == 0 { await Task.yield() }
    }

    func releaseOne() { permits += 1 }
}

private func makeTurnCardDriver(
    clock: TurnCardTestClock,
    transport: TurnCardTransportSpy,
    failures: TurnCardFailureCapture = TurnCardFailureCapture(),
    minimumEditInterval: TimeInterval = 0,
    heartbeatNanoseconds: UInt64 = 0,
    stalledAfter: TimeInterval = 90,
    sleeper: @escaping TelegramTurnProgressCardDriver.Sleeper = { _ in }
) -> TelegramTurnProgressCardDriver {
    TelegramTurnProgressCardDriver(
        token: "test-token",
        chatId: 77,
        turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000077")!,
        minimumEditInterval: minimumEditInterval,
        heartbeatNanoseconds: heartbeatNanoseconds,
        stalledAfter: stalledAfter,
        clock: { clock.now() },
        sleeper: sleeper,
        sendCard: { _, _, text, _ in try await transport.send(text) },
        editCard: { _, _, messageId, text, _ in
            try await transport.edit(messageId: messageId, text: text)
        },
        recordFailure: { await failures.append($0) }
    )
}

@Suite("Telegram durable turn progress card")
struct TelegramTurnProgressCardDriverTests {
    @Test func oneSendThenOnlyInPlaceEdits() async {
        let clock = TurnCardTestClock()
        let transport = TurnCardTransportSpy()
        let driver = makeTurnCardDriver(clock: clock, transport: transport)

        await driver.start()
        await driver.start()
        await driver.transition(.working(action: "Planning"))
        clock.set(5)
        await driver.record(progress: .toolUse(name: "read_file", input: nil))
        clock.set(8)
        await driver.transition(.completed(summary: "Reply delivered"))

        let captured = await transport.snapshot()
        #expect(captured.sends.count == 1)
        #expect(captured.sends[0].hasPrefix("Acknowledged ·"))
        #expect(captured.edits.count == 3)
        #expect(captured.edits.allSatisfy { $0.0 == 4242 })
        #expect(captured.edits.last?.1.hasPrefix("Completed ·") == true)
    }

    @Test func meaningfulProgressCoalescesUntilThrottleBoundary() async {
        let clock = TurnCardTestClock()
        let transport = TurnCardTransportSpy()
        let driver = makeTurnCardDriver(
            clock: clock,
            transport: transport,
            minimumEditInterval: 5
        )

        await driver.start()
        clock.set(1)
        await driver.record(progress: .status(text: "Planning"))
        clock.set(2)
        await driver.record(progress: .toolUse(name: "read_file", input: nil))
        #expect(await transport.snapshot().edits.isEmpty)

        clock.set(5)
        #expect(await driver.heartbeat())
        let edits = await transport.snapshot().edits
        #expect(edits.count == 1)
        #expect(edits[0].1.contains("Using tool"))
        #expect(edits[0].1.contains("Reading file"))
    }

    @Test func automaticHeartbeatRefreshesElapsedAndDerivedStallThenStopsAtTerminal() async {
        let clock = TurnCardTestClock()
        let transport = TurnCardTransportSpy()
        let controlledSleeper = TurnCardControlledSleeper()
        let driver = makeTurnCardDriver(
            clock: clock,
            transport: transport,
            minimumEditInterval: 5,
            heartbeatNanoseconds: 7_000_000_000,
            stalledAfter: 90,
            sleeper: { _ in try await controlledSleeper.sleep() }
        )

        await driver.start()
        await driver.transition(.working(action: "Waiting on provider"))
        await controlledSleeper.waitUntilSleeping()
        clock.set(95)
        await controlledSleeper.releaseOne()

        while await transport.snapshot().edits.isEmpty { await Task.yield() }
        let heartbeatText = await transport.snapshot().edits.last?.1 ?? ""
        #expect(heartbeatText.hasPrefix("Stalled · elapsed 1m 35s"))
        #expect(heartbeatText.contains("moved 1m 35s ago"))

        clock.set(101)
        await driver.transition(.completed(summary: "Reply delivered"))
        let snapshot = await driver.snapshot()
        #expect(snapshot.state.phase == .completed)
        #expect(!snapshot.heartbeatRunning)
    }

    @Test func progressMapsDelegationAndRetryingIntoTheSameCard() async {
        let clock = TurnCardTestClock()
        let transport = TurnCardTransportSpy()
        let driver = makeTurnCardDriver(clock: clock, transport: transport)

        await driver.start()
        clock.set(1)
        await driver.record(progress: .toolUse(name: "codex_message", input: nil))
        var snapshot = await driver.snapshot()
        #expect(snapshot.state.phase == .delegation)
        #expect(snapshot.state.delegateName == "Codex")

        clock.set(2)
        await driver.record(progress: .status(text: "Draft stalled; retrying"))
        snapshot = await driver.snapshot()
        #expect(snapshot.state.phase == .retrying)
        #expect(await transport.snapshot().sends.count == 1)
    }

    @Test func allTerminalsAbsorbLateProgressAndStopHeartbeat() async {
        let terminals: [(TelegramTurnPresentationLifecycleEvent, TelegramTurnPresentationPhase)] = [
            (.completed(summary: "Delivered"), .completed),
            (.canceled(reason: "Stopped"), .canceled),
            (.failed(reason: "Provider failed"), .failed),
            (.outcomeUnknown(reason: "Delivery uncertain"), .outcomeUnknown),
        ]

        for (terminal, expected) in terminals {
            let clock = TurnCardTestClock()
            let transport = TurnCardTransportSpy()
            let driver = makeTurnCardDriver(clock: clock, transport: transport)
            await driver.start()
            await driver.transition(terminal)
            let terminalSnapshot = await driver.snapshot()
            await driver.record(progress: .toolUse(name: "late_tool", input: nil))
            await driver.transition(.working(action: "late work"))
            #expect(await driver.snapshot() == terminalSnapshot)
            #expect(terminalSnapshot.state.phase == expected)
        }
    }

    @Test func failedInitialSendIsRecordedOnceAndNeverCreatesAReplacement() async {
        let clock = TurnCardTestClock()
        let transport = TurnCardTransportSpy()
        let failures = TurnCardFailureCapture()
        let secret = ["7123456789", "AAH-secret_Token123"].joined(separator: ":")
        await transport.configureSendFailure("failed at /bot\(secret)/sendMessage")
        let driver = makeTurnCardDriver(
            clock: clock,
            transport: transport,
            failures: failures
        )

        await driver.start()
        await driver.start()
        await driver.record(progress: .status(text: "Working"))
        await driver.transition(.completed(summary: "Reply delivered"))

        let captured = await transport.snapshot()
        let snapshot = await driver.snapshot()
        let recordedFailures = await failures.snapshot()
        #expect(captured.sends.count == 1)
        #expect(captured.edits.isEmpty)
        #expect(snapshot.transportFailed)
        #expect(snapshot.state.phase == .completed)
        #expect(recordedFailures.count == 1)
        #expect(recordedFailures[0].contains("bot<redacted>"))
        #expect(!recordedFailures[0].contains(secret))
    }

    @Test func editFailureRetriesAtMostOnceThenFreezesCardTransport() async {
        let clock = TurnCardTestClock()
        let transport = TurnCardTransportSpy()
        let failures = TurnCardFailureCapture()
        await transport.configureEditFailures(2, error: "connection reset")
        let driver = makeTurnCardDriver(
            clock: clock,
            transport: transport,
            failures: failures
        )

        await driver.start()
        await driver.transition(.working(action: "Planning"))
        await driver.record(progress: .toolUse(name: "read_file", input: nil))
        await driver.transition(.completed(summary: "Reply delivered"))

        let captured = await transport.snapshot()
        let recordedFailures = await failures.snapshot()
        #expect(captured.sends.count == 1)
        #expect(captured.edits.count == 2)
        #expect(await driver.snapshot().transportFailed)
        #expect(recordedFailures.count == 1)
    }

    @Test func deliveryFailureClassificationIsHonestAndRedacted() {
        let ambiguous = TelegramTurnReplyDeliveryFailure.lifecycleEvent(
            for: URLError(.networkConnectionLost)
        )
        let known = TelegramTurnReplyDeliveryFailure.lifecycleEvent(
            for: TelegramAPIFailure(
                kind: .rejected,
                operation: "sendMessage",
                errorCode: 400,
                telegramDescription: "chat not found"
            )
        )
        let secret = ["sk", "proj", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"]
            .joined(separator: "-")
        let secretFailure = TelegramTurnReplyDeliveryFailure.lifecycleEvent(
            for: TurnCardTestError(description: "delivery failed with \(secret)")
        )

        let initial = TelegramTurnPresentationReducer.initialState(
            at: Date(timeIntervalSince1970: 0)
        )
        let ambiguousState = TelegramTurnPresentationReducer.reduce(
            initial,
            lifecycle: ambiguous,
            at: Date(timeIntervalSince1970: 1)
        )
        let knownState = TelegramTurnPresentationReducer.reduce(
            initial,
            lifecycle: known,
            at: Date(timeIntervalSince1970: 1)
        )
        let secretState = TelegramTurnPresentationReducer.reduce(
            initial,
            lifecycle: secretFailure,
            at: Date(timeIntervalSince1970: 1)
        )

        #expect(ambiguousState.phase == .outcomeUnknown)
        #expect(knownState.phase == .failed)
        #expect(!(secretState.currentAction ?? "").contains(secret))
        #expect((secretState.currentAction ?? "").contains("[REDACTED_OPENAI_KEY]"))
    }
}
