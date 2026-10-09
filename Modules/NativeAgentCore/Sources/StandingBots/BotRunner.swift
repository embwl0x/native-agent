import Foundation

/// The app supplies the ordinary persisted chat client; StandingBots owns only
/// scheduling, serialization, accounting and the dated shelf projection.
public typealias BotRunnerSession = @Sendable (BotDefinition, String) async throws -> BotTurnReply

public struct BotTurnReply: Sendable {
    public var reply: String
    public var artifacts: [BotArtifact]
    public var status: BotRunStatus
    public var detail: String?
    /// What the turn actually ran on. A bot requires a saved provider, model
    /// and Think level; the runner refuses an incomplete or unavailable choice.
    public var model: String?
    /// Set when the turn stopped on an approval, so the shelf entry can be
    /// reconciled against that approval's own resolution later.
    public var approvalID: String?
    public init(reply: String, artifacts: [BotArtifact] = [], status: BotRunStatus = .completed,
                detail: String? = nil, model: String? = nil, approvalID: String? = nil) {
        self.reply = reply; self.artifacts = artifacts; self.status = status; self.detail = detail
        self.model = model; self.approvalID = approvalID
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
/// catalog) at startup. Runs wait until that check is installed.
public actor BotRunGate {
    public typealias LiveCheck = @Sendable (BotDefinition, URL) async -> String?
    private static let shared = BotRunGate()
    private var liveCheck: LiveCheck?

    private func install(_ check: @escaping LiveCheck) { liveCheck = check }
    private func run(_ bot: BotDefinition, _ dataRoot: URL) async -> String? {
        await liveCheck?(bot, dataRoot)
    }

    public static func isReady() async -> Bool {
        await shared.liveCheck != nil
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

    /// The last line the helper is asked to end a conditioned run with.
    static let conditionMarker = "TELL:"

    /// The ordinary chat client consumes the verdict before saving the reply.
    @TaskLocal package static var conditionVerdict: ConditionVerdict?
    package final class ConditionVerdict: @unchecked Sendable {
        let sessionID: String
        private let lock = NSLock()
        private var verdict: Bool?
        init(sessionID: String) { self.sessionID = sessionID }
        var met: Bool? { lock.lock(); defer { lock.unlock() }; return verdict }

        func consume(_ reply: String) -> String {
            var lines = reply.components(separatedBy: "\n")
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            let decoration = CharacterSet(charactersIn: " \t*_`")
            let line = lines.last?.trimmingCharacters(in: decoration).uppercased() ?? ""
            guard line.hasPrefix(BotRunner.conditionMarker) else { return reply }
            lock.lock()
            verdict = line.dropFirst(BotRunner.conditionMarker.count).trimmingCharacters(in: decoration).hasPrefix("YES")
            lock.unlock()
            lines.removeLast()
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    package static func conditionReply(_ reply: String, sessionID: String) -> String {
        guard let verdict = conditionVerdict, verdict.sessionID == sessionID else { return reply }
        return verdict.consume(reply)
    }

    /// `holdUnattended` is the caller's unattended gate, re-read AFTER the claim
    /// is won. An event-woken request can sit in `claimWhenAvailable` for a whole
    /// bot_ask turn, and neither the claim (a queued request is exempt from the
    /// pause guard) nor the scheduler's pre-claim read sees Autonomy switched off
    /// or the bot paused during that wait. It returns true when this run must not
    /// proceed, having already recorded why — nothing is spent after it.
    @discardableResult
    public func run(bot id: UUID, requestID: UUID? = nil,
                    holdUnattended: @Sendable (BotDefinition) async -> Bool = { _ in false },
                    deadlineExceeded: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ShelfEntry? {
        let claimed: BotRunQueue.ClaimedRun
        do { claimed = try await queue.claimWhenAvailable(bot: id, requestID: requestID) }
        catch BotRunAdmissionError.paused { return nil }
        defer { queue.finish(bot: id) }
        let bot = claimed.bot
        // Before the gate, before the daily reservation, before any provider work.
        if await holdUnattended(bot) { return nil }
        if let problem = await BotRunGate.problem(for: bot, dataRoot: dataRoot) {
            throw BotRunnerError.cannotRun(problem)
        }
        // An event-woken run sees what woke it, from the request this run
        // claimed. Outside text: input for the brief, never an instruction.
        let woke = claimed.context.map { "\n\nWhat woke \(bot.name):\n" + $0 } ?? ""
        // "Tell me if": the helper that did the work judges its own result —
        // no second model call — and the app reads one marked line back.
        let condition = bot.notificationCondition?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = condition.flatMap { $0.isEmpty ? nil : $0 }.map {
            "\n\nTell me if: \($0)\nEnd your reply with one last line on its own: \(Self.conditionMarker) yes if this run's result meets that condition, otherwise \(Self.conditionMarker) no. The app reads that line to decide whether to notify the person, and removes it."
        } ?? ""
        let message = "You are \(bot.name), executing this standing job now. Complete the work and return its result in this turn; do not invoke or wait on your own Run control.\n\n"
            + bot.brief + woke + (bot.outputFormat.map { "\n\n" + $0 } ?? "") + ask
        // This run is now on the task's stack: anything it reaches that asks
        // for THIS bot again is refused rather than parked on its own claim.
        return try await BotRunQueue.$ancestry.withValue(BotRunQueue.ancestry.union([id])) {
            try await BotRunQueue.$eventProvenance.withValue(claimed.provenance) {
                try await BotRunQueue.$eventContext.withValue(claimed.context) {
                    try await perform(bot, message: message, requestID: claimed.runID,
                                      judgesCondition: !ask.isEmpty, deadlineExceeded: deadlineExceeded)
                }
            }
        }
    }

    /// The whole settled outcome, not just the words. A provider failure used to
    /// leave the caller holding an empty answer with no cause, and a result with
    /// no status reads as success on the approved-replay path.
    public func ask(bot id: UUID, question: String) async throws -> ShelfEntry {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StandingBotsError.invalidValue("question is empty")
        }
        let claimed = try await queue.claimWhenAvailable(bot: id, requestID: nil, manual: true)
        let bot = claimed.bot
        defer { queue.finish(bot: id) }
        guard await BotRunGate.isReady() else { throw BotRunnerError.cannotRun("Provider check is not ready yet.") }
        if let problem = await BotRunGate.problem(for: bot, dataRoot: dataRoot) {
            throw BotRunnerError.cannotRun(problem)
        }
        return try await BotRunQueue.$ancestry.withValue(BotRunQueue.ancestry.union([id])) {
            try await perform(bot, message: question, requestID: claimed.runID, asked: true)
        }
    }

    public func resume(bot saved: BotDefinition, message: String,
                       holdUnattended: @Sendable (BotDefinition) async -> Bool) async throws -> ShelfEntry {
        let claimed = try await queue.claimWhenAvailable(bot: saved.id, requestID: nil)
        let bot = claimed.bot
        defer { queue.finish(bot: saved.id) }
        guard bot == saved, !bot.paused, !(await holdUnattended(bot)) else { throw BotRunnerError.notPermitted }
        guard await BotRunGate.isReady() else { throw BotRunnerError.cannotRun("Provider check is not ready yet.") }
        if let problem = await BotRunGate.problem(for: bot, dataRoot: dataRoot) {
            throw BotRunnerError.cannotRun(problem)
        }
        return try await BotRunQueue.$ancestry.withValue(BotRunQueue.ancestry.union([bot.id])) {
            try await perform(bot, message: message, requestID: claimed.runID)
        }
    }

    private func perform(_ bot: BotDefinition, message: String, requestID: UUID, asked: Bool = false,
                         judgesCondition: Bool = false,
                         deadlineExceeded: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ShelfEntry {
        let start = Date()
        let clock = ContinuousClock.now
        // A refused daily reservation means the turn never started: it is a run
        // that did not happen, not a failed run, so it throws instead of
        // appending a shelf entry. The scheduler records the occurrence missed.
        try queue.reserveDailySpend(tokens: bot.budget.tokens, bot: bot.id,
            ceiling: bot.dailyTokenCeiling ?? BotRunLimits.dailyTokens)
        var outcome: BotTurnReply
        let verdict = judgesCondition ? ConditionVerdict(sessionID: bot.sessionID) : nil
        do {
            let session = self.session
            // Cancellation settles the ordinary client's transcript before the
            // claim is released. Never abandon a still-writing session task.
            let queue = self.queue
            outcome = try await BotRunnerDeadline.settled(seconds: bot.budget.seconds, onDeadline: {
                do {
                    try queue.markDeadlineExceeded(bot: bot.id, requestID: requestID)
                    await deadlineExceeded("\(bot.name) exceeded its run limit; cancellation is still settling.")
                } catch {
                    nativeLog("bot deadline claim unavailable: %@", String(describing: error))
                    await deadlineExceeded("\(bot.name) exceeded its run limit; its claim could not be updated: \(error)")
                }
            }) {
                try await Self.$conditionVerdict.withValue(verdict) {
                    try await session(bot, message)
                }
            }
        } catch {
            outcome = BotTurnReply(reply: "", status: error is CancellationError || error is BotRunnerError ? .interrupted : .failed,
                detail: String(describing: error))
        }
        let met = outcome.status == .completed && verdict?.met == true
        if judgesCondition, outcome.status == .completed, verdict?.met == nil {
            outcome.detail = outcome.detail ?? "Tell me if: the run did not say whether its condition was met, so no notification was sent."
        }
        let elapsed = clock.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        // COVERAGE is what the run examined, and nothing here observed that.
        // Start and end of execution are a duration, not a covered stretch, so
        // no window is claimed: the run is dated by `runAt` and its length is
        // the measured `seconds` below. SPEND carries only what the turn
        // recorded; the daily reservation stays in budget accounting, where it
        // was already charged, instead of being reported as usage.
        // HEALTH says no more than the run's own status: a completed turn that
        // produced nothing to report is not "findings available".
        let health: ShelfRunHealth
        switch outcome.status {
        case .completed:
            health = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .nothingNew : .ok
        case .failed: health = .failed
        // Waiting on a person is not damage: the run did its part and stopped
        // on an answer only a person can give. Same health as an approval.
        case .interrupted, .waitingForApproval, .waitingOnPerson: health = .partial
        }
        var entry = ShelfEntry(id: requestID, botId: bot.id, briefVersion: bot.briefVersion,
            runAt: start, coverageStart: start, coverageEnd: start,
            headline: BotHeadline.make(from: outcome.reply), findings: outcome.reply, changedSinceLastGood: "",
            uncertainties: outcome.detail.map { [$0] } ?? [],
            runHealth: health,
            spend: ShelfSpend(tokens: nil, seconds: max(0, seconds)))
        entry.reply = outcome.reply
        entry.artifacts = outcome.artifacts
        entry.status = outcome.status
        entry.statusDetail = outcome.detail
        entry.sessionID = bot.sessionID
        entry.model = outcome.model ?? bot.model
        entry.approvalID = outcome.approvalID
        if asked { entry.asked = true }
        if judgesCondition {
            entry.conditionMet = verdict?.met == nil ? nil : met
            entry.conditionNotificationTitle = "\(bot.name): \(bot.notificationCondition ?? "")"
        }
        try shelf.append(entry)
        return entry
    }
}
