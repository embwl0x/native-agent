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
    }
    private let disk: StandingBotsDisk
    private let definitions: BotDefinitionStore
    private let runner: BotRunner
    private let queue: BotRunQueue
    private let shelf: ShelfStore
    public private(set) var failure: String?

    public init(dataRoot: URL, session: @escaping BotRunnerSession) {
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

    private func next(_ bot: BotDefinition, after date: Date) throws -> Date {
        try StandingBotsDisk.nextOccurrence(bot, after: date)
    }

    private func completed(_ id: UUID, at date: Date) throws {
        let bot = try definitions.get(id)
        try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            jobs[id.uuidString] = Job(revision: bot.updatedAt, next: try next(bot, after: date), scheduledFrom: date)
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
                do { jobs[key] = Job(revision: bot.updatedAt, next: try next(bot, after: anchor), scheduledFrom: anchor) }
                catch { jobs[key] = Job(revision: bot.updatedAt, next: .distantFuture,
                                        reason: String(describing: error), failureID: UUID()) }
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

    public func nextDeadline(after now: Date) -> Date? {
        do {
            let bots = try definitions.list()
            let jobs = try reconciled(bots)
            if try queue.pending().keys.contains(where: { jobs[$0.uuidString]?.reason == nil }) { return now }
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
            for bot in bots where !bot.paused {
                try Task.checkCancellation()
                guard reconciledJobs[bot.id.uuidString]?.reason == nil else { continue }
                do {
                let reserved = try disk.locked {
                    var jobs = try disk.read([String: Job].self, at: path) ?? [:]
                    try reconcile(bots, jobs: &jobs)
                    let key = bot.id.uuidString
                    let now = Date()
                    guard let job = jobs[key], job.next <= now else { return false }
                    // Reserve before any network/model work, across processes.
                    // Crash recovery skips this occurrence; never replays spend.
                    jobs[key] = Job(revision: bot.updatedAt,
                                    next: try next(bot, after: now.addingTimeInterval(BotRunLimits.maximumSeconds)),
                                    scheduledFrom: now.addingTimeInterval(BotRunLimits.maximumSeconds))
                    try disk.write(jobs, at: path)
                    return true
                }
                // A manual request also satisfies a coincident due occurrence.
                if reserved, requests[bot.id] == nil, let entry = try await runner.run(bot: bot.id) {
                    try self.completed(bot.id, at: Date())
                    completed.append("bot:\(entry.botId.uuidString)")
                }
                } catch is CancellationError { throw CancellationError() }
                catch { failure = "Bot run unavailable: \(error)" }
            }
        } catch { failure = "Bot run unavailable: \(error)" }
        return completed
    }
}
