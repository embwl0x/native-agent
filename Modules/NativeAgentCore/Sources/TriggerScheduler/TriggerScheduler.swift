import Foundation
import NativeAgentShared
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
import WorkshopExecution
// Blueprint: | `TriggerScheduler.swift` | SwiftNativeTriggerScheduler actor, trigger configuration and consent in the canonical triggers directory and Workshop submission |

/// Owns trigger eligibility, locked durable occurrence claims, job state and inbox acceptance; host delivery follows acceptance.
/// BackgroundLoopLifetimes owns wake lifecycle; SchedulerDueJobRunner executes jobs and Workshop owns execution admission/draining.
/// Trigger arrays live at triggers/trigger_config.json and workshop/triggers.json; cross-process locks serialize mutations and claims.
public actor SwiftNativeTriggerScheduler: Sendable {
    /// A bounded pass left runnable work. The BackgroundLoops listener
    /// coalesces this edge with source changes before admitting the next pass.
    public static let dueWorkRemaining = Notification.Name("NativeAgent.scheduler.dueWorkRemaining")

    let root: URL
    internal let workshopRunner: SwiftNativeWorkshopRunner
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> String
    /// Injected snapshot and notification sender. When a trigger resolves `notify: true`
    /// and this is nil, the fire still lands and the receipt event is written
    /// with `status: "warn"` — LOUD, never silently absent.
    let notifier: TriggerNotifier?
    /// Explicit optional worklog source for the native brief reader.
    /// nil means unconfigured; no personal directory is selected implicitly.
    let worklogPath: URL?
    /// The originating door runs her part; absent/disabled code stays unavailable.
    let morningBriefPart: MorningBriefPart?

    /// The default Workshop runner shares this scheduler's root, clock and identity source.
    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        workshopRunner: SwiftNativeWorkshopRunner? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        notifier: TriggerNotifier? = nil,
        worklogPath: URL? = nil,
        morningBriefPart: MorningBriefPart? = nil
    ) {
        self.root = root
        self.workshopRunner = workshopRunner ?? SwiftNativeWorkshopRunner(
            root: root,
            now: now,
            uuid: uuid
        )
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

    public nonisolated var workshopExecutionsPath: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("triggers.json")
    }

    // MARK: periodic-fire liveness state
    //
    // Each surface keeps its own last-fired stamp and life-stamped unfinished
    // claims, separate from configuration; inbox/workshop names can collide.
    /// Canonical inbox occurrence state.
    public nonisolated var inboxStatePath: URL {
        root
            .appendingPathComponent("triggers", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
    }
    public nonisolated var workshopExecutionStatePath: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
    }

    /// The shared activity feed every fire writes its receipt into.
    public nonisolated var activityFeedPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    /// Max triggers the due-work pass may fire in a single pass. A liveness
    /// backstop (NOT a policy gate): if a config edit or clock jump makes many
    /// triggers due at once, we fire at most this many and log loudly; the
    /// remainder stay due and request one coalesced continuation (their state
    /// isn't advanced, so no occurrence is lost).
    static let periodicFireCapPerTick = 3

    internal static let logger = Logger(subsystem: "com.nativeagent.core", category: "trigger-scheduler")

    // MARK: list

    public func listInboxTriggers() async throws -> [TriggerConfig] {
        return try await Self._readList(path: inboxPath, defaultValue: try await defaults().inbox)
    }

    public func listWorkshopTriggers() async throws -> [TriggerConfig] {
        try await Self._readList(path: workshopExecutionsPath, defaultValue: try await defaults().workshop)
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
                throw TriggerSchedulerError.persistenceFailure("\(path.path) row \(index) is not a supported time trigger with Boolean enabled and a valid clock; bytes preserved.")
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

    /// Submit the saved trigger through Workshop; missing rows/objectives and submission failures retain their result envelopes.
    public func fireWorkshopTrigger(name: String) async throws -> TriggerFireResult {
        let seed: [JSONValue] = if case .missing = Self.readConfigsRaw(workshopExecutionsPath) { try await defaults().workshop } else { [] }
        return try await fireWorkshopTrigger(name: name, occurrence: nil, seed: seed)
    }

    internal func fireWorkshopTrigger(name: String, occurrence: String?, seed: [JSONValue]) async throws -> TriggerFireResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }

        // Read the persisted Workshop execution triggers list.
        let configs: [TriggerConfig]
        do {
            configs = try await Self._readList(
                path: workshopExecutionsPath,
                defaultValue: seed
            )
        } catch {
            return TriggerFireResult(status: "error", name: name,
                                     error: String(describing: error))
        }
        guard let row = configs.first(where: { ExecutionEventVocabulary.matches($0.name, name) }) else {
            return TriggerFireResult(status: "not_found", name: name)
        }

        // Saved title/objective default empty and trust_required defaults send_approval; explicit strings, including empty, stay verbatim.
        var title: String = ""
        var objective: String = ""
        var trustRequired: String = "send_approval"
        if case .object(let m)? = row.extras {
            if case .string(let s) = m["title"] ?? .null { title = s }
            if case .string(let s) = m["objective"] ?? .null { objective = s }
            if case .string(let s) = m["trust_required"] ?? .null { trustRequired = s }
        }

        // Empty objectives return the named error envelope.
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return TriggerFireResult(status: "error", name: name, error: "missing_objective")
        }

        let spec = WorkshopExecutionSpec(
            title: title,
            objective: objective,
            triggerSource: "trigger:\(row.name)" + (occurrence.map { ":occurrence:" + $0 } ?? ""),
            trustRequired: trustRequired
        )

        do {
            let result = try await WorkshopDirectedTaskSubmitter(
                dataRoot: root,
                runner: workshopRunner
            ).submit(spec: spec, project: "Scheduled Workshop")
            return TriggerFireResult(
                status: "fired",
                name: name,
                executionId: result.executionId,
                deskHandle: result.deskItem.handle
            )
        } catch let err as WorkshopExecutionError {
            // errorDescription, not String(describing:) — this string is the
            // user/API surface for Workshop execution-trigger failures, and the typed
            // cases (forbidden, workshopExecutionsBusy, ...) carry actionable
            // messages there.
            return TriggerFireResult(status: "error", name: name, error: err.errorDescription ?? String(describing: err))
        } catch {
            return TriggerFireResult(status: "error", name: name, error: String(describing: error))
        }
    }

}
