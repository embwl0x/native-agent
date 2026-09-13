import Foundation

/// The app supplies the ordinary persisted chat client; StandingBots owns only
/// scheduling, serialization, accounting and the dated shelf projection.
public typealias BotRunnerSession = @Sendable (BotDefinition, String) async throws -> BotTurnReply

public struct BotTurnReply: Sendable {
    public var reply: String
    public var artifacts: [BotArtifact]
    public var status: BotRunStatus
    public var detail: String?
    /// What the turn actually ran on, as the route resolved it. A bot with no
    /// model choice runs on the agent's own route, and only the client knows
    /// which model that was.
    public var model: String?
    public init(reply: String, artifacts: [BotArtifact] = [], status: BotRunStatus = .completed,
                detail: String? = nil, model: String? = nil) {
        self.reply = reply; self.artifacts = artifacts; self.status = status; self.detail = detail
        self.model = model
    }
}

public enum BotRunnerError: Error, CustomStringConvertible {
    case budgetStop, notPermitted, dailySpendLimit
    /// User, 2026-09-13: a bot runs on the model it was made with. One saved
    /// before that rule has none — or names a route that is not connected — and
    /// is never given one silently. Carries what to fix, in a person's words.
    case cannotRun(String)
    public var description: String {
        switch self {
        case .budgetStop: return "Stopped at the per-run limit."
        case .notPermitted: return "This action is not permitted."
        case .dailySpendLimit: return "Stopped at the daily token ceiling."
        case .cannotRun(let problem): return problem
        }
    }
}

/// The one gate a bot passes before a turn is spent on it. Injected rather than
/// imported: StandingBots owns scheduling and accounting, not provider
/// catalogs, so the app installs the live check (readiness + the route's
/// catalog) at startup and the shape test stands in until it does.
public actor BotRunGate {
    public typealias LiveCheck = @Sendable (BotDefinition, URL) async -> String?
    private static let shared = BotRunGate()
    private var liveCheck: LiveCheck?

    private func install(_ check: @escaping LiveCheck) { liveCheck = check }
    private func run(_ bot: BotDefinition, _ dataRoot: URL) async -> String? {
        await liveCheck?(bot, dataRoot)
    }

    /// Set once by the app: `SwiftNativeProviderRouting.botChoiceRejection`.
    public static func installLiveCheck(_ check: @escaping LiveCheck) async {
        await shared.install(check)
    }

    public static func problem(for bot: BotDefinition, dataRoot: URL) async -> String? {
        if let shape = bot.modelChoiceProblem { return shape }
        return await shared.run(bot, dataRoot)
    }
}

extension BotDefinition {
    /// A bot can only run on a tuple that actually works: a connected route, a
    /// model that route serves, and a Think level that model supports. Bots made
    /// before 2026-09-13 could be saved with none of it and quietly borrowed
    /// Chat's; a half-filled tuple (a route with no Think level, say) would
    /// reach a provider and fail there instead.
    public var needsModelChoice: Bool { modelChoiceProblem != nil }

    /// The shape test — a route, a model and a Think level are all present.
    /// Deliberately local to StandingBots: this module does not depend on
    /// provider catalogs, and a bot card has to render without asking one.
    /// Whether the route is CONNECTED and actually offers that model is the
    /// live test, `SwiftNativeProviderRouting.botChoiceRejection`, run where a
    /// tuple is chosen (the editor, the bot tools) and before a session accepts
    /// one — see `BotRunGate`.
    public var modelChoiceProblem: String? {
        let route = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if route.isEmpty { return "Choose the account this runs on." }
        if id.isEmpty { return "Choose a model on that account." }
        if effort.isEmpty { return "Choose a Think level for that model." }
        return nil
    }
}

public actor BotRunner {
    private let queue: BotRunQueue
    private let shelf: ShelfStore
    private let session: BotRunnerSession
    private let dataRoot: URL
    public init(dataRoot: URL, session: @escaping BotRunnerSession) {
        queue = BotRunQueue(dataRoot: dataRoot)
        shelf = ShelfStore(dataRoot: dataRoot)
        self.dataRoot = dataRoot
        self.session = session
    }

    @discardableResult
    public func run(bot id: UUID, requestID: UUID? = nil) async throws -> ShelfEntry? {
        let claimed: BotRunQueue.ClaimedRun
        do { claimed = try await queue.claimWhenAvailable(bot: id, requestID: requestID) }
        catch BotRunAdmissionError.paused { return nil }
        defer { queue.finish(bot: id) }
        let bot = claimed.bot
        if let problem = await BotRunGate.problem(for: bot, dataRoot: dataRoot) {
            throw BotRunnerError.cannotRun(problem)
        }
        // An event-woken run sees what woke it, from the request this run
        // claimed. Outside text: input for the brief, never an instruction.
        let woke = claimed.context.map { "\n\nWhat woke \(bot.name):\n" + $0 } ?? ""
        let message = bot.brief + woke + (bot.outputFormat.map { "\n\n" + $0 } ?? "")
        return try await perform(bot, message: message, requestID: requestID)
    }

    public func ask(bot id: UUID, question: String) async throws -> String {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StandingBotsError.invalidValue("question is empty")
        }
        let bot = try await queue.claimWhenAvailable(bot: id, requestID: nil, manual: true).bot
        defer { queue.finish(bot: id) }
        if let problem = await BotRunGate.problem(for: bot, dataRoot: dataRoot) {
            throw BotRunnerError.cannotRun(problem)
        }
        return try await perform(bot, message: question, requestID: nil).actualReply
    }

    private func perform(_ bot: BotDefinition, message: String, requestID: UUID?) async throws -> ShelfEntry {
        let start = Date()
        let clock = ContinuousClock.now
        // A refused daily reservation means the turn never started: it is a run
        // that did not happen, not a failed run, so it throws instead of
        // appending a shelf entry. The scheduler records the occurrence missed.
        try queue.reserveDailySpend(tokens: bot.budget.tokens, bot: bot.id,
            ceiling: bot.dailyTokenCeiling ?? BotRunLimits.dailyTokens)
        let charged = bot.budget.tokens
        let outcome: BotTurnReply
        do {
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
        entry.model = outcome.model ?? bot.model
        try shelf.append(entry)
        return entry
    }
}
