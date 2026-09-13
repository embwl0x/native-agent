import Foundation
import PersistenceCore
import TriggerScheduler

/// One persisted due/reservation record per definition, projected into the
/// existing BackgroundLoops deadline owner. Definitions remain canonical.
public actor BotRunnerScheduler {
    private struct Job: Codable, Equatable {
        let revision: Date
        var next: Date
        var reason: String? = nil
        var failureID: UUID? = nil
        var minimumInterval: TimeInterval? = BotRunLimits.minimumInterval
        var scheduledFrom: Date? = nil
        /// The last occurrence this scheduler found already past its window.
        var missed: BotMissedRun? = nil
    }
    /// When this scheduler came up, fixed at construction — a `static let` would
    /// be initialized on first read, which is always after the due date and
    /// would call every overdue occurrence "the app was closed".
    private let startedAt = Date()
    private let disk: StandingBotsDisk
    private let definitions: BotDefinitionStore
    private let runner: BotRunner
    private let queue: BotRunQueue
    private let shelf: ShelfStore
    /// The master Autonomy switch, read fresh before every unattended admission.
    /// Scheduled bot work is exactly the unattended provider spend that switch
    /// exists to stop (it gates Workshop the same way). An explicitly queued
    /// manual request is the user asking and stays outside it. Default `true`
    /// keeps secondary/test roots, which have no trust policy, unchanged.
    private let isAutonomyEnabled: @Sendable () async -> Bool
    public private(set) var failure: String?

    public init(
        dataRoot: URL,
        session: @escaping BotRunnerSession,
        isAutonomyEnabled: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.isAutonomyEnabled = isAutonomyEnabled
        disk = StandingBotsDisk(dataRoot: dataRoot)
        shelf = ShelfStore(dataRoot: dataRoot)
        definitions = BotDefinitionStore(dataRoot: dataRoot)
        runner = BotRunner(dataRoot: dataRoot, session: session)
        queue = BotRunQueue(dataRoot: dataRoot)
    }

    private var path: URL { disk.root.appendingPathComponent("runner-jobs.json") }

    /// Read the scheduler's saved projection without reconciling or moving a deadline.
    public static func scheduledDates(dataRoot: URL) throws -> [UUID: Date] {
        let disk = StandingBotsDisk(dataRoot: dataRoot)
        return try disk.locked {
            let jobs = try disk.read([String: Job].self, at: disk.root.appendingPathComponent("runner-jobs.json")) ?? [:]
            return Dictionary(uniqueKeysWithValues: jobs.compactMap { key, job in
                guard let id = UUID(uuidString: key), job.reason == nil, job.next != .distantFuture else { return nil }
                return (id, job.next)
            })
        }
    }

    /// The last missed occurrence per definition, for the Bots page and the Desk.
    public static func missedRuns(dataRoot: URL) throws -> [UUID: BotMissedRun] {
        let disk = StandingBotsDisk(dataRoot: dataRoot)
        return try disk.locked {
            let jobs = try disk.read([String: Job].self, at: disk.root.appendingPathComponent("runner-jobs.json")) ?? [:]
            return Dictionary(uniqueKeysWithValues: jobs.compactMap { key, job in
                guard let id = UUID(uuidString: key), let missed = job.missed else { return nil }
                return (id, missed)
            })
        }
    }

    /// How late an occurrence may be and still just run late. Being later than
    /// one whole cadence (never less than the floor) means the window passed.
    private static func lateness(_ bot: BotDefinition) -> TimeInterval {
        guard case .interval(let seconds) = bot.cadence else { return BotRunLimits.minimumInterval }
        return max(seconds, BotRunLimits.minimumInterval)
    }

    private func next(_ bot: BotDefinition, after date: Date) throws -> Date {
        try StandingBotsDisk.nextOccurrence(bot, after: date)
    }

    private func completed(_ id: UUID, at date: Date) throws {
        let bot = try definitions.get(id)
        try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            jobs[id.uuidString] = Job(revision: bot.updatedAt, next: try next(bot, after: date), scheduledFrom: date,
                                      missed: jobs[id.uuidString]?.missed)
            try disk.write(jobs, at: path)
        }
    }

    private func reconcile(_ bots: [BotDefinition], jobs: inout [String: Job]) throws {
        let ids = Set(bots.map { $0.id.uuidString })
        jobs = jobs.filter { ids.contains($0.key) }
        for bot in bots where !bot.paused {
            let key = bot.id.uuidString
            // Jobs saved before the preference existed already use the 15-minute floor.
            if jobs[key]?.revision != bot.updatedAt || (jobs[key]?.minimumInterval ?? 15 * 60) != BotRunLimits.minimumInterval {
                let anchor = jobs[key]?.revision == bot.updatedAt
                    ? (jobs[key]?.scheduledFrom ?? max(bot.updatedAt, Date())) : bot.updatedAt
                // An edit reschedules the bot; it does not erase the record of
                // an occurrence that never ran.
                let missed = jobs[key]?.missed
                do { jobs[key] = Job(revision: bot.updatedAt, next: try next(bot, after: anchor), scheduledFrom: anchor,
                                     missed: missed) }
                catch { jobs[key] = Job(revision: bot.updatedAt, next: .distantFuture,
                                        reason: String(describing: error), failureID: UUID(), missed: missed) }
            }
        }
        guard jobs.values.allSatisfy({ $0.next.timeIntervalSince1970.isFinite && $0.revision.timeIntervalSince1970.isFinite }) else {
            throw StandingBotsError.corruptStore("bot scheduler dates")
        }
    }

    private func reconciled(_ bots: [BotDefinition]) throws -> [String: Job] {
        let jobs = try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            let previous = jobs
            try reconcile(bots, jobs: &jobs)
            // Deadline projection and due-work selection both come through
            // here. Replacing an unchanged watched file wakes the scheduler
            // again, including its inbox/dream scans, indefinitely.
            if jobs != previous {
                try disk.write(jobs, at: path)
            }
            return jobs
        }
        for bot in bots {
            guard let job = jobs[bot.id.uuidString], let reason = job.reason, let id = job.failureID else { continue }
            failure = "Bot scheduling unavailable: \(reason)"
            do {
                try shelf.append(ShelfEntry(id: id, botId: bot.id, briefVersion: bot.briefVersion,
                    runAt: job.revision, coverageStart: job.revision, coverageEnd: job.revision,
                    headline: "Could not check", findings: "", changedSinceLastGood: "Unknown: invalid schedule.",
                    uncertainties: [reason], runHealth: .failed, spend: ShelfSpend(tokens: 0, seconds: 0)))
            } catch StandingBotsError.alreadyExists { /* Already reported this definition revision. */ }
        }
        return jobs
    }

    /// This scheduler's own last pass. The gap between two passes is the only
    /// positive evidence it has that the machine stopped running it.
    private struct Tick: Codable { var at: Date }
    private var tickPath: URL { disk.root.appendingPathComponent("runner-tick.json") }

    /// A due occurrence whose window has passed with no run: record it, skip it,
    /// schedule the next one. A record, not a retry — the Autonomy gate stands.
    private func noteMissed(_ bots: [BotDefinition], autonomyEnabled: Bool) {
        let now = Date()
        let live = bots.filter { !$0.paused }
        guard !live.isEmpty else { return }
        do {
            try disk.locked {
                var jobs = try disk.read([String: Job].self, at: path) ?? [:]
                let lastTick = try disk.read(Tick.self, at: tickPath)?.at
                var changed = false
                for bot in live {
                    let key = bot.id.uuidString
                    guard var job = jobs[key], job.reason == nil, job.next != .distantFuture,
                          now.timeIntervalSince(job.next) > Self.lateness(bot) else { continue }
                    job.missed = BotMissedRun(dueAt: job.next, reason: Self.reason(
                        bot, due: job.next, autonomyEnabled: autonomyEnabled,
                        startedAt: startedAt, lastTick: lastTick, now: now))
                    job.next = try next(bot, after: now)
                    job.scheduledFrom = now
                    jobs[key] = job
                    changed = true
                }
                if changed { try disk.write(jobs, at: path) }
                try disk.write(Tick(at: now), at: tickPath)
            }
        } catch { failure = "Bot scheduling unavailable: \(error)" }
    }

    /// Only what the scheduler can prove: the gate was shut; or no scheduler
    /// existed when the occurrence came due; or one did and its own tick record
    /// shows it never ran a pass across that window — a machine that stopped.
    /// Anything else is the honest blank.
    private static func reason(_ bot: BotDefinition, due: Date, autonomyEnabled: Bool,
                               startedAt: Date, lastTick: Date?, now: Date) -> BotMissedRun.Reason {
        guard autonomyEnabled else { return .autonomyOff }
        if due < startedAt { return .appClosed }
        guard let lastTick, lastTick < due, now.timeIntervalSince(lastTick) > lateness(bot) else { return .notRun }
        return .asleep
    }

    /// An occurrence that reached the runner and never ran.
    private func recordMissed(_ id: UUID, due: Date, reason: BotMissedRun.Reason) throws {
        try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            guard var job = jobs[id.uuidString] else { return }
            job.missed = BotMissedRun(dueAt: due, reason: reason)
            jobs[id.uuidString] = job
            try disk.write(jobs, at: path)
        }
    }

    public func nextDeadline(after now: Date) async -> Date? {
        do {
            let bots = try definitions.list()
            let jobs = try reconciled(bots)
            if try queue.pending().keys.contains(where: { jobs[$0.uuidString]?.reason == nil }) { return now }
            // Autonomy off: no scheduled occurrence is admissible, so none is a
            // deadline either. Reporting one would wake this loop on a due job
            // the gate then refuses, forever.
            guard await isAutonomyEnabled() else { return nil }
            return bots.filter { !$0.paused && jobs[$0.id.uuidString]?.reason == nil }
                .compactMap { jobs[$0.id.uuidString]?.next }.min()
        } catch { failure = "Bot scheduling unavailable: \(error)"; return nil }
    }

    public func runDue() async -> [String] {
        failure = nil
        var completed: [String] = []
        do {
            let bots = try definitions.list()
            let reconciledJobs = try reconciled(bots)
            let requests = try queue.pending()
            for (id, requestID) in requests {
                try Task.checkCancellation()
                guard reconciledJobs[id.uuidString]?.reason == nil else {
                    try queue.rejectPending(bot: id, requestID: requestID)
                    continue
                }
                do {
                    if let entry = try await runner.run(bot: id, requestID: requestID) {
                        try self.completed(id, at: Date())
                        completed.append("bot:\(entry.botId.uuidString)")
                    }
                } catch let error as BotRunAdmissionError {
                    failure = "Bot request rejected: \(error.rawValue)"
                } catch is CancellationError { throw CancellationError() }
                catch { failure = "Bot request unavailable: \(error)" }
            }
            let autonomyEnabled = await isAutonomyEnabled()
            noteMissed(bots, autonomyEnabled: autonomyEnabled)
            // Unattended admission boundary: scheduled occurrences only.
            guard autonomyEnabled else { return completed }
            for bot in bots where !bot.paused {
                try Task.checkCancellation()
                guard reconciledJobs[bot.id.uuidString]?.reason == nil else { continue }
                do {
                let reserved: Date? = try disk.locked {
                    var jobs = try disk.read([String: Job].self, at: path) ?? [:]
                    try reconcile(bots, jobs: &jobs)
                    let key = bot.id.uuidString
                    let now = Date()
                    guard let job = jobs[key], job.next <= now else { return nil }
                    let due = job.next
                    // Reserve before any network/model work, across processes.
                    // Crash recovery skips this occurrence; never replays spend.
                    jobs[key] = Job(revision: bot.updatedAt,
                                    next: try next(bot, after: now.addingTimeInterval(BotRunLimits.maximumSeconds)),
                                    scheduledFrom: now.addingTimeInterval(BotRunLimits.maximumSeconds),
                                    missed: jobs[key]?.missed)
                    try disk.write(jobs, at: path)
                    return due
                }
                // A manual request also satisfies a coincident due occurrence.
                if let due = reserved, requests[bot.id] == nil {
                    do {
                        if let entry = try await runner.run(bot: bot.id) {
                            try self.completed(bot.id, at: Date())
                            completed.append("bot:\(entry.botId.uuidString)")
                        } else {
                            // Claimed nothing — the bot was paused under us.
                            try recordMissed(bot.id, due: due, reason: .notRun)
                        }
                    } catch let error as BotRunAdmissionError {
                        // Refused admission, so this occurrence never ran.
                        try recordMissed(bot.id, due: due,
                                         reason: error == .overBudget ? .overBudget : .queueBusy)
                        failure = "Bot request rejected: \(error.rawValue)"
                    } catch BotRunnerError.dailySpendLimit {
                        // The turn never started: no spend, no shelf entry.
                        try recordMissed(bot.id, due: due, reason: .overBudget)
                        failure = "Bot request rejected: \(BotRunnerError.dailySpendLimit.description)"
                    }
                }
                } catch is CancellationError { throw CancellationError() }
                catch { failure = "Bot run unavailable: \(error)" }
            }
        } catch { failure = "Bot run unavailable: \(error)" }
        return completed
    }
}
