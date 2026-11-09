import Foundation
import Experiences
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import TrustCenter
import os
import NotificationInbox
// Blueprint: | `TriggerOccurrences.swift` | Each enabled inbox time trigger is a daily `brief:<name>` time on the one clock; its delivery publishes the card |

extension SwiftNativeTriggerScheduler {
    /// The clock owner every inbox time trigger is delivered to.
    public static let clockOwner = "brief"

    /// Saved inbox authority gates all inbox fires; damage throws instead of saying the person disabled it.
    nonisolated var inboxMasterOn: Bool {
        get throws {
            try SwiftNativeTrustCenter(dataRoot: root).savedPolicyFlag(block: "inboxPolicy", key: "enabled", default: true)
        }
    }

    /// The clock holds one daily time per enabled trigger, at the trigger's own hour and minute; a disabled or removed trigger holds none. A time whose
    /// rhythm already matches keeps its next occurrence, so declaring again never moves or repeats one.
    public func declareTimes() async throws {
        let configs = try await listInboxTriggers()
        let clock = OneClock.at(root)
        let declared = try await clock.times(owner: Self.clockOwner)
        var wanted: Set<String> = []
        for cfg in configs where cfg.enabled {
            guard let rhythm = Self.dailySchedule(cfg) else { continue }
            let id = Self.clockOwner + ":" + cfg.name
            wanted.insert(id)
            if declared.first(where: { $0.id == id })?.rhythm == rhythm { continue }
            guard let next = SchedulerJobNormalizer.nextOccurrence(rhythm, after: now()) else {
                throw TriggerSchedulerError.invalidRequest("Trigger \(cfg.name) has no next occurrence at its saved hour and minute")
            }
            try await clock.declare(.init(id: id, rhythm: rhythm, next: next, payload: .object(["name": .string(cfg.name)])))
        }
        for time in declared where !wanted.contains(time.id) { try await clock.withdraw(time.id) }
    }

    /// One occurrence of a trigger, delivered by the clock: the part prepares the card, then it is published once (the occurrence keys the card).
    /// A failure is owed for repair with the call that publishes it now.
    public func deliver(name: String, occurrence: Date) async {
        let stamp = Self.isoTimestamp(occurrence)
        let result: TriggerFireResult
        do { result = await publishInboxTrigger(name: name, occurrence: stamp, prepared: try await prepareInboxTrigger(name: name)) }
        catch { result = TriggerFireResult(status: "error", name: name, error: error.localizedDescription) }
        let operation = "trigger:inbox:\(name):\(stamp)"
        guard result.status == "fired" || result.status == "disabled" else {
            await RepairOwed.owe(root, id: "trigger-occurrence:" + operation, kind: .run, operation: operation,
                owner: inboxPath.path + " > " + name,
                words: "The \(name) trigger's \(stamp) card was not published: \(result.error ?? result.status)",
                nextCall: ToolFailureError.call("app", ["action": .string("scheduler.trigger_fire"), "args": .object(["name": .string(name)])])).value
            return
        }
        await RepairOwed.settle(root, operation: operation, evidence: .init(source: "trigger", id: result.itemId ?? name)).value
    }

    /// A time trigger's daily rhythm; an absent minute means zero and invalid fields make the trigger unreadable.
    nonisolated static func dailySchedule(_ cfg: TriggerConfig) -> JSONValue? {
        guard cfg.kind == "time", let hour = intField(cfg.config, "hour"), (0...23).contains(hour) else { return nil }
        let minute: Int
        if case .object(let object)? = cfg.config, object["minute"] != nil {
            guard let parsed = intField(cfg.config, "minute") else { return nil }
            minute = parsed
        } else { minute = 0 }
        guard (0...59).contains(minute) else { return nil }
        return .object(["type": .string("daily"), "hour": .int(Int64(hour)), "minute": .int(Int64(minute))])
    }

    /// Distinguish missing, parsed and damaged configuration before any defaulting or mutation.
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

    /// One config loader for reads and mutations. Only a missing file asks the part for defaults, before any lock; locked mutations supply prepared defaults.
    /// Parsed → the person's rows. Corrupt → the canonical bytes stay in place and the operation throws, never resurrecting defaults over saved data.
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
                """
                    Trigger configuration \(path.lastPathComponent) is unreadable and has been preserved. Repair the file before using triggers; defaults \
                    have not been restored.
                    """
            )
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
}
