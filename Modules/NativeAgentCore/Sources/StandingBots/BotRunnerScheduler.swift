import Foundation
import PersistenceCore
import TriggerScheduler
// Blueprint: | `BotRunnerScheduler.swift` | `BotRunnerScheduler` actor; `effectiveSchedule` shares reconciled timing and admission with live deadlines |

/// Definitions remain canonical; persisted reservations project into the shared deadline owner.
public actor BotRunnerScheduler {
    private struct Job: Codable, Equatable {
        let revision: Date
        var next: Date
        var reason: String? = nil
        var failureID: UUID? = nil
        var minimumInterval: TimeInterval? = nil
        var scheduledFrom: Date? = nil
        var lastRunAt: Date? = nil
        var missed: BotMissedRun? = nil
        /// Preserve the resolving zone so cron times can follow the Mac when it moves.
        var zone: String? = TimeZone.autoupdatingCurrent.identifier
        /// `next` and the zone it was resolved in are only ever written together.
        mutating func plan(_ date: Date) { next = date; zone = TimeZone.autoupdatingCurrent.identifier }
    }
    /// Capture construction time: lazy static initialization would misclassify every overdue job as app downtime.
    private let startedAt = Date()
    private let disk: StandingBotsDisk
    private let definitions: BotDefinitionStore
    private let runner: BotRunner
    private let queue: BotRunQueue
    private let shelf: ShelfStore
    private let events: BotEventStore
    /// Recheck unattended authority on admission; manual requests carry the user's explicit authority.
    /// Roots without a trust policy use the supplied default.
    private let isAutonomyEnabled: @Sendable () async -> Bool
    public private(set) var failure: String?
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var isShutDown = false
    private var settled: [String] = []
    private var deadlineFailures: [UUID: String] = [:]

    public init(
        dataRoot: URL,
        session: @escaping BotRunnerSession,
        isAutonomyEnabled: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.isAutonomyEnabled = isAutonomyEnabled
        disk = StandingBotsDisk(dataRoot: dataRoot)
        shelf = ShelfStore(dataRoot: dataRoot)
        events = BotEventStore(dataRoot: dataRoot)
        definitions = BotDefinitionStore(dataRoot: dataRoot)
        runner = BotRunner(dataRoot: dataRoot, session: session)
        queue = BotRunQueue(dataRoot: dataRoot)
    }

    private var path: URL { disk.root.appendingPathComponent("runner-jobs.json") }

    public struct BotSchedule: Sendable {
        public let dates: [UUID: Date]
        public let missed: [UUID: BotMissedRun]
        public let unattended: Bool
    }

    /// Read-only projection must not mutate deadlines, claims or missed occurrences.
    public func effectiveSchedule() async throws -> BotSchedule {
        let unattended = await isAutonomyEnabled()
        let bots = try definitions.list()
        let jobs = try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            try reconcile(bots, jobs: &jobs)
            return jobs
        }
        return projection(bots, jobs: jobs, unattended: unattended)
    }

    private func projection(_ bots: [BotDefinition], jobs: [String: Job], unattended: Bool) -> BotSchedule {
        let dates = bots.compactMap { bot -> (UUID, Date)? in
            guard unattended, !bot.paused, inFlight[bot.id] == nil,
                  let job = jobs[bot.id.uuidString], job.reason == nil, job.next != .distantFuture else { return nil }
            return (bot.id, job.next)
        }
        let missed = jobs.compactMap { key, job -> (UUID, BotMissedRun)? in
            guard let id = UUID(uuidString: key), let missed = job.missed else { return nil }
            return (id, missed)
        }
        return BotSchedule(dates: Dictionary(dates, uniquingKeysWith: { first, _ in first }),
                          missed: Dictionary(missed, uniquingKeysWith: { first, _ in first }), unattended: unattended)
    }

    /// One cadence bounds lateness, with the minimum-spacing floor preventing overly short windows.
    private static func lateness(_ bot: BotDefinition) throws -> TimeInterval {
        let minimum = try BotRunLimits.checkedMinimumInterval()
        guard case .interval(let seconds) = bot.cadence else { return minimum }
        return max(seconds, minimum)
    }

    private func next(_ bot: BotDefinition, after date: Date, lastRunAt: Date? = nil, beyond due: Date? = nil) throws -> Date {
        try StandingBotsDisk.nextOccurrence(bot, after: date, lastRunAt: lastRunAt, beyond: due)
    }

    /// Manual work preserves the civil schedule unless minimum spacing requires moving the next occurrence.
    private func completed(_ id: UUID, at date: Date, reschedule: Bool = true, beyond due: Date? = nil) throws {
        let bot = try definitions.get(id)
        try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            // Completion disproves a current block but cannot erase an earlier missed occurrence.
            let missed = jobs[id.uuidString]?.missed
            let cleared = missed?.reason == .blocked ? nil : missed
            if !reschedule {
                guard var job = jobs[id.uuidString] else { return }
                job.missed = cleared
                job.lastRunAt = date
                if job.next < date.addingTimeInterval(try BotRunLimits.checkedMinimumInterval()) {
                    job.plan(try next(bot, after: date, lastRunAt: date))
                    job.scheduledFrom = date
                }
                jobs[id.uuidString] = job
                return try disk.write(jobs, at: path)
            }
            jobs[id.uuidString] = Job(revision: bot.updatedAt, next: try next(bot, after: date, lastRunAt: date, beyond: due),
                                      minimumInterval: try BotRunLimits.checkedMinimumInterval(),
                                      scheduledFrom: date, lastRunAt: date,
                                      missed: cleared)
            try disk.write(jobs, at: path)
        }
    }

    private func reconcile(_ bots: [BotDefinition], jobs: inout [String: Job]) throws {
        let minimumInterval = try BotRunLimits.checkedMinimumInterval()
        let ids = Set(bots.map { $0.id.uuidString })
        jobs = jobs.filter { ids.contains($0.key) }
        for bot in bots where !bot.paused {
            let key = bot.id.uuidString
            var replan = jobs[key]?.revision != bot.updatedAt || jobs[key]?.minimumInterval != minimumInterval
            // Preserve pending cron wall time in the new zone; in-flight work replans on completion.
            // A missing resolving zone requires fresh planning.
            if !replan, case .cron = bot.cadence, inFlight[bot.id] == nil, var job = jobs[key],
               job.reason == nil, job.zone != TimeZone.autoupdatingCurrent.identifier {
                // Replan times inside the spacing floor and civil minutes skipped by DST.
                if let old = job.zone.flatMap(TimeZone.init(identifier:)),
                   let carried = SchedulerJobRuntime.wallClock(job.next, from: old, to: .autoupdatingCurrent),
                   SchedulerJobRuntime.wallClock(carried, from: .autoupdatingCurrent, to: old)
                       == SchedulerJobRuntime.wallClock(job.next, from: old, to: old),
                   carried >= (job.lastRunAt ?? .distantPast).addingTimeInterval(minimumInterval) {
                    job.plan(carried); jobs[key] = job
                } else { replan = true }
            }
            if replan {
                let anchor = jobs[key]?.revision == bot.updatedAt
                    ? (jobs[key]?.scheduledFrom ?? max(bot.updatedAt, Date())) : bot.updatedAt
                // Rescheduling cannot erase evidence of an occurrence that never ran.
                let missed = jobs[key]?.missed
                let lastRunAt = jobs[key]?.lastRunAt
                do { jobs[key] = Job(revision: bot.updatedAt, next: try next(bot, after: anchor, lastRunAt: lastRunAt),
                                     minimumInterval: minimumInterval,
                                     scheduledFrom: anchor, lastRunAt: lastRunAt,
                                     missed: missed) }
                catch { jobs[key] = Job(revision: bot.updatedAt, next: .distantFuture,
                                        reason: String(describing: error), failureID: UUID(), minimumInterval: minimumInterval,
                                        lastRunAt: lastRunAt, missed: missed) }
            }
        }
        guard jobs.values.allSatisfy({ $0.next.timeIntervalSince1970.isFinite && $0.revision.timeIntervalSince1970.isFinite
            && ($0.lastRunAt?.timeIntervalSince1970.isFinite ?? true) }) else {
            throw StandingBotsError.corruptStore("bot scheduler dates")
        }
    }

    private func reconciled(_ bots: [BotDefinition]) throws -> [String: Job] {
        let jobs = try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            let previous = jobs
            try reconcile(bots, jobs: &jobs)
            // Rewriting an unchanged watched file would wake deadline projection indefinitely.
            if jobs != previous {
                try disk.write(jobs, at: path)
            }
            return jobs
        }
        for bot in bots {
            guard let job = jobs[bot.id.uuidString], let reason = job.reason, let id = job.failureID else { continue }
            failure = "Bot scheduling unavailable: \(reason)"
            var entry = ShelfEntry(id: id, botId: bot.id, briefVersion: bot.briefVersion,
                runAt: job.revision, coverageStart: job.revision, coverageEnd: job.revision,
                headline: "Could not check", findings: "", changedSinceLastGood: "Unknown: invalid schedule.",
                uncertainties: [reason], runHealth: .failed, spend: ShelfSpend(tokens: 0, seconds: 0))
            entry.sessionID = bot.sessionID
            do {
                try shelf.append(entry)
            } catch StandingBotsError.alreadyExists { /* Already reported this definition revision. */ }
        }
        return jobs
    }

    /// Record and skip expired occurrences; retrying them would bypass unattended authority.
    private func noteMissed(_ bots: [BotDefinition], autonomyEnabled: Bool) {
        let now = Date()
        let live = bots.filter { !$0.paused }
        guard !live.isEmpty else { return }
        do {
            try disk.locked {
                var jobs = try disk.read([String: Job].self, at: path) ?? [:]
                var changed = false
                for bot in live {
                    let key = bot.id.uuidString
                    guard var job = jobs[key], job.reason == nil, job.next != .distantFuture,
                          now.timeIntervalSince(job.next) > (try Self.lateness(bot)) else { continue }
                    job.missed = BotMissedRun(dueAt: job.next, reason: Self.reason(
                        due: job.next, autonomyEnabled: autonomyEnabled, startedAt: startedAt))
                    job.plan(try next(bot, after: now, lastRunAt: job.lastRunAt, beyond: job.next))
                    job.scheduledFrom = now
                    jobs[key] = job
                    changed = true
                }
                if changed { try disk.write(jobs, at: path) }
            }
        } catch { failure = "Bot scheduling unavailable: \(error)" }
    }

    /// Quiet time between source changes is not evidence that the app slept.
    private static func reason(due: Date, autonomyEnabled: Bool, startedAt: Date) -> BotMissedRun.Reason {
        guard autonomyEnabled else { return .autonomyOff }
        if due < startedAt { return .appClosed }
        return .notRun
    }

    /// Retain the gate's observed reason; rereading a toggled switch could invent a different refusal.
    private var lastUnattendedHold: [UUID: (reason: BotMissedRun.Reason, detail: String?)] = [:]

    /// Recheck after the claim wait using its locked definition; record any hold before spending.
    private func holdUnattendedRun(bot id: UUID, paused: Bool) async throws -> Bool {
        let enabled = await isAutonomyEnabled()
        let stopped = isShutDown || Task.isCancelled
        guard stopped || !enabled || paused else { return false }
        let detail = stopped ? "Background work stopped" : (enabled ? "the bot is paused" : "Autonomy is off")
        // A pause uses the not-run reason with the gate's own words.
        lastUnattendedHold[id] = enabled ? (.notRun, detail) : (.autonomyOff, nil)
        try events.hold(bot: id, detail: detail)
        return true
    }

    private func recordMissed(_ id: UUID, due: Date, reason: BotMissedRun.Reason,
                              detail: String? = nil) throws {
        try disk.locked {
            var jobs = try disk.read([String: Job].self, at: path) ?? [:]
            guard var job = jobs[id.uuidString] else { return }
            job.missed = BotMissedRun(dueAt: due, reason: reason, detail: detail)
            jobs[id.uuidString] = job
            try disk.write(jobs, at: path)
        }
    }

    public func nextDeadline(after now: Date) async -> Date? {
        guard !isShutDown else { return nil }
        do {
            let bots = try definitions.list()
            let jobs = try reconciled(bots)
            if try queue.pending().keys.contains(where: { inFlight[$0] == nil && jobs[$0.uuidString]?.reason == nil }) { return now }
            // Refused jobs cannot remain deadlines: they would wake and refuse forever.
            return projection(bots, jobs: jobs, unattended: await isAutonomyEnabled()).dates.values.min()
        } catch { failure = "Bot scheduling unavailable: \(error)"; return nil }
    }

    public func shutdown() async {
        isShutDown = true
        let tasks = Array(inFlight.values)
        for task in tasks { task.cancel() }
        // Retain claims through all settlement; concurrent shutdown callers join the same work.
        for task in tasks { await task.value }
    }

    public func runDue() async -> [String] {
        guard !isShutDown, await BotRunGate.isReady(), !isShutDown, !Task.isCancelled else { return [] }
        failure = deadlineFailures.values.sorted().first
        let completed = settled
        settled.removeAll()
        do {
            let bots = try definitions.list()
            let reconciledJobs = try reconciled(bots)
            let requests = try queue.pending()
            for (id, request) in requests {
                guard inFlight[id] == nil else { continue }
                let requestID = request.runID
                guard bots.contains(where: { $0.id == id }) else {
                    try queue.rejectPending(
                        bot: id, requestID: requestID,
                        detail: "This helper is deleted or unavailable in the checked definition list. No helper turn ran."
                    )
                    continue
                }
                try Task.checkCancellation()
                guard reconciledJobs[id.uuidString]?.reason == nil else {
                    try queue.rejectPending(bot: id, requestID: requestID, detail: """
                        This helper's schedule is invalid: \(reconciledJobs[id.uuidString]?.reason ?? "schedule unavailable"). No helper turn \
                        ran.
                        """)
                    continue
                }
                // Recheck unattended authority after queue delay or restart; manual requests remain explicitly authorized.
                if request.isEvent {
                    let enabled = await isAutonomyEnabled()
                    guard !isShutDown, !Task.isCancelled else { return completed }
                    let paused = try definitions.get(id).paused
                    if !enabled || paused {
                        try queue.rejectPending(
                            bot: id, requestID: requestID,
                            detail: enabled ? "The bot is paused. No helper turn ran." : "Autonomy is off. No helper turn ran."
                        )
                        try events.hold(bot: id, detail: enabled ? "the bot is paused" : "Autonomy is off")
                        continue
                    }
                }
                // Claim waits can outlast authority changes; queued requests bypass the claim's pause guard.
                let isEvent = request.isEvent
                let holdUnattended: @Sendable (BotDefinition) async throws -> Bool = { claimed in
                    guard isEvent else { return false }
                    return try await self.holdUnattendedRun(bot: id, paused: claimed.paused)
                }
                try Task.checkCancellation()
                inFlight[id] = Task {
                    defer { self.finished(id) }
                    do {
                        if let entry = try await runner.run(bot: id, requestID: requestID, parent: nil, scope: BotRunScope(),
                                                            holdUnattended: holdUnattended,
                                                            deadlineExceeded: { await self.reportDeadline(id, detail: $0) }) {
                            try self.completed(id, at: Date(), reschedule: isEvent)
                            settled.append("bot:\(entry.botId.uuidString)")
                        }
                    } catch { rejected(id, due: Date(), error: error) }
                }
            }
            let autonomyEnabled = await isAutonomyEnabled()
            guard !isShutDown, !Task.isCancelled else { return completed }
            let scheduledBots = try definitions.list()
            let scheduledJobs = try reconciled(scheduledBots)
            noteMissed(scheduledBots, autonomyEnabled: autonomyEnabled)
            guard autonomyEnabled else { return completed }
            let now = Date()
            for bot in scheduledBots where !bot.paused && scheduledJobs[bot.id.uuidString].map({ $0.next <= now }) == true {
                guard inFlight[bot.id] == nil else { continue }
                try Task.checkCancellation()
                guard scheduledJobs[bot.id.uuidString]?.reason == nil else { continue }
                guard await isAutonomyEnabled(), !isShutDown, !Task.isCancelled else { break }
                let live = try definitions.list()
                guard let fresh = live.first(where: { $0.id == bot.id }), !fresh.paused else { continue }
                do {
                let reserved: Date? = try disk.locked {
                    var jobs = try disk.read([String: Job].self, at: path) ?? [:]
                    try reconcile(live, jobs: &jobs)
                    let key = fresh.id.uuidString
                    let now = Date()
                    guard let job = jobs[key], job.next <= now else { return nil }
                    let due = job.next
                    // Reserve across processes before provider work; crash recovery skips the occurrence to prevent replay.
                    jobs[key] = Job(revision: fresh.updatedAt,
                                    next: try next(fresh, after: now.addingTimeInterval(BotRunLimits.maximumSeconds), lastRunAt: now, beyond: due),
                                    minimumInterval: try BotRunLimits.checkedMinimumInterval(),
                                    scheduledFrom: now.addingTimeInterval(BotRunLimits.maximumSeconds),
                                    lastRunAt: jobs[key]?.lastRunAt,
                                    missed: jobs[key]?.missed)
                    try disk.write(jobs, at: path)
                    return due
                }
                // Manual work satisfies coincident due work to avoid duplicate execution.
                if let due = reserved, requests[bot.id] == nil {
                    try Task.checkCancellation()
                    inFlight[bot.id] = Task {
                    defer { self.finished(bot.id) }
                    do {
                        // Recheck after claim waits so disabling unattended work prevents reservation and spend.
                        let botID = bot.id
                        lastUnattendedHold.removeValue(forKey: botID)
                        let holdUnattended: @Sendable (BotDefinition) async throws -> Bool = { claimed in
                            try await self.holdUnattendedRun(bot: botID, paused: claimed.paused)
                        }
                        if let entry = try await runner.run(bot: bot.id, parent: nil, scope: BotRunScope(), holdUnattended: holdUnattended,
                                                          deadlineExceeded: { await self.reportDeadline(bot.id, detail: $0) }) {
                            try self.completed(bot.id, at: Date(), beyond: due)
                            settled.append("bot:\(entry.botId.uuidString)")
                        } else if let held = lastUnattendedHold[botID] {
                            try recordMissed(bot.id, due: due, reason: held.reason,
                                             detail: held.detail)
                        } else {
                            try recordMissed(bot.id, due: due, reason: .notRun)
                        }
                    } catch { rejected(bot.id, due: due, error: error) }
                    }
                }
                } catch is CancellationError { throw CancellationError() }
                catch { failure = "Bot run unavailable: \(error)" }
            }
        } catch { failure = "Bot run unavailable: \(error)" }
        return completed
    }

    private func reportDeadline(_ id: UUID, detail: String) {
        deadlineFailures[id] = detail
        failure = detail
    }

    private func rejected(_ id: UUID, due: Date, error: Error) {
        do {
            switch error {
            case let admission as BotRunAdmissionError:
                try recordMissed(id, due: due, reason: .queueBusy)
                failure = "Bot request rejected: \(admission.rawValue)"
            case BotRunnerError.cannotRun(let problem):
                try recordMissed(id, due: due, reason: .blocked, detail: problem)
                failure = "Bot request rejected: \(problem)"
            case BotRunnerError.dailySpendLimit:
                try recordMissed(id, due: due, reason: .overBudget)
                failure = "Bot request rejected: \(BotRunnerError.dailySpendLimit.description)"
            default: failure = "Bot run unavailable: \(error)"
            }
        } catch { failure = "Bot scheduling unavailable: \(error)" }
    }

    private func finished(_ id: UUID) {
        inFlight.removeValue(forKey: id)
        deadlineFailures.removeValue(forKey: id)
        lastUnattendedHold.removeValue(forKey: id)
        NotificationCenter.default.post(name: BotRunQueue.didChange, object: disk.root.deletingLastPathComponent())
    }
}
