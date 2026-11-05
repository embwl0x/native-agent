import Foundation
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `BotRunner.swift` | `BotRunner` actor; `run`, `ask`: shared admission, accounting and typed notification verdicts |

/// Inject the helper's turn runner so scheduling and accounting do not own its model/tool loop.
public typealias BotRunnerSession = @Sendable (BotDefinition, String, Turn, BotRunScope, BotRunOptions) async throws -> BotTurnReply

/// The helper call stack, carried explicitly through nested helper calls.
public struct BotRunScope: Sendable {
    public let ancestry: Set<UUID>
    public init(ancestry: Set<UUID> = []) { self.ancestry = ancestry }
    public func entering(_ id: UUID) -> BotRunScope { .init(ancestry: ancestry.union([id])) }
}

/// The one run's result contract; ordinary and nested chats do not acquire it.
public struct BotRunOptions: Sendable {
    public let conditionSessionID: String?
    public init(conditionSessionID: String? = nil) { self.conditionSessionID = conditionSessionID }
}

public struct BotTurnReply: Sendable {
    public var reply: String
    public var artifacts: [BotArtifact]
    public var status: BotRunStatus
    public var detail: String?
    public var model: String?
    /// Retain approval identity so shelf reads can reconcile the canonical decision.
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
    case cannotRun(String)
    public var description: String {
        switch self {
        case .notPermitted: return "This action is not permitted."
        case .dailySpendLimit: return "Stopped at the daily token ceiling."
        case .cannotRun(let problem): return problem
        }
    }
}

/// Inject provider admission because the app owns live readiness and catalogs; runs wait for installation.
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

    /// Recheck unattended authority after waiting for a claim; queued requests bypass the claim's pause guard.
    /// A true result records the hold before any provider work or daily reservation.
    @discardableResult
    public func run(bot id: UUID, requestID: UUID? = nil, parent: Turn?, scope: BotRunScope,
                    holdUnattended: @Sendable (BotDefinition) async throws -> Bool = { _ in false },
                    deadlineExceeded: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ShelfEntry? {
        let claimed: BotRunQueue.ClaimedRun
        do { claimed = try await queue.claimWhenAvailable(bot: id, requestID: requestID, scope: scope) }
        catch BotRunAdmissionError.paused { return nil }
        defer { queue.finish(bot: id) }
        let bot = claimed.bot
        // Recheck authority before provider admission and daily reservation.
        let held: Bool
        do {
            held = try await holdUnattended(bot)
            if !held { try await prepare(bot, requestID: claimed.runID) }
        } catch {
            throw retireRefusal(claimed, cause: error)
        }
        if held {
            try queue.retireUnstartedClaim(
                bot: id, requestID: claimed.runID,
                detail: "The unattended gate held this request before execution. No helper turn ran."
            )
            return nil
        }
        // Claimed outside text is run input, never authority to instruct the app.
        let woke = claimed.context.map { "\n\nWhat woke \(bot.name):\n" + $0 } ?? ""
        // The working helper supplies its own typed verdict without spending a second model call.
        let condition = bot.notificationCondition?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = condition.flatMap { $0.isEmpty ? nil : $0 }.map {
            """
                \n\nTell me if: \($0)\nAfter finishing your work and tool calls, return only a JSON job result (no Markdown fence): \
                {\"reply\":\"your complete result for the person\",\"condition_met\":true}. condition_met must be a JSON boolean: true \
                if this run's result meets the condition, false if it does not. If you cannot determine it, use null. The app presents \
                reply and uses this structured verdict for the requested notification.
                """
        } ?? ""
        let message = """
            Execute your standing job now. Complete the work and return its result in this turn; do not invoke or wait on your own \
            Run control.
            """ + woke + ask
        var turn = parent?.derived() ?? Turn(session: bot.sessionID)
        turn.session = bot.sessionID
        turn.botEventProvenance = claimed.provenance
        return try await perform(bot, message: message, requestID: claimed.runID,
            turn: turn, scope: scope.entering(id), judgesCondition: !ask.isEmpty, deadlineExceeded: deadlineExceeded)
    }

    /// Return status and cause with the reply so a failed empty answer cannot read as success.
    public func ask(bot id: UUID, question: String, parent: Turn?, scope: BotRunScope) async throws -> ShelfEntry {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StandingBotsError.invalidValue("question is empty")
        }
        let claimed = try await queue.claimWhenAvailable(bot: id, requestID: nil, manual: true, scope: scope)
        let bot = claimed.bot
        defer { queue.finish(bot: id) }
        do { try await prepare(bot, requestID: claimed.runID) }
        catch { throw retireRefusal(claimed, cause: error) }
        let turn = (parent?.derived() ?? Turn(session: bot.sessionID)).with(\.session, bot.sessionID)
        return try await perform(bot, message: question, requestID: claimed.runID,
            turn: turn, scope: scope.entering(id), asked: true)
    }

    public func resume(bot saved: BotDefinition, message: String, parent: Turn?, scope: BotRunScope,
                       holdUnattended: @Sendable (BotDefinition) async -> Bool) async throws -> ShelfEntry {
        let claimed = try await queue.claimWhenAvailable(bot: saved.id, requestID: nil, scope: scope)
        let bot = claimed.bot
        defer { queue.finish(bot: saved.id) }
        do {
            guard bot == saved, !bot.paused, !(await holdUnattended(bot)) else { throw BotRunnerError.notPermitted }
            try await prepare(bot, requestID: claimed.runID)
        } catch { throw retireRefusal(claimed, cause: error) }
        let turn = (parent?.derived() ?? Turn(session: bot.sessionID)).with(\.session, bot.sessionID)
        return try await perform(bot, message: message, requestID: claimed.runID,
            turn: turn, scope: scope.entering(bot.id))
    }

    private func retireRefusal(_ claimed: BotRunQueue.ClaimedRun, cause: Error) -> Error {
        do {
            try queue.retireUnstartedClaim(bot: claimed.bot.id, requestID: claimed.runID, detail: String(describing: cause))
            return cause
        }
        catch {
            return BotRunnerError.cannotRun("""
                Request \(claimed.runID) did not execute: \(cause). Its refused claim could not be retired: \(error). Repair that exact \
                claim before requesting more work.
                """)
        }
    }

    /// Share provider/accounting admission across entry points and retire refusals under their exact claim lock.
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

    private func perform(_ bot: BotDefinition, message: String, requestID: UUID,
                         turn: Turn, scope: BotRunScope, asked: Bool = false,
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
                try await session(bot, message, turn, scope,
                    BotRunOptions(conditionSessionID: judgesCondition ? bot.sessionID : nil))
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
        // Duration proves no coverage window, and a budget reservation proves no measured usage.
        // Health follows the observed outcome; an empty completed reply proves no findings.
        let health: ShelfRunHealth
        switch outcome.status {
        case .completed:
            health = outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .nothingNew : .ok
        case .failed: health = .failed
        // Waiting on a person is a partial result, not damaged execution.
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
