import Foundation
import NativeAgentShared
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
// Blueprint: | `TriggerScheduler.swift` | Trigger config and consent |

/// Owns trigger eligibility, locked durable occurrence claims, job state and inbox acceptance; host delivery follows acceptance. BackgroundLoopLifetimes owns
/// wake lifecycle; SchedulerDueJobRunner executes jobs. Triggers live at triggers/trigger_config.json; cross-process locks serialize mutations and claims.
public actor SwiftNativeTriggerScheduler: Sendable {
    /// A bounded pass left runnable work. The BackgroundLoops listener coalesces this edge with source changes before admitting the next pass.
    public static let dueWorkRemaining = Notification.Name("NativeAgent.scheduler.dueWorkRemaining")

    let root: URL
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> String
    /// Missing notification transport still accepts the fire but must record warn when the requested push cannot be sent.
    let notifier: TriggerNotifier?
    /// Explicit optional worklog source for the native brief reader. nil means unconfigured; no personal directory is selected implicitly.
    let worklogPath: URL?
    /// The originating door runs the agent's part; absent/disabled code stays unavailable.
    let morningBriefPart: MorningBriefPart?

    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        notifier: TriggerNotifier? = nil,
        worklogPath: URL? = nil,
        morningBriefPart: MorningBriefPart? = nil
    ) {
        self.root = root
        self.now = now
        self.uuid = uuid
        self.notifier = notifier
        self.worklogPath = worklogPath
        self.morningBriefPart = morningBriefPart
    }

    /// Canonical trigger configuration; an absent file receives fresh defaults.
    public nonisolated var inboxPath: URL {
        root
            .appendingPathComponent("triggers", isDirectory: true)
            .appendingPathComponent("trigger_config.json")
    }

    // MARK: periodic-fire liveness state
    /// Canonical inbox occurrence state, kept apart from configuration.
    public nonisolated var inboxStatePath: URL {
        root
            .appendingPathComponent("triggers", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
    }
    /// The shared activity feed every fire writes its receipt into.
    public nonisolated var activityFeedPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    /// Bound each pass to protect liveness after mass edits or clock jumps; keep remaining occurrences due and request one coalesced continuation.
    static let periodicFireCapPerTick = 3

    internal static let logger = Logger(subsystem: "com.nativeagent.core", category: "trigger-scheduler")

    // MARK: list

    public func listInboxTriggers() async throws -> [TriggerConfig] {
        return try await Self._readList(path: inboxPath, defaultValue: try await defaults().inbox)
    }

    internal static func _readList(
        path: URL,
        defaultValue: @autoclosure @Sendable () async throws -> [JSONValue]
    ) async throws -> [TriggerConfig] {
        let items = try await loadConfigs(path: path, defaultValue: try await defaultValue())
        var names: Set<String> = []
        return try items.enumerated().map { index, item in
            guard case .object(let fields) = item,
                  case .bool? = fields["enabled"],
                  let cfg = TriggerConfig(json: item),
                  names.insert(cfg.name).inserted,
                  cfg.kind == "time", Self.dailySchedule(cfg) != nil else {
                throw TriggerSchedulerError.persistenceFailure(
                    "\(path.path) row \(index) is not a supported time trigger with Boolean enabled and a valid clock; bytes preserved.")
            }
            return cfg
        }
    }

    // MARK: enable / disable — inbox

    public func enableInboxTrigger(name: String) async throws -> TriggerStatus {
        try await _setEnabledInbox(name: name, enabled: true)
    }

    public func disableInboxTrigger(name: String) async throws -> TriggerStatus {
        try await _setEnabledInbox(name: name, enabled: false)
    }

    private func _setEnabledInbox(name: String, enabled: Bool) async throws -> TriggerStatus {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }
        let seed: [JSONValue] = if case .missing = Self.readConfigsRaw(inboxPath) { try await defaults().inbox } else { [] }
        let work: @Sendable () async throws -> TriggerStatus = { [inboxPath] in
            try await Self._setEnabledImpl(
                name: name, enabled: enabled,
                path: inboxPath, defaultValue: seed
            )
        }
        return try await SwiftNativePersistenceCore.withFileLock(inboxPath, work)
    }

    /// Update a matching supported inbox trigger; return updated or not_found without dropping saved fields.
    private static func _setEnabledImpl(
        name: String,
        enabled: Bool,
        path: URL,
        defaultValue: [JSONValue]
    ) async throws -> TriggerStatus {
        // Corrupt saved configuration keeps its bytes and throws; only a missing file receives defaults.
        var items = try await Self.loadConfigs(path: path, defaultValue: defaultValue)
        _ = try await Self._readList(path: path, defaultValue: defaultValue)
        var found = false
        for (idx, item) in items.enumerated() {
            guard case .object(var obj) = item,
                  case .string(let nm) = obj["name"] ?? .null,
                  ExecutionEventVocabulary.matches(nm, name) else { continue }
            obj["enabled"] = .bool(enabled)
            items[idx] = .object(obj)
            found = true
            break
        }
        if !found {
            return TriggerStatus(name: name, enabled: enabled, status: "not_found")
        }
        do {
            try await SwiftNativePersistenceCore.writeJSON(.array(items), to: path)
        } catch {
            throw TriggerSchedulerError.persistenceFailure(String(describing: error))
        }
        return TriggerStatus(name: name, enabled: enabled, status: "updated")
    }

}
