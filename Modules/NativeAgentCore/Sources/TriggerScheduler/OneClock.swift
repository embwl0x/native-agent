import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `OneClock.swift` | `OneClock`: declared times, checked recurrence and durable consumption before delivery |

/// The one clock. Every declared time (a moment the agent set, a part's schedule, a helper's cadence, the night) lives here with its next occurrence and
/// is delivered to whoever declared it. The next occurrence moves forward and is saved before delivery, so an occurrence is delivered at most once, and
/// one that came while the app was quit is delivered once when its owner registers. One deadline is armed at the earliest time an owner handles;
/// nothing polls.
public actor OneClock {
    public struct Time: Codable, Sendable, Equatable {
        /// `<owner>:<key>`. The owner (`moment`, `part`, `helper`, `sleep`, `rem`, `watch`, `scan`, `brief`) is whoever the time is delivered to.
        public var id: String
        /// A recurrence in the scheduler's rhythm grammar (`SchedulerJobNormalizer.rhythm`); nil for one moment.
        public var rhythm: JSONValue?
        public var next: Date { didSet { projectionZone = .current } }
        /// The owner's own words for what it is, handed back at delivery.
        public var payload: JSONValue?
        /// Consumption belongs to the clock too: ending a one-shot leaves evidence, not an absent id that restore could replay.
        var delivered: Date?
        /// An ended time has no pending work. Withdrawal can end a time without inventing a delivery.
        var ended: Bool?
        var isPending: Bool { ended != true }
        /// Live projection provenance travels with a time across the caller/clock suspension. It is not part of the saved wire shape.
        private var projectionZone = TimeZone.current
        /// No projection zone persists; a zone change while quit cannot recover the pending civil occurrence from this shape (deferred).
        private enum CodingKeys: String, CodingKey { case id, rhythm, next, payload, delivered, ended }

        public init(id: String, rhythm: JSONValue? = nil, next: Date, payload: JSONValue? = nil) {
            self.id = id; self.rhythm = rhythm; self.next = next; self.payload = payload
        }

        public var owner: String { String(id.prefix { $0 != ":" }) }

        public static func == (lhs: Time, rhs: Time) -> Bool {
            lhs.id == rhs.id && lhs.rhythm == rhs.rhythm && lhs.next == rhs.next && lhs.payload == rhs.payload
                && lhs.delivered == rhs.delivered && lhs.ended == rhs.ended
        }

        fileprivate mutating func resolve(in zone: TimeZone) throws {
            guard isPending, zone != projectionZone else { return }
            if let fields = rhythm?.objectValue,
               ["hourly", "daily", "weekly", "monthly", "cron"].contains(SchedulerJobNormalizer.scheduleType(fields)) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = projectionZone
                let civil = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
                calendar.timeZone = zone
                guard let resolved = calendar.date(from: civil) else {
                    throw TriggerSchedulerError.persistenceFailure("Calendar occurrence \(id) cannot be resolved in \(zone.identifier).")
                }
                next = resolved
            }
            projectionZone = zone
        }
    }

    /// Delivered with the occurrence it fired for (its `next` as it stood).
    public typealias Deliver = @Sendable (_ time: Time, _ occurrence: Date) async -> Void

    private static let clocks = OSAllocatedUnfairLock(initialState: [String: OneClock]())

    public static func at(_ dataRoot: URL) -> OneClock {
        let key = dataRoot.standardizedFileURL.path
        return clocks.withLock { clocks in
            if let clock = clocks[key] { return clock }
            let clock = OneClock(dataRoot: dataRoot)
            clocks[key] = clock
            return clock
        }
    }

    private let dataRoot: URL
    private var loaded: [String: Time]?
    private var handlers: [String: Deliver] = [:]
    private var deadline: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init(dataRoot: URL) { self.dataRoot = dataRoot }

    var url: URL { dataRoot.appendingPathComponent("clock/times.json") }

    /// An owner registers how its times are delivered; any of its times already due are delivered now, once.
    public func handle(_ owner: String, _ deliver: @escaping Deliver) async {
        handlers[owner] = deliver
        if observers.isEmpty { observeClockChanges() }
        await fire()
    }

    /// Declare (or replace) one time.
    public func declare(_ time: Time) async throws {
        var time = time
        try time.resolve(in: .current)
        var times = try read()
        if let previous = times[time.id]?.delivered,
           time.delivered.map({ $0 < previous }) ?? true {
            time.delivered = previous
            time.ended = time.next <= previous ? true : nil
        }
        guard times[time.id] != time else { return }
        times[time.id] = time
        try save(times)
        await fire()
    }

    /// Import an old owner's time only once. Pending, delivered and withdrawn ids are all durably accounted for by this clock.
    public func carryOver(_ time: Time) async throws {
        var times = try read()
        guard times[time.id] == nil else { return }
        var time = time
        try time.resolve(in: .current)
        times[time.id] = time
        try save(times)
        await fire()
    }

    /// Withdraw a time; withdrawing one that is not declared does nothing.
    public func withdraw(_ id: String) async throws {
        var times = try read()
        guard var time = times[id], time.isPending else { return }
        // Withdrawing future work does not erase an occurrence already consumed, or the fact that this id was accounted for.
        time.ended = true
        if let delivered = time.delivered { time.next = delivered }
        times[id] = time
        try save(times)
        await fire()
    }

    /// The pending times declared for one owner; ended delivery/withdrawal evidence is not upcoming work.
    public func times(owner: String) throws -> [Time] {
        try read().values.filter { $0.owner == owner && $0.isPending }.sorted { $0.next < $1.next }
    }

    /// Deliver what is due, moving each time to its next occurrence first, then arm the one deadline.
    private func fire() async {
        let now = Date()
        var times: [String: Time]
        do { times = try read() } catch {
            await failed(operation: "clock:read", owner: url.path, error: error)
            return
        }
        var due: [(time: Time, deliver: Deliver)] = []
        var failedRecurrences: [(id: String, cause: String)] = []
        for var time in times.values.sorted(by: { $0.next < $1.next }) where time.isPending && time.next <= now {
            guard let deliver = handlers[time.owner] else { continue }
            let pending = time
            do {
                if let rhythm = time.rhythm {
                    guard case .object(let fields) = rhythm,
                          SchedulerJobNormalizer.rhythmKinds.contains(SchedulerJobNormalizer.scheduleType(fields)) else {
                        throw TriggerSchedulerError.persistenceFailure("Clock time \(time.id) has an invalid recurring rhythm.")
                    }
                    time.next = try SchedulerJobNormalizer.checkedNextOccurrence(fields, after: now)
                } else {
                    time.ended = true
                }
            } catch {
                failedRecurrences.append((time.id, error.localizedDescription))
                continue
            }
            due.append((pending, deliver))
            time.delivered = pending.next
            times[time.id] = time
        }
        if !due.isEmpty {
            do { try save(times) } catch {
                await failed(operation: "clock:save", owner: url.path, error: error)
                return
            }
            for (time, deliver) in due { Task.detached { await deliver(time, time.next) } }
        }
        arm(times, excluding: Set(times.values.filter { $0.isPending && $0.next <= now }.map(\.id)))
        await RepairOwed.settle(dataRoot, operation: "clock:read", evidence: .init(source: "clock", id: url.path)).value
        if !due.isEmpty {
            await RepairOwed.settle(dataRoot, operation: "clock:save", evidence: .init(source: "clock", id: url.path)).value
        }
        for (time, _) in due {
            await RepairOwed.settle(dataRoot, operation: "clock:recurrence:" + time.id,
                                   evidence: .init(source: "clock", id: time.id)).value
        }
        for failure in failedRecurrences {
            await RepairOwed.owe(dataRoot, id: "clock:recurrence:" + failure.id, kind: .run,
                                 operation: "clock:recurrence:" + failure.id, owner: failure.id,
                                 words: "The clock cannot calculate \(failure.id)'s next occurrence: \(failure.cause)",
                                 lever: "Repair \(url.path), then redeclare the time or relaunch NativeAgent.").value
        }
    }

    private func failed(operation: String, owner: String, error: any Error) async {
        deadline?.cancel()
        await RepairOwed.owe(dataRoot, id: operation, kind: .run, operation: operation, owner: owner,
                             words: "The clock could not complete \(operation): \(error.localizedDescription)",
                             lever: "Repair \(url.path), then redeclare the time or relaunch NativeAgent.").value
    }

    private func arm(_ times: [String: Time], excluding failed: Set<String>) {
        deadline?.cancel()
        guard let earliest = times.values.filter({ $0.isPending && handlers[$0.owner] != nil && !failed.contains($0.id) }).map(\.next).min()
        else { deadline = nil; return }
        let delay = max(0, earliest.timeIntervalSinceNow)
        deadline = Task { [weak self] in
            // Continuous time runs through the Mac's sleep, so a time passed while asleep fires on waking.
            do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    /// A zone change resolves each pending calendar occurrence's civil minute in the new zone before comparing or arming its instant.
    private func observeClockChanges() {
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.fire() }
            })
        }
    }

    private func read() throws -> [String: Time] {
        if let loaded { return try resolveZone(loaded) }
        let times: [Time]
        do { times = try JSONDecoder().decode([Time].self, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { times = [] }
        let keyed = try Self.keyed(times)
        loaded = keyed
        return try resolveZone(keyed)
    }

    static func keyed(_ times: [Time]) throws -> [String: Time] {
        var keyed: [String: Time] = [:]
        for time in times {
            guard keyed[time.id] == nil else {
                throw TriggerSchedulerError.persistenceFailure("The clock contains duplicate identity \(time.id); repair clock/times.json.")
            }
            keyed[time.id] = time
        }
        return keyed
    }

    /// All readers and mutations enter through this resolution before using or adding instants in the current zone.
    private func resolveZone(_ times: [String: Time]) throws -> [String: Time] {
        let zone = TimeZone.current
        var resolved = times
        do {
            for id in times.keys { try resolved[id]?.resolve(in: zone) }
            if resolved != times { try save(resolved) }
            else { loaded = resolved }
            return resolved
        } catch {
            // Keep the old projection and its zone together; never fire an old-zone instant after an unsuccessful resolution.
            deadline?.cancel()
            throw error
        }
    }

    private func save(_ times: [String: Time]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try CredentialFileLock.withLock(url) {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(times.values.sorted { $0.id < $1.id }), to: url)
        }
        loaded = times
    }
}
