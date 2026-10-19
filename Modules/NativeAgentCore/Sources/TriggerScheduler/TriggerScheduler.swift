import Foundation
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
import WorkshopExecution

// CAVEAT — SUBSYSTEM #17 WAVE 4 + WAVE 12 + WAVE 21 (2026-06-01): FLAG-FLIPPABLE.
// Wave 4 closed both prereqs that made the list/enable/disable/configure
// surface flippable (daemon mtime-based lazy reload + flock symmetry on
// trigger config writes — see proactive_triggers.py `_maybe_reload` /
// `_save_config`, missions.py `_maybe_reload` / `_write_json`, plus
// the retired daemon paired with PersistenceCore+FileLock.swift).
//
// Wave 12 (2026-05-31) NARROWED the previously-permanent `/fire_now`
// carve-out — but kept it SPLIT between the inbox and executions sides.
// Wave 21 (2026-06-01) closes the execution side of the carve once
// SwiftNativeWorkshopRunner landed:
//
//   - Inbox fire_now builds the evidence-backed morning brief natively. A5.2
//     (2026-07-24): the built card lands in `notifications/inbox.jsonl`
//     via the app-side mirror seam; TriggerNotificationInbox also runs the
//     active-duplicate check (the legacy `<root>/inbox/` silo is retired).
//     Unknown kinds
//     return `not_found` instead of falling through to a generic stub.
//   - Workshop fire_now is Swift-native. SwiftNativeTriggerScheduler resolves the
//     execution trigger row from
//     <root>/missions/triggers.json, builds the execution spec via the
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
///   - invalidRequest: empty name / malformed payload.
///   - persistenceFailure: IO error reading/writing the trigger configs file.
public enum TriggerSchedulerError: Error, LocalizedError {
    case invalidRequest(String)
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg): return "invalid request: \(msg)"
        case .persistenceFailure(let m): return "persistence failure: \(m)"
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
    /// (e.g. `objective` / `title` / `trust_required` from executions triggers,
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
// `AppToolExecutor` injects its own sender. The app binds it to
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
    // Inbox (proactive) triggers — backed by <root>/triggers/trigger_config.json
    // (relocated 2026-08-13 from the legacy <root>/inbox/ silo; lazy migration)
    func listInboxTriggers() async throws -> [TriggerConfig]
    func enableInboxTrigger(name: String) async throws -> TriggerStatus
    func disableInboxTrigger(name: String) async throws -> TriggerStatus
    func configureInboxTrigger(name: String, config: JSONValue) async throws -> TriggerStatus
    func fireInboxTrigger(name: String) async throws -> TriggerFireResult

    // Workshop triggers — backed by <root>/missions/triggers.json
    func listWorkshopTriggers() async throws -> [TriggerConfig]
    func fireWorkshopTrigger(name: String) async throws -> TriggerFireResult
}

// MARK: - SwiftNative impl

/// File-backed trigger scheduler client mirroring the persistence side of
/// the retired daemon::ProactiveTriggerScheduler and
/// the retired daemon::TriggerScheduler.
///
/// SCOPE NARROWING (WAVE 12 + WAVE 21) — Swift impl now covers fire_now end-to-end:
///   - fireInboxTrigger(name:) — builds the evidence-backed morning brief,
///     dedups it against the live inbox, and lands the card in
///     notifications/inbox.jsonl through the app-side mirror seam (A5.2).
///   - fireMissionTrigger(name:) — native execution enqueue through
///     SwiftNativeWorkshopRunner.
///
/// Native scheduling runs in-process in NativeAgent.app. BackgroundLoopsManager
/// owns loop lifecycle and failure tracking through SwiftNativeLoopScheduler.
/// TriggerSchedulerEventDeadlineRunner wakes for due jobs and triggers; this actor
/// owns trigger eligibility, durable claims and firing. SwiftNativeSchedulerJobs
/// owns job state, SchedulerDueJobRunner executes due jobs, and Workshop owns
/// execution admission and draining.
///
/// Persistence file paths:
///   - Inbox:    <root>/triggers/trigger_config.json  (2026-08-13: relocated
///     from the daemon-era <root>/inbox/trigger_config.json with a lazy
///     copy-forward migration; the file FORMAT stays byte-equivalent)
///   - Executions: <root>/workshop/triggers.json
///
/// Both are JSON arrays of trigger dicts. Atomic write + cross-process flock
/// serialize persisted mutations and claims across overlapping native callers.
public actor SwiftNativeTriggerScheduler: TriggerSchedulerClient {
    let root: URL
    let persistence: any PersistenceCoreProtocol
    private let workshopRunner: SwiftNativeWorkshopRunner
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
    /// L5 G3/G1 seam: the tool-capable turn that supplies the morning brief's
    /// synthesized lead. Missing synthesis is an owned failure, never a
    /// substituted counts brief.
    let morningBriefSynthesizer: MorningBriefSynthesizer?
    private var mutationTail: Task<Void, Never>? = nil

    /// `workshopRunner` is the wave-21 execution-fire seam. Defaults to a
    /// SwiftNativeWorkshopRunner with the same `root`/`persistence`/`now`/
    /// `uuid` injection seams so persistence paths and timestamps line up
    /// with the trigger-scheduler's own writes. Tests pass a stub.
    /// `now` / `uuid` are injection seams for deterministic tests.
    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        workshopRunner: SwiftNativeWorkshopRunner? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        connectorActionIDs: Set<String>? = nil,
        notifier: TriggerNotifier? = nil,
        worklogPath: URL? = nil,
        morningBriefSynthesizer: MorningBriefSynthesizer? = nil
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
        self.morningBriefSynthesizer = morningBriefSynthesizer
    }

    /// `<root>/triggers/trigger_config.json`. Relocated 2026-08-13 out of the
    /// legacy `<root>/inbox/` silo (the retired Python daemon's notification
    /// inbox dir, now frozen). Existing installs are migrated lazily —
    /// see `migrateLegacyInboxTriggerFilesIfNeeded()`.
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

    // MARK: periodic-fire liveness state (W3c)
    //
    // Per-surface `{ "<trigger name>": { "last_fired_at": "<iso8601>" } }` maps
    // that record when a trigger last SELF-fired on the periodic tick. These
    // are LIVENESS state, not config — kept in a sibling file so a write never
    // touches the daemon-shaped config array. Persisting them is what stops a
    // restart from re-firing a storm: after a crash+relaunch the scheduler
    // reads last_fired_at and sees a time trigger already fired today.
    // Inbox and execution trigger names can collide ("morning_brief" exists in
    // both surfaces), so each surface gets its own state file.
    /// `<root>/triggers/trigger_state.json` (same 2026-08-13 relocation and lazy
    /// migration as `inboxPath`).
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

    // MARK: legacy-path migration (2026-08-13)

    /// Set once BOTH inbox-surface files are settled at their new home (either
    /// migrated, already present, or fresh-install absent), so steady state pays
    /// one boolean check per access instead of file stats.
    private var legacyInboxTriggerMigrationDone = false

    /// One-shot lazy relocation of the inbox-surface trigger files out of the
    /// legacy `<root>/inbox/` silo (the retired Python daemon's notification-
    /// inbox dir, frozen since the daemon decommission) into `<root>/triggers/`.
    ///
    /// Read-old-write-new: if the new file is absent and the legacy one exists,
    /// copy the legacy bytes to the new home BEFORE the caller reads or writes —
    /// so a live install's trigger config and last-fired liveness state survive
    /// the move (losing trigger_state.json would re-fire time triggers that
    /// already fired today; see the W3c note above). The legacy files are left
    /// in place, frozen — nothing reads them once the new files exist.
    ///
    /// Failure is LOUD, FAIL-CLOSED, and non-latching (gpt-5.5 review BLOCKING,
    /// 2026-08-13): when a legacy file exists but its copy-forward fails, this
    /// THROWS and the guarded entry point aborts. Proceeding would let a
    /// mutation seed built-in DEFAULTS at the new home — after which the
    /// exists-check here would skip the legacy file forever, silently losing
    /// the user's config or `last_fired_at` (whose loss re-fires time triggers).
    /// The surface stays dormant-until-repaired — same posture as corrupt
    /// state — and the unset done-flag retries on the next access.
    /// The copy runs under the LEGACY file's flock so it cannot snapshot a
    /// mid-write file, and re-checks the destination inside the lock so a
    /// concurrent interleaved call (actor methods yield at await) cannot
    /// double-copy.
    private func migrateLegacyInboxTriggerFilesIfNeeded() async throws {
        if legacyInboxTriggerMigrationDone { return }
        let legacyDir = root.appendingPathComponent("inbox", isDirectory: true)
        let pairs: [(legacy: URL, new: URL)] = [
            (legacyDir.appendingPathComponent("trigger_config.json"), inboxPath),
            (legacyDir.appendingPathComponent("trigger_state.json"), inboxStatePath),
        ]
        for (legacy, new) in pairs {
            if FileManager.default.fileExists(atPath: new.path) { continue }
            guard FileManager.default.fileExists(atPath: legacy.path) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: new.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try await persistence.withFileLock(legacy) {
                    if !FileManager.default.fileExists(atPath: new.path) {
                        try FileManager.default.copyItem(at: legacy, to: new)
                    }
                }
                Self.logger.notice("migrated legacy \(legacy.lastPathComponent, privacy: .public) from inbox/ to triggers/")
            } catch {
                Self.logger.error("FAILED to migrate legacy \(legacy.lastPathComponent, privacy: .public) from inbox/ to triggers/: \(String(describing: error), privacy: .public) — inbox trigger surface stays DORMANT until repaired; will retry on next access")
                throw TriggerSchedulerError.persistenceFailure(
                    "legacy trigger-file migration failed for \(legacy.lastPathComponent): \(String(describing: error))"
                )
            }
        }
        legacyInboxTriggerMigrationDone = true
    }

    // MARK: list

    public func listInboxTriggers() async throws -> [TriggerConfig] {
        try await migrateLegacyInboxTriggerFilesIfNeeded()
        return try await Self._readList(path: inboxPath, defaultValue: Self._defaultInboxConfigs)
    }

    public func listWorkshopTriggers() async throws -> [TriggerConfig] {
        try await Self._readList(path: workshopExecutionsPath, defaultValue: Self._defaultWorkshopExecutionConfigs)
    }

    private static func _readList(
        path: URL,
        defaultValue: [JSONValue]
    ) async throws -> [TriggerConfig] {
        let items = try loadConfigsForMutation(path: path, defaultValue: defaultValue)
        // Old inbox rows stay on disk; only kinds with a current owner are exposed.
        let kinds = Set(defaultValue.compactMap(TriggerConfig.init(json:)).compactMap(\.kind))
        return items.compactMap(TriggerConfig.init(json:)).filter { cfg in
            defaultValue != Self._defaultInboxConfigs || cfg.kind.map(kinds.contains) == true
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
        try await migrateLegacyInboxTriggerFilesIfNeeded()
        return try await runSerialized { [persistence, inboxPath] in
            let work: @Sendable () async throws -> TriggerStatus = {
                try await Self._setEnabledImpl(
                    name: name, enabled: enabled,
                    path: inboxPath, defaultValue: Self._defaultInboxConfigs,
                    persistence: persistence
                )
            }
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            return try await persistence.withFileLock(inboxPath, work)
        }
    }

    /// Mirrors daemon proactive_triggers.set_enabled + executions.set_enabled:
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
        let kinds = Set(defaultValue.compactMap(TriggerConfig.init(json:)).compactMap(\.kind))
        var found = false
        for (idx, item) in items.enumerated() {
            guard case .object(var obj) = item,
                  defaultValue != Self._defaultInboxConfigs || TriggerConfig(json: item)?.kind.map(kinds.contains) == true,
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
        try await migrateLegacyInboxTriggerFilesIfNeeded()
        return try await runSerialized { [persistence, inboxPath] in
            let work: @Sendable () async throws -> TriggerStatus = {
                // M4: same read-then-write destruction as _setEnabledImpl — a
                // corrupt file yielded the default array, whose rows then got
                // merged and written over the user's config.
                var items: [JSONValue] = try Self.loadConfigsForMutation(
                    path: inboxPath, defaultValue: Self._defaultInboxConfigs
                )
                let kinds = Set(Self._defaultInboxConfigs.compactMap(TriggerConfig.init(json:)).compactMap(\.kind))
                var found = false
                for (idx, item) in items.enumerated() {
                    guard case .object(var obj) = item,
                          TriggerConfig(json: item)?.kind.map(kinds.contains) == true,
                          case .string(let nm) = obj["name"] ?? .null,
                          ExecutionEventVocabulary.matches(nm, name) else { continue }
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
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            return try await persistence.withFileLock(inboxPath, work)
        }
    }

    // MARK: fire_now — Swift-native

    /// Mirrors daemon proactive_triggers.py::ProactiveTriggerScheduler.fire_now.
    public func fireInboxTrigger(name: String) async throws -> TriggerFireResult {
        try await fireInboxTrigger(name: name, occurrence: nil)
    }

    private func fireInboxTrigger(name: String, occurrence: String?) async throws -> TriggerFireResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }
        guard inboxMasterOn else {
            return TriggerFireResult(
                status: "disabled", name: name, stub: true,
                error: "Raising things unasked is off (Notifications), so no trigger fires."
            )
        }
        try await migrateLegacyInboxTriggerFilesIfNeeded()

        // Look up the trigger row.
        let configs: [TriggerConfig]
        do {
            configs = try await Self._readList(
                path: inboxPath,
                defaultValue: Self._defaultInboxConfigs
            )
        } catch {
            return TriggerFireResult(status: "error", name: name, stub: true,
                                     error: String(describing: error))
        }
        guard let row = configs.first(where: { ExecutionEventVocabulary.matches($0.name, name) }) else {
            return TriggerFireResult(status: "not_found", name: name, stub: true)
        }

        // Canonical-kind guard: unknown kinds return not_found (matches Python
        // which would have no per-kind trigger class to fire). Don't fall
        // through to a generic stub.
        guard let rowKind = row.kind, rowKind == "time" else {
            return TriggerFireResult(status: "not_found", name: name, stub: true)
        }

        // Swift-native fire path for the morning brief.
        do {
            var item = try await _buildMorningBriefItem()
            if let occurrence, case .object(var fields) = item {
                fields["trigger_occurrence"] = .string(occurrence)
                item = .object(fields)
            }
            guard inboxMasterOn else {
                return TriggerFireResult(
                    status: "disabled", name: name, stub: true,
                    error: "Raising things unasked is off (Notifications), so no trigger fires."
                )
            }
            let id = try await TriggerNotificationInbox.surface(item, dataRoot: root)

            // `surface` SUPPRESSES an active duplicate (same source+title+summary,
            // still unread/read, within 7 days) and hands back the EXISTING id
            // instead of appending. When that happens no new card appeared, so
            // pushing would notify User about something already sitting in his
            // inbox. Detect it by identity: the id we minted vs the id we got.
            let deduped = (id != Self.itemId(of: item))

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
                    delivery = await notifier(Self.notification(for: item, name: name, kind: rowKind))
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
                    } else if case .object(let d) = delivery {
                        if d["delivery"] == .string("failed") || d["status"] == .string("failed") {
                            status = "warn"
                            detail += "; card saved but notification delivery failed"
                        } else if d["deduped_against"] != nil || d["delivery"] == .string("previously_handled") {
                            detail += "; notification already handled — no new push"
                        } else if d["delivery"] == .string("deferred") {
                            detail += "; notification deferred for quiet hours"
                        } else if d["delivery"] == .string("no_channel") {
                            detail += "; no notification channel selected"
                        } else if d["delivered"] == .bool(false) {
                            detail += "; card saved; notification not delivered"
                        } else {
                            detail += "; notification accepted or queued for delivery"
                        }
                    } else {
                        detail += "; notifier handled the notification"
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
                item: item, itemId: id, name: name, kind: rowKind,
                notified: notified, placeholder: false, deduped: deduped,
                delivery: delivery, status: status, detail: detail
            )

            // Hand the caller the built card + whether the notifier already
            // mirrored it, so a non-notified fire can still reach the real
            // inbox app-side. Deduped fires carry no item: the card they'd
            // mirror is the one already sitting in the inbox (board M18).
            return TriggerFireResult(
                status: "fired", name: name, itemId: id, stub: false,
                item: deduped ? nil : item, notified: notified
            )
        } catch {
            return TriggerFireResult(status: "error", name: name, stub: true,
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
            "executionId": .null,
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

    /// Wave 21: Swift-native execution fire. Resolves the trigger row, builds the
    /// execution spec via the ProactiveTrigger.build_mission() shape (missions.py
    /// L1821-L1827 — title/objective/trigger_source/trust_required), and calls
    /// SwiftNativeWorkshopRunner.submit(). Mirrors the Python TriggerScheduler.fire_now
    /// failure envelopes: not_found, missing_objective, and any WorkshopExecutionError
    /// throw maps to {status:"error", name, error:<description>}.
    public func fireWorkshopTrigger(name: String) async throws -> TriggerFireResult {
        try await fireWorkshopTrigger(name: name, occurrence: nil)
    }

    private func fireWorkshopTrigger(name: String, occurrence: String?) async throws -> TriggerFireResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }

        // Read the persisted Workshop execution triggers list.
        let configs: [TriggerConfig]
        do {
            configs = try await Self._readList(
                path: workshopExecutionsPath,
                defaultValue: Self._defaultWorkshopExecutionConfigs
            )
        } catch {
            return TriggerFireResult(status: "error", name: name,
                                     error: String(describing: error))
        }
        guard let row = configs.first(where: { ExecutionEventVocabulary.matches($0.name, name) }) else {
            return TriggerFireResult(status: "not_found", name: name)
        }

        // Build the execution spec from the row, mirroring
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

    // MARK: evaluate-and-fire

    /// Evaluate every persisted trigger and fire each enabled one through the
    /// matching Swift-native fire path. Returns the names of triggers that
    /// actually fired (status == "fired"). Mirrors what the daemon's
    /// `_proactive_triggers_loop` does on each periodic tick: enumerate, gate
    /// on `enabled`, and dispatch. Disabled triggers, unknown kinds, and
    /// missing-objective execution triggers are skipped without being reported as
    /// fired. Inbox triggers fire as stubs (the only fully Swift-native path).
    /// Errors from a single trigger do not block evaluation of the others.
    /// Notifications ▸ "Let her raise things unasked", read fresh off saved
    /// authority. Off, no inbox trigger fires — not on the tick, not by hand —
    /// whatever each trigger's own switch says. It was written and shown and
    /// read by nothing here, so the morning brief went on firing with it off.
    /// Shipped on (TrustCenter+Defaults); damaged policy fails closed.
    nonisolated var inboxMasterOn: Bool {
        SavedTrustPolicyAuthority.flag(block: "inboxPolicy", key: "enabled", default: true, dataRoot: root)
    }

    /// The full fire envelopes for this tick, in fire order. The periodic tick
    /// site needs these (not just the names) so it can mirror the card of any
    /// NON-notified inbox fire into the real notifications inbox — a notified
    /// fire is already mirrored by the injected notifier (board M18).
    public func evaluateAndFireDetailed() async -> [TriggerFireResult] {
        var fired: [TriggerFireResult] = []
        var deferredDueToCap = false
        for (surface, path) in [("inbox", inboxStatePath), ("workshop", workshopExecutionStatePath)] {
            guard case .parsed(let state) = Self.readStateRaw(path) else { continue }
            for (name, value) in state {
                guard case .object(let entry) = value, case .array(let pending)? = entry["unfinished_occurrences"] else { continue }
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
                guard scheduledInstantIfDue(cfg) != nil else { continue }
                if fired.count >= Self.periodicFireCapPerTick { deferredDueToCap = true; break }
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
                "periodic trigger fire cap (\(Self.periodicFireCapPerTick, privacy: .public)) hit this tick — fired \(fired.count, privacy: .public), remaining due triggers deferred to next tick"
            )
        }
        return fired + unavailable
    }

    public func repairTrigger(surface: String, name: String, occurrence: String? = nil) async -> TriggerFireResult {
        await runClaimedTrigger(surface: surface, name: name, occurrence: occurrence)
    }

    private func runClaimedTrigger(surface: String, name: String, occurrence: String? = nil) async -> TriggerFireResult {
        let statePath = surface == "inbox" ? inboxStatePath : workshopExecutionStatePath
        let claimed: String? = if case .parsed(let state) = Self.readStateRaw(statePath),
            let at = Self.lastFiredFromState(state, name: name) { Self.isoTimestamp(at) } else { nil }
        let occurrence = occurrence ?? claimed ?? uuid()
        let operation = "trigger:\(surface):\(name):\(occurrence)"
        var result: TriggerFireResult
        do {
            result = try await persistence.withFileLock(statePath) { [self] in
                var result: TriggerFireResult
                switch surface {
                case "inbox":
                    let rows = try await LiveNotificationInbox.live(dataRoot: root).rows()
                    if let prior = rows.first(where: {
                        guard case .object(let row) = $0 else { return false }
                        return row["source"] == .string("trigger:" + name) && row["trigger_occurrence"] == .string(occurrence)
                    }), let id = Self.itemId(of: prior) {
                        result = TriggerFireResult(status: "fired", name: name, itemId: id)
                    } else {
                        result = try await fireInboxTrigger(name: name, occurrence: occurrence)
                    }
                    if result.status == "fired", let item = result.item {
                        if case .failed = await TriggerNotificationInbox.mirrorCardIntoRealInbox(item, triggerName: name, dataRoot: root) {
                            result = TriggerFireResult(status: "error", name: name, error: "Trigger card could not be durably accepted by the inbox.")
                        }
                    }
                case "workshop":
                    let rows = try await workshopRunner.listWorkshopExecutionsMerged()
                    let source = "trigger:\(name):occurrence:\(occurrence)"
                    if let prior = rows.first(where: {
                        guard case .object(let row) = $0 else { return false }
                        return row["trigger_source"] == .string(source)
                    }), case .object(let row) = prior, case .string(let id)? = row["id"] {
                        result = TriggerFireResult(status: "fired", name: name, executionId: id)
                    } else {
                        result = try await fireWorkshopTrigger(name: name, occurrence: occurrence)
                    }
                default: throw TriggerSchedulerError.invalidRequest("surface must be inbox or workshop")
                }
                if result.status == "fired" {
                    guard case .parsed(var state) = Self.readStateRaw(statePath),
                          case .object(var entry)? = state[name] else { return result }
                    if case .array(let pending)? = entry["unfinished_occurrences"] {
                        entry["unfinished_occurrences"] = .array(pending.filter { $0 != .string(occurrence) })
                        state[name] = .object(entry)
                        try await persistence.writeJSON(.object(state), to: statePath)
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
                if Self.hasFired(cfg, state: state, scheduled: today) {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = .autoupdatingCurrent
                    var components = DateComponents()
                    components.hour = hour
                    components.minute = minute
                    components.second = 0
                    return calendar.nextDate(
                        after: max(reference, today),
                        matching: components,
                        matchingPolicy: .nextTime,
                        repeatedTimePolicy: .first,
                        direction: .forward
                    )
                }
                if today > reference { return today }
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
    ///     daily execution `morning_brief` enqueue and the daily inbox brief. A
    ///     missing / out-of-range / fractional hour makes the trigger DORMANT
    ///     (returns nil), never a crash.
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
        default:
            return nil
        }
    }

    // MARK: periodic-fire helpers (W3c)

    /// Classification of a per-surface `trigger_state.json` read, distinguishing
    /// the two "no last_fired_at" cases that MUST behave differently (Finding 2):
    ///   - `.missing` — file absent: a legitimately fresh
    ///     install. Triggers stay firing-eligible (never-fired).
    ///   - `.corrupt` — file EXISTS but is empty, unreadable, or has invalid
    ///     entries. Fail-safe: affected triggers go DORMANT, never treated
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
        // Preserve-and-throw like any other corruption.
        if data.isEmpty { return .corrupt }
        guard case .array(let items)? = try? JSONValue.parse(data) else { return .corrupt }
        return .parsed(items)
    }

    /// Corrupt-safe load of a trigger config array for a MUTATION (enable /
    /// disable / configure). Missing → defaults (a legitimately fresh install,
    /// where writing defaults is correct). Parsed → the user's rows. Corrupt →
    /// the canonical bytes stay in place and the mutation THROWS. This
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
            logger.error("corrupt trigger config \(path.lastPathComponent, privacy: .public) — preserved in place; refusing to overwrite it with defaults")
            throw TriggerSchedulerError.persistenceFailure(
                "Trigger configuration \(path.lastPathComponent) is unreadable and has been preserved. Repair the file before using triggers; defaults have not been restored."
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
        if data.isEmpty { return .corrupt }
        guard case .object(let o)? = try? JSONValue.parse(data) else {
            // Non-empty but not a JSON object (garbage, or a JSON array/scalar).
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
    /// False: not due, or already claimed. A claim that cannot be read or
    /// written throws: a due occurrence is owed, never "nothing due".
    private func claimIfDue(_ cfg: TriggerConfig, statePath: URL) async throws -> Bool {
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
            // Win the claim: stamp THIS occurrence's scheduled instant.
            var entry: [String: JSONValue] = if case .object(let saved)? = state[name] { saved } else { [:] }
            let unfinished: [JSONValue] = if case .array(let saved)? = entry["unfinished_occurrences"] { saved } else { [] }
            entry["unfinished_occurrences"] = .array(unfinished + [.string(stamp)])
            entry["last_fired_at"] = .string(stamp)
            if cfg.kind == "time" {
                entry["last_fired_occurrence"] = .string(Self.timeOccurrence(cfg, scheduled: scheduled))
            }
            state[name] = .object(entry)
            try await persistence.writeJSON(.object(state), to: statePath)
            await oweTrigger(surface: surface, name: name, occurrence: stamp).value
            return true
        }
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it.
        return try await persistence.withFileLock(statePath, work)
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
        cal.timeZone = .autoupdatingCurrent
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
        return NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }

    // MARK: InboxItem builder

    private func _buildMorningBriefItem() async throws -> JSONValue {
        let id = uuid()
        let createdAt = Self.isoTimestamp(now())

        let content = TriggerContentBuilder(
            root: root, persistence: persistence, now: now, worklogPath: worklogPath
        )

        let built = try await content.morningBrief(synthesizer: morningBriefSynthesizer)

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
            "source": .string("trigger:morning_brief"),
            "presentation": .object(["icon": .string("sun.horizon.fill"), "badge": .string("MORNING-BRIEF"),
                                     "words": .string("Your morning brief"), "act_label": .string("Go ahead")]),
            "severity": .string("important"),
            "title": .string(built.title),
            "summary": .string(built.summary),
            "detail": built.detail,
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .null,
            "related_groups": .null,
            "actions": actions,
            "status": .string("unread"),
            "read_at": .null,
        ])
        return item
    }

    /// Same shape as MCPDispatcher.isoTimestamp / ApprovalInbox stamps.
    nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
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

    // MARK: defaults

    /// Every proactive lane ships OFF. Existing installs' `trigger_config.json`
    /// is merged against this list by name, so an install that already wrote
    /// the file keeps whatever the user chose — flipping a seed value here only
    /// ever changes what a FRESH root starts with.
    nonisolated static let _defaultInboxConfigs: [JSONValue] = [
        .object([
            "name": .string("morning_brief"),
            "kind": .string("time"),
            // Ships OFF, like every other proactive lane. A fresh root should
            // not start speaking on a schedule nobody asked for; the person
            // turns this on in Settings → Inbox Policy. An install that already
            // enabled it is untouched — the merge is by name.
            "enabled": .bool(false),
            "config": .object([
                "hour": .int(8),
                "minute": .int(0),
                // The one trigger whose whole point is to reach the person when
                // they aren't looking at the app — it only applies once they
                // enable it. Mirrored in `notifyDefaultsByName`
                // so EXISTING installs (whose trigger_config.json predates this
                // key) get the push too.
                "notify": .bool(true),
            ]),
            "description": .string("Daily morning brief at configured hour."),
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

}

// MARK: - Factory

/// Returns SwiftNative. The daemon route is retired for production runtime.
///
/// Wave 24-amendment (2026-06-01): when `.executions` is ON we MUST inject a
/// execution runner whose planner is `HTTPCodexMissionPlannerLLM` (the
/// production planner that actually drives an LLM). The default
/// `SwiftNativeWorkshopRunner.init` planner is `StubWorkshopPlannerLLM`, which
/// would silently ship 2-step stub plans for every fired trigger — the bug
/// that wave 24's retirement assumed away. We thread the runner through
/// `makeWorkshopRunner(runtime:)` so the factory wiring + the standalone
/// execution-runner factory share one source of truth.
///
/// `notifier` is nil by default: the list / enable / disable / configure call
/// sites never fire, so they must never carry a push sender. ONLY the two fire
/// sites (the event/deadline due-work runner and manual "fire now") pass one in.
///
/// `morningBriefSynthesizer` follows the same rule for the same reason: only
/// the fire sites can produce a brief, so only they carry the seam that gives
/// the brief its synthesized lead (L5 G3/G1).
public func makeTriggerScheduler(
    notifier: TriggerNotifier? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    morningBriefSynthesizer: MorningBriefSynthesizer? = nil
) -> any TriggerSchedulerClient {
    let runner = makeWorkshopRunner(dataRoot: dataRoot)
    return SwiftNativeTriggerScheduler(
        root: dataRoot,
        workshopRunner: runner,
        notifier: notifier,
        morningBriefSynthesizer: morningBriefSynthesizer
    )
}
