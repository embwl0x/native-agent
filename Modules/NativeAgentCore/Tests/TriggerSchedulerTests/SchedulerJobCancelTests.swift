import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// MARK: - Wave 35 W14: scheduler-job CANCEL write port tests
//
// Empirically exercises the SwiftNative `cancelJob(jobId:)` path — the faithful
// port of `Daemon.cancel_job`, the backing call for
// the `scheduler.cancel_job` connector action. There is NO HTTP cancel route;
// this is the native parity of that mutation. Covered: round-trip create→cancel
// (enabled→false + cancelledAt stamped), empty-id throw, unknown-id throw (no
// write on the miss path), the "warn" activity event with name-or-id detail,
// flock-preserves-other-jobs, and the `{ok, job}` return shape.

private func cancelTestRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchedulerJobCancelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func withCancelRoot(_ body: (URL) async throws -> Void) async throws {
    let root = try cancelTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func cancelReadJobs(root: URL) throws -> [JSONValue] {
    let url = root.appendingPathComponent("scheduler", isDirectory: true)
        .appendingPathComponent("jobs.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    guard case .array(let arr) = try JSONValue.parse(data) else { return [] }
    return arr
}

private func cancelReadActivity(root: URL) throws -> [JSONValue] {
    let url = root.appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
        try? JSONValue.parse(Data($0.utf8))
    }
}

private func cobj(_ v: JSONValue?) -> [String: JSONValue] {
    if case .object(let o)? = v { return o }
    return [:]
}
private func cstr(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

private let cancelFixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_660_800) }

// Distinct uuids per call so the activity event id doesn't collide.
private final class CancelCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

private func makeCancelClient(root: URL, uuid: @escaping @Sendable () -> String = { "cancel-uuid" }) -> SwiftNativeTriggerScheduler {
    SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: cancelFixedNow,
        uuid: uuid
    )
}

// Seed jobs.json directly so cancel tests don't depend on createJob's id.
private func seedJobs(_ jobs: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("scheduler", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("jobs.json")
    let data = try JSONValue.array(jobs).serializedData(pretty: false)
    try data.write(to: url)
}

private func sampleJob(id: String, name: String, enabled: Bool = true) -> JSONValue {
    .object([
        "id": .string(id),
        "name": .string(name),
        "kind": .string("notify"),
        "intervalSeconds": .int(3600),
        "enabled": .bool(enabled),
        "oneShot": .bool(false),
        "payload": .object(["message": .string("hi")]),
    ])
}

// MARK: - happy path

@Test func cancelJob_disablesAndStampsCancelledAt() async throws {
    try await withCancelRoot { root in
        try seedJobs([sampleJob(id: "job-1", name: "Reminder"), sampleJob(id: "job-2", name: "Other")], root: root)
        let client = makeCancelClient(root: root)

        let result = try await client.cancelJob(jobId: "job-1")
        let r = cobj(result)
        // Return shape: {"ok": true, "job": <updated>}
        #expect(r["ok"] == .bool(true))
        let job = cobj(r["job"])
        #expect(cstr(job["id"]) == "job-1")
        #expect(job["enabled"] == .bool(false))
        #expect(cstr(job["cancelledAt"]) != nil)

        // Persisted: job-1 disabled + cancelledAt, job-2 untouched.
        let jobs = try cancelReadJobs(root: root)
        #expect(jobs.count == 2)
        let j1 = cobj(jobs.first { cstr(cobj($0)["id"]) == "job-1" })
        #expect(j1["enabled"] == .bool(false))
        #expect(cstr(j1["cancelledAt"]) != nil)
        let j2 = cobj(jobs.first { cstr(cobj($0)["id"]) == "job-2" })
        #expect(j2["enabled"] == .bool(true))
        #expect(j2["cancelledAt"] == nil)
    }
}

@Test func cancelJob_appendsWarnActivityWithName() async throws {
    try await withCancelRoot { root in
        try seedJobs([sampleJob(id: "job-1", name: "Reminder")], root: root)
        let client = makeCancelClient(root: root)
        _ = try await client.cancelJob(jobId: "job-1")

        let activity = try cancelReadActivity(root: root)
        #expect(activity.count == 1)
        let ev = cobj(activity.first)
        #expect(cstr(ev["kind"]) == "scheduler")
        #expect(cstr(ev["title"]) == "Scheduled job cancelled")
        #expect(cstr(ev["status"]) == "warn")
        // detail = str(target.name or job_id) → "Reminder"
        #expect(cstr(ev["detail"]) == "Reminder")
        let payload = cobj(ev["payload"])
        #expect(cstr(payload["jobId"]) == "job-1")
    }
}

@Test func cancelJob_nameFallsBackToId_whenNameBlank() async throws {
    try await withCancelRoot { root in
        // Python `str(target.get("name") or job_id)`: empty name is falsey → id.
        try seedJobs([sampleJob(id: "job-x", name: "")], root: root)
        let client = makeCancelClient(root: root)
        _ = try await client.cancelJob(jobId: "job-x")

        let ev = cobj(try cancelReadActivity(root: root).first)
        #expect(cstr(ev["detail"]) == "job-x")
    }
}

// MARK: - validation

@Test func cancelJob_emptyId_throws() async throws {
    try await withCancelRoot { root in
        try seedJobs([sampleJob(id: "job-1", name: "R")], root: root)
        let client = makeCancelClient(root: root)
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.cancelJob(jobId: "")
        }
        // Nothing mutated, no activity appended.
        let j = cobj(try cancelReadJobs(root: root).first)
        #expect(j["enabled"] == .bool(true))
        #expect(try cancelReadActivity(root: root).isEmpty)
    }
}

@Test func cancelJob_unknownId_throws_andDoesNotWrite() async throws {
    try await withCancelRoot { root in
        try seedJobs([sampleJob(id: "job-1", name: "R")], root: root)
        let client = makeCancelClient(root: root)
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.cancelJob(jobId: "nope")
        }
        // The miss path raises before write_json — job-1 stays enabled, no
        // activity event written.
        let j = cobj(try cancelReadJobs(root: root).first)
        #expect(j["enabled"] == .bool(true))
        #expect(j["cancelledAt"] == nil)
        #expect(try cancelReadActivity(root: root).isEmpty)
    }
}

@Test func cancelJob_emptyJobsFile_unknownId_throws() async throws {
    try await withCancelRoot { root in
        // No jobs.json at all → read defaults to [] → unknown id.
        let client = makeCancelClient(root: root)
        await #expect(throws: TriggerSchedulerError.self) {
            _ = try await client.cancelJob(jobId: "anything")
        }
    }
}

// MARK: - round trip with createJob

@Test func createThenCancel_roundTrip() async throws {
    try await withCancelRoot { root in
        let counter = CancelCounter()
        let client = makeCancelClient(root: root, uuid: { "job-rt-\(counter.next())" })
        let created = cobj(try await client.createJob(body: .object([
            "name": .string("Nightly"), "kind": .string("dream"), "interval_seconds": .int(86400),
        ])))
        let createdId = cstr(created["id"]) ?? ""
        #expect(!createdId.isEmpty)
        #expect(created["enabled"] == .bool(true))

        let cancelled = cobj(try await client.cancelJob(jobId: createdId))
        #expect(cancelled["ok"] == .bool(true))
        #expect(cobj(cancelled["job"])["enabled"] == .bool(false))

        // One created job, still present, now disabled.
        let jobs = try cancelReadJobs(root: root)
        #expect(jobs.count == 1)
        #expect(cobj(jobs.first)["enabled"] == .bool(false))

        // Two activity events: created (ok) then cancelled (warn).
        let activity = try cancelReadActivity(root: root)
        #expect(activity.count == 2)
        #expect(cstr(cobj(activity.first)["title"]) == "Scheduled job created")
        #expect(cstr(cobj(activity.last)["title"]) == "Scheduled job cancelled")
        #expect(cstr(cobj(activity.last)["status"]) == "warn")
    }
}

// MARK: - id coercion parity

@Test func cancelJob_matchesNumericIdViaStrCoercion() async throws {
    try await withCancelRoot { root in
        // Python matches via `str(job.get("id")) == job_id`; a numeric stored
        // id coerces to its decimal string. Mirror: stored int 42 matches "42".
        try seedJobs([
            .object([
                "id": .int(42), "name": .string("NumId"), "kind": .string("notify"),
                "enabled": .bool(true), "payload": .object(["message": .string("x")]),
            ]),
        ], root: root)
        let client = makeCancelClient(root: root)
        let r = cobj(try await client.cancelJob(jobId: "42"))
        #expect(r["ok"] == .bool(true))
        #expect(cobj(r["job"])["enabled"] == .bool(false))
    }
}

@Test func cancelJob_missingId_matchesLiteralNone() async throws {
    // gpt-5.5 review parity: Python `str(job.get("id")) == job_id` with an
    // absent/null id is `str(None) == "None"`, so a malformed job with no id
    // is a cancel target for jobId == "None". `pyStrForId` reproduces that.
    try await withCancelRoot { root in
        try seedJobs([
            .object([
                "name": .string("NoId"), "kind": .string("notify"),
                "enabled": .bool(true), "payload": .object(["message": .string("x")]),
            ]),  // no "id" key at all
            .object([
                "id": .null, "name": .string("NullId"), "kind": .string("notify"),
                "enabled": .bool(true), "payload": .object(["message": .string("y")]),
            ]),
        ], root: root)
        let client = makeCancelClient(root: root)
        let r = cobj(try await client.cancelJob(jobId: "None"))
        #expect(r["ok"] == .bool(true))
        // First match wins (the absent-id job); it is now disabled.
        #expect(cstr(cobj(r["job"])["name"]) == "NoId")
        #expect(cobj(r["job"])["enabled"] == .bool(false))
    }
}
