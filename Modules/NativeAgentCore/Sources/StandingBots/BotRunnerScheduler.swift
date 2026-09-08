import Foundation
import PersistenceCore
import TriggerScheduler

/// One persisted due/reservation record per definition, projected into the
/// existing BackgroundLoops deadline owner. Definitions remain canonical.
public actor BotRunnerScheduler {
    private struct Job: Codable {
        let revision: Date
        var next: Date
        var reason: String? = nil
        var failureID: UUID? = nil
    }
    private let disk: StandingBotsDisk
    private let definitions: BotDefinitionStore
    private let runner: BotRunner
    private let queue: BotRunQueue
    private let shelf: ShelfStore
    public private(set) var failure: String?

    public init(dataRoot: URL, session: @escaping BotRunnerSession,
                fetch: @escaping BotRunnerFetch = BotRunnerHTTP.fetch,
                admission: @escaping BotRunnerAdmission = { false },
                toolSession: BotRunnerToolSession? = nil,
                compact: BotContextCompactor? = nil) {
        disk = StandingBotsDisk(dataRoot: dataRoot)
        shelf = ShelfStore(dataRoot: dataRoot)
        definitions = BotDefinitionStore(dataRoot: dataRoot)
        if let compact {
            runner = BotRunner(dataRoot: dataRoot, session: session, fetch: fetch, admission: admission,
                               toolSession: toolSession, compact: compact)
        } else {
            runner = BotRunner(dataRoot: dataRoot, session: session, fetch: fetch, admission: admission, toolSession: toolSession)
        }
        queue = BotRunQueue(dataRoot: dataRoot)
    }

    private var path: URL { disk.root.appendingPathComponent("runner-jobs.json") }

    private func next(_ bot: BotDefinition, after date: Date) throws -> Date {
        try StandingBotsDisk.nextOccurrence(bot, after: date)
    }

    private func completed(_ id: UUID, at date: Date) throws {
        let bot = try definitions.get(id)
        try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            jobs[id.uuidString] = Job(revision: bot.updatedAt, next: try next(bot, after: date))
            try disk.write(jobs, at: path)
        }
    }

    private func reconcile(_ bots: [BotDefinition], jobs: inout [String: Job]) throws {
        let ids = Set(bots.map { $0.id.uuidString })
        jobs = jobs.filter { ids.contains($0.key) }
        for bot in bots where !bot.paused {
            let key = bot.id.uuidString
            if jobs[key]?.revision != bot.updatedAt {
                do { jobs[key] = Job(revision: bot.updatedAt, next: try next(bot, after: bot.updatedAt)) }
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
            try reconcile(bots, jobs: &jobs)
            try disk.write(jobs, at: path)
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
                                    next: try next(bot, after: now.addingTimeInterval(BotRunLimits.maximumSeconds)))
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
