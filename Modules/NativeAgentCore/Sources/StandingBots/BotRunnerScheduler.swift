import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TriggerScheduler
import Experiences
// Blueprint: | `BotRunnerScheduler.swift` | `BotRunnerScheduler`: helper cadence declarations, queued runs and durable scheduling failures |

/// A helper's cadence is one time on the one clock, `helper:<id>`, declared from its definition; the clock delivers it here and the helper runs. A requested
/// run (by hand, or an event) runs as soon as it is queued. Helpers think for themselves; only their clock is the clock's.
public actor BotRunnerScheduler {
    static let clockOwner = "helper"

    private let dataRoot: URL
    private let disk: StandingBotsDisk
    private let definitions: BotDefinitionStore
    private let runner: BotRunner
    private let queue: BotRunQueue
    private let events: BotEventStore
    /// Recheck unattended authority on admission; manual requests carry the person's explicit authority.
    private let isAutonomyEnabled: @Sendable () async -> Bool
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var attached = false
    /// Failed rows keep only their own cadence undeclared this launch; nil means the shared migration input could not be read at all.
    private var carryOverHeld: Set<UUID>? = []
    /// Retain the gate's observed reason; rereading a toggled switch could invent a different refusal.
    private var lastUnattendedHold: [UUID: (reason: BotMissedRun.Reason, detail: String?)] = [:]

    public init(
        dataRoot: URL,
        session: @escaping BotRunnerSession,
        isAutonomyEnabled: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.dataRoot = dataRoot
        self.isAutonomyEnabled = isAutonomyEnabled
        disk = StandingBotsDisk(dataRoot: dataRoot)
        events = BotEventStore(dataRoot: dataRoot)
        definitions = BotDefinitionStore(dataRoot: dataRoot)
        runner = BotRunner(dataRoot: dataRoot, session: session)
        queue = BotRunQueue(dataRoot: dataRoot)
    }

    /// An occurrence that did not run, kept per helper until the next one replaces it.
    private var missedPath: URL { disk.root.appendingPathComponent("missed-runs.json") }

    public struct BotSchedule: Sendable {
        public let dates: [UUID: Date]
        public let missed: [UUID: BotMissedRun]
        public let unattended: Bool
    }

    /// Read-only projection: each live helper's next time on the clock and its last missed occurrence.
    public func effectiveSchedule() async throws -> BotSchedule {
        let unattended = await isAutonomyEnabled()
        let bots = try definitions.list()
        let times = try await OneClock.at(dataRoot).times(owner: Self.clockOwner)
        let dates = bots.compactMap { bot -> (UUID, Date)? in
            guard unattended, !bot.paused, inFlight[bot.id] == nil, let time = times.first(where: { $0.id == Self.timeID(bot.id) }) else { return nil }
            return (bot.id, time.next)
        }
        let missed = try disk.locked { try disk.read([String: BotMissedRun].self, at: missedPath) ?? [:] }
        return BotSchedule(dates: Dictionary(dates, uniquingKeysWith: { first, _ in first }),
                           missed: Dictionary(missed.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                                              uniquingKeysWith: { first, _ in first }),
                           unattended: unattended)
    }

    static func timeID(_ id: UUID) -> String { clockOwner + ":" + id.uuidString }

    /// Cron follows the clock's calendar rhythm path; intervals keep the helper's spacing floor and remain absolute instants.
    private static func rhythm(_ cadence: BotCadence) -> JSONValue? {
        switch cadence {
        case .cron(let expression): return .object(["type": .string("cron"), "expression": .string(expression)])
        case .manual, .interval: return nil
        }
    }

    /// Once, at launch: the clock delivers each helper's time here, the clock's helper times follow the definitions from now on, and requested runs
    /// left queued run. On the first launch on the clock, each helper keeps the next occurrence bots/runner-jobs.json held.
    public func attach(carryingOver: Bool?) async -> Bool {
        guard !attached else { return false }
        attached = true
        var carried = true
        switch carryingOver {
        case true?: carried = await carryOver()
        case false?: break
        case nil: carryOverHeld = nil; carried = false
        }
        await OneClock.at(dataRoot).handle(Self.clockOwner) { [weak self] time, occurrence in await self?.deliver(time, occurrence: occurrence) }
        await changed()
        Task.detached { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: BotRunQueue.didChange) { await self?.changed() }
        }
        return carried
    }

    /// A definition or the queue changed: the clock follows the definitions, and queued requests run.
    private func changed() async {
        await declareTimes()
        await runRequests()
    }

    // MARK: - The clock's helper times

    /// Each helper that runs on a cadence (not paused, not deleted, not manual) holds one time; a time whose definition changed is declared again from
    /// the new definition, and a time with no such helper is withdrawn.
    private func declareTimes() async {
        guard let held = carryOverHeld else { return }
        let clock = OneClock.at(dataRoot)
        do {
            let bots = try definitions.list()
            let declared = try await clock.times(owner: Self.clockOwner)
            var wanted: Set<String> = []
            for bot in bots where !bot.paused && bot.deleted != true && bot.cadence != .manual {
                let id = Self.timeID(bot.id)
                wanted.insert(id)
                if held.contains(bot.id) { continue }
                let revision = JSONValue.double(bot.updatedAt.timeIntervalSince1970)
                let rhythm = Self.rhythm(bot.cadence)
                do {
                    var time: OneClock.Time
                    if let previous = declared.first(where: { $0.id == id }), previous.payload?.objectValue?["revision"] == revision {
                        if previous.rhythm == rhythm { continue }
                        // Add calendar provenance to an unchanged declaration without moving or skipping its pending occurrence.
                        time = previous
                        time.rhythm = rhythm
                    } else {
                        time = .init(id: id, rhythm: rhythm, next: try StandingBotsDisk.nextOccurrence(bot, after: Date()),
                                     payload: .object(["revision": revision]))
                    }
                    try await clock.declare(time)
                } catch {
                    try recordMissed(bot.id, due: Date(), reason: .blocked, detail: "Its clock declaration failed: \(error)")
                }
            }
            for time in declared where !wanted.contains(time.id) { try await clock.withdraw(time.id) }
            await RepairOwed.settle(dataRoot, operation: "helper:declarations",
                                   evidence: .init(source: "clock", id: Self.clockOwner)).value
        } catch {
            await failed(operation: "helper:declarations", error: error)
        }
    }

    /// One occurrence: the next one is declared first, so the cadence holds whatever this run does; then the helper runs if unattended work is on.
    private func deliver(_ time: OneClock.Time, occurrence due: Date) async {
        guard let id = UUID(uuidString: String(time.id.dropFirst(Self.clockOwner.count + 1))) else {
            await failed(operation: "helper:occurrence:" + time.id,
                         error: StandingBotsError.corruptStore("Invalid helper clock identity \(time.id)"))
            return
        }
        do {
            guard let bot = try definitions.list().first(where: { $0.id == id }), !bot.paused, bot.deleted != true, bot.cadence != .manual else {
                await declareTimes()
                return
            }
            let now = Date()
            try await OneClock.at(dataRoot).declare(.init(id: time.id, rhythm: Self.rhythm(bot.cadence),
                                                          next: try StandingBotsDisk.nextOccurrence(bot, after: now, lastRunAt: now, beyond: due),
                                                          payload: time.payload))
            guard await isAutonomyEnabled() else { return try recordMissed(id, due: due, reason: .autonomyOff) }
            guard inFlight[id] == nil else {
                return try recordMissed(id, due: due, reason: .notRun, detail: "its previous run was still working")
            }
            lastUnattendedHold.removeValue(forKey: id)
            inFlight[id] = Task {
                defer { self.finished(id) }
                do {
                    let holdUnattended: @Sendable (BotDefinition) async throws -> Bool = { claimed in
                        try await self.holdUnattendedRun(bot: id, paused: claimed.paused)
                    }
                    if try await runner.run(bot: id, parent: nil, scope: BotRunScope(), holdUnattended: holdUnattended) != nil {
                        try self.completed(id)
                    } else if let held = lastUnattendedHold[id] {
                        try recordMissed(id, due: due, reason: held.reason, detail: held.detail)
                    } else {
                        try recordMissed(id, due: due, reason: .notRun)
                    }
                } catch { await rejected(id, due: due, error: error) }
            }
        } catch {
            await rejected(id, due: due, error: error)
        }
    }

    // MARK: - Requested runs

    /// Runs each queued request (by hand or an event) that is not already running. An event rechecks unattended authority after its wait.
    private func runRequests() async {
        guard await BotRunGate.isReady() else { return }
        do {
            let bots = try definitions.list()
            for (id, request) in try queue.pending() where inFlight[id] == nil {
                let requestID = request.runID
                guard bots.contains(where: { $0.id == id }) else {
                    try queue.rejectPending(bot: id, requestID: requestID,
                        detail: "This helper is deleted or unavailable in the checked definition list. No helper turn ran.")
                    continue
                }
                if request.isEvent {
                    let enabled = await isAutonomyEnabled()
                    let paused = try definitions.get(id).paused
                    if !enabled || paused {
                        try queue.rejectPending(bot: id, requestID: requestID,
                            detail: enabled ? "The bot is paused. No helper turn ran." : "Autonomy is off. No helper turn ran.")
                        try events.hold(bot: id, detail: enabled ? "the bot is paused" : "Autonomy is off")
                        continue
                    }
                }
                guard inFlight[id] == nil else { continue }
                let isEvent = request.isEvent
                let holdUnattended: @Sendable (BotDefinition) async throws -> Bool = { claimed in
                    guard isEvent else { return false }
                    return try await self.holdUnattendedRun(bot: id, paused: claimed.paused)
                }
                inFlight[id] = Task {
                    defer { self.finished(id) }
                    do {
                        if try await runner.run(bot: id, requestID: requestID, parent: nil, scope: BotRunScope(), holdUnattended: holdUnattended) != nil {
                            try self.completed(id)
                        }
                    } catch { await rejected(id, due: Date(), error: error) }
                }
            }
            await RepairOwed.settle(dataRoot, operation: "helper:requests",
                                   evidence: .init(source: "helper-queue", id: disk.root.appendingPathComponent("run-queue.json").path)).value
        } catch {
            await failed(operation: "helper:requests", error: error)
        }
    }

    // MARK: - Outcomes

    /// Recheck after the claim wait using its locked definition; record any hold before spending.
    private func holdUnattendedRun(bot id: UUID, paused: Bool) async throws -> Bool {
        let enabled = await isAutonomyEnabled()
        guard Task.isCancelled || !enabled || paused else { return false }
        let detail = Task.isCancelled ? "Background work stopped" : (enabled ? "the bot is paused" : "Autonomy is off")
        lastUnattendedHold[id] = enabled ? (.notRun, detail) : (.autonomyOff, nil)
        try events.hold(bot: id, detail: detail)
        return true
    }

    /// Completion disproves a current block but cannot erase an earlier missed occurrence.
    private func completed(_ id: UUID) throws {
        try disk.locked {
            var missed = try disk.read([String: BotMissedRun].self, at: missedPath) ?? [:]
            guard missed[id.uuidString]?.reason == .blocked else { return }
            missed.removeValue(forKey: id.uuidString)
            try disk.write(missed, at: missedPath)
        }
    }

    private func recordMissed(_ id: UUID, due: Date, reason: BotMissedRun.Reason, detail: String? = nil) throws {
        try disk.locked {
            var missed = try disk.read([String: BotMissedRun].self, at: missedPath) ?? [:]
            let record = BotMissedRun(dueAt: due, reason: reason, detail: detail)
            guard missed[id.uuidString] != record else { return }
            missed[id.uuidString] = record
            try disk.write(missed, at: missedPath)
        }
    }

    private func rejected(_ id: UUID, due: Date, error: Error) async {
        do {
            switch error {
            case is BotRunAdmissionError: try recordMissed(id, due: due, reason: .queueBusy)
            case BotRunnerError.cannotRun(let problem): try recordMissed(id, due: due, reason: .blocked, detail: problem)
            case BotRunnerError.dailySpendLimit: try recordMissed(id, due: due, reason: .overBudget)
            default: try recordMissed(id, due: due, reason: .blocked, detail: String(describing: error))
            }
            await RepairOwed.settle(dataRoot, operation: "helper:outcome:" + id.uuidString,
                                   evidence: .init(source: "helper-missed", id: id.uuidString)).value
        } catch let recordingError {
            await failed(operation: "helper:outcome:" + id.uuidString,
                         error: StandingBotsError.corruptStore("Could not record \(error): \(recordingError)"))
        }
    }

    private func failed(operation: String, error: any Error) async {
        await RepairOwed.owe(dataRoot, id: operation, kind: .run, operation: operation, owner: disk.root.path,
                             words: "The helper scheduler could not complete \(operation): \(error.localizedDescription)",
                             lever: "Repair the helper definitions, queue or missed-runs.json in \(disk.root.path), then reopen NativeAgent.").value
    }

    private func finished(_ id: UUID) {
        inFlight.removeValue(forKey: id)
        lastUnattendedHold.removeValue(forKey: id)
        NotificationCenter.default.post(name: BotRunQueue.didChange, object: disk.root.deletingLastPathComponent())
    }

    // MARK: - Carrying runner-jobs.json over

    /// The first launch on the clock, once: each helper's next occurrence (and its last missed one) in bots/runner-jobs.json becomes its clock time, so
    /// nothing fires twice or is skipped. A helper already on the clock keeps its time; the file is never read again.
    private func carryOver() async -> Bool {
        struct Saved: Decodable { let revision: Date; let next: Date; let missed: BotMissedRun? }
        do {
            let saved = try disk.locked { try disk.read([String: Saved].self, at: disk.root.appendingPathComponent("runner-jobs.json")) } ?? [:]
            let clock = OneClock.at(dataRoot)
            let declared = Set(try await clock.times(owner: Self.clockOwner).map(\.id))
            let bots = try definitions.list()
            var complete = true
            for (key, job) in saved {
                guard let id = UUID(uuidString: key) else {
                    complete = false
                    nativeLog("helper %@ carry-over has an unreadable id; its source stays intact for repair and relaunch", key)
                    continue
                }
                guard let bot = bots.first(where: { $0.id == id }), !declared.contains(Self.timeID(id)) else { continue }
                do {
                    if let missed = job.missed { try recordMissed(id, due: missed.dueAt, reason: missed.reason, detail: missed.detail) }
                    // A next occurrence planned for an older definition is planned again from the current one.
                    guard job.revision == bot.updatedAt, job.next != .distantFuture else { continue }
                    try await clock.carryOver(.init(id: Self.timeID(id), rhythm: Self.rhythm(bot.cadence), next: job.next,
                                                  payload: .object(["revision": .double(bot.updatedAt.timeIntervalSince1970)])))
                } catch {
                    complete = false
                    carryOverHeld?.insert(id)
                    nativeLog("helper %@ carry-over is incomplete; its cadence awaits repair and relaunch: %@", key, String(describing: error))
                }
            }
            return complete
        } catch {
            carryOverHeld = nil
            nativeLog("helper carry-over is incomplete; saved times stay intact and undeclared cadences wait for repair and relaunch: %@",
                      String(describing: error))
            return false
        }
    }
}
