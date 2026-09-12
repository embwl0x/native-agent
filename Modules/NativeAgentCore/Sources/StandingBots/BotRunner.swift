import Foundation

/// The app supplies the ordinary persisted chat client; StandingBots owns only
/// scheduling, serialization, accounting and the dated shelf projection.
public typealias BotRunnerSession = @Sendable (BotDefinition, String) async throws -> BotTurnReply

public struct BotTurnReply: Sendable {
    public var reply: String
    public var artifacts: [BotArtifact]
    public var status: BotRunStatus
    public var detail: String?
    public init(reply: String, artifacts: [BotArtifact] = [], status: BotRunStatus = .completed, detail: String? = nil) {
        self.reply = reply; self.artifacts = artifacts; self.status = status; self.detail = detail
    }
}

public enum BotRunnerError: Error, CustomStringConvertible {
    case budgetStop, notPermitted, dailySpendLimit
    public var description: String {
        switch self {
        case .budgetStop: return "Stopped at the per-run limit."
        case .notPermitted: return "This action is not permitted."
        case .dailySpendLimit: return "Stopped at the daily token ceiling."
        }
    }
}

public actor BotRunner {
    private let queue: BotRunQueue
    private let shelf: ShelfStore
    private let session: BotRunnerSession
    public init(dataRoot: URL, session: @escaping BotRunnerSession) {
        queue = BotRunQueue(dataRoot: dataRoot)
        shelf = ShelfStore(dataRoot: dataRoot)
        self.session = session
    }

    @discardableResult
    public func run(bot id: UUID, requestID: UUID? = nil) async throws -> ShelfEntry? {
        let bot: BotDefinition
        do { bot = try await queue.claimWhenAvailable(bot: id, requestID: requestID) }
        catch BotRunAdmissionError.paused { return nil }
        defer { queue.finish(bot: id) }
        let message = bot.brief + (bot.outputFormat.map { "\n\n" + $0 } ?? "")
        return try await perform(bot, message: message, requestID: requestID)
    }

    public func ask(bot id: UUID, question: String) async throws -> String {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StandingBotsError.invalidValue("question is empty")
        }
        let bot = try await queue.claimWhenAvailable(bot: id, requestID: nil, manual: true)
        defer { queue.finish(bot: id) }
        return try await perform(bot, message: question, requestID: nil).actualReply
    }

    private func perform(_ bot: BotDefinition, message: String, requestID: UUID?) async throws -> ShelfEntry {
        let start = Date()
        let clock = ContinuousClock.now
        var charged = 0
        let outcome: BotTurnReply
        do {
            try queue.reserveDailySpend(tokens: bot.budget.tokens, bot: bot.id,
                ceiling: bot.dailyTokenCeiling ?? BotRunLimits.dailyTokens)
            charged = bot.budget.tokens
            let session = self.session
            // Cancellation settles the ordinary client's transcript before the
            // claim is released. Never abandon a still-writing session task.
            outcome = try await BotRunnerDeadline.settled(seconds: bot.budget.seconds) {
                try await session(bot, message)
            }
        } catch {
            outcome = BotTurnReply(reply: "", status: error is CancellationError || error is BotRunnerError ? .interrupted : .failed,
                detail: String(describing: error))
        }
        let elapsed = clock.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var entry = ShelfEntry(id: requestID ?? UUID(), botId: bot.id, briefVersion: bot.briefVersion,
            runAt: start, coverageStart: start, coverageEnd: max(start, Date()),
            headline: BotHeadline.make(from: outcome.reply), findings: outcome.reply, changedSinceLastGood: "",
            uncertainties: outcome.detail.map { [$0] } ?? [],
            runHealth: outcome.status == .completed ? .ok : outcome.status == .failed ? .failed : .partial,
            spend: ShelfSpend(tokens: charged, seconds: max(0, seconds)))
        entry.reply = outcome.reply
        entry.artifacts = outcome.artifacts
        entry.status = outcome.status
        entry.statusDetail = outcome.detail
        entry.sessionID = bot.sessionID
        try shelf.append(entry)
        return entry
    }
}
