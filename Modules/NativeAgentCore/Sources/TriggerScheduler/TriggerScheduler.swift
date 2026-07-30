import Foundation
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import WorkshopExecution

// CAVEAT — SUBSYSTEM #17 WAVE 4 + WAVE 12 + WAVE 21 (2026-06-01): FLAG-FLIPPABLE.
// Wave 4 closed both prereqs that made the list/enable/disable/configure
// surface flippable (daemon mtime-based lazy reload + flock symmetry on
// trigger config writes — see proactive_triggers.py `_maybe_reload` /
// `_save_config`, missions.py `_maybe_reload` / `_write_json`, plus
// the retired daemon paired with PersistenceCore+FileLock.swift).
//
// Wave 12 (2026-05-31) NARROWED the previously-permanent `/fire_now`
// carve-out — but kept it SPLIT between the inbox and missions sides.
// Wave 21 (2026-06-01) closes the mission side of the carve once
// SwiftNativeWorkshopRunner landed:
//
//   - Inbox fire_now with `stub=true` is now FULLY Swift-native. The five
//     CANONICAL trigger kinds (file_watch, idle, time/morning_brief,
//     mission_complete/mission_followup, session_pattern/stuck_pattern)
//     each have their stub branch ported byte-for-byte from
//     proactive_triggers.py `build_inbox_item(is_stub=True)`. A5.2
//     (2026-07-24): the built card lands in `notifications/inbox.jsonl`
//     via the app-side mirror seam; ProactiveInboxStore only runs the
//     active-duplicate check (the legacy `<root>/inbox/` silo is retired).
//     Unknown kinds
//     return `not_found` instead of falling through to a generic stub.
//   - Inbox fire_now with `stub=false` is not yet Swift-native. The non-stub
//     branches invoke codex / connector actions / mission-queue scans /
//     personality_runtime reads that are still being ported, so production
//     returns an explicit error envelope.
//   - Workshop fire_now is Swift-native. SwiftNativeTriggerScheduler resolves the
//     mission trigger row from
//     <root>/missions/triggers.json, builds the mission spec via the
//     ProactiveTrigger.build_mission() shape (title/objective/trigger_source/
//     trust_required — the retired daemon), and calls
//     SwiftNativeWorkshopRunner.submit() which writes timeline.jsonl FIRST
//     then mission.json natively (wave-21 inverted-write fix; see
//     WorkshopExecution.swift submit() ordering note).
//
// TriggerScheduler is the sole Swift owner for list/enable/disable/configure,
// the canonical stub-inbox fire path, and the Workshop fire_now path.

// MARK: - Errors

/// Errors raised by the trigger-scheduler subsystem. Mirrors the small set of
/// failure cases the daemon's two schedulers return (proactive_triggers.py
/// `ProactiveTriggerScheduler` and missions.py `TriggerScheduler`):
///   - notFound: no trigger with that name in the persisted config.
///   - invalidRequest: empty name / malformed payload.
///   - persistenceFailure: IO error reading/writing the trigger configs file.
///   - unavailable: legacy error case retained for API compatibility.
///   - underlying: pass-through for other subsystem errors.
public enum TriggerSchedulerError: Error, LocalizedError {
    case notFound(String)
    case invalidRequest(String)
    case persistenceFailure(String)
    case unavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): return "trigger not found: \(name)"
        case .invalidRequest(let msg): return "invalid request: \(msg)"
        case .persistenceFailure(let m): return "persistence failure: \(m)"
        case .unavailable: return "trigger scheduler unavailable"
        case .underlying(let m): return m
        }
    }
}

// MARK: - TriggerConfig
//
// The daemon writes a schema-LOOSE dict per trigger. Both schedulers share the
// SAME outer shape ({name, kind?, enabled, config, description?, ...}) but the
// inner `config` dict and the optional fields differ per kind. We carve a
// small set of typed fields (name/kind/enabled/description) and round-trip
// everything else through `extras` so a write never drops daemon-written keys.
//
// `extras` is JSONValue.object(...) when non-empty, nil otherwise — same
// shape used by ToolRegistry/MCPDispatcher records.

public struct TriggerConfig: Sendable, Equatable {
    // Required.
    public var name: String
    public var enabled: Bool

    // Optional typed fields. Absent → nil. Present → some(v).
    public var kind: String?
    public var description: String?

    // The trigger's own `config` dict — flexible bag of per-kind keys
    // (paths/hour/minute/idle_minutes/etc.). Always JSONValue.object(...)
    // when present, even if empty.
    public var config: JSONValue?

    /// Bag of unknown / non-typed top-level keys the daemon writes
    /// (e.g. `objective` / `title` / `trust_required` from missions triggers,
    /// `_legacy_morning_brief_migrated` from the inbox scheduler).
    /// Lossless on round-trip.
    public var extras: JSONValue?

    public init(
        name: String,
        enabled: Bool,
        kind: String? = nil,
        description: String? = nil,
        config: JSONValue? = nil,
        extras: JSONValue? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.description = description
        self.config = config
        self.extras = extras
    }
}

extension TriggerConfig {
    /// Typed keys this struct claims directly. Everything else round-trips via extras.
    static let typedKeys: Set<String> = ["name", "enabled", "kind", "description", "config"]

    public init?(json: JSONValue) {
        guard case .object(let obj) = json else { return nil }
        // name is required and must be non-empty.
        guard case .string(let nm) = obj["name"] ?? .null, !nm.isEmpty else { return nil }
        self.name = nm
        // enabled defaults to false to match Python: bool(item.get("enabled", False)).
        if case .bool(let b) = obj["enabled"] ?? .null {
            self.enabled = b
        } else {
            self.enabled = false
        }
        if case .string(let s) = obj["kind"] ?? .null { self.kind = s } else { self.kind = nil }
        if case .string(let s) = obj["description"] ?? .null { self.description = s } else { self.description = nil }
        if let v = obj["config"], case .object = v {
            self.config = v
        } else {
            self.config = nil
        }
        var extra: [String: JSONValue] = [:]
        for (k, v) in obj where !TriggerConfig.typedKeys.contains(k) {
            extra[k] = v
        }
        self.extras = extra.isEmpty ? nil : .object(extra)
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "name": .string(name),
            "enabled": .bool(enabled),
        ]
        if let kind { obj["kind"] = .string(kind) }
        if let description { obj["description"] = .string(description) }
        if let config { obj["config"] = config }
        if case .object(let extra)? = extras {
            for (k, v) in extra where !TriggerConfig.typedKeys.contains(k) {
                obj[k] = v
            }
        }
        return .object(obj)
    }
}

// MARK: - Result envelopes

/// Status envelope returned by enable/disable/configure. Mirrors the daemon's
/// `{name, enabled?, status, ...}` dict shape from both schedulers.
public struct TriggerStatus: Sendable, Equatable {
    public var name: String
    public var enabled: Bool?
    public var status: String     // "updated" | "not_found"
    public var config: JSONValue? // populated by configure()

    public init(name: String, enabled: Bool?, status: String, config: JSONValue? = nil) {
        self.name = name
        self.enabled = enabled
        self.status = status
        self.config = config
    }
}

/// Envelope returned by fire_now. Mirrors the inbox path ({status, name,
/// item_id, stub}) and the Workshop executions path ({status, mission_id}). Both fields
/// are optional because only one schedule populates each.
public struct TriggerFireResult: Sendable, Equatable {
    public var status: String           // "fired" | "not_found" | "error"
    public var name: String?
    public var itemId: String?          // inbox
    public var executionId: String?       // Workshop execution
    public var deskHandle: String?      // Workshop identity for scheduled work
    public var stub: Bool?              // inbox only
    public var error: String?
    /// The built inbox card, present ONLY when this fire created a NEW one.
    /// Nil when the fire was deduped against an active card (nothing new to
    /// surface) or when no card was built at all. Carried so the app-side fire
    /// sites can mirror it into the real notifications inbox, the way
    /// `TriggerNotification.item` already lets the notifier do (board M18).
    public var item: JSONValue?         // inbox only
    /// True when the injected notifier ran for this fire. The notifier ALREADY
    /// mirrors the card into notifications/inbox.jsonl, so an app-side mirror
    /// must happen only when this is false — otherwise the card double-writes.
    public var notified: Bool?          // inbox only

    public init(
        status: String,
        name: String? = nil,
        itemId: String? = nil,
        executionId: String? = nil,
        deskHandle: String? = nil,
        stub: Bool? = nil,
        error: String? = nil,
        item: JSONValue? = nil,
        notified: Bool? = nil
    ) {
        self.status = status
        self.name = name
        self.itemId = itemId
        self.executionId = executionId
        self.deskHandle = deskHandle
        self.stub = stub
        self.error = error
        self.item = item
        self.notified = notified
    }
}

// MARK: - Notifier seam
//
// `MobileNotificationDeliveryReceipt` / `MacSyncEngine` / `SwiftNativeAPNS` all
// live in `Sources/NativeAgentApp/`. TriggerScheduler is a NativeAgentCore
// target whose deps are ["PersistenceCore", "WorkshopExecution"] — it cannot import the
// app. So the push sender is an INJECTED CLOSURE, mirroring how
// `AppChatToolDispatcher` injects its own sender. The app binds it to
// `MacSyncEngine.shared.sendNotificationToPairedDevices` — the same call the
// DeskNotify loop already makes.

/// What a fired trigger asks the app to push. App-agnostic by construction.
public struct TriggerNotification: Sendable, Equatable {
    public let triggerName: String
    public let kind: String
    public let title: String
    public let body: String        // the item summary, truncated for a push
    public let screen: String      // "inbox"
    public let source: String      // "trigger:<name>"
    public let urgency: String     // severity-derived: important → "high"
    /// The FULL built inbox item + its scheduler-assigned id, so the app-side
    /// notifier can surface the exact card (severity/detail/actions intact,
    /// stable id for dedup/correlation) instead of rebuilding a lossy copy
    /// from the push-truncated fields (gpt-5.5 review MED, 2026-07-09).
    public let itemId: String
    public let item: JSONValue

    public init(
        triggerName: String, kind: String, title: String, body: String,
        screen: String, source: String, urgency: String,
        itemId: String = "", item: JSONValue = .null
    ) {
        self.triggerName = triggerName
        self.kind = kind
        self.title = title
        self.body = body
        self.screen = screen
        self.source = source
        self.urgency = urgency
        self.itemId = itemId
        self.item = item
    }
}

/// Returns the sender's delivery fields (the `receipt.deliveryFields()` object)
/// or `.null` on failure. NEVER throws — a failed push must not un-fire a
/// trigger, and it must not suppress the receipt event either.
public typealias TriggerNotifier = @Sendable (TriggerNotification) async -> JSONValue

// MARK: - Protocol

public protocol TriggerSchedulerClient: Sendable {
    // Inbox (proactive) triggers — backed by <root>/inbox/trigger_config.json
    func listInboxTriggers() async throws -> [TriggerConfig]
    func enableInboxTrigger(name: String) async throws -> TriggerStatus
    func disableInboxTrigger(name: String) async throws -> TriggerStatus
    func configureInboxTrigger(name: String, config: JSONValue) async throws -> TriggerStatus
    func fireInboxTrigger(name: String, isStub: Bool) async throws -> TriggerFireResult

    // Workshop triggers — backed by <root>/missions/triggers.json
    func listWorkshopTriggers() async throws -> [TriggerConfig]
    func enableWorkshopTrigger(name: String) async throws -> TriggerStatus
    func disableWorkshopTrigger(name: String) async throws -> TriggerStatus
    func fireWorkshopTrigger(name: String) async throws -> TriggerFireResult
}

// MARK: - SwiftNative impl

/// File-backed trigger scheduler client mirroring the persistence side of
/// the retired daemon::ProactiveTriggerScheduler and
/// the retired daemon::TriggerScheduler.
///
/// SCOPE NARROWING (WAVE 12 + WAVE 21) — Swift impl now covers fire_now end-to-end:
///   - fireInboxTrigger(isStub: true)  — FULLY native. Builds the per-kind
///     stub InboxItem (file_watch / idle / morning_brief / mission_followup /
///     stuck_pattern) byte-for-byte against proactive_triggers.py, dedups it
///     via ProactiveInboxStore against the live inbox, and lands the card in
///     notifications/inbox.jsonl through the app-side mirror seam (A5.2).
///   - fireInboxTrigger(isStub: false) — explicit unsupported envelope unless
///     a caller injects a compatibility fallback for tests.
///     Non-stub branches invoke codex / connectors / mission-queue scans /
///     personality_runtime reads — not Swift-native.
///   - fireMissionTrigger(name:) — native mission enqueue through
///     SwiftNativeWorkshopRunner.
///
/// STILL CARVED — Swift impl deliberately does NOT touch:
///   - The two scheduler background threads (start/stop/_loop/_check_all)
///     keep firing inside the daemon process. Swift only manages on-disk
///     state the daemon re-reads each tick.
///   - The auto-disable / consecutive-failure tracking is in-memory inside
///     the daemon's scheduler instances; Swift only touches persisted state.
///
/// Persistence file paths (must stay byte-equivalent to daemon):
///   - Inbox:    <root>/inbox/trigger_config.json
///   - Missions: <root>/missions/triggers.json
///
/// Both are JSON arrays of trigger dicts. Atomic write + cross-process flock
/// follow the ToolRegistry pattern so the daemon's writes can't race with the
/// Swift app's writes.
public actor SwiftNativeTriggerScheduler: TriggerSchedulerClient {
    let root: URL
    let persistence: any PersistenceCoreProtocol
    private let workshopRunner: any WorkshopRunnerClient
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> String
    let connectorActionIDs: Set<String>?
    /// Injected push sender. nil at every non-firing call site (list / enable /
    /// disable / configure never push). When a trigger resolves `notify: true`
    /// and this is nil, the fire still lands and the receipt event is written
    /// with `status: "warn"` — LOUD, never silently absent.
    let notifier: TriggerNotifier?
    /// Injection seam for `TriggerContentBuilder`'s worklog source, which lives
    /// OUTSIDE the data root (~/.claude/state/claude-worklog.jsonl). nil keeps
    /// the production default; tests point it at a temp file so a brief built
    /// under a bare temp root is genuinely empty. Same role as `now` / `uuid`.
    let worklogPath: URL?
    private var mutationTail: Task<Void, Never>? = nil

    /// `missionRunner` is the wave-21 mission-fire seam. Defaults to a
    /// SwiftNativeWorkshopRunner with the same `root`/`persistence`/`now`/
    /// `uuid` injection seams so persistence paths and timestamps line up
    /// with the trigger-scheduler's own writes. Tests pass a stub.
    /// `now` / `uuid` are injection seams for deterministic tests.
    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        workshopRunner: (any WorkshopRunnerClient)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        connectorActionIDs: Set<String>? = nil,
        notifier: TriggerNotifier? = nil,
        worklogPath: URL? = nil
    ) {
        let resolvedPersistence = persistence ?? SwiftNativePersistenceCore()
        self.root = root
        self.persistence = resolvedPersistence
        self.workshopRunner = workshopRunner ?? SwiftNativeWorkshopRunner(
            root: root,
            persistence: resolvedPersistence,
            now: now,
            uuid: uuid
        )
        self.now = now
        self.uuid = uuid
        self.connectorActionIDs = connectorActionIDs
        self.notifier = notifier
        self.worklogPath = worklogPath
    }

    public nonisolated var inboxPath: URL {
        root
            .appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent("trigger_config.json")
    }

    public nonisolated var workshopExecutionsPath: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("triggers.json")
    }

    // MARK: periodic-fire liveness state (W3c)
    //
    // Per-surface `{ "<trigger name>": { "last_fired_at": "<iso8601>" } }` maps
    // that record when a trigger last SELF-fired on the periodic tick. These
    // are LIVENESS state, not config — kept in a sibling file so a write never
    // touches the daemon-shaped config array. Persisting them is what stops a
    // restart from re-firing a storm: after a crash+relaunch the scheduler
    // reads last_fired_at and sees a time trigger already fired today.
    // Inbox and mission trigger names can collide ("morning_brief" exists in
    // both surfaces), so each surface gets its own state file.
    public nonisolated var inboxStatePath: URL {
        root
            .appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
    }
    public nonisolated var workshopExecutionStatePath: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
    }

    /// The shared activity feed every fire writes its receipt into.
    public nonisolated var activityFeedPath: URL {
        root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// Max triggers the due-work pass may fire in a single pass. A liveness
    /// backstop (NOT a policy gate): if a config edit or clock jump makes many
    /// triggers due at once, we fire at most this many and log loudly; the
    /// remainder stay due and receive one legacy-cadence recovery deadline
    /// (their state isn't advanced, so no occurrence is lost).
    static let periodicFireCapPerTick = 3

    private static let logger = Logger(subsystem: "com.nativeagent.core", category: "trigger-scheduler")

    /// Test-only seam: returns the injected mission runner's planner type
    /// name when it's a `SwiftNativeWorkshopRunner`, else nil. Lets factory-
    /// level tests assert that the PRODUCTION trigger-factory wiring
    /// (`makeTriggerScheduler` → `makeWorkshopRunner`) hands in
    /// `HTTPCodexMissionPlannerLLM` instead of the `StubWorkshopPlannerLLM`
    /// default. See BLOCKING #1 of the wave-24-amendment. Mirrors the same-
    /// purpose seam on SwiftNativeWorkshopRunner in WorkshopExecution.swift.
    nonisolated var _testWorkshopRunnerPlannerTypeName: String? {
        (workshopRunner as? SwiftNativeWorkshopRunner)?._testPlannerTypeName
    }

    // MARK: list

    public func listInboxTriggers() async throws -> [TriggerConfig] {
        try await Self._readList(path: inboxPath, persistence: persistence, defaultValue: Self._defaultInboxConfigs)
    }

    public func listWorkshopTriggers() async throws -> [TriggerConfig] {
        try await Self._readList(path: workshopExecutionsPath, persistence: persistence, defaultValue: Self._defaultWorkshopExecutionConfigs)
    }

    private static func _readList(
        path: URL,
        persistence: any PersistenceCoreProtocol,
        defaultValue: [JSONValue]
    ) async throws -> [TriggerConfig] {
        // Match daemon list_configs / list_triggers_raw: read JSON; if absent
        // or not an array, return the per-scheduler default. Bad entries
        // inside the array are skipped (compactMap).
        let raw = await persistence.readJSON(path, defaultValue: .array(defaultValue))
        let items: [JSONValue]
        if case .array(let arr) = raw {
            items = arr
        } else {
            items = defaultValue
        }
        return items.compactMap(TriggerConfig.init(json:))
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
        return try await runSerialized { [persistence, inboxPath] in
            let work: @Sendable () async throws -> TriggerStatus = {
                try await Self._setEnabledImpl(
                    name: name, enabled: enabled,
                    path: inboxPath, defaultValue: Self._defaultInboxConfigs,
                    persistence: persistence
                )
            }
            if let p = persistence as? SwiftNativePersistenceCore {
                return try await p.withFileLock(inboxPath, work)
            }
            return try await work()
        }
    }

    // MARK: enable / disable — Workshop executions

    public func enableWorkshopTrigger(name: String) async throws -> TriggerStatus {
        try await _setEnabledWorkshopExecution(name: name, enabled: true)
    }

    public func disableWorkshopTrigger(name: String) async throws -> TriggerStatus {
        try await _setEnabledWorkshopExecution(name: name, enabled: false)
    }

    private func _setEnabledWorkshopExecution(name: String, enabled: Bool) async throws -> TriggerStatus {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }
        return try await runSerialized { [persistence, workshopExecutionsPath] in
            let work: @Sendable () async throws -> TriggerStatus = {
                try await Self._setEnabledImpl(
                    name: name, enabled: enabled,
                    path: workshopExecutionsPath, defaultValue: Self._defaultWorkshopExecutionConfigs,
                    persistence: persistence
                )
            }
            if let p = persistence as? SwiftNativePersistenceCore {
                return try await p.withFileLock(workshopExecutionsPath, work)
            }
            return try await work()
        }
    }

    /// Mirrors daemon proactive_triggers.set_enabled + missions.set_enabled:
    ///   - load list (with defaults if missing)
    ///   - flip enabled on matching name; not_found if no match
    ///   - persist + return status envelope
    /// Both Python paths return {"name", "enabled", "status"} where status is
    /// "updated" on hit and "not_found" on miss. Inbox path returns an error
    /// envelope ({"error": "not_found", "name": ...}); we normalize to the
    /// "not_found" status string for uniform handling — InboxSettingsView
    /// already swallows the error dict path.
    private static func _setEnabledImpl(
        name: String,
        enabled: Bool,
        path: URL,
        defaultValue: [JSONValue],
        persistence: any PersistenceCoreProtocol
    ) async throws -> TriggerStatus {
        // M4 (2026-07-09): this used to resurrect defaults on a corrupt file
        // "for daemon parity" — and then WRITE them back, permanently destroying
        // the user's triggers. There is no daemon to be in parity with. Corrupt
        // now quarantines the bytes and throws.
        var items: [JSONValue] = try Self.loadConfigsForMutation(path: path, defaultValue: defaultValue)
        var found = false
        for (idx, item) in items.enumerated() {
            guard case .object(var obj) = item,
                  case .string(let nm) = obj["name"] ?? .null,
                  nm == name else { continue }
            obj["enabled"] = .bool(enabled)
            items[idx] = .object(obj)
            found = true
            break
        }
        if !found {
            return TriggerStatus(name: name, enabled: enabled, status: "not_found")
        }
        do {
            try await persistence.writeJSON(.array(items), to: path)
        } catch {
            throw TriggerSchedulerError.persistenceFailure(String(describing: error))
        }
        return TriggerStatus(name: name, enabled: enabled, status: "updated")
    }

    // MARK: configure — inbox

    /// Mirrors daemon proactive_triggers.update_config: shallow-merge the new
    /// config dict into the existing trigger's `config` dict. Returns
    /// {"name", "status": "updated", "config": <new_config>} on hit,
    /// or {"status": "not_found"} on miss (mirrors the daemon's
    /// "{"error":"not_found", "name": name}" failure envelope, normalized).
    public func configureInboxTrigger(name: String, config: JSONValue) async throws -> TriggerStatus {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }
        // Accept .object only — daemon does `dict(c.get("config") or {});
        // existing.update(new_config)` which requires a dict.
        guard case .object(let newCfg) = config else {
            throw TriggerSchedulerError.invalidRequest("config must be a JSON object")
        }
        return try await runSerialized { [persistence, inboxPath] in
            let work: @Sendable () async throws -> TriggerStatus = {
                // M4: same read-then-write destruction as _setEnabledImpl — a
                // corrupt file yielded the default array, whose rows then got
                // merged and written over the user's config.
                var items: [JSONValue] = try Self.loadConfigsForMutation(
                    path: inboxPath, defaultValue: Self._defaultInboxConfigs
                )
                var found = false
                for (idx, item) in items.enumerated() {
                    guard case .object(var obj) = item,
                          case .string(let nm) = obj["name"] ?? .null,
                          nm == name else { continue }
                    var existing: [String: JSONValue] = [:]
                    if case .object(let cur) = obj["config"] ?? .null { existing = cur }
                    // Python: existing.update(new_config) — shallow merge.
                    for (k, v) in newCfg { existing[k] = v }
                    obj["config"] = .object(existing)
                    items[idx] = .object(obj)
                    found = true
                    break
                }
                if !found {
                    return TriggerStatus(name: name, enabled: nil, status: "not_found", config: .object(newCfg))
                }
                do {
                    try await persistence.writeJSON(.array(items), to: inboxPath)
                } catch {
                    throw TriggerSchedulerError.persistenceFailure(String(describing: error))
                }
                return TriggerStatus(name: name, enabled: nil, status: "updated", config: .object(newCfg))
            }
            if let p = persistence as? SwiftNativePersistenceCore {
                return try await p.withFileLock(inboxPath, work)
            }
            return try await work()
        }
    }

    // MARK: fire_now — Swift-native

    /// Mirrors daemon proactive_triggers.py::ProactiveTriggerScheduler.fire_now.
    /// - isStub=true  → builds the per-kind stub InboxItem natively + surfaces
    ///   it via ProactiveInboxStore. Returns {status:"fired", name, item_id, stub:true}.
    /// - isStub=false → explicit error envelope because the non-stub
    ///   `build_inbox_item` branches invoke codex/connectors/runtime reads
    ///   that are not Swift-native yet.
    /// - name not found → {status:"not_found", name, stub:isStub}.
    /// - any Swift-side throw (stub path) → {status:"error", name, stub, error}.
    public func fireInboxTrigger(name: String, isStub: Bool) async throws -> TriggerFireResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }

        // Look up the trigger row.
        let configs: [TriggerConfig]
        do {
            configs = try await Self._readList(
                path: inboxPath, persistence: persistence,
                defaultValue: Self._defaultInboxConfigs
            )
        } catch {
            return TriggerFireResult(status: "error", name: name, stub: isStub,
                                     error: String(describing: error))
        }
        guard let row = configs.first(where: { $0.name == name }) else {
            return TriggerFireResult(status: "not_found", name: name, stub: isStub)
        }

        // Non-stub needs codex/connectors/runtime-state branches that have not
        // been ported.
        if !isStub {
            return TriggerFireResult(
                status: "error",
                name: name,
                stub: false,
                error: "non-stub inbox trigger firing is not yet Swift-native"
            )
        }

        // Canonical-kind guard: unknown kinds return not_found (matches Python
        // which would have no per-kind trigger class to fire). Don't fall
        // through to a generic stub.
        let canonicalKinds: Set<String> = ["file_watch", "idle", "time", "mission_complete", "session_pattern"]
        guard let rowKind = row.kind, canonicalKinds.contains(rowKind) else {
            return TriggerFireResult(status: "not_found", name: name, stub: true)
        }

        // Swift-native fire path. `morning_brief` (time) and `idle_checkin`
        // (idle) now carry REAL content; the other three are still declared
        // placeholders (see `_buildInboxItem`).
        do {
            let built = try await _buildInboxItem(kind: rowKind, row: row, name: name)
            let store = ProactiveInboxStore(
                root: root,
                persistence: persistence
            )
            let id = try await store.surface(built.item)

            // `surface` SUPPRESSES an active duplicate (same source+title+summary,
            // still unread/read, within 7 days) and hands back the EXISTING id
            // instead of appending. When that happens no new card appeared, so
            // pushing would notify User about something already sitting in his
            // inbox. Detect it by identity: the id we minted vs the id we got.
            let deduped = (id != Self.itemId(of: built.item))

            // NOTIFY + RECEIPT: ONE uninterrupted await chain. The push may be
            // suppressed by config or by dedupe; the receipt NEVER is. A fire
            // that leaves no trace is the blind-quiet failure this whole path
            // exists to avoid.
            var notified = false
            var delivery: JSONValue = .null
            var status = "ok"
            var detail = "trigger '\(name)' fired — inbox item \(id)"

            if deduped {
                detail += "; suppressed as a duplicate of an active inbox item — no push"
            } else if Self.resolveNotify(row) {
                if let notifier {
                    delivery = await notifier(Self.notification(for: built.item, name: name, kind: rowKind))
                    // `notified` tracks the notifier's RETURN, not its invocation
                    // (gpt-5.5 review, 2026-07-09): a `.null` return means the
                    // sender handled NOTHING — for the app notifier, the real-inbox
                    // card write itself failed and the push was suppressed. Leaving
                    // notified=false lets the app-side fire sites retry the mirror
                    // instead of treating the card as delivered and losing it. A
                    // partial outcome (card landed, push failed) returns a non-null
                    // delivery object so it still counts as notified — mirroring it
                    // again would double-write the card.
                    notified = delivery != .null
                    if delivery == .null {
                        // The sender reported failure. Say so on the record
                        // rather than logging "ok".
                        status = "warn"
                        detail += "; notifier reported FAILURE — nothing delivered; fire-site mirror may retry"
                    } else if case .object(let d) = delivery, d["delivered"] == .bool(false) {
                        // Partial: the sender landed the card but the push send
                        // failed. notified stays true (mirroring again would
                        // double-write) but the record must not read "ok".
                        status = "warn"
                        detail += "; card landed but the push send FAILED"
                    } else {
                        detail += "; push dispatched to paired devices"
                    }
                } else {
                    Self.logger.error("trigger '\(name, privacy: .public)' resolved notify=true but NO notifier was injected into this scheduler — the inbox item landed, the push did NOT")
                    status = "warn"
                    detail += "; notify requested but no notifier wired — push NOT dispatched"
                }
            } else {
                detail += "; notify disabled for this trigger — no push"
            }

            await appendTriggerEvent(
                item: built.item, itemId: id, name: name, kind: rowKind,
                notified: notified, placeholder: built.isPlaceholder, deduped: deduped,
                delivery: delivery, status: status, detail: detail
            )

            // Hand the caller the built card + whether the notifier already
            // mirrored it, so a non-notified fire can still reach the real
            // inbox app-side. Deduped fires carry no item: the card they'd
            // mirror is the one already sitting in the inbox (board M18).
            return TriggerFireResult(
                status: "fired", name: name, itemId: id, stub: built.isPlaceholder,
                item: deduped ? nil : built.item, notified: notified
            )
        } catch {
            return TriggerFireResult(status: "error", name: name, stub: isStub,
                                     error: String(describing: error))
        }
    }

    // MARK: notify resolution

    /// Per-name fallback used when a trigger's `config` carries no `notify` key.
    /// LOAD-BEARING: `_defaultInboxConfigs` seeding alone only reaches FRESH
    /// installs — every existing user already has `inbox/trigger_config.json`
    /// on disk and would never see a push. Seed the defaults AND keep this
    /// table. Both, not either.
    nonisolated static let notifyDefaultsByName: [String: Bool] = [
        "morning_brief": true,
    ]

    /// 1. `config.notify` when present and a bool. 2. else the per-name table.
    /// 3. else false — a trigger nobody opted in stays quiet.
    nonisolated static func resolveNotify(_ cfg: TriggerConfig) -> Bool {
        if case .object(let o)? = cfg.config, case .bool(let b)? = o["notify"] {
            return b
        }
        return notifyDefaultsByName[cfg.name] ?? false
    }

    private nonisolated static func itemId(of item: JSONValue) -> String? {
        guard case .object(let o) = item, case .string(let s)? = o["id"] else { return nil }
        return s
    }

    private nonisolated static func notification(
        for item: JSONValue, name: String, kind: String
    ) -> TriggerNotification {
        var title = name
        var summary = ""
        var severity = "info"
        if case .object(let o) = item {
            if case .string(let s)? = o["title"] { title = s }
            if case .string(let s)? = o["summary"] { summary = s }
            if case .string(let s)? = o["severity"] { severity = s }
        }
        // A push body is a glance, not a document.
        let body = summary.count > 240 ? String(summary.prefix(239)) + "…" : summary
        var itemId = ""
        if case .object(let o) = item, case .string(let s)? = o["id"] { itemId = s }
        return TriggerNotification(
            triggerName: name,
            kind: kind,
            title: title,
            body: body,
            screen: "inbox",
            source: "trigger:\(name)",
            urgency: severity == "important" ? "high" : "normal",
            itemId: itemId,
            item: item
        )
    }

    /// The delivery receipt. Written on EVERY fire — `notified: false` when the
    /// push was suppressed, `status: "warn"` when it was requested but
    /// unwireable. Matches the activity envelope
    /// (`PersonaEngine.makePersonaActivityEvent`):
    /// `{id, kind, title, detail, status, missionId, payload, createdAt}`.
    /// Best-effort: a failed receipt write is logged, never thrown — the item
    /// already landed and un-firing it would be worse.
    private func appendTriggerEvent(
        item: JSONValue, itemId: String, name: String, kind: String,
        notified: Bool, placeholder: Bool, deduped: Bool, delivery: JSONValue,
        status: String, detail: String
    ) async {
        var title = name
        if case .object(let o) = item, case .string(let s)? = o["title"] { title = s }

        var payload: [String: JSONValue] = [
            "triggerName": .string(name),
            "triggerKind": .string(kind),
            "itemId": .string(itemId),
            "notified": .bool(notified),
            "placeholder": .bool(placeholder),
        ]
        if deduped { payload["deduped"] = .bool(true) }
        if delivery != .null { payload["delivery"] = delivery }

        let event: JSONValue = .object([
            "id": .string(uuid()),
            "kind": .string("trigger"),
            "title": .string(title),
            "detail": .string(detail),
            "status": .string(status),
            "missionId": .null,
            "payload": .object(payload),
            "createdAt": .string(Self.isoTimestamp(now())),
        ])
        do {
            try await appendJSONLCapped(
                event, to: activityFeedPath, using: persistence,
                logLabel: "TriggerScheduler"
            )
        } catch {
            Self.logger.error("trigger '\(name, privacy: .public)' fired but its activity receipt FAILED to write: \(String(describing: error), privacy: .public)")
        }
    }

    /// Wave 21: Swift-native mission fire. Resolves the trigger row, builds the
    /// mission spec via the ProactiveTrigger.build_mission() shape (missions.py
    /// L1821-L1827 — title/objective/trigger_source/trust_required), and calls
    /// SwiftNativeWorkshopRunner.submit(). Mirrors the Python TriggerScheduler.fire_now
    /// failure envelopes: not_found, missing_objective, and any WorkshopExecutionError
    /// throw maps to {status:"error", name, error:<description>}.
    public func fireWorkshopTrigger(name: String) async throws -> TriggerFireResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }

        // Read the persisted Workshop execution triggers list.
        let configs: [TriggerConfig]
        do {
            configs = try await Self._readList(
                path: workshopExecutionsPath, persistence: persistence,
                defaultValue: Self._defaultWorkshopExecutionConfigs
            )
        } catch {
            return TriggerFireResult(status: "error", name: name,
                                     error: String(describing: error))
        }
        guard let row = configs.first(where: { $0.name == name }) else {
            return TriggerFireResult(status: "not_found", name: name)
        }

        // Build the mission spec from the row, mirroring
        // ProactiveTrigger.build_mission. Extras
        // carry title/objective/trust_required as top-level keys on the row.
        // FIX #5 (wave 21 review): mirror Python defaults exactly.
        // - title:           str(item.get("title", ""))           → "" when missing
        // - objective:       str(item.get("objective", ""))       → "" when missing
        // - trust_required:  str(item.get("trust_required", "send_approval"))
        //                    Python keeps an explicit "" verbatim — only missing
        //                    falls back to "send_approval". Mirror that: take any
        //                    string value (even ""), only default when absent/non-string.
        var title: String = ""
        var objective: String = ""
        var trustRequired: String = "send_approval"
        if case .object(let m)? = row.extras {
            if case .string(let s) = m["title"] ?? .null { title = s }
            if case .string(let s) = m["objective"] ?? .null { objective = s }
            if case .string(let s) = m["trust_required"] ?? .null { trustRequired = s }
        }

        // The daemon's MissionRunner.submit raises missing_objective when the
        // trimmed objective is empty. Mirror that as
        // an error envelope rather than letting the throw bubble out.
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return TriggerFireResult(status: "error", name: name, error: "missing_objective")
        }

        let spec = WorkshopExecutionSpec(
            title: title,
            objective: objective,
            triggerSource: "trigger:\(row.name)",
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
            // cases (executorUnavailable, forbidden, ...) carry actionable
            // messages there.
            return TriggerFireResult(status: "error", name: name, error: err.errorDescription ?? String(describing: err))
        } catch {
            return TriggerFireResult(status: "error", name: name, error: String(describing: error))
        }
    }

    // MARK: evaluate-and-fire

    /// Evaluate every persisted trigger and fire each enabled one through the
    /// matching Swift-native fire path. Returns the names of triggers that
    /// actually fired (status == "fired"). Mirrors what the daemon's
    /// `_proactive_triggers_loop` does on each periodic tick: enumerate, gate
    /// on `enabled`, and dispatch. Disabled triggers, unknown kinds, and
    /// missing-objective mission triggers are skipped without being reported as
    /// fired. Inbox triggers fire as stubs (the only fully Swift-native path).
    /// Errors from a single trigger do not block evaluation of the others.
    /// Names of the triggers this tick fired. Thin wrapper over
    /// `evaluateAndFireDetailed()` for callers that only need the names.
    public func evaluateAndFire() async -> [String] {
        await evaluateAndFireDetailed().compactMap(\.name)
    }

    /// The full fire envelopes for this tick, in fire order. The periodic tick
    /// site needs these (not just the names) so it can mirror the card of any
    /// NON-notified inbox fire into the real notifications inbox — a notified
    /// fire is already mirrored by the injected notifier (board M18).
    public func evaluateAndFireDetailed() async -> [TriggerFireResult] {
        var fired: [TriggerFireResult] = []
        var deferredDueToCap = false

        // AUDIT 2026-06-09 (live regression, shipped 2026-06-03 as "PATCH T2"):
        // this used to fire EVERY enabled trigger on EVERY 60s tick, storming
        // the inbox with content-free stubs. W3c (2026-07-01) LIGHTS the
        // periodic path honestly: the tick fires ONLY triggers whose per-kind
        // condition approves (`scheduledInstantIfDue`). Today that is the `time`
        // kind (hour/minute reached + not-already-fired-for-this-occurrence).
        // idle / file_watch / mission_complete / session_pattern stay dark —
        // see the note on `scheduledInstantIfDue` for why each is not yet a
        // self-firing condition.
        //
        // ATOMIC CLAIM (W3c review Finding 1, 2026-07-01): dueness and the
        // "I fired this occurrence" stamp are NOT separate steps. Two
        // overlapping scheduler instances that both read a stale last_fired_at
        // would BOTH fire (duplicate morning_brief). `claimIfDue` folds the
        // re-read + re-evaluate + stamp into ONE locked read-modify-write under
        // the state-file flock, stamping `last_fired_at = the SCHEDULED INSTANT`
        // (not now() — which also closes the clock-backwards refire hazard,
        // Finding 3). We fire ONLY after winning the claim. This is
        // deliberately AT-MOST-ONCE: a fire that fails AFTER a successful claim
        // is logged loudly and NOT retried and NOT un-claimed — the trigger
        // waits for its next scheduled occurrence. A duplicate brief is worse
        // than a rare missed one.
        //
        // Corrupt-state fail-safe (Finding 2): a missing state file is a
        // legitimately-never-fired fresh install (stays eligible). An EXISTING
        // non-empty file that won't parse to a JSON object is treated as
        // corrupt — every trigger on that surface goes DORMANT with one loud
        // log per pass, never "never fired" (which would fire-storm).
        //
        // Safety rails (liveness, not policy): a per-tick fire cap and dormant
        // behaviour for any trigger whose schedule doesn't parse. Firing still
        // routes through the SAME gated fire paths a manual fire uses — approval
        // and policy posture are unchanged.
        if let inbox = try? await listInboxTriggers() {
            if case .corrupt = Self.readStateRaw(inboxStatePath) {
                Self.logger.error("inbox trigger_state.json is corrupt (exists, non-empty, not a JSON object) — all inbox time triggers DORMANT this pass until repaired")
            } else {
                for cfg in inbox where cfg.enabled {
                    guard scheduledInstantIfDue(cfg) != nil else { continue }
                    if fired.count >= Self.periodicFireCapPerTick { deferredDueToCap = true; break }
                    guard await claimIfDue(cfg, statePath: inboxStatePath) else { continue }
                    // Claimed — the occurrence is stamped. AT-MOST-ONCE from here:
                    // a failed/throwing fire is NOT un-claimed and NOT retried.
                    do {
                        let res = try await fireInboxTrigger(name: cfg.name, isStub: true)
                        if res.status == "fired" {
                            fired.append(res)
                        } else {
                            Self.logger.error("inbox trigger '\(cfg.name, privacy: .public)' CLAIMED but fire returned status '\(res.status, privacy: .public)' — NOT retried (at-most-once); waits for next scheduled occurrence")
                        }
                    } catch {
                        Self.logger.error("inbox trigger '\(cfg.name, privacy: .public)' CLAIMED but fire threw: \(String(describing: error), privacy: .public) — NOT retried (at-most-once); waits for next scheduled occurrence")
                    }
                }
            }
        }
        if let executions = try? await listWorkshopTriggers() {
            if case .corrupt = Self.readStateRaw(workshopExecutionStatePath) {
                Self.logger.error("Workshop trigger_state.json is corrupt (exists, non-empty, not a JSON object) — all Workshop time triggers DORMANT this pass until repaired")
            } else {
                for cfg in executions where cfg.enabled {
                    guard scheduledInstantIfDue(cfg) != nil else { continue }
                    if fired.count >= Self.periodicFireCapPerTick { deferredDueToCap = true; break }
                    guard await claimIfDue(cfg, statePath: workshopExecutionStatePath) else { continue }
                    do {
                        let res = try await fireWorkshopTrigger(name: cfg.name)
                        if res.status == "fired" {
                            fired.append(res)
                        } else {
                            Self.logger.error("Workshop trigger '\(cfg.name, privacy: .public)' CLAIMED but fire returned status '\(res.status, privacy: .public)' — NOT retried (at-most-once); waits for next scheduled occurrence")
                        }
                    } catch {
                        Self.logger.error("Workshop trigger '\(cfg.name, privacy: .public)' CLAIMED but fire threw: \(String(describing: error), privacy: .public) — NOT retried (at-most-once); waits for next scheduled occurrence")
                    }
                }
            }
        }
        if deferredDueToCap {
            Self.logger.error(
                "periodic trigger fire cap (\(Self.periodicFireCapPerTick, privacy: .public)) hit this tick — fired \(fired.count, privacy: .public), remaining due triggers deferred to next tick"
            )
        }
        return fired
    }

    /// Earliest clock crossing for an enabled, self-firing trigger. This is a
    /// read-only scheduling projection over canonical config, liveness state,
    /// and (for idle triggers) the persisted chat activity signal. It never
    /// claims or fires an occurrence.
    ///
    /// Future time/idle instants remain exact. An already-due unclaimed
    /// occurrence receives one 60-second recovery crossing, preserving the old
    /// retry cadence only while due work remains after a capped or failed pass.
    /// A claimed idle episode has no next clock crossing until chat activity
    /// changes; the app-owned file invalidation supplies that edge.
    public func nextMeaningfulDeadline(after reference: Date) async -> Date? {
        var candidates: [Date] = []
        if let inbox = try? await listInboxTriggers() {
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
            let lastFired = Self.lastFiredFromState(state, name: cfg.name)
            switch cfg.kind {
            case "time":
                guard let hour = Self.intField(cfg.config, "hour"), (0...23).contains(hour)
                else { return nil }
                let minute: Int
                if case .object(let obj)? = cfg.config, obj["minute"] != nil {
                    guard let parsed = Self.intField(cfg.config, "minute") else { return nil }
                    minute = parsed
                } else {
                    minute = 0
                }
                guard (0...59).contains(minute),
                      let today = Self.scheduledInstantToday(
                        hour: hour,
                        minute: minute,
                        on: reference
                      ) else { return nil }
                if let lastFired, lastFired >= today {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone.current
                    var components = DateComponents()
                    components.hour = hour
                    components.minute = minute
                    components.second = 0
                    return calendar.nextDate(
                        after: max(reference, lastFired),
                        matching: components,
                        matchingPolicy: .nextTime,
                        repeatedTimePolicy: .first,
                        direction: .forward
                    )
                }
                if today > reference { return today }
                return reference.addingTimeInterval(60)
            case "idle":
                guard let minutes = Self.intField(cfg.config, "idle_minutes"), minutes > 0,
                      let lastActivity = TriggerContentBuilder.lastActivityInstant(root: root)
                else { return nil }
                let scheduled = lastActivity.addingTimeInterval(TimeInterval(minutes) * 60)
                if let start = Self.intField(cfg.config, "quiet_start_hour"),
                   let end = Self.intField(cfg.config, "quiet_end_hour"),
                   Self.inQuietHours(scheduled, startHour: start, endHour: end) {
                    return nil
                }
                if scheduled > reference { return scheduled }
                if let lastFired, lastFired >= scheduled { return nil }
                return reference.addingTimeInterval(60)
            default:
                return nil
            }
        }
    }

    /// The SCHEDULED INSTANT this trigger is currently eligible to fire at, or
    /// nil if it is not clock-due (or its schedule doesn't parse). This is the
    /// PURE, clock-only half of dueness — it does NOT read `last_fired_at`; the
    /// "have we already fired this occurrence" check is folded into the atomic
    /// `claimIfDue` under the state-file flock so a check-then-fire race can't
    /// double-fire (Finding 1). W3c lights the kinds whose condition is
    /// self-contained (checkable from the clock + config alone) and whose fire
    /// path delivers real capability:
    ///
    ///   - `time` — LIT. Eligible when the local clock has reached the
    ///     configured hour:minute; returns that scheduled instant. Powers the
    ///     daily mission `morning_brief` enqueue and the daily inbox brief. A
    ///     missing / out-of-range / fractional hour makes the trigger DORMANT
    ///     (returns nil), never a crash.
    ///
    ///   - `idle` — LIT (2026-07-09). The activity signal the old note said was
    ///     missing now exists: `max(updatedAt)` over `<root>/chat/sessions.json`
    ///     (`TriggerContentBuilder.lastActivityInstant`). Eligible when
    ///     `lastActivity + idle_minutes` has passed and that instant does NOT
    ///     fall inside the configured quiet hours. Returning the EPISODE INSTANT
    ///     (not now()) is what makes `claimIfDue` re-arm for free: it stamps
    ///     `last_fired_at = scheduled` and refuses to refire while
    ///     `last >= scheduled`, so one fire per idle episode — and a new user
    ///     message advances lastActivity, which advances the next episode's
    ///     instant, which un-holds the claim. No activity signal ⇒ still dark.
    ///
    /// The remaining kinds stay DARK, each for an honest reason — NOT laziness:
    ///
    ///   - `file_watch` — a cheap mtime check on `config.paths` IS possible,
    ///     but the Swift-native fire path only emits a content-free STUB ("file
    ///     watcher trigger is wired"); the real changed-file summary lives in
    ///     the non-stub branch that isn't Swift-native yet (see
    ///     fireInboxTrigger isStub:false). Self-firing a stub on every save is
    ///     noise, not the advertised capability. Light this once the non-stub
    ///     diff path lands.
    ///   - `mission_complete` — needs to detect an ACTUAL newly-completed
    ///     mission; the config is empty and no completion cursor is tracked
    ///     here, and the fire path is a placeholder "Stub Mission".
    ///   - `session_pattern` — needs live conversation-register state
    ///     (`min_turns_in_register`) that the scheduler cannot see.
    ///
    /// When a dark kind's real condition lands, add its case here.
    ///
    /// `nonisolated` so `claimIfDue`'s locked RMW body (a `@Sendable` closure)
    /// can recompute it INSIDE the flock — it touches only the immutable
    /// Sendable `now` closure + static helpers, no actor state.
    private nonisolated func scheduledInstantIfDue(_ cfg: TriggerConfig) -> Date? {
        switch cfg.kind {
        case "time":
            // Schedule must parse to a valid hour (0...23); an unparseable /
            // absent / fractional schedule keeps the trigger dormant rather
            // than firing at an arbitrary time.
            guard let hour = Self.intField(cfg.config, "hour"), (0...23).contains(hour) else {
                return nil
            }
            // minute: ABSENT → default 0 (many configs specify only an hour).
            // But a PRESENT-but-invalid minute (fractional like 8.9, a string,
            // etc.) must make the trigger DORMANT — same rule as an invalid
            // hour (Finding 4). Silently snapping `minute: 8.9` to :00 would
            // fire at the wrong time, which is exactly the truncation bug.
            let minute: Int
            if case .object(let cfgObj)? = cfg.config, cfgObj["minute"] != nil {
                guard let m = Self.intField(cfg.config, "minute") else { return nil }
                minute = m
            } else {
                minute = 0
            }
            guard (0...59).contains(minute) else { return nil }

            let current = now()
            guard let scheduled = Self.scheduledInstantToday(hour: hour, minute: minute, on: current),
                  current >= scheduled else {
                return nil
            }
            return scheduled
        case "idle":
            // A non-positive / unparseable idle_minutes keeps the trigger
            // DORMANT rather than firing on every tick.
            guard let minutes = Self.intField(cfg.config, "idle_minutes"), minutes > 0 else {
                return nil
            }
            // No persisted activity signal ⇒ idleness is unknowable ⇒ stay dark.
            guard let last = TriggerContentBuilder.lastActivityInstant(root: root) else {
                return nil
            }
            let scheduled = last.addingTimeInterval(TimeInterval(minutes) * 60)
            guard now() >= scheduled else { return nil }
            // Quiet hours suppress the EPISODE, not the tick: an episode whose
            // instant lands at 02:00 never fires, and never accumulates either
            // (the claim isn't stamped, so a later episode is still eligible).
            if let start = Self.intField(cfg.config, "quiet_start_hour"),
               let end = Self.intField(cfg.config, "quiet_end_hour"),
               Self.inQuietHours(scheduled, startHour: start, endHour: end) {
                return nil
            }
            return scheduled
        default:
            return nil
        }
    }

    /// Local-wall-clock quiet-hours test. Wraps midnight when `startHour >
    /// endHour` (the default 23→08). Out-of-range or equal bounds mean "no
    /// quiet hours configured" rather than "always quiet" — a misconfiguration
    /// must not silence a trigger forever.
    static func inQuietHours(_ date: Date, startHour: Int, endHour: Int) -> Bool {
        guard (0...23).contains(startHour), (0...23).contains(endHour),
              startHour != endHour else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let h = cal.component(.hour, from: date)
        if startHour < endHour { return h >= startHour && h < endHour }
        return h >= startHour || h < endHour
    }

    // MARK: periodic-fire helpers (W3c)

    /// Classification of a per-surface `trigger_state.json` read, distinguishing
    /// the two "no last_fired_at" cases that MUST behave differently (Finding 2):
    ///   - `.missing` — file absent (or zero-length): a legitimately fresh
    ///     install. Triggers stay firing-eligible (never-fired).
    ///   - `.corrupt` — file EXISTS and is non-empty but does not parse to a
    ///     JSON object. Fail-safe: affected triggers go DORMANT, never treated
    ///     as never-fired (which would fire-storm). Callers log once per pass.
    ///   - `.parsed` — a well-formed `{ "<name>": { "last_fired_at": "..." } }`.
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

    /// Raw read of a trigger config file that distinguishes missing from corrupt.
    /// `persistence.readJSON` returns its `defaultValue` for BOTH an absent file
    /// and an unparseable one, so a mutation path that reads-then-writes would
    /// overwrite a corrupt (but recoverable) config with factory defaults,
    /// destroying every trigger the user configured (M4, 2026-07-09).
    nonisolated static func readConfigsRaw(_ path: URL) -> ConfigRead {
        guard FileManager.default.fileExists(atPath: path.path) else { return .missing }
        guard let data = try? Data(contentsOf: path) else { return .corrupt }
        // An EXISTING zero-byte file is a truncated write, not a fresh install
        // (gpt-5.5 review MED, 2026-07-09): treating it as .missing let the
        // reseed path write defaults over what used to be the user's config.
        // Quarantine-and-throw like any other corruption.
        if data.isEmpty { return .corrupt }
        guard case .array(let items)? = try? JSONValue.parse(data) else { return .corrupt }
        return .parsed(items)
    }

    /// Move a corrupt config file aside as `<name>.corrupt-<epoch>` so the bytes
    /// survive for recovery. Returns the new URL, or nil when the move failed.
    nonisolated static func quarantineCorruptConfig(_ path: URL) -> URL? {
        let stamp = String(Int(Date().timeIntervalSince1970))
        let aside = path.appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: path, to: aside)
            return aside
        } catch {
            logger.error("failed to quarantine corrupt trigger config \(path.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Corrupt-safe load of a trigger config array for a MUTATION (enable /
    /// disable / configure). Missing → defaults (a legitimately fresh install,
    /// where writing defaults is correct). Parsed → the user's rows. Corrupt →
    /// the bytes are moved aside and the mutation THROWS. The one thing this
    /// must never do is resurrect defaults on top of user data (M4).
    nonisolated static func loadConfigsForMutation(
        path: URL,
        defaultValue: [JSONValue]
    ) throws -> [JSONValue] {
        switch readConfigsRaw(path) {
        case .missing:
            return defaultValue
        case .parsed(let items):
            return items
        case .corrupt:
            let aside = quarantineCorruptConfig(path)
            let where_ = aside?.lastPathComponent ?? "<move failed — file left in place>"
            logger.error("corrupt trigger config \(path.lastPathComponent, privacy: .public) — moved aside to \(where_, privacy: .public); refusing to overwrite it with defaults")
            throw TriggerSchedulerError.persistenceFailure(
                "corrupt trigger config \(path.lastPathComponent): moved aside to \(where_). Triggers were NOT reset to defaults; restore the file or reconfigure."
            )
        }
    }

    /// Raw read of a state file that distinguishes missing from corrupt —
    /// `persistence.readJSON` collapses both to its default, which is exactly
    /// the fail-open bug Finding 2 closes. Reads bytes directly; writes are
    /// atomic (rename), so a reader never sees a torn intermediate.
    nonisolated static func readStateRaw(_ statePath: URL) -> StateRead {
        guard FileManager.default.fileExists(atPath: statePath.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: statePath) else {
            // Exists but unreadable — treat as corrupt (fail safe: don't fire).
            return .corrupt
        }
        if data.isEmpty { return .missing }
        guard case .object(let o)? = try? JSONValue.parse(data) else {
            // Non-empty but not a JSON object (garbage, or a JSON array/scalar).
            return .corrupt
        }
        return .parsed(o)
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

    /// Atomic CLAIM of a trigger's current scheduled occurrence (Finding 1).
    /// Under the state-file flock — the SAME cross-process lock the daemon uses
    /// — this re-reads state, re-evaluates dueness against the freshly-read
    /// `last_fired_at`, and if still due stamps `last_fired_at = the SCHEDULED
    /// INSTANT` (not now(); this also closes the clock-backwards refire hazard,
    /// Finding 3). Returns true IFF this caller won the claim and should fire.
    /// Two overlapping schedulers therefore serialize here: the first stamps
    /// and wins, the second re-reads the fresh stamp and loses. A corrupt state
    /// file makes the claim fail safe (returns false, no stamp). A persistence
    /// failure is logged and returns false — no fire, no torn state.
    private func claimIfDue(_ cfg: TriggerConfig, statePath: URL) async -> Bool {
        // Cheap unlocked PRE-GATE only — skip taking the lock when the trigger
        // isn't even clock-due. NOT the authoritative decision: the clock may
        // move (even backward, e.g. an NTP step) between here and lock
        // acquisition, so full dueness is RE-EVALUATED inside the lock below.
        guard scheduledInstantIfDue(cfg) != nil else { return false }
        let name = cfg.name

        let work: @Sendable () async throws -> Bool = { [self, persistence] in
            // Re-evaluate the FULL dueness INSIDE the lock (Finding 1: dueness
            // AND the fired-stamp are one atomic step). Recompute the scheduled
            // instant here — a clock rewind since the pre-gate could have made
            // `current >= scheduled` false, and trusting a value captured
            // outside the lock would fire before the scheduled time.
            guard let scheduled = self.scheduledInstantIfDue(cfg) else { return false }
            let stamp = Self.isoTimestamp(scheduled)
            var state: [String: JSONValue]
            switch Self.readStateRaw(statePath) {
            case .corrupt:
                return false                       // fail safe: dormant
            case .missing:
                state = [:]
            case .parsed(let o):
                state = o
            }
            // Re-check under the lock: another instance may have just claimed
            // this same occurrence.
            if let last = Self.lastFiredFromState(state, name: name), last >= scheduled {
                return false
            }
            // Win the claim: stamp THIS occurrence's scheduled instant.
            state[name] = .object(["last_fired_at": .string(stamp)])
            try await persistence.writeJSON(.object(state), to: statePath)
            return true
        }
        do {
            if let p = persistence as? SwiftNativePersistenceCore {
                return try await p.withFileLock(statePath, work)
            }
            return try await work()
        } catch {
            Self.logger.error("claim RMW failed for trigger '\(name, privacy: .public)': \(String(describing: error), privacy: .public) — treated as not-claimed (no fire this tick)")
            return false
        }
    }

    /// Extract an integer config field. Tolerates whole numbers emitted as
    /// doubles (some JSON writers do), but a FRACTIONAL double is rejected to
    /// nil rather than silently truncated (Finding 4): `hour: 8.9` must make the
    /// trigger DORMANT, not fire at 08:00. Non-finite / out-of-Int-range doubles
    /// are likewise nil.
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

    /// Today's local wall-clock instant at hour:minute, relative to `reference`.
    /// nil only if the components can't form a valid date.
    static func scheduledInstantToday(hour: Int, minute: Int, on reference: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let day = cal.dateComponents([.year, .month, .day], from: reference)
        var dc = DateComponents()
        dc.year = day.year
        dc.month = day.month
        dc.day = day.day
        dc.hour = hour
        dc.minute = minute
        dc.second = 0
        return cal.date(from: dc)
    }

    /// Parse an ISO8601 timestamp (with or without fractional seconds), matching
    /// the shape `isoTimestamp` writes.
    static func parseISOTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: value) { return d }
        return ISO8601DateFormatter().date(from: value)
    }

    // MARK: InboxItem builder

    /// Build the JSONValue body matching daemon inbox.py::InboxItem.to_dict().
    ///
    /// `isPlaceholder` is the honest answer to "is this content fabricated?":
    ///   - `time` / `idle` → REAL content from `TriggerContentBuilder` (desk,
    ///     worklog, missions, inbox, last session). `isPlaceholder == false`.
    ///   - the other three → still placeholders, each with an explicit marker
    ///     naming the signal that is missing. `isPlaceholder == true`.
    ///
    /// `TriggerFireResult.stub` is set from `isPlaceholder`, so the field stops
    /// claiming that a real morning brief is a stub.
    private func _buildInboxItem(
        kind: String, row: TriggerConfig, name: String
    ) async throws -> (item: JSONValue, isPlaceholder: Bool) {
        let id = uuid()
        let createdAt = Self.isoTimestamp(now())
        let source: String
        let severity: String
        let title: String
        let summary: String
        let detail: JSONValue
        var relatedPaths: JSONValue = .null
        var relatedWorkshopExecutionId: JSONValue = .null
        var isPlaceholder = true

        let content = TriggerContentBuilder(
            root: root, persistence: persistence, now: now, worklogPath: worklogPath
        )

        switch kind {
        case "file_watch":
            // proactive_triggers.py L261-295 (is_stub branch). Port watched
            // paths from row.config["paths"][:3] → basename-only source
            // suffix + count-suffix title + related_paths array.
            var paths: [String] = []
            if case .object(let cfg)? = row.config,
               case .array(let arr) = cfg["paths"] ?? .null {
                for v in arr.prefix(3) {
                    if case .string(let s) = v { paths.append(s) }
                }
            }
            let suffix: String
            if paths.isEmpty {
                suffix = "stub"
            } else {
                suffix = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ",")
            }
            source = "trigger:file_watch:\(suffix)"
            severity = "info"
            title = "File change detected" + (paths.count > 1 ? " (\(paths.count) files)" : "")
            // stub: not yet ported — real content needs the CHANGED-FILE DIFF
            // (which paths changed, and how). Only `config.paths` is knowable
            // here; no mtime cursor or diff summary is persisted. Declared, not
            // silent: `stub: true` on the fire result, and the `file_watch` kind
            // stays dark on the periodic tick for exactly this reason.
            summary = "Stub: file watcher trigger is wired."
            detail = .null
            relatedPaths = paths.isEmpty ? .null : .array(paths.map { .string($0) })
        case "idle":
            // REAL content. Quiet duration from max(updatedAt) over
            // chat/sessions.json + one live fact (open desk count, else the
            // last thread's title). Honest when no activity signal resolves.
            let built = await content.idleCheckin()
            source = "idle_checkin"
            severity = "info"
            title = built.title
            summary = built.summary
            detail = built.detail
            isPlaceholder = false
        case "time":
            // REAL content. Desk + worklog + Workshop executions + unread + last session,
            // every section fail-open. Title keeps its "%A, %B %-d" label.
            let built = await content.morningBrief()
            source = "trigger:morning_brief"
            severity = "important"
            title = built.title
            summary = built.summary
            detail = built.detail
            isPlaceholder = false
        case "mission_complete":
            // stub: not yet ported — real content needs a COMPLETION CURSOR
            // (which mission newly finished since the last fire). The scheduler
            // tracks no such cursor, so it cannot name the mission. Declared,
            // not silent.
            source = "mission_complete:stub"
            severity = "actionable"
            title = "Workshop complete: Stub task"
            summary = "Stub: Workshop task completed. Want to see results?"
            detail = .null
            relatedWorkshopExecutionId = .null
        case "session_pattern":
            // stub: not yet ported — real content needs the live CONVERSATION
            // REGISTER (`min_turns_in_register`), which lives in the chat turn
            // engine, not on disk. The nudge text is generic on purpose; it
            // cannot cite what we're circling. Declared, not silent.
            source = "trigger:stuck_pattern"
            severity = "info"
            title = "We might be circling"
            summary = "I notice we've been circling this. Want to step back and look at it differently?"
            detail = .string("This is a gentle nudge — not a judgment. Sometimes a different angle helps. You can dismiss this.")
        default:
            // Defensive: the caller's canonical-kind guard should make this
            // unreachable, but a guarded fatalError would crash the whole
            // scheduler if that invariant ever breaks. Fail loud + honest
            // instead — the caller's do/catch turns this into an
            // {status:"error"} envelope, never a crash.
            Self.logger.error("unhandled trigger kind '\(kind, privacy: .public)' reached stub builder — refusing to fabricate an item")
            throw TriggerSchedulerError.invalidRequest("unhandled trigger kind: \(kind)")
        }
        _ = row // row kept in signature for symmetry with build_inbox_item(runtime, is_stub)

        // Match _STANDARD_ACTIONS shape.
        let actions: JSONValue = .array([
            .object(["id": .string("view"),    "label": .string("View"),    "description": .string("See full detail")]),
            .object(["id": .string("act"),     "label": .string("Act"),     "description": .string("Take primary action")]),
            .object(["id": .string("archive"), "label": .string("Archive"), "description": .string("Archive this item")]),
            .object(["id": .string("dismiss"), "label": .string("Dismiss"), "description": .string("Dismiss this item")]),
        ])

        let item: JSONValue = .object([
            "id": .string(id),
            "created_at": .string(createdAt),
            "source": .string(source),
            "severity": .string(severity),
            "title": .string(title),
            "summary": .string(summary),
            "detail": detail,
            "related_mission_id": relatedWorkshopExecutionId,
            "related_approval_id": .null,
            "related_paths": relatedPaths,
            "related_groups": .null,
            "actions": actions,
            "status": .string("unread"),
            "read_at": .null,
        ])
        return (item, isPlaceholder)
    }

    /// Same shape as MCPDispatcher.isoTimestamp / ApprovalInbox stamps.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    // MARK: serialization helper

    func runSerialized<T: Sendable>(
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prior = mutationTail
        let task = Task<T, Error> {
            _ = await prior?.value
            return try await body()
        }
        mutationTail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: defaults — must stay byte-equivalent to daemon defaults

    /// Mirrors the retired daemon::_DEFAULT_TRIGGER_CONFIGS (L789-L825).
    /// Keep these in sync — the file gets seeded with this exact list on first
    /// write (daemon `_ensure_config`).
    nonisolated static let _defaultInboxConfigs: [JSONValue] = [
        .object([
            "name": .string("file_watch"),
            "kind": .string("file_watch"),
            "enabled": .bool(false),
            "config": .object(["paths": .array([])]),
            "description": .string("Watch files for changes and summarize what changed."),
        ]),
        .object([
            "name": .string("idle_checkin"),
            "kind": .string("idle"),
            "enabled": .bool(false),
            "config": .object([
                "idle_minutes": .int(30),
                "quiet_start_hour": .int(23),
                "quiet_end_hour": .int(8),
                // Ships quiet: the idle condition is newly lit, so the item
                // surfaces in the inbox but does not push until User opts in.
                "notify": .bool(false),
            ]),
            "description": .string("Check in after a period of silence."),
        ]),
        .object([
            "name": .string("morning_brief"),
            "kind": .string("time"),
            "enabled": .bool(false),
            "config": .object([
                "hour": .int(8),
                "minute": .int(0),
                // The one trigger whose whole point is to reach User when he
                // isn't looking at the app. Mirrored in `notifyDefaultsByName`
                // so EXISTING installs (whose trigger_config.json predates this
                // key) get the push too.
                "notify": .bool(true),
            ]),
            "description": .string("Daily morning brief at configured hour."),
        ]),
        .object([
            "name": .string("mission_followup"),
            "kind": .string("mission_complete"),
            "enabled": .bool(true),
            "config": .object([:]),
            "description": .string("Notify when a Workshop task completes."),
        ]),
        .object([
            "name": .string("stuck_pattern"),
            "kind": .string("session_pattern"),
            "enabled": .bool(false),
            "config": .object(["min_turns_in_register": .int(3)]),
            "description": .string("Gentle nudge when conversation is circling."),
        ]),
    ]

    /// Mirrors the retired daemon::TriggerScheduler.DEFAULT_TRIGGERS (L1824-L1834).
    nonisolated static let _defaultWorkshopExecutionConfigs: [JSONValue] = [
        .object([
            "name": .string("morning_brief"),
            "kind": .string("time"),
            "config": .object([
                "hour": .int(8),
                "minute": .int(0),
            ]),
            "objective": .string("Read calendar + email summary, draft a morning brief"),
            "title": .string("Morning Brief"),
            "trust_required": .string("send_approval"),
            "enabled": .bool(false),
        ]),
    ]

    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }
}

// MARK: - ProactiveInboxStore

/// A5.2 (2026-07-24): formerly the file-backed mirror of the retired
/// daemon::Inbox.surface (`<root>/inbox/` items.jsonl + index.json). That
/// silo is retired — nothing user-facing ever read it, and every fired card
/// already lands in `notifications/inbox.jsonl` via the app-side mirror seam.
/// What remains here is the 7-day active-duplicate identity check against
/// the live inbox; the fire path uses it to suppress duplicate pushes.
public actor ProactiveInboxStore {
    private let root: URL
    private let persistence: any PersistenceCoreProtocol

    public init(root: URL, persistence: any PersistenceCoreProtocol) {
        self.root = root
        self.persistence = persistence
    }

    /// The LIVE inbox — the one store the Mac UI, getInboxItems, and the iOS
    /// snapshot read, and the one the app-side mirror seam writes.
    public nonisolated var notificationsInboxPath: URL {
        root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    /// A5.2 (2026-07-24): the legacy `<root>/inbox/` silo (items.jsonl +
    /// index.json) is retired — nothing user-facing ever read it, and every
    /// fired card already lands in the live inbox via the app-side seam
    /// (`TriggerNotifierBinding.pairedDevicePush` for notify:true fires,
    /// `mirrorNonNotifiedFire` for everything else). This store's remaining
    /// job is the 7-day active-duplicate check, now anchored to the live
    /// inbox: a repeat fire hands back the EXISTING card id, and the fire
    /// path uses that identity to suppress the duplicate push + mirror.
    /// No writes happen here anymore.
    public func surface(_ item: JSONValue) async throws -> String {
        guard case .object(let obj) = item,
              case .string(let id) = obj["id"] ?? .null,
              !id.isEmpty else {
            throw TriggerSchedulerError.invalidRequest("inbox item missing id")
        }
        if let existing = Self.activeDuplicateId(
            for: obj,
            notificationsInboxPath: notificationsInboxPath
        ) {
            return existing
        }
        return id
    }

    private static let activeDuplicateWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Suppress repeated proactive/routine inbox cards while an equivalent
    /// active card is still visible. This is deliberately scoped to proactive
    /// sources so event-like inbox writers can still emit separate events.
    /// Public so the app-side mirror seam (TriggerNotifierBinding) can run the
    /// SAME matcher atomically under the live-inbox file lock right before it
    /// appends — surface()'s call is advisory (suppresses the push early); the
    /// mirror's locked call is the backstop that closes the check-then-append
    /// race between concurrent fires (gpt-5.5 review, 2026-07-24).
    public nonisolated static func activeDuplicateId(
        for candidate: [String: JSONValue],
        notificationsInboxPath: URL
    ) -> String? {
        guard let candidateKey = duplicateKey(candidate),
              shouldDedupeSource(candidateKey.source) else {
            return nil
        }
        let candidateCreatedAt = parseInboxDate(string(candidate["created_at"]))
        guard let data = try? Data(contentsOf: notificationsInboxPath),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        // The live inbox is append-only with last-write-wins per id (a status
        // change appends a full replacement row). Collapse to the FINAL row
        // per id first, so a dismissed/archived card can't shadow-match on an
        // earlier unread revision of itself.
        var order: [String] = []
        var latest: [String: [String: JSONValue]] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  case .object(let row)? = try? JSONValue.parse(lineData),
                  let rowId = string(row["id"]), !rowId.isEmpty else {
                continue
            }
            if latest[rowId] == nil { order.append(rowId) }
            latest[rowId] = row
        }
        for rowId in order.reversed() {
            guard let existing = latest[rowId],
                  let existingKey = duplicateKey(existing),
                  existingKey == candidateKey,
                  activeStatus(for: existing) else {
                continue
            }
            if isStaleDuplicate(existing: existing, candidateCreatedAt: candidateCreatedAt) {
                continue
            }
            return rowId
        }
        return nil
    }

    private nonisolated static func shouldDedupeSource(_ source: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "idle_checkin"
            || s.hasPrefix("trigger:")
            || s.hasPrefix("mission_complete:")
            || s.hasPrefix("proactive_autonomy:")
    }

    private nonisolated static func duplicateKey(_ object: [String: JSONValue])
        -> (source: String, title: String, summary: String)?
    {
        guard let source = normalizedText(object["source"]),
              let title = normalizedText(object["title"]) else {
            return nil
        }
        return (source, title, normalizedText(object["summary"]) ?? "")
    }

    /// Status lives per-line in the live inbox (the caller already collapsed
    /// to the final row per id — no index overlay exists anymore).
    private nonisolated static func activeStatus(
        for item: [String: JSONValue]
    ) -> Bool {
        let status = (string(item["status"]) ?? "unread")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return status == "unread" || status == "read"
    }

    private nonisolated static func isStaleDuplicate(
        existing: [String: JSONValue],
        candidateCreatedAt: Date?
    ) -> Bool {
        guard let candidateCreatedAt,
              let existingCreatedAt = parseInboxDate(string(existing["created_at"])) else {
            return false
        }
        return candidateCreatedAt.timeIntervalSince(existingCreatedAt) > activeDuplicateWindow
    }

    private nonisolated static func normalizedText(_ value: JSONValue?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private nonisolated static func parseInboxDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

// MARK: - Factory

/// Returns SwiftNative. The daemon route is retired for production runtime.
///
/// Wave 24-amendment (2026-06-01): when `.missions` is ON we MUST inject a
/// mission runner whose planner is `HTTPCodexMissionPlannerLLM` (the
/// production planner that actually drives an LLM). The default
/// `SwiftNativeWorkshopRunner.init` planner is `StubWorkshopPlannerLLM`, which
/// would silently ship 2-step stub plans for every fired trigger — the bug
/// that wave 24's retirement assumed away. We thread the runner through
/// `makeWorkshopRunner(runtime:)` so the factory wiring + the standalone
/// mission-runner factory share one source of truth.
///
/// `notifier` is nil by default: the list / enable / disable / configure call
/// sites never fire, so they must never carry a push sender. ONLY the two fire
/// sites (the event/deadline due-work runner and manual "fire now") pass one in.
public func makeTriggerScheduler(
    notifier: TriggerNotifier? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any TriggerSchedulerClient {
    let runner = makeWorkshopRunner(dataRoot: dataRoot)
    return SwiftNativeTriggerScheduler(root: dataRoot, workshopRunner: runner, notifier: notifier)
}
