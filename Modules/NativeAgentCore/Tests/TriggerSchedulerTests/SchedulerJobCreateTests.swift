import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// MARK: - Wave 33 W18: scheduler-job create write port tests
//
// Empirically exercises the SwiftNative create_job path: normalization across
// all six kinds + seven schedule types, the flock'd jobs.json append, the
// activity-event append, and the connector_action delegation boundary.

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchedulerJobCreateTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Run `body` against a fresh temp root, cleaning it up on every exit path.
private func withTempRoot(_ body: (URL) async throws -> Void) async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func readJobs(root: URL) throws -> [JSONValue] {
    let url = root.appendingPathComponent("scheduler", isDirectory: true)
        .appendingPathComponent("jobs.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    guard case .array(let arr) = try JSONValue.parse(data) else { return [] }
    return arr
}

private func writeJSON(_ value: JSONValue, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.serializedData(pretty: false).write(to: url, options: .atomic)
}

private func readActivityLines(root: URL) throws -> [JSONValue] {
    let url = root.appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
        try? JSONValue.parse(Data($0.utf8))
    }
}

private func obj(_ v: JSONValue?) -> [String: JSONValue] {
    if case .object(let o)? = v { return o }
    return [:]
}
private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

// A fixed-clock at 2026-06-01T12:00:00Z (a Monday).
private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_660_800) }

// Thread-safe monotonic counter for tests that need distinct uuids per call.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

private func makeSchedulerClient(root: URL) -> SwiftNativeTriggerScheduler {
    SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: fixedNow,
        uuid: { "uuid-fixed" },
        connectorActionIDs: ["gmail.list_inbox"]
    )
}

// MARK: - notify

@Test func createNotifyJob_persistsAndAppendsActivity() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("Reminder"),
        "kind": .string("notify"),
        "interval_seconds": .int(3600),
        "payload": .object([
            "message": .string("drink water"),
            "delivery": .array([.string("iphone"), .string("telegram")]),
        ]),
    ])
    let result = try await client.createJob(body: body)
    let r = obj(result)
    #expect(str(r["kind"]) == "notify")
    #expect(str(r["name"]) == "Reminder")
    #expect(r["enabled"] == .bool(true))

    // Persisted to jobs.json.
    let jobs = try readJobs(root: root)
    #expect(jobs.count == 1)
    let job = obj(jobs.first)
    #expect(str(job["id"]) == "uuid-fixed")
    let payload = obj(job["payload"])
    #expect(str(payload["message"]) == "drink water")
    #expect(str(payload["source"]) == "scheduled_job")
    // iphone → push alias; telegram stays; deduped + canonical.
    #expect(payload["delivery"] == .array([.string("push"), .string("telegram")]))

    // Activity event appended.
    let activity = try readActivityLines(root: root)
    #expect(activity.count == 1)
    let ev = obj(activity.first)
    #expect(str(ev["kind"]) == "scheduler")
    #expect(str(ev["title"]) == "Scheduled job created")
    #expect(str(ev["detail"]) == "Reminder · notify")
    #expect(str(ev["status"]) == "ok")
}

@Test func createNotifyJob_missingMessage_throws() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("X"), "kind": .string("notify"),
        "payload": .object([:]),
    ])
    await #expect(throws: TriggerSchedulerError.self) {
        _ = try await client.createJob(body: body)
    }
    // Nothing persisted on the validation throw (normalization runs before write).
    #expect(try readJobs(root: root).isEmpty)
}

@Test func installWorkshopBlueprintIsIdempotentAndRepairsCancelledVersion() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "id": .string("native-experience-project-status"),
        "name": .string("Project status"),
        "kind": .string("workshop"),
        "schedule": .object(["type": .string("daily"), "at": .string("17:00")]),
        "payload": .object([
            "title": .string("Project status"),
            "objective": .string("Review the selected project with read-only evidence."),
            "expectedEvidence": .string("Git and Workshop receipts"),
            "blueprintId": .string("project-status"),
            "blueprintVersion": .int(1),
        ]),
    ])
    let first = obj(try await client.installBlueprintJob(body: body))
    #expect(str(first["status"]) == "installed")
    let second = obj(try await client.installBlueprintJob(body: body))
    #expect(str(second["status"]) == "already_present")
    #expect(try readJobs(root: root).count == 1)

    let jobsPath = root.appendingPathComponent("scheduler/jobs.json")
    var row = obj(try readJobs(root: root).first)
    row["enabled"] = .bool(false)
    row["status"] = .string("cancelled")
    try writeJSON(.array([.object(row)]), to: jobsPath)
    let repaired = obj(try await client.installBlueprintJob(body: body))
    #expect(str(repaired["status"]) == "repaired")
    let persisted = obj(try readJobs(root: root).first)
    #expect(persisted["enabled"] == .bool(true))
    #expect(str(persisted["status"]) != "cancelled")
}

// MARK: - runtime schedule advancement

@Test func runtimeNextRun_every_advancesFromNow() throws {
    let job: JSONValue = .object([
        "oneShot": .bool(false),
        "intervalSeconds": .int(300),
    ])
    let next = try SchedulerJobRuntime.nextRunEpochAfterNow(for: job, now: fixedNow)
    #expect(next == fixedNow().timeIntervalSince1970 + 300)
}

@Test func runtimeNextRun_once_returnsNil() throws {
    let job: JSONValue = .object([
        "oneShot": .bool(true),
        "intervalSeconds": .int(300),
    ])
    let next = try SchedulerJobRuntime.nextRunEpochAfterNow(for: job, now: fixedNow)
    #expect(next == nil)
}

@Test func runtimeNextRun_daily_usesNormalizerScheduleMath() throws {
    let job: JSONValue = .object([
        "oneShot": .bool(false),
        "schedule": .object([
            "type": .string("daily"),
            "at": .string("08:00"),
            "timezone": .string("UTC"),
        ]),
    ])
    let next = try #require(try SchedulerJobRuntime.nextRunEpochAfterNow(for: job, now: fixedNow))
    #expect(next > fixedNow().timeIntervalSince1970)
    #expect(SchedulerJobRuntime.decorationISO(epoch: next).contains("T08:00:00+00:00"))
}

// MARK: - dream / improve

@Test func createDreamJob_defaultObjective() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object(["name": .string("Nightly Reflection"), "kind": .string("dream"), "interval_seconds": .int(86400)])
    let r = obj(try await client.createJob(body: body))
    #expect(str(r["kind"]) == "dream")
    #expect(r["intervalSeconds"] == .int(86400))
    let payload = obj(r["payload"])
    #expect(str(payload["objective"]) == "Scheduled reflection")
}

@Test func createREMJob_defaultObjective() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("Weekly REM"),
        "kind": .string("rem"),
        "schedule": .object(["type": .string("weekly"), "weekdays": .array([.string("sun")]), "at": .string("04:30")]),
    ])
    let r = obj(try await client.createJob(body: body))
    #expect(str(r["kind"]) == "rem")
    let payload = obj(r["payload"])
    #expect(str(payload["objective"]) == "Scheduled REM consolidation")
}

@Test func createImproveJob_defaultObjective() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object(["name": .string("Improve"), "kind": .string("improve")])
    let r = obj(try await client.createJob(body: body))
    let payload = obj(r["payload"])
    #expect(str(payload["objective"])?.hasPrefix("Make NativeAgent meaningfully better") == true)
}

// MARK: - kind validation

@Test func createJob_unsupportedKind_throws() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object(["name": .string("X"), "kind": .string("launch_missiles")])
    await #expect(throws: TriggerSchedulerError.self) {
        _ = try await client.createJob(body: body)
    }
}

// MARK: - harness_benchmark (else branch)

@Test func createHarnessBenchmark_addsLightweightFlags() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object(["name": .string("Bench"), "kind": .string("harness_benchmark")])
    let r = obj(try await client.createJob(body: body))
    let payload = obj(r["payload"])
    #expect(payload["manualAllowed"] == .bool(true))
    #expect(payload["lightweight"] == .bool(true))
}

// MARK: - proactive_scan clamping

@Test func createProactiveScan_clampsLimits() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("Scan"), "kind": .string("proactive_scan"),
        "payload": .object([
            "limit": .int(999),            // clamp to 50
            "surfaceLimit": .int(999),     // clamp to 12
            "sources": .array([.string("a"), .string("b")]),
        ]),
    ])
    let r = obj(try await client.createJob(body: body))
    let payload = obj(r["payload"])
    #expect(payload["limit"] == .int(50))
    #expect(payload["surfaceLimit"] == .int(12))
    #expect(payload["sources"] == .array([.string("a"), .string("b")]))
}

// MARK: - schedule: once / every / daily / cron

@Test func schedule_once_usesRunAt() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    // run_at far in the future so max(now, run_at) keeps it.
    let future = fixedNow().timeIntervalSince1970 + 100_000
    let body: JSONValue = .object([
        "name": .string("Once"), "kind": .string("notify"),
        "payload": .object(["message": .string("hi")]),
        "schedule": .object(["type": .string("once"), "run_at": .double(future)]),
    ])
    let r = obj(try await client.createJob(body: body))
    #expect(r["oneShot"] == .bool(true))
    #expect(r["nextRunAtEpoch"] == .int(Int64(future)))
}

@Test func schedule_every_intervalFloor() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("Every"), "kind": .string("notify"),
        "payload": .object(["message": .string("hi")]),
        "schedule": .object(["type": .string("every"), "seconds": .int(10)]),  // floored to 60
    ])
    let r = obj(try await client.createJob(body: body))
    #expect(r["intervalSeconds"] == .int(60))
    #expect(r["oneShot"] == .bool(false))
    // next run = now + 60.
    let expected = Int64(fixedNow().timeIntervalSince1970 + 60)
    #expect(r["nextRunAtEpoch"] == .int(expected))
}

@Test func schedule_daily_findsNextHHMM() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("Daily"), "kind": .string("notify"),
        "payload": .object(["message": .string("hi")]),
        "schedule": .object(["type": .string("daily"), "at": .string("08:00")]),
    ])
    let r = obj(try await client.createJob(body: body))
    // next 08:00 local at/after now (fixedNow is 12:00 UTC).
    let epoch = { () -> Double in
        if case .int(let i)? = r["nextRunAtEpoch"] { return Double(i) }
        return 0
    }()
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    let comps = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: epoch))
    #expect(comps.hour == 8)
    #expect(comps.minute == 0)
    #expect(epoch > fixedNow().timeIntervalSince1970)
}

@Test func schedule_cron_matches() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("Cron"), "kind": .string("notify"),
        "payload": .object(["message": .string("hi")]),
        // every day at 09:30
        "schedule": .object(["type": .string("cron"), "expression": .string("30 9 * * *")]),
    ])
    let r = obj(try await client.createJob(body: body))
    let epoch = { () -> Double in
        if case .int(let i)? = r["nextRunAtEpoch"] { return Double(i) }
        return 0
    }()
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    let comps = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: epoch))
    #expect(comps.hour == 9)
    #expect(comps.minute == 30)
}

// MARK: - connector_action validation

@Test func connectorAction_knownAction_persistsNormalizedPayload() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("CA"), "kind": .string("connector_action"),
        "payload": .object([
            "actionId": .string("gmail.list_inbox"),
            "input": .object(["max": .int(5)]),
        ]),
    ])
    let r = obj(try await client.createJob(body: body))
    #expect(str(r["kind"]) == "connector_action")
    let payload = obj(r["payload"])
    #expect(str(payload["actionId"]) == "gmail.list_inbox")
    let input = obj(payload["input"])
    #expect(input["max"] == .int(5))
}

@Test func connectorAction_unknownAction_throws() async throws {
    let root = try makeTempRoot()
    let client = makeSchedulerClient(root: root)
    let body: JSONValue = .object([
        "name": .string("CA"), "kind": .string("connector_action"),
        "payload": .object(["actionId": .string("missing.nope")]),
    ])
    await #expect(throws: TriggerSchedulerError.self) {
        _ = try await client.createJob(body: body)
    }
}

// MARK: - multiple creates append (state lifecycle)

@Test func multipleCreates_appendNotOverwrite() async throws {
    let root = try makeTempRoot()
    let counter = Counter()
    let client = SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: fixedNow,
        uuid: { "id-\(counter.next())" }
    )
    for i in 0..<3 {
        let body: JSONValue = .object([
            "name": .string("J\(i)"), "kind": .string("notify"),
            "payload": .object(["message": .string("m\(i)")]),
        ])
        _ = try await client.createJob(body: body)
    }
    let jobs = try readJobs(root: root)
    #expect(jobs.count == 3)
    let names = jobs.compactMap { str(obj($0)["name"]) }.sorted()
    #expect(names == ["J0", "J1", "J2"])
    // Activity log has one event per create.
    #expect(try readActivityLines(root: root).count == 3)
}

// MARK: - factory honors the flag

@Test func factory_returnsSwiftNative() {
    let writer = makeSchedulerJobWriter()
    #expect(writer is SwiftNativeTriggerScheduler)
}

// MARK: - Python-semantics parity (wave 33 W18 gpt-5.5 review fixes)

@Test func enabledExplicitNull_isFalsey() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        // bool(body.get("enabled", True)) — explicit null → False (Python).
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "enabled": .null,
            "payload": .object(["message": .string("m")]),
        ])
        let r = obj(try await client.createJob(body: body))
        #expect(r["enabled"] == .bool(false))
    }
}

@Test func enabledAbsent_defaultsTrue() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "payload": .object(["message": .string("m")]),
        ])
        let r = obj(try await client.createJob(body: body))
        #expect(r["enabled"] == .bool(true))
    }
}

@Test func intervalZero_fallsThroughOrChain() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        // Python: int(0 or 7200 or … or 3600) → 7200. (0 is falsey.)
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "interval_seconds": .int(0),
            "intervalSeconds": .int(7200),
            "payload": .object(["message": .string("m")]),
        ])
        let r = obj(try await client.createJob(body: body))
        #expect(r["intervalSeconds"] == .int(7200))
    }
}

@Test func invalidIntervalString_throws() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        // Python int("abc") raises ValueError → 400.
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "interval_seconds": .string("abc"),
            "payload": .object(["message": .string("m")]),
        ])
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.createJob(body: body)
        }
    }
}

@Test func numericKind_coercedThenRejected() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        // str(123) == "123", not in allowed → Unsupported scheduled job kind.
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .int(123),
            "payload": .object(["message": .string("m")]),
        ])
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.createJob(body: body)
        }
    }
}

@Test func numericMessage_coercedToString() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        // str(42) == "42" — a numeric message is NOT "missing".
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "payload": .object(["message": .int(42)]),
        ])
        let r = obj(try await client.createJob(body: body))
        let payload = obj(r["payload"])
        #expect(str(payload["message"]) == "42")
    }
}

@Test func firstRunAtEmpty_fallsBackToRunAt() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        let future = fixedNow().timeIntervalSince1970 + 50_000
        // schedule.firstRunAt = "" (falsey) → Python `or body.run_at`.
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "run_at": .double(future),
            "payload": .object(["message": .string("m")]),
            "schedule": .object(["type": .string("every"), "seconds": .int(120), "firstRunAt": .string("")]),
        ])
        let r = obj(try await client.createJob(body: body))
        #expect(r["nextRunAtEpoch"] == .int(Int64(future)))
    }
}

@Test func scheduleAtEmpty_fallsBackToTime() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        // _scheduler_time_parts: spec.get("at") or spec.get("time").
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "payload": .object(["message": .string("m")]),
            "schedule": .object(["type": .string("daily"), "at": .string(""), "time": .string("07:15")]),
        ])
        let r = obj(try await client.createJob(body: body))
        let epoch = { () -> Double in if case .int(let i)? = r["nextRunAtEpoch"] { return Double(i) }; return 0 }()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let comps = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: epoch))
        #expect(comps.hour == 7)
        #expect(comps.minute == 15)
    }
}

@Test func cronInvalidStep_throws() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        let body: JSONValue = .object([
            "name": .string("N"), "kind": .string("notify"),
            "payload": .object(["message": .string("m")]),
            "schedule": .object(["type": .string("cron"), "expression": .string("*/bogus * * * *")]),
        ])
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.createJob(body: body)
        }
    }
}

@Test func improveDefaultObjective_isFullPythonConstant() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        let body: JSONValue = .object(["name": .string("I"), "kind": .string("improve")])
        let r = obj(try await client.createJob(body: body))
        let payload = obj(r["payload"])
        let objective = str(payload["objective"]) ?? ""
        // Full constant ends with the receipt-backed clause (not a truncated prefix).
        #expect(objective.hasSuffix("tested and receipt-backed."))
        #expect(objective.contains("the bug ledger"))
    }
}

@Test func weeklySchedule_findsNamedWeekday() async throws {
    try await withTempRoot { root in
        let client = makeSchedulerClient(root: root)
        // fixedNow is a Monday; ask for Wednesday 06:00.
        let body: JSONValue = .object([
            "name": .string("W"), "kind": .string("notify"),
            "payload": .object(["message": .string("m")]),
            "schedule": .object(["type": .string("weekly"), "weekdays": .array([.string("wed")]), "at": .string("06:00")]),
        ])
        let r = obj(try await client.createJob(body: body))
        let epoch = { () -> Double in if case .int(let i)? = r["nextRunAtEpoch"] { return Double(i) }; return 0 }()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: Date(timeIntervalSince1970: epoch))
        #expect(comps.weekday == 4)  // Calendar: 1=Sun..7=Sat → 4=Wed
        #expect(comps.hour == 6)
        #expect(comps.minute == 0)
    }
}
