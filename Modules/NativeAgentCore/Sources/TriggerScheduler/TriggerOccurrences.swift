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

    /// Saved inbox authority gates all inbox fires; damage throws instead of saying the person disabled it.
    nonisolated var inboxMasterOn: Bool {
        get throws {
            try SavedTrustPolicyAuthority.flag(block: "inboxPolicy", key: "enabled", default: true, dataRoot: root)
        }
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
            let configs: [TriggerConfig]
            do {
                if surface == "inbox", try !inboxMasterOn { continue }
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
                let occurrence: String
                do {
                    guard let claimed = try await claimIfDue(cfg, statePath: statePath) else { continue }
                    occurrence = claimed
                } catch {
                    unavailable.append(TriggerFireResult(status: "error", name: cfg.name,
                        error: "Trigger \(cfg.name) is due but could not be claimed, so it did not fire: \(error.localizedDescription)"))
                    continue
                }
                fired.append(await runClaimedTrigger(surface: surface, name: cfg.name, occurrence: occurrence))
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
        return await runClaimedTrigger(surface: surface, name: name, occurrence: occurrence)
    }

    private func runClaimedTrigger(surface: String, name: String, occurrence requestedOccurrence: String? = nil) async -> TriggerFireResult {
        guard ["inbox", "workshop"].contains(surface) else {
            return TriggerFireResult(status: "error", name: name, error: "surface must be inbox or workshop")
        }
        let statePath = surface == "inbox" ? inboxStatePath : workshopExecutionStatePath
        let occurrence: String
        do { occurrence = try retainedClaim(statePath: statePath, name: name, requested: requestedOccurrence) }
        catch { return TriggerFireResult(status: "error", name: name, error: error.localizedDescription) }
        let operation = "trigger:\(surface):\(name):\(occurrence)"
        var result: TriggerFireResult
        do {
            // Admission precedes the part's model/tools. Release both locks
            // while it thinks, then use the same admission again to publish.
            if let refused = try await withEnabledTriggerClaim(surface: surface, name: name, occurrence: occurrence, work: { _ in nil }) {
                result = refused
            } else {
                let prepared: InboxPreparation
                switch surface {
                case "inbox":
                    prepared = try await prepareInboxTrigger(name: name)
                case "workshop":
                    prepared = .refused(TriggerFireResult(status: "not_found", name: name))
                default: throw TriggerSchedulerError.invalidRequest("surface must be inbox or workshop")
                }
                guard let published = try await withEnabledTriggerClaim(surface: surface, name: name, occurrence: occurrence, work: { [self] current in
                    var result: TriggerFireResult
                    switch surface {
                    case "inbox":
                        let currentPreparation: InboxPreparation
                        switch prepared {
                        case .ready(_, let notify, let item): currentPreparation = .ready(row: current, notify: notify, item: item)
                        case .refused: currentPreparation = prepared
                        }
                        result = await publishInboxTrigger(name: name, occurrence: occurrence, prepared: currentPreparation)
                    case "workshop":
                        let rows = try await workshopRunner.listWorkshopExecutions()
                        let source = "trigger:\(name):occurrence:\(occurrence)"
                        if let prior = rows.first(where: {
                            guard case .object(let row) = $0 else { return false }
                            return row["trigger_source"] == .string(source)
                        }), case .object(let row) = prior, case .string(let id)? = row["id"] {
                            result = TriggerFireResult(status: "fired", name: name, executionId: id)
                        } else {
                            result = try await fireWorkshopTrigger(name: name, occurrence: occurrence, seed: [])
                        }
                    default: throw TriggerSchedulerError.invalidRequest("surface must be inbox or workshop")
                    }
                    return result
                }) else {
                    throw TriggerSchedulerError.persistenceFailure("Trigger publication returned no result; its retained claim remains unfinished.")
                }
                result = published
            }
        } catch {
            result = TriggerFireResult(status: "error", name: name, error: error.localizedDescription)
        }
        if result.status == "fired" || result.status == "disabled" {
            await RepairOwed.settle(root, operation: operation,
                evidence: .init(source: "trigger", id: result.itemId ?? result.executionId ?? name)).value
        }
        return result
    }

    /// nil means admission succeeded without publication (the preparation pass).
    /// Both passes use the same config → state transaction and exact claim.
    private func withEnabledTriggerClaim(
        surface: String, name: String, occurrence: String,
        work: @Sendable (TriggerConfig) async throws -> TriggerFireResult?
    ) async throws -> TriggerFireResult? {
        try Task.checkCancellation()
        let configPath = surface == "inbox" ? inboxPath : workshopExecutionsPath
        let statePath = surface == "inbox" ? inboxStatePath : workshopExecutionStatePath
        return try await SwiftNativePersistenceCore.withFileLock(configPath) { [self] in
            // A retained claim requires an existing definition, never seeded defaults.
            if case .missing = Self.readConfigsRaw(configPath) {
                throw TriggerSchedulerError.persistenceFailure("The current trigger definition is unavailable; its retained claim has not been run.")
            }
            let configs = try await Self._readList(path: configPath, defaultValue: [])
            guard let current = configs.first(where: { $0.name == name }) else {
                throw TriggerSchedulerError.persistenceFailure("The current trigger definition is unavailable; its retained claim has not been run.")
            }
            return try await SwiftNativePersistenceCore.withFileLock(statePath) { [self] in
                _ = try retainedClaim(statePath: statePath, name: name, requested: occurrence)
                guard case .parsed(var state) = Self.readStateRaw(statePath),
                      case .object(var entry)? = state[name],
                      case .array(let pending)? = entry["unfinished_occurrences"] else {
                    throw TriggerSchedulerError.persistenceFailure("Retained trigger claim became unreadable before admission; no effect was attempted.")
                }
                try Task.checkCancellation()
                let result: TriggerFireResult?
                if !current.enabled {
                    result = TriggerFireResult(status: "disabled", name: name, error: "The current trigger definition is disabled; its retained occurrence was settled without running.")
                } else if surface == "inbox", try !inboxMasterOn {
                    result = TriggerFireResult(status: "disabled", name: name, error: "Raising things unasked is off (Notifications); its retained occurrence was settled without running.")
                } else {
                    result = try await work(current)
                }
                if result?.status == "fired" || result?.status == "disabled" {
                    entry["unfinished_occurrences"] = .array(pending.filter { $0 != .string(occurrence) })
                    state[name] = .object(entry)
                    try await SwiftNativePersistenceCore.writeJSON(.object(state), to: statePath)
                }
                return result
            }
        }
    }

    private nonisolated func retainedClaim(statePath: URL, name: String, requested: String?) throws -> String {
        guard case .parsed(let state) = Self.readStateRaw(statePath),
              case .object(let entry)? = state[name],
              entry["state"] == .string("running"),
              case .string(let life)? = entry["lifeID"], UUID(uuidString: life) != nil,
              try DataRootLife.isCurrent(life, in: root),
              case .array(let pending)? = entry["unfinished_occurrences"] else {
            throw TriggerSchedulerError.persistenceFailure("No readable current-life claim for \(name) at \(statePath.path); no repair effect was attempted.")
        }
        let claims = pending.compactMap { value -> String? in
            if case .string(let stamp) = value { return stamp }; return nil
        }
        if let requested, claims.contains(requested) { return requested }
        if requested == nil, claims.count == 1 { return claims[0] }
        throw TriggerSchedulerError.invalidRequest("Supply the exact retained unfinished occurrence for \(name); no repair effect was attempted")
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
        do {
            if try inboxMasterOn {
                let inbox = try await listInboxTriggers()
                candidates.append(contentsOf: deadlines(for: inbox, statePath: inboxStatePath, after: reference))
            }
            await RepairOwed.settle(root, operation: "scheduler.inbox.discovery",
                evidence: .init(source: "trust", id: SavedTrustPolicyAuthority.policyURL(dataRoot: root).path)).value
        } catch {
            await RepairOwed.owe(root, id: "trigger-inbox-policy", kind: .run,
                operation: "scheduler.inbox.discovery", owner: "Trust policy and inbox triggers",
                words: "Inbox trigger deadline is unavailable: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("doctor.run")])).value
        }
        do {
            let executions = try await listWorkshopTriggers()
            candidates.append(contentsOf: deadlines(
                for: executions,
                statePath: workshopExecutionStatePath,
                after: reference
            ))
            await RepairOwed.settle(root, operation: "scheduler.workshop.discovery",
                evidence: .init(source: "trigger", id: workshopExecutionsPath.path)).value
        } catch {
            await RepairOwed.owe(root, id: "trigger-workshop-config", kind: .run,
                operation: "scheduler.workshop.discovery", owner: workshopExecutionsPath.path,
                words: "Workshop trigger deadline is unavailable: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("doctor.run")])).value
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
    nonisolated static func dailySchedule(_ cfg: TriggerConfig) -> [String: JSONValue]? {
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
                  parseISOTimestamp(stamp) != nil,
                  case .string(let life)? = entry["lifeID"], UUID(uuidString: life) != nil,
                  case .string(let state)? = entry["state"], ["running", "stopped"].contains(state) else { return false }
            guard case .string(let key)? = entry["last_fired_occurrence"],
                  SchedulerJobRuntime.civilEpoch(key) != nil else { return false }
                guard case .array(let pending)? = entry["unfinished_occurrences"], pending.allSatisfy({
                    if case .string(let stamp) = $0 { return parseISOTimestamp(stamp) != nil }
                    return false
                }) else { return false }
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
        return false // readStateRaw rejects missing civil evidence.
    }

    private static func timeOccurrence(_ cfg: TriggerConfig, scheduled: Date) -> String {
        let date = SchedulerJobRuntime.occurrence(at: scheduled, zone: .autoupdatingCurrent).prefix(10)
        return date + String(format: " %02d:%02d", intField(cfg.config, "hour")!, intField(cfg.config, "minute") ?? 0)
    }

    /// Lock order is configuration → state, shared with the configuration writer.
    /// Re-read the enabled definition before claiming its scheduled instant.
    /// Nil means not due or already claimed; unavailable claims throw.
    private func claimIfDue(_ cfg: TriggerConfig, statePath: URL) async throws -> String? {
        let name = cfg.name
        let configPath = statePath == inboxStatePath ? inboxPath : workshopExecutionsPath
        let seed: [JSONValue]
        if case .missing = Self.readConfigsRaw(configPath) {
            let proposed = try await defaults()
            seed = statePath == inboxStatePath ? proposed.inbox : proposed.workshop
        } else { seed = [] }
        return try await SwiftNativePersistenceCore.withFileLock(configPath) { [self] in
            let configs = try await Self._readList(path: configPath, defaultValue: seed)
            guard let cfg = configs.first(where: { $0.name == name }), cfg.enabled else { return nil }
            return try await SwiftNativePersistenceCore.withFileLock(statePath) { [self] in
                guard let scheduled = self.scheduledInstantIfDue(cfg) else { return nil }
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
                    return nil
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
                return stamp
            }
        }
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
