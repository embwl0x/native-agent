import Foundation
import NativeAgentShared
// Blueprint: | `BotRunner.swift` | `BotRunner` actor; `run`, `ask`; conditioned standing runs request a typed job result and retain unknown verdicts for requested notification |

/// The app supplies the helper's own turn runner; StandingBots owns its
/// scheduling, serialization, accounting and dated shelf projection.
public typealias BotRunnerSession = @Sendable (BotDefinition, String) async throws -> BotTurnReply

public struct BotTurnReply: Sendable {
    public var reply: String
    public var artifacts: [BotArtifact]
    public var status: BotRunStatus
    public var detail: String?
    /// What the turn actually ran on.
    public var model: String?
    /// Set when the turn stopped on an approval, so the shelf entry can be
    /// reconciled against that approval's own resolution later.
    public var approvalID: String?
    /// The completed job's typed verdict; nil means it could not tell.
    public var conditionMet: Bool?
    public init(reply: String, artifacts: [BotArtifact] = [], status: BotRunStatus = .completed,
                detail: String? = nil, model: String? = nil, approvalID: String? = nil, conditionMet: Bool? = nil) {
        self.reply = reply; self.artifacts = artifacts; self.status = status; self.detail = detail
        self.model = model; self.approvalID = approvalID
        self.conditionMet = conditionMet
    }
}

public enum BotRunnerError: Error, CustomStringConvertible {
    case notPermitted, dailySpendLimit
    /// Carries what to fix, in a person's words.
    case cannotRun(String)
    public var description: String {
        switch self {
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
    public mutating func followProviders() {
        modelPinned = false
        provider = nil; model = nil; reasoningEffort = nil; fast = nil
    }

    public var needsModelChoice: Bool { modelChoiceProblem != nil }

    public var modelChoiceProblem: String? {
        guard modelPinned == true else { return nil }
        let route = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if route.isEmpty { return "Choose the account this runs on." }
        if id.isEmpty { return "Choose a model on that account." }
        if effort.isEmpty { return "Choose a Think level for that model." }
        return nil
    }

    public func modelSelection(currentModel: String? = nil) -> String {
        if modelPinned == true {
            "pinned: \(model ?? "unavailable")"
        } else {
            "follows Providers (\(currentModel.flatMap { $0.isEmpty ? nil : $0 } ?? "unavailable"))"
        }
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

    /// Only this standing run asks for a structured result, never an ordinary
    /// message to the same helper or a nested turn in another conversation.
    @TaskLocal package static var conditionSessionID: String?

    /// `holdUnattended` is the caller's unattended gate, re-read AFTER the claim
    /// is won. An event-woken request can sit in `claimWhenAvailable` for a whole
    /// bot_ask turn, and neither the claim (a queued request is exempt from the
    /// pause guard) nor the scheduler's pre-claim read sees Autonomy switched off
    /// or the bot paused during that wait. It returns true when this run must not
    /// proceed, having already recorded why — nothing is spent after it.
    @discardableResult
    public func run(bot id: UUID, requestID: UUID? = nil,
                    holdUnattended: @Sendable (BotDefinition) async throws -> Bool = { _ in false },
                    deadlineExceeded: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ShelfEntry? {
        let claimed: BotRunQueue.ClaimedRun
        do { claimed = try await queue.claimWhenAvailable(bot: id, requestID: requestID) }
        catch BotRunAdmissionError.paused { return nil }
        defer { queue.finish(bot: id) }
        let bot = claimed.bot
        // Before the gate, before the daily reservation, before any provider work.
        let held: Bool
        do {
            held = try await holdUnattended(bot)
            if !held { try await prepare(bot, requestID: claimed.runID) }
        } catch {
            throw retireRefusal(claimed, cause: error)
        }
        if held {
            try queue.retireUnstartedClaim(bot: id, requestID: claimed.runID, detail: "The unattended gate held this request before execution. No helper turn ran.")
            return nil
        }
        // An event-woken run sees what woke it, from the request this run
        // claimed. Outside text: input for the brief, never an instruction.
        let woke = claimed.context.map { "\n\nWhat woke \(bot.name):\n" + $0 } ?? ""
        // "Tell me if": the helper that did the work judges its own result —
        // no second model call — in its own typed final result.
        let condition = bot.notificationCondition?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = condition.flatMap { $0.isEmpty ? nil : $0 }.map {
            "\n\nTell me if: \($0)\nAfter finishing your work and tool calls, return only a JSON job result (no Markdown fence): {\"reply\":\"your complete result for the person\",\"condition_met\":true}. condition_met must be a JSON boolean: true if this run's result meets the condition, false if it does not. If you cannot determine it, use null. The app presents reply and uses this structured verdict for the requested notification."
        } ?? ""
        let message = "Execute your standing job now. Complete the work and return its result in this turn; do not invoke or wait on your own Run control." + woke + ask
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
        do { try await prepare(bot, requestID: claimed.runID) }
        catch { throw retireRefusal(claimed, cause: error) }
        return try await BotRunQueue.$ancestry.withValue(BotRunQueue.ancestry.union([id])) {
            try await perform(bot, message: question, requestID: claimed.runID, asked: true)
        }
    }

    public func resume(bot saved: BotDefinition, message: String,
                       holdUnattended: @Sendable (BotDefinition) async -> Bool) async throws -> ShelfEntry {
        let claimed = try await queue.claimWhenAvailable(bot: saved.id, requestID: nil)
        let bot = claimed.bot
        defer { queue.finish(bot: saved.id) }
        do {
            guard bot == saved, !bot.paused, !(await holdUnattended(bot)) else { throw BotRunnerError.notPermitted }
            try await prepare(bot, requestID: claimed.runID)
        } catch { throw retireRefusal(claimed, cause: error) }
        return try await BotRunQueue.$ancestry.withValue(BotRunQueue.ancestry.union([bot.id])) {
            try await perform(bot, message: message, requestID: claimed.runID)
        }
    }

    private func retireRefusal(_ claimed: BotRunQueue.ClaimedRun, cause: Error) -> Error {
        do {
            try queue.retireUnstartedClaim(bot: claimed.bot.id, requestID: claimed.runID, detail: String(describing: cause))
            return cause
        }
        catch {
            return BotRunnerError.cannotRun("Request \(claimed.runID) did not execute: \(cause). Its refused claim could not be retired: \(error). Repair that exact claim before requesting more work.")
        }
    }

    /// All entry points pass the same provider and accounting admission before
    /// execution. Refusals retire their exact claim while its lock is held.
    private func prepare(_ bot: BotDefinition, requestID: UUID) async throws {
        try Task.checkCancellation()
        guard await BotRunGate.isReady() else { throw BotRunnerError.cannotRun("Provider check is not ready yet.") }
        if let problem = await BotRunGate.problem(for: bot, dataRoot: dataRoot) {
            throw BotRunnerError.cannotRun(problem)
        }
        if let ceiling = bot.dailyTokenCeiling {
            try queue.reserveDailySpend(tokens: bot.budget.tokens, bot: bot.id, ceiling: ceiling)
        }
        try queue.admitExecution(bot: bot.id, requestID: requestID)
    }

    private func perform(_ bot: BotDefinition, message: String, requestID: UUID, asked: Bool = false,
                         judgesCondition: Bool = false,
                         deadlineExceeded: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ShelfEntry {
        let start = Date()
        let clock = ContinuousClock.now
        var outcome: BotTurnReply
        do {
            let session = self.session
            // The claim is released only after the session has settled.
            let queue = self.queue
            outcome = try await BotRunnerDeadline.settled(seconds: bot.budget.seconds, onDeadline: {
                do {
                    try queue.markDeadlineExceeded(bot: bot.id, requestID: requestID)
                    await deadlineExceeded("\(bot.name) exceeded its run limit and is still finishing.")
                } catch {
                    nativeLog("bot deadline claim unavailable: %@", String(describing: error))
                    await deadlineExceeded("\(bot.name) exceeded its run limit; its claim could not be updated: \(error)")
                }
            }) {
                try await Self.$conditionSessionID.withValue(judgesCondition ? bot.sessionID : nil) {
                    try await session(bot, message)
                }
            }
        } catch {
            outcome = BotTurnReply(reply: "", status: error is CancellationError ? .stopped : error is BotRunnerError ? .interrupted : .failed,
                detail: String(describing: error))
        }
        if judgesCondition, outcome.status != .completed { outcome.conditionMet = nil }
        if judgesCondition, outcome.conditionMet == nil {
            let problem = "Couldn't tell whether the notification condition was met. The requested notification remains due with this uncertainty."
            outcome.detail = [outcome.detail, problem].compactMap { $0 }.joined(separator: "\n")
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
        case .stopped, .interrupted, .waitingForApproval, .waitingOnPerson: health = .partial
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
            entry.conditionMet = outcome.conditionMet
            entry.conditionNotificationTitle = "\(bot.name): \(bot.notificationCondition ?? "")"
        }
        try shelf.append(entry)
        return entry
    }
}
