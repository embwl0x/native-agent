import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import TelegramBot

private struct TurnCardLedgerTestError: Error, Sendable, CustomStringConvertible {
    let description: String
}

private actor TurnCardMemoryStorage: TelegramTurnCardStorage {
    var records: [TelegramPersistedTurnCard]
    var saveCount = 0
    var loadError: Error?
    var saveError: Error?

    init(records: [TelegramPersistedTurnCard] = []) {
        self.records = records
    }

    func load() async throws -> [TelegramPersistedTurnCard] {
        if let loadError { throw loadError }
        return records
    }

    func save(_ records: [TelegramPersistedTurnCard]) async throws {
        if let saveError { throw saveError }
        self.records = records
        saveCount += 1
    }

    func setSaveError(_ error: Error?) { saveError = error }
}

private actor TurnCardRepairSpy {
    struct Edit: Sendable {
        let chatId: Int
        let messageId: Int
        let text: String
        let markup: JSONValue?
    }

    var edits: [Edit] = []
    var error: Error?

    func edit(chatId: Int, messageId: Int, text: String, markup: JSONValue?) throws {
        edits.append(Edit(chatId: chatId, messageId: messageId, text: text, markup: markup))
        if let error { throw error }
    }
}

@Suite("Telegram durable work-card restart repair")
struct TelegramTurnCardLedgerTests {
    @Test func activeCardRepairsInPlaceClearsMarkupAndDoesNotCreateReplacement() async throws {
        let record = TelegramPersistedTurnCard(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            chatId: 91,
            messageId: 1201,
            phase: .delegation,
            updatedAt: 50
        )
        let storage = TurnCardMemoryStorage(records: [record])
        let ledger = TelegramTurnCardLedger(storage: storage)
        let repairer = TelegramTurnCardRestartRepairer(ledger: ledger)
        let spy = TurnCardRepairSpy()

        let result = await repairer.repairOnce(
            token: "token",
            editCard: { _, chatId, messageId, text, markup in
                try await spy.edit(chatId: chatId, messageId: messageId, text: text, markup: markup)
            }
        )

        #expect(result.repaired == 1)
        #expect(result.failures.isEmpty)
        let edits = await spy.edits
        #expect(edits.count == 1)
        #expect(edits[0].chatId == 91)
        #expect(edits[0].messageId == 1201)
        #expect(edits[0].text == TelegramTurnCardRestartRepairer.interruptedText)
        #expect(edits[0].text.hasPrefix("Outcome unknown"))
        #expect(edits[0].markup == TelegramTurnControlCallback.clearedReplyMarkup)
        #expect(try await ledger.records().isEmpty)

        _ = await repairer.repairOnce(
            token: "token",
            editCard: { _, _, _, _, _ in Issue.record("repair must run once") }
        )
        #expect(await spy.edits.count == 1)
    }

    @Test func transientTerminalRecordPreservesTerminalTextAndImmutability() async throws {
        let record = TelegramPersistedTurnCard(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            chatId: 92,
            messageId: 1202,
            phase: .completed,
            updatedAt: 60,
            terminalText: "Completed · elapsed 10s\nReply delivered"
        )
        let storage = TurnCardMemoryStorage(records: [record])
        let ledger = TelegramTurnCardLedger(storage: storage)
        let repairer = TelegramTurnCardRestartRepairer(ledger: ledger)
        let spy = TurnCardRepairSpy()

        let result = await repairer.repairOnce(
            token: "token",
            editCard: { _, chatId, messageId, text, markup in
                try await spy.edit(chatId: chatId, messageId: messageId, text: text, markup: markup)
            }
        )

        #expect(result.cleanedTerminal == 1)
        let edit = try #require(await spy.edits.first)
        #expect(edit.text.hasPrefix("Completed"))
        #expect(!edit.text.contains("Outcome unknown"))
        #expect(edit.markup == TelegramTurnControlCallback.clearedReplyMarkup)
        #expect(try await ledger.records().isEmpty)
    }

    @Test func failedRepairKeepsIdentityForNextProcessAndRedactsError() async throws {
        let secret = "7123456789:AAH-secret_Token123"
        let record = TelegramPersistedTurnCard(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            chatId: 93,
            messageId: 1203,
            phase: .working,
            updatedAt: 70
        )
        let storage = TurnCardMemoryStorage(records: [record])
        let ledger = TelegramTurnCardLedger(storage: storage)
        let repairer = TelegramTurnCardRestartRepairer(ledger: ledger)

        let result = await repairer.repairOnce(
            token: "token",
            editCard: { _, _, _, _, _ in
                throw TurnCardLedgerTestError(description: "failed at /bot\(secret)/editMessageText")
            }
        )

        #expect(result.repaired == 0)
        #expect(result.failures.count == 1)
        #expect(!result.failures[0].contains(secret))
        #expect(result.failures[0].contains("bot<redacted>"))
        #expect(try await ledger.records() == [record])
    }

    @Test func ledgerIsBoundedWithoutEvictingRepairableIdentity() async throws {
        let storage = TurnCardMemoryStorage()
        let ledger = TelegramTurnCardLedger(storage: storage, maximumRecords: 3)
        for value in 0..<3 {
            try await ledger.upsert(TelegramPersistedTurnCard(
                turnId: UUID(),
                chatId: value,
                messageId: 2_000 + value,
                phase: .working,
                updatedAt: TimeInterval(value)
            ))
        }
        await #expect(throws: TelegramTurnCardLedgerError.self) {
            try await ledger.upsert(TelegramPersistedTurnCard(
                turnId: UUID(),
                chatId: 99,
                messageId: 2_099,
                phase: .working,
                updatedAt: 99
            ))
        }

        let records = try await ledger.records()
        #expect(records.count == 3)
        #expect(records.map(\.chatId) == [0, 1, 2])
        #expect(await storage.records.count == 3)
    }

    @Test func ledgerRedactsTransientTerminalEvidenceBeforeStorage() async throws {
        let storage = TurnCardMemoryStorage()
        let ledger = TelegramTurnCardLedger(storage: storage)
        let telegramSecret = "7123456789:AAH-secret_Token123"
        let openAISecret = "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"

        try await ledger.upsert(TelegramPersistedTurnCard(
            turnId: UUID(),
            chatId: 1,
            messageId: 2,
            phase: .failed,
            updatedAt: 3,
            terminalText: "failed with \(telegramSecret) and \(openAISecret)"
        ))

        let terminalText = try #require(await storage.records.first?.terminalText)
        #expect(!terminalText.contains(telegramSecret))
        #expect(!terminalText.contains(openAISecret))
        #expect(terminalText.contains("[REDACTED_TELEGRAM_TOKEN]"))
        #expect(terminalText.contains("[REDACTED_OPENAI_KEY]"))
    }

    @Test func cardDriverPersistsActiveIdentityThenCleansAfterConfirmedTerminalEdit() async throws {
        let storage = TurnCardMemoryStorage()
        let ledger = TelegramTurnCardLedger(storage: storage)
        let driver = TelegramTurnProgressCardDriver(
            token: "token",
            chatId: 94,
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            minimumEditInterval: 0,
            heartbeatNanoseconds: 0,
            clock: { Date(timeIntervalSince1970: 100) },
            sleeper: { _ in },
            sendCard: { _, _, _, _ in 1204 },
            editCard: { _, _, _, _, _ in },
            persistCard: { try await ledger.upsert($0) },
            removePersistedCard: { try await ledger.remove(turnId: $0) }
        )

        await driver.start()
        var records = try await ledger.records()
        #expect(records.count == 1)
        #expect(records[0].messageId == 1204)
        #expect(records[0].phase == .acknowledged)
        #expect(records[0].terminalText == nil)

        await driver.transition(.working(action: "secret-free action"))
        records = try await ledger.records()
        #expect(records[0].phase == .working)

        await driver.transition(.completed(summary: "Reply delivered"))
        #expect(try await ledger.records().isEmpty)
        #expect((await driver.snapshot()).state.phase == .completed)
    }

    @Test func persistenceFailureLeavesOneHonestNonActionableCard() async {
        let storage = TurnCardMemoryStorage()
        await storage.setSaveError(TurnCardLedgerTestError(description: "disk unavailable"))
        let ledger = TelegramTurnCardLedger(storage: storage)
        let spy = TurnCardRepairSpy()
        let driver = TelegramTurnProgressCardDriver(
            token: "token",
            chatId: 95,
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            minimumEditInterval: 0,
            heartbeatNanoseconds: 0,
            sleeper: { _ in },
            sendCard: { _, _, _, _ in 1205 },
            editCard: { _, chatId, messageId, text, markup in
                try await spy.edit(chatId: chatId, messageId: messageId, text: text, markup: markup)
            },
            persistCard: { try await ledger.upsert($0) },
            removePersistedCard: { try await ledger.remove(turnId: $0) }
        )

        await driver.start()

        let snapshot = await driver.snapshot()
        let edits = await spy.edits
        #expect(snapshot.transportFailed)
        #expect(edits.count == 1)
        #expect(edits[0].messageId == 1205)
        #expect(edits[0].text.hasPrefix("Outcome unknown"))
        #expect(edits[0].markup == TelegramTurnControlCallback.clearedReplyMarkup)
    }
}
