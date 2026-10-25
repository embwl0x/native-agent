import Foundation
import Experiences
import NotificationInbox
import Darwin
import os
import NativeAgentCore
import PersistenceCore
import TrustCenter
import WorkshopExecution
// Blueprint: | `TriggerScheduler.swift` | `SwiftNativeTriggerScheduler` actor; daily trigger admission uses one parser and the shared job normalizer's civil-minute math; retains catch-up and claims; morning brief content, card and defaults come from `Resources/abilities/native-morning-brief.js` through the engine's read-only originating part door; one config loader requests seed rows only for missing files, with native supported inbox kinds keeping saved controls and Workshop triggers independent of the brief part; native consent forces proposed default schedules off and preserves saved rows, occurrence identity and publication/delivery settlement; legacy inbox trigger inputs copy only to absent canonical files under the destination lock, leaving legacy files and their folder untouched; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |

// TriggerScheduler is the sole Swift owner for list/enable/disable,
// the native inbox fire path, and the Workshop fire_now path.

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
        case .invalidRequest(let msg): return "schedule_input_invalid: \(msg). Correct the named input in the scheduled Desk task request."
        case .persistenceFailure(let m): return "schedule_store_unavailable: \(m). Inspect the named scheduler file and repair its contents or access before changing scheduled Desk tasks."
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
// shape used by ToolRegistry records.

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

/// Status envelope returned by enable/disable. Mirrors the daemon's
/// `{name, enabled?, status, ...}` dict shape from both schedulers.
public struct TriggerStatus: Sendable, Equatable {
    public var name: String
    public var enabled: Bool?
    public var status: String     // "updated" | "not_found"

    public init(name: String, enabled: Bool?, status: String) {
        self.name = name
        self.enabled = enabled
        self.status = status
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
    /// A bounded pass left runnable work. The BackgroundLoops listener
    /// coalesces this edge with source changes before admitting the next pass.
    public static let dueWorkRemaining = Notification.Name("NativeAgent.scheduler.dueWorkRemaining")

    let root: URL
    let persistence: any PersistenceCoreProtocol
    private let workshopRunner: SwiftNativeWorkshopRunner
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> String
    let connectorActionIDs: Set<String>?
    /// Injected push sender. nil at every non-firing call site (list / enable /
    /// disable never push). When a trigger resolves `notify: true`
    /// and this is nil, the fire still lands and the receipt event is written
    /// with `status: "warn"` — LOUD, never silently absent.
    let notifier: TriggerNotifier?
    /// Injection seam for the native brief source reader's worklog, which lives
    /// OUTSIDE the data root (~/.claude/state/claude-worklog.jsonl). nil keeps
    /// the production default; tests point it at a temp file so a brief built
    /// under a bare temp root is genuinely empty. Same role as `now` / `uuid`.
    let worklogPath: URL?
    /// The originating door runs her part; absent/disabled code stays unavailable.
    let morningBriefPart: MorningBriefPart?
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
        morningBriefPart: MorningBriefPart? = nil
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
        self.morningBriefPart = morningBriefPart
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
    // Each surface keeps its own last-fired stamp and life-stamped unfinished
    // claims, separate from configuration; inbox/workshop names can collide.
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
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    /// Max triggers the due-work pass may fire in a single pass. A liveness
    /// backstop (NOT a policy gate): if a config edit or clock jump makes many
    /// triggers due at once, we fire at most this many and log loudly; the
    /// remainder stay due and request one coalesced continuation (their state
    /// isn't advanced, so no occurrence is lost).
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
    /// Copy failure throws before defaults or mutations can replace the old
    /// decision. The canonical destination's flock serializes the import and
    /// live writers; no lock sidecar is created in the frozen legacy folder.
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
                try await persistence.withFileLock(new) {
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

    private static let supportedInboxKinds: Set<String> = ["time"]

    public func listInboxTriggers() async throws -> [TriggerConfig] {
        try await migrateLegacyInboxTriggerFilesIfNeeded()
        return try await Self._readList(path: inboxPath, defaultValue: try await defaults().inbox, inbox: true)
    }

    public func listWorkshopTriggers() async throws -> [TriggerConfig] {
        try await Self._readList(path: workshopExecutionsPath, defaultValue: try await defaults().workshop)
    }

    private static func _readList(
        path: URL,
        defaultValue: @autoclosure @Sendable () async throws -> [JSONValue], inbox: Bool = false
    ) async throws -> [TriggerConfig] {
        let items = try await loadConfigs(path: path, defaultValue: try await defaultValue())
        // Old inbox rows stay on disk; only kinds with a current owner are exposed.
        return items.compactMap(TriggerConfig.init(json:)).filter { cfg in
            !inbox || cfg.kind.map(supportedInboxKinds.contains) == true
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
        let seed: [JSONValue] = if case .missing = Self.readConfigsRaw(inboxPath) { try await defaults().inbox } else { [] }
        return try await runSerialized { [persistence, inboxPath] in
            let work: @Sendable () async throws -> TriggerStatus = {
                try await Self._setEnabledImpl(
                    name: name, enabled: enabled,
                    path: inboxPath, defaultValue: seed,
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
        // now preserves the bytes and throws.
        var items = try await Self.loadConfigs(path: path, defaultValue: defaultValue)
        var found = false
        for (idx, item) in items.enumerated() {
            guard case .object(var obj) = item,
                  TriggerConfig(json: item)?.kind.map(supportedInboxKinds.contains) == true,
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

    // MARK: fire_now — Swift-native

    /// Mirrors daemon proactive_triggers.py::ProactiveTriggerScheduler.fire_now.
    public func fireInboxTrigger(name: String) async throws -> TriggerFireResult {
        let prepared = try await prepareInboxTrigger(name: name)
        return await publishInboxTrigger(name: name, occurrence: nil, prepared: prepared)
    }

    private enum InboxPreparation: Sendable {
        case ready(row: TriggerConfig, notify: [String: Bool], item: JSONValue)
        case refused(TriggerFireResult)
    }

    /// JavaScript and its model run before taking any publication/state lock.
    private func prepareInboxTrigger(name: String) async throws -> InboxPreparation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TriggerSchedulerError.invalidRequest("empty name") }
        guard inboxMasterOn else {
            return .refused(TriggerFireResult(
                status: "disabled", name: name, stub: true,
                error: "Raising things unasked is off (Notifications), so no trigger fires."
            ))
        }
        try await migrateLegacyInboxTriggerFilesIfNeeded()

        // Look up the trigger row.
        let configs: [TriggerConfig]
        let seed: MorningBriefDefaults
        do {
            seed = try await defaults()
            configs = try await Self._readList(
                path: inboxPath,
                defaultValue: seed.inbox, inbox: true
            )
        } catch {
            return .refused(TriggerFireResult(status: "error", name: name, stub: true,
                                     error: String(describing: error)))
        }
        guard let row = configs.first(where: { ExecutionEventVocabulary.matches($0.name, name) }) else {
            return .refused(TriggerFireResult(status: "not_found", name: name, stub: true))
        }

        do { return .ready(row: row, notify: seed.notify, item: try await _buildMorningBriefItem()) }
        catch { return .refused(TriggerFireResult(status: "error", name: name, stub: true, error: String(describing: error))) }
    }

    /// Native publication rechecks authority and owns the one delivery record.
    private func publishInboxTrigger(name: String, occurrence: String?, prepared: InboxPreparation) async -> TriggerFireResult {
        let row: TriggerConfig, notify: [String: Bool]
        var item: JSONValue
        switch prepared {
        case .refused(let result): return result
        case .ready(let selected, let defaults, let proposal): row = selected; notify = defaults; item = proposal
        }
        let rowKind = "time"
        do {
            try Task.checkCancellation()
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
            } else if Self.resolveNotify(row, defaults: notify) {
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

    /// Saved consent overrides the part's proposed notification preference.
    nonisolated static func resolveNotify(_ cfg: TriggerConfig, defaults: [String: Bool]) -> Bool {
        if case .object(let o)? = cfg.config, case .bool(let b)? = o["notify"] {
            return b
        }
        return defaults[cfg.name] ?? false
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

        let event = SwiftNativePersistenceCore.activityEvent(
            id: uuid(),
            kind: "trigger",
            title: title,
            detail: detail,
            status: status,
            executionId: nil,
            payload: .object(payload),
            createdAt: Self.isoTimestamp(now())
        )
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(
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
        let seed: [JSONValue] = if case .missing = Self.readConfigsRaw(workshopExecutionsPath) { try await defaults().workshop } else { [] }
        return try await fireWorkshopTrigger(name: name, occurrence: nil, seed: seed)
    }

    private func fireWorkshopTrigger(name: String, occurrence: String?, seed: [JSONValue]) async throws -> TriggerFireResult {
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
                let rows = try await LiveNotificationInbox.live(dataRoot: root).rows()
                if let prior = rows.first(where: { $0.objectValue?["source"] == .string("trigger:" + name)
                    && $0.objectValue?["trigger_occurrence"] == .string(occurrence) }), let id = Self.itemId(of: prior) {
                    prepared = .refused(TriggerFireResult(status: "fired", name: name, itemId: id))
                } else { prepared = try await prepareInboxTrigger(name: name) }
                workshopSeed = []
            case "workshop":
                prepared = .refused(TriggerFireResult(status: "not_found", name: name))
                workshopSeed = if case .missing = Self.readConfigsRaw(workshopExecutionsPath) { try await defaults().workshop } else { [] }
            default: throw TriggerSchedulerError.invalidRequest("surface must be inbox or workshop")
            }
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
                        result = await publishInboxTrigger(name: name, occurrence: occurrence, prepared: prepared)
                    }
                    if result.status == "fired", let item = result.item {
                        if case .failed = await TriggerNotificationInbox.mirrorCardIntoRealInbox(item, triggerName: name, dataRoot: root) {
                            result = TriggerFireResult(status: "error", name: name, error: "Trigger card could not be durably accepted by the inbox.")
                        }
                    }
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

        let work: @Sendable () async throws -> Bool = { [self, persistence] in
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
            try await persistence.writeJSON(.object(state), to: statePath)
            await oweTrigger(surface: surface, name: name, occurrence: stamp).value
            return true
        }
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

    /// Parse an ISO8601 timestamp (with or without fractional seconds), matching
    /// the shape `isoTimestamp` writes.
    static func parseISOTimestamp(_ value: String) -> Date? {
        return NativeTimestampFormat.parseISO8601FractionalFirst(value)
    }

    // MARK: InboxItem builder

    private func _buildMorningBriefItem() async throws -> JSONValue {
        let id = uuid()
        let createdAt = Self.isoTimestamp(now())

        let packet = await MorningBriefSources(root: root, persistence: persistence, now: now(), worklogPath: worklogPath).packet()
        let built = try await callBrief(packet, as: MorningBriefProposal.self)

        let item: JSONValue = .object([
            "id": .string(id),
            "created_at": .string(createdAt),
            "source": .string("trigger:morning_brief"),
            "presentation": built.presentation,
            "severity": .string("important"),
            "title": .string(built.title),
            "summary": .string(built.summary),
            "detail": built.detail,
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .null,
            "related_groups": .null,
            "actions": built.actions,
            "status": .string("unread"),
            "read_at": .null,
        ])
        return item
    }

    /// Same shape as ApprovalInbox stamps.
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

    // MARK: Authored brief and inactive defaults

    private func callBrief<Value: Decodable>(_ input: JSONValue, as: Value.Type) async throws -> Value {
        guard let morningBriefPart else {
            throw TriggerSchedulerError.persistenceFailure("The native-morning-brief part has no originating app door.")
        }
        let value = try await morningBriefPart(input)
        return try JSONDecoder().decode(Value.self, from: value.serializedData(pretty: false))
    }

    private func defaults() async throws -> MorningBriefDefaults {
        var value = try await callBrief(.object(["operation": .string("defaults")]), as: MorningBriefDefaults.self)
        // A seed is behaviour, never consent. Only an explicit enable mutation
        // can activate a schedule; existing saved rows remain untouched.
        func inactive(_ rows: [JSONValue]) -> [JSONValue] {
            rows.map { row in
                guard case .object(var fields) = row else { return row }
                fields["enabled"] = .bool(false)
                return .object(fields)
            }
        }
        value.inbox = inactive(value.inbox)
        value.workshop = inactive(value.workshop)
        return value
    }
}
