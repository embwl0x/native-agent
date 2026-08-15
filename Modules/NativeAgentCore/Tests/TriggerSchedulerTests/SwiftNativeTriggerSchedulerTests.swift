import Testing
import Foundation
@testable import TriggerScheduler
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TriggerSchedulerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Seeds the LEGACY `<root>/inbox/trigger_config.json` location on purpose:
/// every test that seeds here also exercises the 2026-08-13 lazy migration
/// (copy-forward to `<root>/triggers/`) before the behavior under test.
/// Steady-state reads of the new path are covered implicitly — after the first
/// scheduler call the file lives at `triggers/` and later calls read it there.
private func seedInbox(_ records: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("trigger_config.json")
    let data = try JSONValue.array(records).serializedData(pretty: true)
    try data.write(to: path)
}

private func seedWorkshopExecutions(_ records: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("workshop", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("triggers.json")
    let data = try JSONValue.array(records).serializedData(pretty: true)
    try data.write(to: path)
}

/// Reads the NEW `<root>/triggers/trigger_config.json` home — mutation writes
/// land there after the relocation.
private func readInboxRaw(root: URL) throws -> [JSONValue] {
    let url = root
        .appendingPathComponent("triggers", isDirectory: true)
        .appendingPathComponent("trigger_config.json")
    let data = try Data(contentsOf: url)
    guard case .array(let arr) = try JSONValue.parse(data) else { return [] }
    return arr
}

private func readWorkshopExecutionsRaw(root: URL) throws -> [JSONValue] {
    let url = root
        .appendingPathComponent("workshop", isDirectory: true)
        .appendingPathComponent("triggers.json")
    let data = try Data(contentsOf: url)
    guard case .array(let arr) = try JSONValue.parse(data) else { return [] }
    return arr
}

/// HERMETIC BY DEFAULT: `worklogPath` points inside the temp root at a file
/// that does not exist, so a test never reads the developer's real
/// ~/.claude/state/claude-worklog.jsonl and a "bare root" brief is genuinely
/// bare. Tests that want worklog content pass a seeded path.
private func makeClient(
    root: URL,
    now: @escaping @Sendable () -> Date = { Date() },
    uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
    workshopRunner: (any WorkshopRunnerClient)? = nil,
    notifier: TriggerNotifier? = nil,
    worklogPath: URL? = nil
) -> SwiftNativeTriggerScheduler {
    SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        workshopRunner: workshopRunner,
        now: now,
        uuid: uuid,
        notifier: notifier,
        worklogPath: worklogPath ?? root.appendingPathComponent("no-such-worklog.jsonl")
    )
}

/// Runner with the executor gate explicitly opened, mirroring the scheduler's
/// default wiring otherwise — for tests that exercise the enqueue MECHANICS.
/// Since the executor port (2026-06-10) the production default is ALREADY
/// executorAvailable=true (see `fireMissionDefaultRunnerEnqueues`); the
/// explicit `true` is kept so these tests stay pinned to the mechanics
/// independent of the default. `fireMissionExplicitlyGatedRunnerRefuses`
/// covers the constructor-false gate.
private func makeEnqueueCapableRunner(root: URL) -> SwiftNativeWorkshopRunner {
    SwiftNativeWorkshopRunner(
        executorAvailable: true,
        root: root,
        persistence: SwiftNativePersistenceCore()
    )
}

private func readInboxItemsJSONL(root: URL) throws -> [JSONValue] {
    let url = root
        .appendingPathComponent("inbox", isDirectory: true)
        .appendingPathComponent("items.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    var out: [JSONValue] = []
    for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        out.append(try JSONValue.parse(Data(trimmed.utf8)))
    }
    return out
}

/// The LIVE inbox — `<root>/notifications/inbox.jsonl`, the one store the Mac
/// UI, getInboxItems and the iOS snapshot read, and the ONLY place a fired card
/// lands since A5.2 retired the `<root>/inbox/` silo.
///
/// Append-only JSONL with LAST-WRITE-WINS PER id: a status change appends a
/// full replacement row carrying the same id. Collapse to the final row per id
/// (first-seen order) exactly the way `ProactiveInboxStore.activeDuplicateId`
/// does, so a card counts ONCE no matter how many revisions it has.
private func readLiveInbox(root: URL) throws -> [JSONValue] {
    let url = root
        .appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    var order: [String] = []
    var latest: [String: JSONValue] = [:]
    for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        let row = try JSONValue.parse(Data(trimmed.utf8))
        guard let id = str(obj(row)?["id"]), !id.isEmpty else { continue }
        if latest[id] == nil { order.append(id) }
        latest[id] = row
    }
    return order.compactMap { latest[$0] }
}

/// Append ONE row to the live inbox, the way the app-side seam
/// (`TriggerNotifierBinding.mirrorCardIntoRealInbox`) does. Used both to seed
/// duplicate fixtures and by the card-landing notifier below.
private func appendLiveInboxRow(_ row: JSONValue, root: URL) throws {
    let dir = root.appendingPathComponent("notifications", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("inbox.jsonl")
    var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    let encoded = String(data: try row.serializedData(pretty: false), encoding: .utf8) ?? "{}"
    text += encoded + "\n"
    try Data(text.utf8).write(to: url)
}

/// Core has NO app seam, so a test that needs fired cards to LAND must simulate
/// the production contract itself: `TriggerNotifierBinding.pairedDevicePush`
/// mirrors `note.item` into `<root>/notifications/inbox.jsonl` (normalized —
/// id / status=unread / read_at=null / created_at) BEFORE it knocks, and
/// returns the delivery fields. This is that seam, minus the push.
private func cardLandingNotifier(root: URL) -> TriggerNotifier {
    { note in
        guard case .object(var card) = note.item,
              let id = str(card["id"]), !id.isEmpty else { return .null }
        if card["status"] == nil { card["status"] = .string("unread") }
        if card["read_at"] == nil { card["read_at"] = .null }
        if card["created_at"] == nil {
            card["created_at"] = .string(SwiftNativeTriggerScheduler.isoTimestamp(Date()))
        }
        do { try appendLiveInboxRow(.object(card), root: root) } catch { return .null }
        return .object([
            "status": .string("accepted"),
            "route": .string("apns"),
            "apnsAccepted": .bool(true),
        ])
    }
}

private func obj(_ v: JSONValue) -> [String: JSONValue]? {
    if case .object(let o) = v { return o }
    return nil
}
private func str(_ v: JSONValue?) -> String? {
    if case .string(let s) = v ?? .null { return s }
    return nil
}

private func inboxSurfaceItem(
    id: String,
    source: String,
    title: String,
    summary: String,
    createdAt: String,
    status: String = "unread"
) -> JSONValue {
    .object([
        "id": .string(id),
        "created_at": .string(createdAt),
        "source": .string(source),
        "severity": .string("info"),
        "title": .string(title),
        "summary": .string(summary),
        "detail": .null,
        "related_mission_id": .null,
        "related_approval_id": .null,
        "related_paths": .null,
        "related_groups": .null,
        "actions": .array([]),
        "status": .string(status),
        "read_at": .null,
    ])
}

// MARK: - Default seeding

@Suite("SwiftNativeTriggerScheduler: defaults")
struct DefaultsSuite {
    @Test func listInboxReturnsDefaultsWhenFileMissing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeClient(root: root)
        let configs = try await client.listInboxTriggers()
        // Default order: file_watch, idle_checkin, morning_brief,
        // execution_followup (P2-4; `mission_followup` before 0.3.8),
        // stuck_pattern.
        #expect(configs.count == 5)
        #expect(configs.map(\.name) == ["file_watch", "idle_checkin", "morning_brief", "execution_followup", "stuck_pattern"])
        // Enabled by default: morning_brief (L5 G2 — the one proactive lane
        // that ships lit) and execution_followup. Everything else is opt-in.
        let enabled = configs.filter(\.enabled).map(\.name)
        #expect(enabled == ["morning_brief", "execution_followup"])
    }

    @Test func listWorkshopExecutionsReturnsDefaultsWhenFileMissing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeClient(root: root)
        let configs = try await client.listWorkshopTriggers()
        #expect(configs.count == 1)
        #expect(configs[0].name == "morning_brief")
        #expect(configs[0].enabled == false)
        #expect(configs[0].kind == "time")
    }
}

// MARK: - Round-trip persistence (daemon byte shape)

@Suite("SwiftNativeTriggerScheduler: round-trip persistence")
struct RoundTripSuite {
    @Test func enableInboxFlipsAndPersists() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "kind": .string("file_watch"),
                "enabled": .bool(false),
                "config": .object(["paths": .array([])]),
                "description": .string("Watch files for changes and summarize what changed."),
            ]),
        ], root: root)
        let client = makeClient(root: root)

        let st = try await client.enableInboxTrigger(name: "file_watch")
        #expect(st.name == "file_watch")
        #expect(st.enabled == true)
        #expect(st.status == "updated")

        // Re-read from disk and verify the bit flipped + shape preserved.
        let raw = try readInboxRaw(root: root)
        #expect(raw.count == 1)
        guard case .object(let obj) = raw[0] else { Issue.record("entry not an object"); return }
        #expect(obj["enabled"] == .bool(true))
        #expect(obj["name"] == .string("file_watch"))
        // Description and config carried through untouched.
        #expect(obj["description"] == .string("Watch files for changes and summarize what changed."))
        if case .object(let cfg) = obj["config"] ?? .null {
            #expect(cfg["paths"] == .array([]))
        } else {
            Issue.record("config should be an object")
        }
    }

    @Test func disableWorkshopExecutionFlipsAndPersists() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "config": .object(["hour": .int(8), "minute": .int(0)]),
                "objective": .string("Read calendar + email summary, draft a morning brief"),
                "title": .string("Morning Brief"),
                "trust_required": .string("send_approval"),
                "enabled": .bool(true),
            ]),
        ], root: root)
        let client = makeClient(root: root)

        let st = try await client.disableWorkshopTrigger(name: "morning_brief")
        #expect(st.status == "updated")
        #expect(st.enabled == false)

        let raw = try readWorkshopExecutionsRaw(root: root)
        #expect(raw.count == 1)
        guard case .object(let obj) = raw[0] else { Issue.record("entry not an object"); return }
        #expect(obj["enabled"] == .bool(false))
        // Critical: the executions-shape extras (objective/title/trust_required)
        // must round-trip — these are the fields daemon's TriggerScheduler
        // reads to build the Execution. Dropping them would silently break
        // the morning_brief execution.
        #expect(obj["objective"] == .string("Read calendar + email summary, draft a morning brief"))
        #expect(obj["title"] == .string("Morning Brief"))
        #expect(obj["trust_required"] == .string("send_approval"))
    }

    @Test func unknownNameReturnsNotFoundAndDoesNotMutate() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "kind": .string("file_watch"),
                "enabled": .bool(false),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let st = try await client.enableInboxTrigger(name: "no_such_trigger")
        #expect(st.status == "not_found")
        #expect(st.name == "no_such_trigger")
        // On-disk file unchanged — file_watch still disabled.
        let raw = try readInboxRaw(root: root)
        guard case .object(let obj) = raw[0] else { Issue.record("entry not an object"); return }
        #expect(obj["enabled"] == .bool(false))
    }
}

// MARK: - Configure (shallow-merge)

@Suite("SwiftNativeTriggerScheduler: configure")
struct ConfigureSuite {
    @Test func configureMergesIntoExistingConfig() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("idle_checkin"),
                "kind": .string("idle"),
                "enabled": .bool(false),
                "config": .object([
                    "idle_minutes": .int(30),
                    "quiet_start_hour": .int(23),
                    "quiet_end_hour": .int(8),
                ]),
                "description": .string("Check in after a period of silence."),
            ]),
        ], root: root)
        let client = makeClient(root: root)

        // Update only idle_minutes; quiet_* keys should survive.
        let new: JSONValue = .object(["idle_minutes": .int(60)])
        let st = try await client.configureInboxTrigger(name: "idle_checkin", config: new)
        #expect(st.status == "updated")
        #expect(st.name == "idle_checkin")

        let raw = try readInboxRaw(root: root)
        guard case .object(let obj) = raw[0] else { Issue.record("entry not an object"); return }
        if case .object(let cfg) = obj["config"] ?? .null {
            #expect(cfg["idle_minutes"] == .int(60))
            #expect(cfg["quiet_start_hour"] == .int(23))
            #expect(cfg["quiet_end_hour"] == .int(8))
        } else {
            Issue.record("config should be an object after merge")
        }
    }

    @Test func configureRejectsNonObjectPayload() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "enabled": .bool(false),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        do {
            _ = try await client.configureInboxTrigger(name: "file_watch", config: .array([]))
            Issue.record("configure should reject non-object payload")
        } catch TriggerSchedulerError.invalidRequest {
            // expected
        } catch {
            Issue.record("expected invalidRequest, got \(error)")
        }
    }

    @Test func configureWatchedPathsRoundtripsArray() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "kind": .string("file_watch"),
                "enabled": .bool(false),
                "config": .object(["paths": .array([])]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let new: JSONValue = .object(["paths": .array([
            .string("/Users/example/Projects/foo"),
            .string("/Users/example/Projects/bar"),
        ])])
        _ = try await client.configureInboxTrigger(name: "file_watch", config: new)
        let raw = try readInboxRaw(root: root)
        guard case .object(let obj) = raw[0],
              case .object(let cfg) = obj["config"] ?? .null,
              case .array(let paths) = cfg["paths"] ?? .null else {
            Issue.record("paths array missing on disk"); return
        }
        #expect(paths.count == 2)
        #expect(paths[0] == .string("/Users/example/Projects/foo"))
    }
}

// MARK: - Fire_now native paths

@Suite("SwiftNativeTriggerScheduler: fire_now Swift-native (wave 12)")
struct FireCarveSuite {

    // ── Inbox: per-kind native stub items ────────────────────────────────

    @Test func fireInboxFileWatchRefusesFabricatedPlaceholder() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "kind": .string("file_watch"),
                "enabled": .bool(true),
                "config": .object(["paths": .array([])]),
            ]),
        ], root: root)
        let client = makeClient(root: root)

        let result = try await client.fireInboxTrigger(name: "file_watch", isStub: true)
        #expect(result.status == "error")
        #expect(result.name == "file_watch")
        #expect(result.stub == false)
        #expect(result.item == nil)
        #expect((result.error ?? "").contains("evidence-backed content path is unavailable"))
        #expect(try readInboxItemsJSONL(root: root).isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("inbox/items.jsonl").path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("inbox/index.json").path))
    }

    @Test func fireInboxStubIdleSurfacesNativeItem() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("idle_checkin"),
                "kind": .string("idle"),
                "enabled": .bool(true),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireInboxTrigger(name: "idle_checkin", isStub: true)
        #expect(result.status == "fired")
        guard let o = obj(try #require(result.item)) else { Issue.record("no item"); return }
        #expect(str(o["title"]) == "Idle check-in")
        #expect(str(o["source"]) == "idle_checkin")
        #expect(str(o["severity"]) == "info")
        // DELIBERATE CHANGE (2026-07-09): idle_checkin no longer emits a stub
        // string, and `stub` no longer claims it does. This bare temp root has
        // no chat/sessions.json, so there is no activity signal and the honest
        // answer is that the quiet can't be measured. Real content, real limits.
        #expect(str(o["summary"]) == "You've been quiet — I can't tell how long (no recorded session activity).")
        #expect(!(str(o["summary"]) ?? "").contains("Stub"))
        #expect(result.stub == false)
    }

    @Test func fireInboxStubMorningBriefSurfacesNativeItem() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["hour": .int(8), "minute": .int(0)]),
            ]),
        ], root: root)
        // Pin clock to Fri Mar 5 2026 09:00 local for a deterministic label.
        let comps = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone.current,
            year: 2026, month: 3, day: 5, hour: 9, minute: 0
        )
        let fixed = Calendar(identifier: .gregorian).date(from: comps)!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "EEEE, MMMM d"
        let label = fmt.string(from: fixed)
        let client = makeClient(root: root, now: { fixed })
        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.status == "fired")
        guard let o = obj(try #require(result.item)) else { Issue.record("no item"); return }
        #expect(str(o["severity"]) == "important")
        #expect(str(o["title"]) == "Morning brief — \(label)")
        // DELIBERATE CHANGE (2026-07-09): the brief carries REAL content now.
        // Under a bare temp root (no desk, no executions, no inbox, no sessions)
        // with the worklog seam pointed at a nonexistent file, every section
        // fails open and the summary states that plainly. It is a true claim
        // about real state — not a placeholder — so `stub` is false.
        #expect(str(o["summary"]) == "Morning brief for \(label) — nothing new since yesterday.")
        #expect(!(str(o["summary"]) ?? "").contains("Stub"))
        #expect(result.stub == false)
    }

    @Test func fireInboxWorkshopFollowupRefusesFabricatedPlaceholder() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("mission_followup"),
                "kind": .string("mission_complete"),
                "enabled": .bool(true),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireInboxTrigger(name: "mission_followup", isStub: true)
        #expect(result.status == "error")
        #expect(result.stub == false)
        #expect(result.item == nil)
        #expect((result.error ?? "").contains("evidence-backed content path is unavailable"))
    }

    @Test func fireInboxStuckPatternRefusesFabricatedPlaceholder() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("stuck_pattern"),
                "kind": .string("session_pattern"),
                "enabled": .bool(true),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireInboxTrigger(name: "stuck_pattern", isStub: true)
        #expect(result.status == "error")
        #expect(result.stub == false)
        #expect(result.item == nil)
        #expect((result.error ?? "").contains("evidence-backed content path is unavailable"))
    }

    // -- Inbox: non-stub is explicit unsupported until the native live path lands --

    @Test func fireInboxNonStubWithoutFallbackReturnsUnsupportedEnvelope() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "kind": .string("file_watch"),
                "enabled": .bool(true),
                "config": .object(["paths": .array([])]),
            ]),
        ], root: root)
        let client = SwiftNativeTriggerScheduler(
            root: root,
            persistence: SwiftNativePersistenceCore()
        )
        let result = try await client.fireInboxTrigger(name: "file_watch", isStub: false)
        #expect(result.status == "error")
        #expect(result.name == "file_watch")
        #expect(result.stub == false)
        #expect(result.error == "non-stub inbox trigger firing is not yet Swift-native")
        let items = try readInboxItemsJSONL(root: root)
        #expect(items.isEmpty)
    }

    @Test func fireInboxUnknownNameReturnsNotFound() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "kind": .string("file_watch"),
                "enabled": .bool(false),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireInboxTrigger(name: "no_such", isStub: true)
        #expect(result.status == "not_found")
        #expect(result.name == "no_such")
        let items = try readInboxItemsJSONL(root: root)
        #expect(items.isEmpty)
    }

    // ── Execution: native enqueue (WAVE 21) ────────────────────────────────
    //
    // Execution fire_now now calls SwiftNativeWorkshopRunner.submit() in-process.
    // The factory makeTriggerScheduler threads the production execution runner
    // through makeWorkshopRunner() so this path uses the real planner instead of
    // the SwiftNativeWorkshopRunner test stub default.

    @Test func fireWorkshopExecutionNativeWritesWorkshopExecutionAndTimeline() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "config": .object(["hour": .int(8)]),
                "objective": .string("Read calendar"),
                "title": .string("Morning Brief"),
                "trust_required": .string("send_approval"),
                "enabled": .bool(true),
            ]),
        ], root: root)
        let client = makeClient(root: root, workshopRunner: makeEnqueueCapableRunner(root: root))
        let result = try await client.fireWorkshopTrigger(name: "morning_brief")
        #expect(result.status == "fired")
        #expect(result.name == "morning_brief")
        #expect(result.executionId != nil)
        let deskHandle = try #require(result.deskHandle)
        let deskState = try await SwiftNativeDeskStore(dataRoot: root).liveState()
        let deskItem = try #require(deskState.items.first { $0.handle == deskHandle })
        #expect(deskItem.origin == .owner)
        #expect(deskItem.project == "Scheduled Workshop")
        #expect(deskItem.status == .now)
        if let id = result.executionId {
            // Native path writes <root>/workshop/executions/<id>/execution.json
            // and timeline.jsonl (timeline FIRST per wave-21 ordering fix).
            let workshopExecutionDir = root
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("executions", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: workshopExecutionDir.appendingPathComponent("execution.json").path))
            #expect(FileManager.default.fileExists(atPath: workshopExecutionDir.appendingPathComponent("timeline.jsonl").path))
            let workshopExecutionData = try Data(contentsOf: workshopExecutionDir.appendingPathComponent("execution.json"))
            guard case .object(let workshopExecutionObject) = try JSONValue.parse(workshopExecutionData) else {
                Issue.record("execution.json is not an object"); return
            }
            #expect(workshopExecutionObject["desk_handle"] == .string(deskHandle))
        }
    }

    // ── Execution: default-runner executor gate (2026-06-10) ──────────────
    //
    // NEW CONTRACT (executor port, 2026-06-10): the scheduler's DEFAULT
    // runner now has executorAvailable=true — WorkshopExecutorLoop drains the
    // queue — so an execution trigger fire ENQUEUES. The constructor-false test
    // below proves the honest-refusal gate still works when explicitly off.

    @Test func fireWorkshopExecutionDefaultRunnerEnqueues() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "config": .object(["hour": .int(8)]),
                "objective": .string("Read calendar"),
                "title": .string("Morning Brief"),
                "trust_required": .string("send_approval"),
                "enabled": .bool(true),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireWorkshopTrigger(name: "morning_brief")
        #expect(result.status == "fired")
        let executionId = try #require(result.executionId)
        let workshopExecutionDir = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
            .appendingPathComponent(executionId, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: workshopExecutionDir.appendingPathComponent("execution.json").path))
        #expect(FileManager.default.fileExists(atPath: workshopExecutionDir.appendingPathComponent("timeline.jsonl").path))
    }

    @Test func fireWorkshopExecutionExplicitlyGatedRunnerRefuses() async throws {
        // executorAvailable: false (explicit opt-out — no executor loop
        // registered) must still surface the typed refusal as an honest
        // error envelope and write NOTHING to the queue.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "config": .object(["hour": .int(8)]),
                "objective": .string("Read calendar"),
                "title": .string("Morning Brief"),
                "trust_required": .string("send_approval"),
                "enabled": .bool(true),
            ]),
        ], root: root)
        let gatedRunner = SwiftNativeWorkshopRunner(
            executorAvailable: false,
            root: root,
            persistence: SwiftNativePersistenceCore()
        )
        let client = makeClient(root: root, workshopRunner: gatedRunner)
        let result = try await client.fireWorkshopTrigger(name: "morning_brief")
        #expect(result.status == "error")
        #expect(result.executionId == nil)
        let refusedDesk = try await SwiftNativeDeskStore(dataRoot: root).liveState()
        #expect(refusedDesk.items.count == 1)
        #expect(refusedDesk.items[0].status == .blocked)
        #expect(result.error?.contains("Workshop executor unavailable") == true)
        let queueDir = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: queueDir.path))
    }

    @Test func fireWorkshopExecutionUnknownNameReturnsNotFound() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "config": .object([:]),
                "objective": .string("x"),
                "enabled": .bool(false),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireWorkshopTrigger(name: "nope")
        #expect(result.status == "not_found")
        #expect(result.name == "nope")
    }

    @Test func fireInboxStubFileWatchRefusesToInventChangeEvidence() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("file_watch"),
                "kind": .string("file_watch"),
                "enabled": .bool(true),
                "config": .object(["paths": .array([
                    .string("/Users/example/Projects/foo/main.swift"),
                    .string("/Users/example/Projects/bar/util.swift"),
                ])]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireInboxTrigger(name: "file_watch", isStub: true)
        #expect(result.status == "error")
        #expect(result.item == nil)
        #expect(result.error?.contains("evidence-backed content path is unavailable") == true)
    }

    @Test func fireInboxStubUnknownKindReturnsNotFound() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("weird_trigger"),
                "kind": .string("not_a_canonical_kind"),
                "enabled": .bool(true),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireInboxTrigger(name: "weird_trigger", isStub: true)
        #expect(result.status == "not_found")
        #expect(result.name == "weird_trigger")
        let items = try readInboxItemsJSONL(root: root)
        #expect(items.isEmpty)
    }
}

/// A5.2: `surface()` WRITES NOTHING. It runs the 7-day active-duplicate check
/// against the LIVE inbox (`<root>/notifications/inbox.jsonl`) and returns the
/// EXISTING card's id on a duplicate, else the candidate's own id. So these
/// tests seed the duplicate by appending rows to the live inbox directly — the
/// way the app-side notifier seam does — instead of by calling surface() twice.
@Suite("ProactiveInboxStore: quality gate")
struct ProactiveInboxQualityGateSuite {
    @Test func duplicateActiveProactiveCardReturnsExistingId() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProactiveInboxStore(root: root, persistence: SwiftNativePersistenceCore())

        // An ACTIVE (unread) card already sitting in the live inbox.
        try appendLiveInboxRow(inboxSurfaceItem(
            id: "first",
            source: "proactive_autonomy:inbox_digest:opp-1",
            title: "Inbox digest",
            summary: "Three open items need attention.",
            createdAt: "2026-06-20T10:00:00Z"
        ), root: root)

        let second = try await store.surface(inboxSurfaceItem(
            id: "second",
            source: "proactive_autonomy:inbox_digest:opp-1",
            title: "Inbox digest",
            summary: "Three open items need attention.",
            createdAt: "2026-06-20T10:05:00Z"
        ))

        #expect(second == "first")
        // surface() is READ-ONLY now: no new row, and the legacy silo is dead.
        let rows = try readLiveInbox(root: root)
        #expect(rows.count == 1)
        #expect(str(obj(rows[0])?["id"]) == "first")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    @Test func archivedDuplicateDoesNotBlockFreshOpportunity() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProactiveInboxStore(root: root, persistence: SwiftNativePersistenceCore())

        try appendLiveInboxRow(inboxSurfaceItem(
            id: "old",
            source: "idle_checkin",
            title: "Idle check-in",
            summary: "You have been quiet.",
            createdAt: "2026-06-20T10:00:00Z"
        ), root: root)
        // LAST-WRITE-WINS: a status change appends a FULL replacement row with
        // the SAME id. The collapse must see `archived`, not the earlier unread.
        try appendLiveInboxRow(inboxSurfaceItem(
            id: "old",
            source: "idle_checkin",
            title: "Idle check-in",
            summary: "You have been quiet.",
            createdAt: "2026-06-20T10:00:00Z",
            status: "archived"
        ), root: root)

        let fresh = try await store.surface(inboxSurfaceItem(
            id: "fresh",
            source: "idle_checkin",
            title: "Idle check-in",
            summary: "You have been quiet.",
            createdAt: "2026-06-20T10:05:00Z"
        ))

        #expect(fresh == "fresh")
        // Collapsed by id: two rows on disk, ONE card, and it is archived.
        let rows = try readLiveInbox(root: root)
        #expect(rows.count == 1)
        #expect(str(obj(rows[0])?["status"]) == "archived")
    }

    /// NEW PIN (A5.2): `dismissed` is the other terminal status a replacement
    /// row can carry. Only `unread`/`read` count as active, so a dismissed card
    /// must not block a fresh one either.
    @Test func dismissedDuplicateDoesNotBlockFreshOpportunity() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProactiveInboxStore(root: root, persistence: SwiftNativePersistenceCore())

        try appendLiveInboxRow(inboxSurfaceItem(
            id: "old",
            source: "trigger:stuck_pattern",
            title: "We might be circling",
            summary: "Want to step back?",
            createdAt: "2026-06-20T10:00:00Z"
        ), root: root)
        try appendLiveInboxRow(inboxSurfaceItem(
            id: "old",
            source: "trigger:stuck_pattern",
            title: "We might be circling",
            summary: "Want to step back?",
            createdAt: "2026-06-20T10:00:00Z",
            status: "dismissed"
        ), root: root)

        let fresh = try await store.surface(inboxSurfaceItem(
            id: "fresh",
            source: "trigger:stuck_pattern",
            title: "We might be circling",
            summary: "Want to step back?",
            createdAt: "2026-06-20T10:05:00Z"
        ))

        #expect(fresh == "fresh")
        // Sanity: the SAME fixture still deduped while it was unread — so the
        // fresh id above is the dismissal doing the work, not a broken key.
        let stillActive = try await store.surface(inboxSurfaceItem(
            id: "other",
            source: "trigger:stuck_pattern",
            title: "We might be circling",
            summary: "Want to step back?",
            createdAt: "2026-06-20T10:05:00Z",
            status: "unread"
        ))
        #expect(stillActive == "other")
    }

    @Test func staleDuplicateDoesNotBlockFreshOpportunity() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProactiveInboxStore(root: root, persistence: SwiftNativePersistenceCore())

        // Active + identical, but 19 days older than the candidate → outside
        // the 7-day window, so it must NOT suppress the fresh card.
        try appendLiveInboxRow(inboxSurfaceItem(
            id: "old",
            source: "trigger:stuck_pattern",
            title: "We might be circling",
            summary: "Want to step back?",
            createdAt: "2026-06-01T10:00:00Z"
        ), root: root)

        let fresh = try await store.surface(inboxSurfaceItem(
            id: "fresh",
            source: "trigger:stuck_pattern",
            title: "We might be circling",
            summary: "Want to step back?",
            createdAt: "2026-06-20T10:00:00Z"
        ))
        #expect(fresh == "fresh")

        // Inside the window, the same fixture DOES suppress — proving the
        // fresh id above comes from staleness, not a mismatched key.
        let withinWindow = try await store.surface(inboxSurfaceItem(
            id: "soon",
            source: "trigger:stuck_pattern",
            title: "We might be circling",
            summary: "Want to step back?",
            createdAt: "2026-06-03T10:00:00Z"
        ))
        #expect(withinWindow == "old")
    }
}

// MARK: - Cross-process flock (concurrent enable + read)

@Suite("SwiftNativeTriggerScheduler: cross-process flock")
struct FlockSuite {
    /// Concurrent enable + list under the cross-process flock: every read
    /// after the write must see the post-write state, and the on-disk JSON
    /// must never be torn (no partial writes, no missing keys).
    /// This isn't a true cross-process test (single process), but it
    /// exercises the actor + flock R-M-W path under contention.
    @Test func concurrentEnableAndReadStaysConsistent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
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
                "config": .object([:]),
                "description": .string("Check in after a period of silence."),
            ]),
        ], root: root)
        let client = makeClient(root: root)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                let enable = (i % 2 == 0)
                group.addTask {
                    if enable {
                        _ = try? await client.enableInboxTrigger(name: "file_watch")
                    } else {
                        _ = try? await client.disableInboxTrigger(name: "file_watch")
                    }
                }
                group.addTask {
                    let configs = (try? await client.listInboxTriggers()) ?? []
                    // The list must always be parseable (no torn JSON).
                    #expect(configs.count == 2)
                }
            }
        }
        // Final state on disk parses cleanly.
        let raw = try readInboxRaw(root: root)
        #expect(raw.count == 2)
        // Both rows have all the expected keys (no torn write dropped them).
        for entry in raw {
            guard case .object(let obj) = entry else { Issue.record("torn entry"); continue }
            #expect(obj["name"] != nil)
            #expect(obj["enabled"] != nil)
            #expect(obj["config"] != nil)
        }
    }
}

// MARK: - Factory + flag

@Suite("makeTriggerScheduler: factory")
struct FactorySuite {
    @Test func factoryReturnsSwiftNative() {
        let client = makeTriggerScheduler()
        #expect(client is SwiftNativeTriggerScheduler)
    }

    @Test func factoryThreadsInjectedRootIntoSchedulerOwner() throws {
        let root = try makeTempRoot().standardizedFileURL
        let scheduler = try #require(
            makeTriggerScheduler(dataRoot: root) as? SwiftNativeTriggerScheduler
        )

        #expect(scheduler.inboxPath == root
            .appendingPathComponent("triggers", isDirectory: true)
            .appendingPathComponent("trigger_config.json"))
        #expect(scheduler.workshopExecutionsPath == root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("triggers.json"))
    }
}

// MARK: - Wave 21 review fixes (FIX #1 + FIX #5)
// Fix 8: FIX #1 test rewritten. The old test verified that executions delegate
// to another runtime. Workshop execution
// always proceed native — there is no Python delegate path. The test is
// rewritten as 'executions always proceed native' per the task spec.

@Suite("SwiftNativeTriggerScheduler: wave 21 review fixes")
struct Wave21ReviewFixSuite {
    /// Fix 8 rewrite of FIX #1: executions always proceed native (cutover complete).
    /// The old 'delegates to Python when flag off' assertion is replaced by
    /// 'fireMissionTrigger takes the SwiftNative enqueue path unconditionally'.
    @Test func fireWorkshopExecutionAlwaysProceedsNative() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            .object([
                "name": .string("morning_brief"),
                "kind": .string("time"),
                "config": .object([:]),
                "objective": .string("Read calendar"),
                "title": .string("Morning Brief"),
                "trust_required": .string("send_approval"),
                "enabled": .bool(true),
            ]),
        ], root: root)
        // Fix 8: no runtime: param in makeClient. Enqueue-mechanics test →
        // gate-open runner (the default refuses until the executor port).
        let client = makeClient(root: root, workshopRunner: makeEnqueueCapableRunner(root: root))
        let result = try await client.fireWorkshopTrigger(name: "morning_brief")
        // Workshop always proceed native — status is "fired" with a native Workshop execution id.
        #expect(result.status == "fired")
        // The execution id is non-nil and not the Python sentinel.
        #expect(result.executionId != nil)
        #expect(result.executionId != "py-delegated-mid")
        // A native Workshop execution record WAS written to disk.
        let queueDir = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        if FileManager.default.fileExists(atPath: queueDir.path) {
            let children = (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil)) ?? []
            #expect(!children.isEmpty, "native enqueue should have written execution.json")
        }
    }

    /// FIX #5: when the trigger row has NO title key (missing entirely),
    /// the spec title must default to "" (matching Python's
    /// `str(item.get("title", ""))`), not to row.name. If objective is also
    /// missing the call returns the missing_objective error envelope.
    @Test func fireWorkshopExecutionMissingTitleDefaultsToEmptyString() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No "title", no "objective", no "trust_required" extras — pure defaults.
        try seedWorkshopExecutions([
            .object([
                "name": .string("bare_trigger"),
                "kind": .string("time"),
                "config": .object([:]),
                "enabled": .bool(true),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let result = try await client.fireWorkshopTrigger(name: "bare_trigger")
        // Objective missing → Python raises missing_objective. Swift mirrors as error envelope.
        #expect(result.status == "error")
        #expect(result.error == "missing_objective")
        #expect(result.name == "bare_trigger")
        // No Workshop execution was written.
        let queueDir = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        if FileManager.default.fileExists(atPath: queueDir.path) {
            let children = (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil)) ?? []
            #expect(children.isEmpty)
        }
    }

    /// Companion to FIX #5: title defaults to "" but submit still proceeds
    /// when objective is present. The native enqueue writes execution.json
    /// with an empty title (not row.name).
    @Test func fireWorkshopExecutionMissingTitleEmptyTitlePersistedWhenObjectivePresent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            .object([
                "name": .string("bare_trigger"),
                "kind": .string("time"),
                "config": .object([:]),
                "objective": .string("Do the thing"),
                "enabled": .bool(true),
            ]),
        ], root: root)
        let client = makeClient(root: root, workshopRunner: makeEnqueueCapableRunner(root: root))
        let result = try await client.fireWorkshopTrigger(name: "bare_trigger")
        #expect(result.status == "fired")
        guard let id = result.executionId else { Issue.record("missionId nil"); return }
        let mj = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("execution.json")
        let data = try Data(contentsOf: mj)
        guard case .object(let o) = try JSONValue.parse(data) else {
            Issue.record("execution.json not object"); return
        }
        #expect(str(o["title"]) == "")
        #expect(str(o["objective"]) == "Do the thing")
    }
}

// MARK: - W3c: periodic self-fire (time kind + safety rails)

/// Mutable injected clock so a single test can advance wall-time between
/// evaluateAndFire() calls. Thread-safe box behind the @Sendable now closure.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func set(_ d: Date) { lock.lock(); _now = d; lock.unlock() }
}

/// Build a deterministic local wall-clock instant at Y/M/D H:M.
private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = 0
    return cal.date(from: dc)!
}

private func timeTrigger(
    name: String,
    hour: Int,
    minute: Int = 0,
    enabled: Bool = true,
    objective: String? = nil
) -> JSONValue {
    var obj: [String: JSONValue] = [
        "name": .string(name),
        "kind": .string("time"),
        "enabled": .bool(enabled),
        "config": .object(["hour": .int(Int64(hour)), "minute": .int(Int64(minute))]),
    ]
    if let objective { obj["objective"] = .string(objective) }
    return .object(obj)
}

private func readTriggerState(root: URL, surface: String) -> [String: JSONValue] {
    let url = root
        .appendingPathComponent(surface, isDirectory: true)
        .appendingPathComponent("trigger_state.json")
    guard let data = try? Data(contentsOf: url),
          case .object(let o) = (try? JSONValue.parse(data)) ?? .null else { return [:] }
    return o
}

@Suite("SwiftNativeTriggerScheduler: W3c periodic self-fire")
struct PeriodicFireSuite {

    // ── time trigger: not due before hour, due after, once per day ──────────

    @Test func timeTriggerNotDueBeforeScheduledHour() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        // 07:00 — before the 08:00 schedule.
        let clock = MutableClock(localDate(2026, 3, 5, 7, 0))
        let client = makeClient(root: root, now: { clock.now })

        let fired = await client.evaluateAndFire()
        #expect(fired.isEmpty)
        let itemsPath = root.appendingPathComponent("inbox/items.jsonl")
        #expect(!FileManager.default.fileExists(atPath: itemsPath.path))
    }

    @Test func timeTriggerFiresOnceAfterHourThenNotAgainSameDay() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 7, 0))
        // morning_brief resolves notify=true (per-name default), so the card
        // reaches the notifier — the seam that lands it in the live inbox in
        // production. Simulate that contract so the card COUNT is a real anchor.
        let client = makeClient(root: root, now: { clock.now },
                                notifier: cardLandingNotifier(root: root))

        // 07:00 — not yet due.
        #expect(await client.evaluateAndFire() == [])

        // 09:00 — past 08:00, never fired → due, fires exactly once.
        clock.set(localDate(2026, 3, 5, 9, 0))
        #expect(await client.evaluateAndFire() == ["morning_brief"])
        #expect(try readLiveInbox(root: root).count == 1)

        // last_fired_at persisted for this trigger.
        let state = readTriggerState(root: root, surface: "triggers")
        #expect(state["morning_brief"] != nil)

        // 09:30 same day — already fired today → NOT due again.
        clock.set(localDate(2026, 3, 5, 9, 30))
        #expect(await client.evaluateAndFire() == [])
        #expect(try readLiveInbox(root: root).count == 1)
        // The retired silo stayed dead through both ticks.
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    @Test func timeTriggerBecomesDueAgainNextDay() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([timeTrigger(name: "morning_brief", hour: 8, objective: "Read calendar")], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now }, workshopRunner: makeEnqueueCapableRunner(root: root))
        // The WORKSHOP morning_brief seeded above is the subject; the
        // default-enabled INBOX morning_brief (L5 G2) shares its name and
        // would double every fired list.
        _ = try await client.disableInboxTrigger(name: "morning_brief")

        // Day 1, 09:00 — due, fires.
        #expect(await client.evaluateAndFire() == ["morning_brief"])
        // Day 1, 10:00 — already fired.
        clock.set(localDate(2026, 3, 5, 10, 0))
        #expect(await client.evaluateAndFire() == [])
        // Day 2, 08:30 — new day, past 08:00, last fire was yesterday → due again.
        clock.set(localDate(2026, 3, 6, 8, 30))
        #expect(await client.evaluateAndFire() == ["morning_brief"])
    }

    // ── lastFiredAt survives a re-instantiated scheduler (no restart storm) ──

    @Test func lastFiredAtPersistsAcrossReinstantiation() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))

        // First scheduler instance fires. Both instances carry the card-landing
        // notifier, so the live-inbox count is an honest "fired once" anchor.
        let first = makeClient(root: root, now: { clock.now },
                               notifier: cardLandingNotifier(root: root))
        #expect(await first.evaluateAndFire() == ["morning_brief"])
        #expect(try readLiveInbox(root: root).count == 1)

        // Brand-new scheduler instance over the same root (simulates an app
        // restart). It must read the persisted last_fired_at and NOT re-fire.
        clock.set(localDate(2026, 3, 5, 9, 45))
        let second = makeClient(root: root, now: { clock.now },
                                notifier: cardLandingNotifier(root: root))
        #expect(await second.evaluateAndFire() == [])
        #expect(try readLiveInbox(root: root).count == 1)
    }

    // ── disabled trigger never self-fires ───────────────────────────────────

    @Test func disabledTimeTriggerNeverFires() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8, enabled: false)], root: root)
        // Well past the scheduled hour — only `enabled` keeps it dormant.
        let clock = MutableClock(localDate(2026, 3, 5, 12, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    // ── per-tick fire cap ───────────────────────────────────────────────────

    @Test func perTickFireCapEnforced() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Four DISTINCT Workshop execution time triggers, all due (each enqueues its own
        // Workshop execution — no inbox dedup collapsing them). Cap is 3.
        try seedWorkshopExecutions([
            timeTrigger(name: "brief_a", hour: 8, objective: "A"),
            timeTrigger(name: "brief_b", hour: 8, objective: "B"),
            timeTrigger(name: "brief_c", hour: 8, objective: "C"),
            timeTrigger(name: "brief_d", hour: 8, objective: "D"),
        ], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now }, workshopRunner: makeEnqueueCapableRunner(root: root))

        let fired = await client.evaluateAndFire()
        // At most the cap fires this tick.
        #expect(fired.count == 3)
    }

    // ── unparseable schedule stays dormant (no crash) ───────────────────────

    @Test func timeTriggerWithMissingHourStaysDormant() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // config has no `hour` key at all → schedule cannot be parsed.
        try seedInbox([
            .object([
                "name": .string("broken_time"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["minute": .int(0)]),
            ]),
        ], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 12, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    @Test func timeTriggerWithOutOfRangeHourStaysDormant() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "bad_hour", hour: 99)], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 12, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
    }

    // ── dark kinds do not self-fire even when enabled ───────────────────────

    @Test func darkKindsDoNotSelfFire() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object(["name": .string("idle_checkin"), "kind": .string("idle"),
                     "enabled": .bool(true), "config": .object(["idle_minutes": .int(1)])]),
            .object(["name": .string("file_watch"), "kind": .string("file_watch"),
                     "enabled": .bool(true), "config": .object(["paths": .array([])])]),
            .object(["name": .string("mission_followup"), "kind": .string("mission_complete"),
                     "enabled": .bool(true), "config": .object([:])]),
            .object(["name": .string("stuck_pattern"), "kind": .string("session_pattern"),
                     "enabled": .bool(true), "config": .object(["min_turns_in_register": .int(1)])]),
        ], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 12, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }
}

// MARK: - W3c review fixes (atomic claim, corrupt-state, clock-backwards, fractional hour, cap-next-tick)

@Suite("SwiftNativeTriggerScheduler: W3c review fixes")
struct PeriodicFireReviewFixSuite {

    // ── Finding 1: due-check + fired-claim atomic → EXACTLY one of two
    //    overlapping scheduler instances fires the same occurrence ───────────
    @Test func twoSchedulersOverSameStateExactlyOneFires() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        // 09:00 — past the 08:00 schedule, never fired → due for both.
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let a = makeClient(root: root, now: { clock.now },
                           notifier: cardLandingNotifier(root: root))
        let b = makeClient(root: root, now: { clock.now },
                           notifier: cardLandingNotifier(root: root))

        // Both tick concurrently. The claim RMW serializes on the state-file
        // flock — one wins the stamp, the other re-reads it and stands down.
        async let ra = a.evaluateAndFire()
        async let rb = b.evaluateAndFire()
        let (fa, fb) = await (ra, rb)

        // Assert on the FIRED RESULT (not just item count) so this proves the
        // claim atomicity, independent of the inbox dedup that would also
        // collapse a second morning_brief card.
        #expect(fa.count + fb.count == 1)
        // Exactly one card reached the live inbox through the notifier seam.
        #expect(try readLiveInbox(root: root).count == 1)
        // last_fired_at is stamped to the SCHEDULED instant (08:00), not 09:00.
        let state = readTriggerState(root: root, surface: "triggers")
        guard case .object(let entry)? = state["morning_brief"],
              case .string(let ts)? = entry["last_fired_at"] else {
            Issue.record("last_fired_at not stamped"); return
        }
        let scheduled = localDate(2026, 3, 5, 8, 0)
        let parsed = SwiftNativeTriggerScheduler.parseISOTimestamp(ts)
        #expect(parsed == scheduled)
    }

    // ── Finding 2: corrupt (existing, non-empty, unparseable) state → dormant
    //    fresh-install missing state already covered by the "fires once" test ─
    @Test func corruptStateGarbageKeepsTriggersDormant() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        // Write garbage to the state file — exists, non-empty, not JSON.
        let statePath = root.appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
        try Data("not json {{{ >>>".utf8).write(to: statePath)
        // 09:00 — would fire if the state were merely "missing".
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    @Test func corruptStateNonObjectJSONKeepsTriggersDormant() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        // Valid JSON, but an ARRAY (non-object) → corrupt for our purposes.
        let statePath = root.appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
        try Data("[1, 2, 3]".utf8).write(to: statePath)
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    @Test func readStateRawDistinguishesMissingCorruptParsed() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = dir.appendingPathComponent("trigger_state.json")

        // Missing.
        if case .missing = SwiftNativeTriggerScheduler.readStateRaw(p) {} else {
            Issue.record("absent file should read as .missing")
        }
        // Zero-length → still a fresh install, not corrupt.
        try Data().write(to: p)
        if case .missing = SwiftNativeTriggerScheduler.readStateRaw(p) {} else {
            Issue.record("empty file should read as .missing")
        }
        // Garbage → corrupt.
        try Data("garbage".utf8).write(to: p)
        if case .corrupt = SwiftNativeTriggerScheduler.readStateRaw(p) {} else {
            Issue.record("garbage should read as .corrupt")
        }
        // Valid JSON but non-object: scalar, null, array → all corrupt (fail safe).
        for nonObject in ["123", "null", "[1,2,3]", "\"a string\""] {
            try Data(nonObject.utf8).write(to: p)
            if case .corrupt = SwiftNativeTriggerScheduler.readStateRaw(p) {} else {
                Issue.record("non-object JSON \(nonObject) should read as .corrupt")
            }
        }
        // Empty object {} → parsed (well-formed, just nothing fired yet → eligible).
        try Data("{}".utf8).write(to: p)
        if case .parsed(let o) = SwiftNativeTriggerScheduler.readStateRaw(p) {
            #expect(o.isEmpty)
        } else {
            Issue.record("empty object should read as .parsed")
        }
        // Well-formed populated object → parsed.
        try Data("{\"morning_brief\":{\"last_fired_at\":\"x\"}}".utf8).write(to: p)
        if case .parsed(let o) = SwiftNativeTriggerScheduler.readStateRaw(p) {
            #expect(o["morning_brief"] != nil)
        } else {
            Issue.record("object should read as .parsed")
        }
    }

    // ── Finding 3: scheduled-instant stamp → clock rewound the same day does
    //    NOT refire (would-be double if we stamped now()) ─────────────────────
    @Test func clockRewoundSameDayDoesNotRefire() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        // Fire at 10:00; last_fired_at is stamped to 08:00 (the scheduled instant).
        let clock = MutableClock(localDate(2026, 3, 5, 10, 0))
        let client = makeClient(root: root, now: { clock.now },
                                notifier: cardLandingNotifier(root: root))
        #expect(await client.evaluateAndFire() == ["morning_brief"])
        #expect(try readLiveInbox(root: root).count == 1)

        // ISOLATE scheduled-instant vs now() stamp: last_fired_at must be 08:00
        // (the scheduled instant), NOT 10:00 (wall-clock at fire). A now()-stamp
        // would ALSO block the rewind below, so this assertion is what actually
        // proves Finding 3's fix rather than an incidental pass.
        let stateAfter = readTriggerState(root: root, surface: "triggers")
        guard case .object(let e)? = stateAfter["morning_brief"],
              case .string(let ts)? = e["last_fired_at"] else {
            Issue.record("last_fired_at not stamped"); return
        }
        #expect(SwiftNativeTriggerScheduler.parseISOTimestamp(ts) == localDate(2026, 3, 5, 8, 0))

        // Clock jumps BACK 2h to exactly 08:00 — still clock-due (current ==
        // scheduled), but the stamped occurrence blocks a refire.
        clock.set(localDate(2026, 3, 5, 8, 0))
        #expect(await client.evaluateAndFire() == [])
        #expect(try readLiveInbox(root: root).count == 1)

        // And further back, before the schedule — still no refire.
        clock.set(localDate(2026, 3, 5, 6, 0))
        #expect(await client.evaluateAndFire() == [])
        #expect(try readLiveInbox(root: root).count == 1)
    }

    // ── Finding 4: fractional hour (8.9) is rejected → trigger stays dormant,
    //    it does NOT truncate to 08:00 and fire ────────────────────────────────
    @Test func fractionalHourStaysDormant() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("frac_time"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["hour": .double(8.9), "minute": .int(0)]),
            ]),
        ], root: root)
        // Noon — well past 08:00, so a truncating bug (8.9→8) would fire here.
        let clock = MutableClock(localDate(2026, 3, 5, 12, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    // A PRESENT-but-invalid `minute` (fractional / non-numeric) must make the
    // trigger dormant — NOT silently default to :00 and fire at the wrong time.
    // An ABSENT minute legitimately defaults to :00.
    @Test func presentButInvalidMinuteStaysDormant() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("frac_minute"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["hour": .int(8), "minute": .double(8.9)]),
            ]),
        ], root: root)
        // Noon — a snap-to-:00 bug would have fired at 08:00.
        let clock = MutableClock(localDate(2026, 3, 5, 12, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == [])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/items.jsonl").path))
    }

    @Test func absentMinuteDefaultsToTopOfHourAndFires() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No "minute" key at all → defaults to :00, still fires.
        try seedInbox([
            .object([
                "name": .string("hour_only"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["hour": .int(8)]),
            ]),
        ], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now })
        #expect(await client.evaluateAndFire() == ["hour_only"])
    }

    @Test func intFieldRejectsFractionalAcceptsWholeDouble() {
        // Whole doubles still parse (some JSON writers emit 8.0 for ints).
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(8.0)]), "hour") == 8)
        // Fractional → nil (dormant), not 8.
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(8.9)]), "hour") == nil)
        // Non-finite → nil (both signs).
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(.nan)]), "hour") == nil)
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(.infinity)]), "hour") == nil)
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(-.infinity)]), "hour") == nil)
        // Negative whole double accepted (range check downstream rejects it).
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(-1.0)]), "hour") == -1)
        // Negative fractional → nil (not truncated toward zero to 0 or -8).
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(-8.9)]), "hour") == nil)
        // Out-of-Int32-range doubles → nil (no overflow trap on Int(d)).
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(2147483648.0)]), "hour") == nil)
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .double(-2147483649.0)]), "hour") == nil)
        // Plain int passes through.
        #expect(SwiftNativeTriggerScheduler.intField(.object(["hour": .int(8)]), "hour") == 8)
    }

    // ── Finding 5: the 4th due trigger, deferred by the cap of 3, FIRES on the
    //    next tick (its state was not advanced, so it stays due) ───────────────
    @Test func cappedTriggerFiresOnNextTick() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedWorkshopExecutions([
            timeTrigger(name: "brief_a", hour: 8, objective: "A"),
            timeTrigger(name: "brief_b", hour: 8, objective: "B"),
            timeTrigger(name: "brief_c", hour: 8, objective: "C"),
            timeTrigger(name: "brief_d", hour: 8, objective: "D"),
        ], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now }, workshopRunner: makeEnqueueCapableRunner(root: root))
        // This test measures the CAP over the four seeded briefs; the
        // default-enabled inbox morning_brief (L5 G2) would be a fifth due
        // trigger at 09:00 and skew both tick counts.
        _ = try await client.disableInboxTrigger(name: "morning_brief")

        // Tick 1: cap of 3 fires 3, the 4th is deferred (not claimed).
        let tick1 = await client.evaluateAndFire()
        #expect(tick1.count == 3)

        // Tick 2 at the SAME clock: the 3 already-claimed skip; the deferred
        // 4th is still due and fires now.
        let tick2 = await client.evaluateAndFire()
        #expect(tick2.count == 1)

        // Across both ticks every distinct trigger fired exactly once.
        #expect(Set(tick1 + tick2) == ["brief_a", "brief_b", "brief_c", "brief_d"])

        // Tick 3: nothing left due.
        #expect(await client.evaluateAndFire() == [])
    }

    // ── At-most-once: a fire that FAILS after a successful claim consumes the
    //    occurrence — it is NOT retried, even once the config is repaired the
    //    same day. This is the documented bias (a duplicate is worse than a
    //    rare miss). A Workshop execution time trigger with no objective is due (clock),
    //    gets claimed, but fireWorkshopTrigger returns error(missing_objective). ─
    @Test func failedFireAfterClaimConsumesOccurrenceNoRetrySameDay() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Due by clock (kind time, hour 8) but NO objective → fire errors.
        try seedWorkshopExecutions([
            .object([
                "name": .string("bad_brief"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["hour": .int(8)]),
            ]),
        ], root: root)
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now }, workshopRunner: makeEnqueueCapableRunner(root: root))
        // Keep the default-enabled inbox morning_brief (L5 G2) out of the
        // ticks — this test's [] assertions are about bad_brief alone.
        _ = try await client.disableInboxTrigger(name: "morning_brief")

        // Tick 1: claimed (occurrence stamped) but fire fails → nothing fired.
        #expect(await client.evaluateAndFire() == [])
        // The occurrence WAS consumed — last_fired_at is stamped despite the
        // failed fire.
        let state = readTriggerState(root: root, surface: "workshop")
        #expect(state["bad_brief"] != nil)

        // Repair the config (add an objective) SAME DAY.
        try seedWorkshopExecutions([
            .object([
                "name": .string("bad_brief"),
                "kind": .string("time"),
                "enabled": .bool(true),
                "config": .object(["hour": .int(8)]),
                "objective": .string("Now valid"),
            ]),
        ], root: root)
        // Tick 2 same day: at-most-once — the claimed occurrence is not
        // re-fired even though the trigger would now succeed.
        #expect(await client.evaluateAndFire() == [])
        let queueDir = root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
        if FileManager.default.fileExists(atPath: queueDir.path) {
            let children = (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil)) ?? []
            #expect(children.isEmpty, "no execution should have been enqueued — occurrence already consumed")
        }
    }
}

// MARK: - TriggerConfig encode/decode

@Suite("TriggerConfig: JSON round-trip")
struct TriggerConfigJSONSuite {
    @Test func extrasRoundtripsWorkshopExecutionShape() throws {
        // Workshop trigger shape includes objective/title/trust_required as
        // non-typed top-level keys — those go through extras and must
        // re-emit on toJSON().
        let json: JSONValue = .object([
            "name": .string("morning_brief"),
            "kind": .string("time"),
            "enabled": .bool(true),
            "config": .object(["hour": .int(8), "minute": .int(0)]),
            "objective": .string("Read calendar"),
            "title": .string("Morning Brief"),
            "trust_required": .string("send_approval"),
        ])
        let cfg = TriggerConfig(json: json)
        #expect(cfg != nil)
        let roundtripped = cfg!.toJSON()
        guard case .object(let obj) = roundtripped else { Issue.record("not object"); return }
        #expect(obj["name"] == .string("morning_brief"))
        #expect(obj["enabled"] == .bool(true))
        #expect(obj["kind"] == .string("time"))
        #expect(obj["objective"] == .string("Read calendar"))
        #expect(obj["title"] == .string("Morning Brief"))
        #expect(obj["trust_required"] == .string("send_approval"))
    }

    @Test func emptyNameRejected() {
        let json: JSONValue = .object(["name": .string(""), "enabled": .bool(true)])
        #expect(TriggerConfig(json: json) == nil)
    }

    @Test func missingEnabledDefaultsToFalse() {
        let json: JSONValue = .object(["name": .string("x")])
        let cfg = TriggerConfig(json: json)
        #expect(cfg?.enabled == false)
    }
}

// MARK: - Wave 25 empirical verification gate
//
// EMPIRICAL ONLY — opt-in via NA_WAVE25_EMPIRICAL=1. Calls the PRODUCTION
// `makeWorkshopRunner()` factory (fix 8: no runtime: param — always native)
// and invokes the real `planWorkshopExecution(...)` path. This is
// the hard gate that distinguishes wave-25 retirement (real LLM plan) from
// retirement-deferred (stub fallback because the production environment
// lacks API credentials for the planner's resolved surface).
//
// Why opt-in: with no provider credentials in `data/credentials/` or env
// vars, the planner WILL fall back to the stub — that's the legitimate
// production state on CI / a clean checkout. Without the env-var gate this
// test would either pass-stub (no signal) or fail-noisy (false negative).
// Run locally with `NA_WAVE25_EMPIRICAL=1 swift test --filter Wave25Empirical`
// from the package directory.
//
// Result encoding for the orchestrator:
//   - plan.fromStub == false  → real LLM plan, retirement READY
//   - plan.fromStub == true   → stub fallback, retirement DEFERRED
//   - throws                  → unexpected; HALT and report
@Suite("Wave25EmpiricalRealLLM")
struct Wave25EmpiricalSuite {
    @Test func productionFactoryProducesRealLLMPlanOrStubFallback() async throws {
        guard ProcessInfo.processInfo.environment["NA_WAVE25_EMPIRICAL"] == "1" else {
            // Skip silently when not opted in. The non-empirical wave-24-amendment
            // factory test (`factoryWiresProductionMissionRunnerWithRealPlannerWhenBothFlagsOn`)
            // already covers the WIRING side of the regression; this suite is
            // strictly the END-TO-END empirical gate.
            return
        }
        let runner = makeWorkshopRunner()
        guard let native = runner as? SwiftNativeWorkshopRunner else {
            Issue.record("EMPIRICAL: makeWorkshopRunner did not return SwiftNativeWorkshopRunner")
            return
        }
        let plannerType = native._testPlannerTypeName
        // Confirm the wave-24-amendment wiring is intact at runtime.
        #expect(plannerType == "SwiftNativeWorkshopPlannerLLM",
                "planner type at runtime: \(plannerType)")

        let spec = WorkshopExecutionSpec(
            title: "Wave 25 Empirical",
            objective: "List the names of three classical planets in our solar system in JSON.",
            triggerSource: "wave25_empirical",
            trustRequired: "send_approval"
        )
        // Use the internal `_planWorkshopExecutionWithReason` seam so the harness ALSO
        // captures the planner's failure reason (e.g. `LLMError.notConfigured(openai)`)
        // when the LLM call falls back to the stub. Q1-NIT of the wave-25
        // gpt-5.5 review: without this, the harness only prints `fromStub=true`
        // and the missing-API-key cause is inferred from environment state, not
        // directly observed. Capturing the reason makes the verdict directly
        // diagnostic instead of merely consistent with the inference.
        let plan: WorkshopExecutionPlan
        let reason: String?
        do {
            (plan, reason) = try await native._planWorkshopExecutionWithReason(spec: spec)
        } catch {
            Issue.record("EMPIRICAL: planWorkshopExecution threw: \(error)")
            return
        }
        // Print machine-readable result lines so the orchestrator can grep
        // them out of the swift-test output. Test status itself is "pass" in
        // both outcomes — the orchestrator inspects the printed lines to
        // decide retire-vs-defer.
        print("WAVE25_EMPIRICAL_RESULT plannerType=\(plannerType)")
        print("WAVE25_EMPIRICAL_RESULT fromStub=\(plan.fromStub)")
        print("WAVE25_EMPIRICAL_RESULT stubReason=\(reason ?? "nil")")
        print("WAVE25_EMPIRICAL_RESULT stepCount=\(plan.steps.count)")
        for (i, step) in plan.steps.enumerated() {
            print("WAVE25_EMPIRICAL_RESULT step[\(i)] id=\(step.id) tool=\(step.toolOrAction) desc=\(step.description)")
        }
        if plan.fromStub {
            print("WAVE25_EMPIRICAL_RESULT verdict=DEFER_RETIREMENT_STUB_FALLBACK")
        } else {
            print("WAVE25_EMPIRICAL_RESULT verdict=RETIREMENT_READY_REAL_LLM_PLAN")
        }
        // We do NOT #expect on fromStub here — both outcomes are valid empirical results.
    }
}

// MARK: - P2-4: the mission_* -> execution_* trigger seam

/// `inbox/trigger_config.json` on a live 0.3.x install still carries
/// `{"name":"mission_followup","kind":"mission_complete"}`. The file is the
/// user's config and is never rewritten wholesale, so the new binary has to
/// read it, list it, toggle it, and fire it — while the defaults it seeds for a
/// fresh install use the canonical spelling. Every case below crosses the two.
@Suite("SwiftNativeTriggerScheduler: mission -> execution vocabulary")
struct TriggerVocabularySeamSuite {

    private func seedLegacyFollowup(root: URL, enabled: Bool = true) throws {
        try seedInbox([
            .object([
                "name": .string("mission_followup"),
                "kind": .string("mission_complete"),
                "enabled": .bool(enabled),
                "config": .object([:]),
                "description": .string("Notify when a Workshop task completes."),
            ]),
        ], root: root)
    }

    @Test func legacyConfigFileListsUnderTheCanonicalName() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyFollowup(root: root)
        let configs = try await makeClient(root: root).listInboxTriggers()
        #expect(configs.map(\.name) == ["execution_followup"])
        #expect(configs.first?.kind == "execution_complete")
    }

    @Test func canonicalNameTogglesARowStoredWithTheLegacyName() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyFollowup(root: root, enabled: true)
        let client = makeClient(root: root)
        let status = try await client.disableInboxTrigger(name: "execution_followup")
        #expect(status.status != "not_found")
        #expect(try await client.listInboxTriggers().first?.enabled == false)

        // The row's STORED name is untouched — the config file is the user's,
        // not ours to rewrite.
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root
                .appendingPathComponent("inbox", isDirectory: true)
                .appendingPathComponent("trigger_config.json"))
        ) as? [[String: Any]]
        #expect(raw?.first?["name"] as? String == "mission_followup")
    }

    @Test func legacyNameTogglesARowStoredWithTheCanonicalName() async throws {
        // The mirror: a fresh install's canonical config, addressed by a client
        // still on the old spelling.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([
            .object([
                "name": .string("execution_followup"),
                "kind": .string("execution_complete"),
                "enabled": .bool(true),
                "config": .object([:]),
            ]),
        ], root: root)
        let client = makeClient(root: root)
        let status = try await client.disableInboxTrigger(name: "mission_followup")
        #expect(status.status != "not_found")
        #expect(try await client.listInboxTriggers().first?.enabled == false)
    }

    @Test func canonicalNameFindsLegacyRowButRefusesFabricatedFollowup() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyFollowup(root: root)
        let result = try await makeClient(root: root)
            .fireInboxTrigger(name: "execution_followup", isStub: true)
        #expect(result.status == "error")
        #expect(result.name == "execution_followup")
        #expect(result.item == nil)
        #expect(result.error?.contains("evidence-backed content path is unavailable") == true)
    }

    @Test func anUnknownTriggerNameIsStillNotFound() async throws {
        // The fold must not have loosened name matching into a wildcard.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyFollowup(root: root)
        let result = try await makeClient(root: root)
            .fireInboxTrigger(name: "some_other_trigger", isStub: true)
        #expect(result.status == "not_found")
    }
}

// MARK: - 2026-08-13 legacy-path migration (inbox/ → triggers/)

@Suite("SwiftNativeTriggerScheduler: legacy inbox/ file migration")
struct LegacyTriggerFileMigrationSuite {
    private func legacyConfigPath(_ root: URL) -> URL {
        root.appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent("trigger_config.json")
    }
    private func legacyStatePath(_ root: URL) -> URL {
        root.appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
    }
    private func newConfigPath(_ root: URL) -> URL {
        root.appendingPathComponent("triggers", isDirectory: true)
            .appendingPathComponent("trigger_config.json")
    }
    private func newStatePath(_ root: URL) -> URL {
        root.appendingPathComponent("triggers", isDirectory: true)
            .appendingPathComponent("trigger_state.json")
    }

    @Test func firstAccessCopiesLegacyConfigAndStateForward() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Legacy install shape: config + liveness state under <root>/inbox/.
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8, enabled: false)], root: root)
        try Data(#"{"morning_brief": {"last_fired_at": "2026-08-13T08:00:11+00:00"}}"#.utf8)
            .write(to: legacyStatePath(root))

        let listed = try await makeClient(root: root).listInboxTriggers()

        // The seeded row (not built-in defaults) came through — the read
        // honored the legacy content via the copy-forward.
        #expect(listed.contains { $0.name == "morning_brief" && $0.enabled == false })
        // Both files now live at the new home; the legacy pair is left frozen
        // in place, byte-identical.
        #expect(FileManager.default.fileExists(atPath: newConfigPath(root).path))
        #expect(FileManager.default.fileExists(atPath: newStatePath(root).path))
        #expect(try Data(contentsOf: legacyStatePath(root)) == Data(contentsOf: newStatePath(root)))
        #expect(try Data(contentsOf: legacyConfigPath(root)) == Data(contentsOf: newConfigPath(root)))
    }

    @Test func migratedStateSuppressesRefireOfAlreadyFiredOccurrence() async throws {
        // THE loss this migration exists to prevent: dropping last_fired_at
        // would re-fire a time trigger that already fired today.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8)], root: root)
        let scheduled = localDate(2026, 3, 5, 8, 0)
        let iso = ISO8601DateFormatter().string(from: scheduled)
        try Data(#"{"morning_brief": {"last_fired_at": "\#(iso)"}}"#.utf8)
            .write(to: legacyStatePath(root))
        let clock = MutableClock(localDate(2026, 3, 5, 9, 0))
        let client = makeClient(root: root, now: { clock.now })
        // 09:00 same day, already stamped at the 08:00 occurrence → no fire.
        #expect(await client.evaluateAndFire() == [])
    }

    @Test func existingNewFileWinsOverLegacy() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Legacy row says enabled=true; the NEW home already has enabled=false.
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8, enabled: true)], root: root)
        try FileManager.default.createDirectory(
            at: newConfigPath(root).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let newRow = try JSONValue.array(
            [timeTrigger(name: "morning_brief", hour: 8, enabled: false)]
        ).serializedData(pretty: true)
        try newRow.write(to: newConfigPath(root))

        let listed = try await makeClient(root: root).listInboxTriggers()
        // No overwrite: the new-home content is authoritative.
        #expect(listed.contains { $0.name == "morning_brief" && $0.enabled == false })
        #expect(!listed.contains { $0.name == "morning_brief" && $0.enabled == true })
    }

    @Test func freshInstallCreatesNoMigrationArtifacts() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No legacy dir at all → defaults served, nothing copied or created.
        let listed = try await makeClient(root: root).listInboxTriggers()
        #expect(!listed.isEmpty)   // built-in defaults
        #expect(!FileManager.default.fileExists(atPath: newConfigPath(root).path))
        #expect(!FileManager.default.fileExists(atPath: legacyConfigPath(root).path))
    }

    @Test func failedMigrationFailsClosedWithoutSeedingDefaults() async throws {
        // gpt-5.5 review BLOCKING (2026-08-13): if the copy-forward fails,
        // proceeding would let a mutation write built-in defaults to the new
        // home — after which the exists-check skips the legacy file forever
        // (config silently replaced, last_fired_at lost → refire). The guarded
        // entry points must THROW instead, leaving both homes untouched.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8, enabled: false)], root: root)
        let legacyBytesBefore = try Data(contentsOf: legacyConfigPath(root))
        // Block the migration: a FILE named "triggers" makes createDirectory
        // (and thus the copy) fail deterministically.
        try Data("not a directory".utf8).write(
            to: root.appendingPathComponent("triggers", isDirectory: false)
        )

        let client = makeClient(root: root)
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.listInboxTriggers()
        }
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.enableInboxTrigger(name: "morning_brief")
        }
        // Nothing was seeded or overwritten anywhere.
        #expect(try Data(contentsOf: legacyConfigPath(root)) == legacyBytesBefore)
        #expect(!FileManager.default.fileExists(atPath: newConfigPath(root).path))

        // Repair the blockage → the non-latched migration retries and succeeds.
        try FileManager.default.removeItem(at: root.appendingPathComponent("triggers"))
        let listed = try await client.listInboxTriggers()
        #expect(listed.contains { $0.name == "morning_brief" && $0.enabled == false })
    }

    @Test func mutationAfterMigrationWritesNewHomeOnly() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedInbox([timeTrigger(name: "morning_brief", hour: 8, enabled: true)], root: root)
        let legacyBytesBefore = try Data(contentsOf: legacyConfigPath(root))

        let client = makeClient(root: root)
        _ = try await client.disableInboxTrigger(name: "morning_brief")

        // New home carries the flip; the frozen legacy file is untouched.
        let rows = try readInboxRaw(root: root)
        let brief = rows.first {
            if case .object(let o) = $0, case .string(let n)? = o["name"] { return n == "morning_brief" }
            return false
        }
        if case .object(let o)? = brief {
            #expect(o["enabled"] == .bool(false))
        } else {
            Issue.record("morning_brief row missing from triggers/trigger_config.json")
        }
        #expect(try Data(contentsOf: legacyConfigPath(root)) == legacyBytesBefore)
    }
}
