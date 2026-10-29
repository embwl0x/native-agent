import Foundation
import Experiences
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
import WorkshopExecution
import os
import Privacy
import NotificationInbox
import Darwin
// Blueprint: | `TriggerOccurrences.swift` | SwiftNativeTriggerScheduler daily eligibility, durable life-stamped trigger claims, repair, deadlines and checked occurrence/config reads |

extension SwiftNativeTriggerScheduler {

    /// Saved inbox authority gates all inbox fires; default-on authority fails closed when damaged.
    nonisolated var inboxMasterOn: Bool {
        SavedTrustPolicyAuthority.flag(block: "inboxPolicy", key: "enabled", default: true, dataRoot: root)
    }

    /// The full fire envelopes for this tick, in fire order.
    public func evaluateAndFireDetailed() async -> [TriggerFireResult] {
        var fired: [TriggerFireResult] = []
        var deferredDueToCap = false
        for (surface, path) in [("inbox", inboxStatePath), ("workshop", workshopExecutionStatePath)] {
            guard case .parsed(let state) = Self.readStateRaw(path) else { continue }
            for (name, value) in state {
                guard case .object(let entry) = value, entry["state"] != .string("stopped"),
                      case .array(let pending)? = entry["unfinished_occurrences"] else { continue }
                for case .string(let occurrence) in pending {
                    await oweTrigger(surface: surface, name: name, occurrence: occurrence).value
                }
            }
        }

        // Claims prevent duplicate effects; only successful work settles repair.
        // A surface whose configuration cannot be read or whose state is
        // damaged fires nothing until repaired, and the pass says so: its
        // receipt is an error row, never an empty pass.
        var unavailable: [TriggerFireResult] = []
        for (surface, statePath) in [("inbox", inboxStatePath), ("workshop", workshopExecutionStatePath)] {
            if surface == "inbox", !inboxMasterOn { continue }
            let configs: [TriggerConfig]
            do {
                configs = try await surface == "inbox" ? listInboxTriggers() : listWorkshopTriggers()
            } catch {
                unavailable.append(TriggerFireResult(status: "error", name: "\(surface) triggers",
                    error: "\(surface.capitalized) triggers could not be read; none fire until they can: \(error.localizedDescription)"))
                continue
            }
            if case .corrupt = Self.readStateRaw(statePath) {
                Self.logger.error("\(surface, privacy: .public) trigger_state.json is corrupt — its time triggers are DORMANT this pass until repaired")
                unavailable.append(TriggerFireResult(status: "error", name: "\(surface) triggers",
                    error: "\(statePath.path) is damaged; \(surface) time triggers stay dormant until it is repaired or restored."))
                continue
            }
            for cfg in configs where cfg.enabled {
                guard let scheduled = scheduledInstantIfDue(cfg) else { continue }
                if fired.count >= Self.periodicFireCapPerTick {
                    // A clock-due trigger may already have fired. Only an
                    // unclaimed remainder earns another pass; failed/corrupt
                    // state waits for its repair or source-change event.
                    let state: [String: JSONValue]
                    switch Self.readStateRaw(statePath) {
                    case .corrupt: continue
                    case .missing: state = [:]
                    case .parsed(let saved): state = saved
                    }
                    guard !Self.hasFired(cfg, state: state, scheduled: scheduled) else { continue }
                    deferredDueToCap = true
                    break
                }
                do {
                    guard try await claimIfDue(cfg, statePath: statePath) else { continue }
                } catch {
                    unavailable.append(TriggerFireResult(status: "error", name: cfg.name,
                        error: "Trigger \(cfg.name) is due but could not be claimed, so it did not fire: \(error.localizedDescription)"))
                    continue
                }
                fired.append(await runClaimedTrigger(surface: surface, name: cfg.name))
            }
        }
        if deferredDueToCap {
            Self.logger.error(
                "periodic trigger fire cap (\(Self.periodicFireCapPerTick, privacy: .public)) hit this tick — fired \(fired.count, privacy: .public), remaining due triggers request a continuation"
            )
            if !Task.isCancelled {
                NotificationCenter.default.post(name: Self.dueWorkRemaining, object: nil)
            }
        }
        return fired + unavailable
    }

    public func repairTrigger(surface: String, name: String, occurrence: String? = nil) async -> TriggerFireResult {
        let path = surface == "inbox" ? inboxStatePath : workshopExecutionStatePath
        if case .parsed(let state) = Self.readStateRaw(path), state[name]?.objectValue?["state"] == .string("stopped") {
            do { return try await surface == "inbox" ? fireInboxTrigger(name: name) : fireWorkshopTrigger(name: name) }
            catch { return TriggerFireResult(status: "error", name: name, error: error.localizedDescription) }
        }
        return await runClaimedTrigger(surface: surface, name: name, occurrence: occurrence)
    }

    private func runClaimedTrigger(surface: String, name: String, occurrence: String? = nil) async -> TriggerFireResult {
        let statePath = surface == "inbox" ? inboxStatePath : workshopExecutionStatePath
        if case .parsed(let state) = Self.readStateRaw(statePath), state[name]?.objectValue?["state"] == .string("stopped") {
            return TriggerFireResult(status: "stopped", name: name, error: DataRootLife.stoppedReason)
        }
        let claimed: String? = if case .parsed(let state) = Self.readStateRaw(statePath),
            let at = Self.lastFiredFromState(state, name: name) { Self.isoTimestamp(at) } else { nil }
        let occurrence = occurrence ?? claimed ?? uuid()
        let operation = "trigger:\(surface):\(name):\(occurrence)"
        var result: TriggerFireResult
        do {
            // A competing repair can finish while the part thinks; the locked
            // read below still decides whether anything may be published.
            let prepared: InboxPreparation
            let workshopSeed: [JSONValue]
            switch surface {
            case "inbox":
                prepared = try await prepareInboxTrigger(name: name)
                workshopSeed = []
            case "workshop":
                prepared = .refused(TriggerFireResult(status: "not_found", name: name))
                workshopSeed = if case .missing = Self.readConfigsRaw(workshopExecutionsPath) { try await defaults().workshop } else { [] }
            default: throw TriggerSchedulerError.invalidRequest("surface must be inbox or workshop")
            }
            result = try await SwiftNativePersistenceCore.withFileLock(statePath) { [self] in
                var result: TriggerFireResult
                switch surface {
                case "inbox":
                    result = await publishInboxTrigger(name: name, occurrence: occurrence, prepared: prepared)
                case "workshop":
                    let rows = try await workshopRunner.listWorkshopExecutions()
                    let source = "trigger:\(name):occurrence:\(occurrence)"
                    if let prior = rows.first(where: {
                        guard case .object(let row) = $0 else { return false }
                        return row["trigger_source"] == .string(source)
                    }), case .object(let row) = prior, case .string(let id)? = row["id"] {
                        result = TriggerFireResult(status: "fired", name: name, executionId: id)
                    } else {
                        result = try await fireWorkshopTrigger(name: name, occurrence: occurrence, seed: workshopSeed)
                    }
                default: throw TriggerSchedulerError.invalidRequest("surface must be inbox or workshop")
                }
                if result.status == "fired" {
                    guard case .parsed(var state) = Self.readStateRaw(statePath),
                          case .object(var entry)? = state[name] else { return result }
                    if case .array(let pending)? = entry["unfinished_occurrences"] {
                        entry["unfinished_occurrences"] = .array(pending.filter { $0 != .string(occurrence) })
                        state[name] = .object(entry)
                        try await SwiftNativePersistenceCore.writeJSON(.object(state), to: statePath)
                    }
                }
                return result
            }
        } catch {
            result = TriggerFireResult(status: "error", name: name, error: error.localizedDescription)
        }
        if result.status == "fired" {
            await RepairOwed.settle(root, operation: operation,
                evidence: .init(source: "trigger", id: result.itemId ?? result.executionId ?? name)).value
        } else {
            await oweTrigger(surface: surface, name: name, occurrence: occurrence).value
        }
        return result
    }

    private func oweTrigger(surface: String, name: String, occurrence: String) -> Task<Void, Never> {
        let path = surface == "inbox" ? inboxStatePath : workshopExecutionStatePath
        let operation = "trigger:\(surface):\(name):\(occurrence)"
        return RepairOwed.owe(root, id: "trigger-claim:" + operation, kind: .run,
            operation: operation, owner: path.path + " > " + name + ".unfinished_occurrences",
            words: "This trigger occurrence awaits durable acceptance.",
            nextCall: ToolFailureError.call("app", ["action": .string("scheduler.trigger_fire"), "args": .object([
                "surface": .string(surface), "name": .string(name), "occurrence": .string(occurrence)])]))
    }

    /// Earliest clock crossing for an enabled `time` trigger; other kinds have
    /// no deadline. This is a read-only projection over canonical config and liveness
    /// state. It never claims or fires an occurrence.
    ///
    /// Future time instants remain exact. A capped pass requests a coalesced
    /// continuation; an unavailable or failed occurrence waits for source or
    /// repair invalidation, with the slow integrity sweep as a missed-event
    /// backstop. Overdue work never manufactures a retry deadline.
    public func nextMeaningfulDeadline(after reference: Date) async -> Date? {
        var candidates: [Date] = []
        if inboxMasterOn, let inbox = try? await listInboxTriggers() {
            candidates.append(contentsOf: deadlines(
                for: inbox,
                statePath: inboxStatePath,
                after: reference
            ))
        }
        if let executions = try? await listWorkshopTriggers() {
            candidates.append(contentsOf: deadlines(
                for: executions,
                statePath: workshopExecutionStatePath,
                after: reference
            ))
        }
        return candidates.min()
    }

    private nonisolated func deadlines(
        for configs: [TriggerConfig],
        statePath: URL,
        after reference: Date
    ) -> [Date] {
        let state: [String: JSONValue]
        switch Self.readStateRaw(statePath) {
        case .corrupt:
            return []
        case .missing:
            state = [:]
        case .parsed(let parsed):
            state = parsed
        }
        return configs.compactMap { cfg in
            guard cfg.enabled else { return nil }
            switch cfg.kind {
            case "time":
                guard let schedule = Self.dailySchedule(cfg) else { return nil }
                guard let today = SchedulerJobRuntime.dailyOccurrence(schedule, on: reference) else {
                    return Self.nextDailyOccurrence(schedule, after: reference)
                }
                if Self.hasFired(cfg, state: state, scheduled: today) {
                    return Self.nextDailyOccurrence(schedule, after: max(reference, today))
                }
                if today > reference { return today }
                return nil
            default:
                return nil
            }
        }
    }

    /// Clock-only daily eligibility; invalid schedules are dormant. claimIfDue recomputes under the state lock with last-fired state to prevent double fires.
    private nonisolated func scheduledInstantIfDue(_ cfg: TriggerConfig) -> Date? {
        let current = now()
        guard let schedule = Self.dailySchedule(cfg),
              let scheduled = SchedulerJobRuntime.dailyOccurrence(schedule, on: current),
              current >= scheduled else { return nil }
        return scheduled
    }

    /// Trigger admission stays strict: absent minute means zero; invalid fields are dormant.
    private nonisolated static func dailySchedule(_ cfg: TriggerConfig) -> [String: JSONValue]? {
        guard cfg.kind == "time", let hour = intField(cfg.config, "hour"), (0...23).contains(hour) else { return nil }
        let minute: Int
        if case .object(let object)? = cfg.config, object["minute"] != nil {
            guard let parsed = intField(cfg.config, "minute") else { return nil }
            minute = parsed
        } else { minute = 0 }
        guard (0...59).contains(minute) else { return nil }
        return ["type": .string("daily"), "hour": .int(Int64(hour)), "minute": .int(Int64(minute))]
    }

    private nonisolated static func nextDailyOccurrence(_ schedule: [String: JSONValue], after date: Date) -> Date? {
        (try? SchedulerJobNormalizer.nextFromSchedule(schedule, afterEpoch: date.timeIntervalSince1970, now: { date }))
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// Missing state is never-fired; damaged state is unavailable; parsed state retains saved claims.
    enum StateRead {
        case missing
        case corrupt
        case parsed([String: JSONValue])
    }

    /// Classification of a per-surface trigger CONFIG file (a JSON array), the
    /// array-shaped sibling of `StateRead`. Same three cases, same reason.
    enum ConfigRead {
        case missing
        case corrupt
        case parsed([JSONValue])
    }

    /// Distinguish missing configuration from corrupt saved bytes before any defaulting or mutation.
    nonisolated static func readConfigsRaw(_ path: URL) -> ConfigRead {
        guard FileManager.default.fileExists(atPath: path.path) else { return .missing }
        guard let data = try? Data(contentsOf: path) else { return .corrupt }
        // An existing empty file is corrupt and cannot be reseeded.
        if data.isEmpty { return .corrupt }
        guard case .array(let items)? = try? JSONValue.parse(data) else { return .corrupt }
        return .parsed(items)
    }

    /// One config loader for reads and mutations. Only a missing file asks the
    /// part for defaults, before any lock; locked mutations supply prepared defaults.
    /// Parsed → the user's rows. Corrupt → the canonical bytes stay in place
    /// and the operation throws, never resurrecting defaults over user data.
    nonisolated static func loadConfigs(
        path: URL,
        defaultValue: @autoclosure @Sendable () async throws -> [JSONValue]
    ) async throws -> [JSONValue] {
        switch readConfigsRaw(path) {
        case .missing:
            return try await defaultValue()
        case .parsed(let items):
            return items
        case .corrupt:
            logger.error("corrupt trigger config \(path.lastPathComponent, privacy: .public) — preserved in place; refusing to overwrite it with defaults")
            throw TriggerSchedulerError.persistenceFailure(
                "Trigger configuration \(path.lastPathComponent) is unreadable and has been preserved. Repair the file before using triggers; defaults have not been restored."
            )
        }
    }

    /// Missing is empty; damaged state is unavailable; another life's work is stopped.
    nonisolated static func readStateRaw(_ statePath: URL) -> StateRead {
        guard FileManager.default.fileExists(atPath: statePath.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: statePath) else {
            return .corrupt
        }
        if data.isEmpty { return .corrupt }
        guard case .object(let o)? = try? JSONValue.parse(data) else {
            return .corrupt
        }
        guard o.values.allSatisfy({ value in
            guard case .object(let entry) = value,
                  case .string(let stamp)? = entry["last_fired_at"],
                  parseISOTimestamp(stamp) != nil else { return false }
            if let occurrence = entry["last_fired_occurrence"] {
                guard case .string(let key) = occurrence, SchedulerJobRuntime.civilEpoch(key) != nil else { return false }
            }
            if let unfinished = entry["unfinished_occurrences"] {
                guard case .array(let pending) = unfinished, pending.allSatisfy({
                    if case .string(let stamp) = $0 { return parseISOTimestamp(stamp) != nil }
                    return false
                }) else { return false }
            }
            return true
        }) else { return .corrupt }
        guard let life = try? DataRootLife.current(in: statePath.deletingLastPathComponent().deletingLastPathComponent()) else { return .corrupt }
        return .parsed(o.mapValues { value in
            guard case .object(var entry) = value, DataRootLife.life(of: entry["lifeID"]) != life,
                  case .array(let pending)? = entry["unfinished_occurrences"], !pending.isEmpty else { return value }
            entry["state"] = .string("stopped")
            entry["reason"] = .string(DataRootLife.stoppedReason)
            return .object(entry)
        })
    }

    /// Pull a trigger's persisted `last_fired_at` out of an already-read state
    /// map. nil when the trigger has no recorded fire.
    private static func lastFiredFromState(_ state: [String: JSONValue], name: String) -> Date? {
        guard case .object(let entry)? = state[name],
              case .string(let s)? = entry["last_fired_at"] else {
            return nil
        }
        return parseISOTimestamp(s)
    }

    private static func hasFired(_ cfg: TriggerConfig, state: [String: JSONValue], scheduled: Date) -> Bool {
        guard let last = lastFiredFromState(state, name: cfg.name) else { return false }
        guard cfg.kind == "time" else { return last >= scheduled }
        let occurrence = timeOccurrence(cfg, scheduled: scheduled)
        if case .object(let entry)? = state[cfg.name], case .string(let completed)? = entry["last_fired_occurrence"] {
            return completed >= occurrence
        }
        // Older claims retain the firing date; their configured clock time is still known.
        let date = SchedulerJobRuntime.occurrence(at: last, zone: .autoupdatingCurrent).prefix(10)
        return date + occurrence.dropFirst(10) >= occurrence
    }

    private static func timeOccurrence(_ cfg: TriggerConfig, scheduled: Date) -> String {
        let date = SchedulerJobRuntime.occurrence(at: scheduled, zone: .autoupdatingCurrent).prefix(10)
        return date + String(format: " %02d:%02d", intField(cfg.config, "hour")!, intField(cfg.config, "minute") ?? 0)
    }

    /// Recheck dueness and claim the scheduled instant under the state-file lock.
    /// False means not due or already claimed; unavailable claims throw.
    private func claimIfDue(_ cfg: TriggerConfig, statePath: URL) async throws -> Bool {
        // The locked check remains authoritative when the clock moves.
        guard scheduledInstantIfDue(cfg) != nil else { return false }
        let name = cfg.name

        let work: @Sendable () async throws -> Bool = { [self] in
            guard let scheduled = self.scheduledInstantIfDue(cfg) else { return false }
            let stamp = Self.isoTimestamp(scheduled)
            var state: [String: JSONValue]
            switch Self.readStateRaw(statePath) {
            case .corrupt:
                throw TriggerSchedulerError.invalidRequest("\(statePath.path) is damaged; restore it so the trigger can be claimed")
            case .missing:
                state = [:]
            case .parsed(let o):
                state = o
            }
            // Re-check under the lock: another instance may have just claimed
            // this same occurrence.
            if Self.hasFired(cfg, state: state, scheduled: scheduled) {
                return false
            }
            let surface = statePath == inboxStatePath ? "inbox" : "workshop"
            // `last_fired_at` stamps the scheduled instant at claim, not successful completion.
            var entry: [String: JSONValue] = if case .object(let saved)? = state[name] { saved } else { [:] }
            let life = try DataRootLife.current(in: root)
            let unfinished: [JSONValue] = if DataRootLife.life(of: entry["lifeID"]) == life, case .array(let saved)? = entry["unfinished_occurrences"] { saved } else { [] }
            entry["unfinished_occurrences"] = .array(unfinished + [.string(stamp)])
            entry["lifeID"] = .string(life)
            entry["state"] = .string("running")
            entry.removeValue(forKey: "reason")
            entry["last_fired_at"] = .string(stamp)
            if cfg.kind == "time" {
                entry["last_fired_occurrence"] = .string(Self.timeOccurrence(cfg, scheduled: scheduled))
            }
            state[name] = .object(entry)
            try await SwiftNativePersistenceCore.writeJSON(.object(state), to: statePath)
            await oweTrigger(surface: surface, name: name, occurrence: stamp).value
            return true
        }
        return try await SwiftNativePersistenceCore.withFileLock(statePath, work)
    }

    /// Accept integer fields and whole finite doubles within Int32 bounds; fractional fields are dormant.
    static func intField(_ config: JSONValue?, _ key: String) -> Int? {
        guard case .object(let cfg)? = config else { return nil }
        switch cfg[key] ?? .null {
        case .int(let i): return Int(i)
        case .double(let d):
            guard d.isFinite,
                  d.truncatingRemainder(dividingBy: 1) == 0,
                  d >= Double(Int32.min), d <= Double(Int32.max) else { return nil }
            return Int(d)
        default: return nil
        }
    }

    /// Parse an ISO8601 timestamp (with or without fractional seconds), matching
    /// the shape `isoTimestamp` writes.
    static func parseISOTimestamp(_ value: String) -> Date? {
        return NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }

}
