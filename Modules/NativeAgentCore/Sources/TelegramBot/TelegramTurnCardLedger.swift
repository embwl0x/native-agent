import Foundation
import NativeAgentCore
import PersistenceCore

struct TelegramPersistedTurnCard: Sendable, Codable, Equatable {
    let turnId: UUID
    let chatId: Int
    let messageId: Int
    let phase: TelegramTurnPresentationPhase
    let updatedAt: TimeInterval
    let terminalText: String?

    init(
        turnId: UUID,
        chatId: Int,
        messageId: Int,
        phase: TelegramTurnPresentationPhase,
        updatedAt: TimeInterval,
        terminalText: String? = nil
    ) {
        self.turnId = turnId
        self.chatId = chatId
        self.messageId = messageId
        self.phase = phase
        self.updatedAt = updatedAt
        self.terminalText = terminalText
    }

    var isTerminal: Bool {
        switch phase {
        case .completed, .failed, .canceled, .outcomeUnknown:
            return true
        default:
            return false
        }
    }
}

protocol TelegramTurnCardStorage: Sendable {
    func load() async throws -> [TelegramPersistedTurnCard]
    func save(_ records: [TelegramPersistedTurnCard]) async throws
}

enum TelegramTurnCardLedgerError: Error, Sendable, Equatable {
    case capacityExceeded(Int)
}

struct TelegramTurnCardFileStorage: TelegramTurnCardStorage {
    private struct Envelope: Sendable, Codable {
        let schemaVersion: Int
        let cards: [TelegramPersistedTurnCard]
    }

    let fileURL: URL

    func load() async throws -> [TelegramPersistedTurnCard] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else {
            throw TelegramBotError.underlying("unsupported Telegram work-card ledger schema")
        }
        return envelope.cards
    }

    func save(_ records: [TelegramPersistedTurnCard]) async throws {
        let envelope = Envelope(schemaVersion: 1, cards: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try await SwiftNativePersistenceCore().writeDataAtomicDurable(data, to: fileURL)
    }
}

/// Bounded, actor-owned identity ledger. It intentionally stores no prompt,
/// action, delegate, reply, token, or provider content.
actor TelegramTurnCardLedger {
    private let storage: any TelegramTurnCardStorage
    private let maximumRecords: Int
    private var loadedRecords: [TelegramPersistedTurnCard]?

    init(
        storage: any TelegramTurnCardStorage,
        maximumRecords: Int = 64
    ) {
        self.storage = storage
        self.maximumRecords = max(1, maximumRecords)
    }

    init(fileURL: URL, maximumRecords: Int = 64) {
        self.storage = TelegramTurnCardFileStorage(fileURL: fileURL)
        self.maximumRecords = max(1, maximumRecords)
    }

    func upsert(_ record: TelegramPersistedTurnCard) async throws {
        var records = try await currentRecords()
        let safeRecord = TelegramPersistedTurnCard(
            turnId: record.turnId,
            chatId: record.chatId,
            messageId: record.messageId,
            phase: record.phase,
            updatedAt: record.updatedAt,
            terminalText: record.terminalText.flatMap {
                TelegramTurnPresentationReducer.sanitized(
                    TelegramRichMessageRenderer.sanitize($0)
                )
            }
        )
        let replacesExisting = records.contains { $0.turnId == safeRecord.turnId }
        if !replacesExisting, records.count >= maximumRecords {
            throw TelegramTurnCardLedgerError.capacityExceeded(maximumRecords)
        }
        records.removeAll { $0.turnId == safeRecord.turnId }
        records.append(safeRecord)
        records.sort {
            if $0.updatedAt == $1.updatedAt {
                return $0.turnId.uuidString < $1.turnId.uuidString
            }
            return $0.updatedAt < $1.updatedAt
        }
        try await storage.save(records)
        loadedRecords = records
    }

    func remove(turnId: UUID) async throws {
        var records = try await currentRecords()
        let priorCount = records.count
        records.removeAll { $0.turnId == turnId }
        guard records.count != priorCount else { return }
        try await storage.save(records)
        loadedRecords = records
    }

    func records() async throws -> [TelegramPersistedTurnCard] {
        try await currentRecords()
    }

    private func currentRecords() async throws -> [TelegramPersistedTurnCard] {
        if let loadedRecords { return loadedRecords }
        let records = try await storage.load()
        loadedRecords = records
        return records
    }
}

struct TelegramTurnCardRepairResult: Sendable, Equatable {
    let repaired: Int
    let cleanedTerminal: Int
    let failures: [String]
}

/// Runs once per process-owned poll-loop instance. A prior active card is
/// edited in place to outcome-unknown and its controls are cleared. No new
/// card is ever created and no completion is inferred.
actor TelegramTurnCardRestartRepairer {
    typealias EditCard = @Sendable (
        _ token: String,
        _ chatId: Int,
        _ messageId: Int,
        _ text: String,
        _ replyMarkup: JSONValue?
    ) async throws -> Void

    static let interruptedText = """
    Outcome unknown · interrupted
    The prior process stopped before reply delivery could be confirmed.
    """

    private let ledger: TelegramTurnCardLedger
    private var attempted = false

    init(ledger: TelegramTurnCardLedger) {
        self.ledger = ledger
    }

    func repairOnce(
        token: String,
        editCard: @escaping EditCard
    ) async -> TelegramTurnCardRepairResult {
        guard !attempted else {
            return TelegramTurnCardRepairResult(repaired: 0, cleanedTerminal: 0, failures: [])
        }
        attempted = true
        let records: [TelegramPersistedTurnCard]
        do {
            records = try await ledger.records()
        } catch {
            return TelegramTurnCardRepairResult(
                repaired: 0,
                cleanedTerminal: 0,
                failures: [safe(error)]
            )
        }

        var repaired = 0
        var cleanedTerminal = 0
        var failures: [String] = []
        for record in records {
            if record.isTerminal {
                do {
                    if let terminalText = record.terminalText, !terminalText.isEmpty {
                        try await editCard(
                            token,
                            record.chatId,
                            record.messageId,
                            terminalText,
                            TelegramTurnControlCallback.clearedReplyMarkup
                        )
                    }
                    try await ledger.remove(turnId: record.turnId)
                    cleanedTerminal += 1
                } catch {
                    failures.append(safe(error))
                }
                continue
            }
            do {
                try await editCard(
                    token,
                    record.chatId,
                    record.messageId,
                    Self.interruptedText,
                    TelegramTurnControlCallback.clearedReplyMarkup
                )
                try await ledger.remove(turnId: record.turnId)
                repaired += 1
            } catch {
                // Preserve the active identity for a future process start. An
                // ambiguous edit may already have repaired the card, and the
                // validator's not-modified handling makes that retry safe.
                failures.append(safe(error))
            }
        }
        return TelegramTurnCardRepairResult(
            repaired: repaired,
            cleanedTerminal: cleanedTerminal,
            failures: failures
        )
    }

    private func safe(_ error: Error) -> String {
        TelegramPollLoop._tgRedactToken(
            TurnTraceRedactor.redactText(String(describing: error))
        )
    }
}
