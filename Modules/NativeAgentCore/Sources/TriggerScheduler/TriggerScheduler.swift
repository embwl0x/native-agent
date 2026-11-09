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

/// Owns inbox trigger configuration and inbox acceptance; each enabled time trigger is a time on the one clock, and host delivery follows acceptance.
/// Triggers live at triggers/trigger_config.json; a cross-process lock serializes their mutations.
public actor SwiftNativeTriggerScheduler: Sendable {
    let root: URL
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> String
    /// Missing notification transport still accepts the fire but must record warn when the requested push cannot be sent.
    let notifier: TriggerNotifier?
    /// The originating door runs the agent's part; absent/disabled code stays unavailable.
    let morningBriefPart: MorningBriefPart?

    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        notifier: TriggerNotifier? = nil,
        morningBriefPart: MorningBriefPart? = nil
    ) {
        self.root = root
        self.now = now
        self.uuid = uuid
        self.notifier = notifier
        self.morningBriefPart = morningBriefPart
    }

    /// Canonical trigger configuration; an absent file receives fresh defaults.
    public nonisolated var inboxPath: URL {
        root
            .appendingPathComponent("triggers", isDirectory: true)
            .appendingPathComponent("trigger_config.json")
    }

    /// The shared activity feed every fire writes its receipt into.
    public nonisolated var activityFeedPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

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
        let status = try await SwiftNativePersistenceCore.withFileLock(inboxPath, work)
        // The clock follows the saved configuration: an enabled trigger holds its daily time, a disabled one none.
        if status.status == "updated" { try await declareTimes() }
        return status
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
