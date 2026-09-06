import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// MARK: - Fable 5.1 sweep item 36 — the Scheduler's status becomes a control
//
// The Scheduler screen rendered `job.enabled ? "enabled" : "paused"` as plain
// text. `setJobEnabled(jobId:enabled:)` is the write that makes that readout a
// switch: the same flocked `scheduler/jobs.json` read-modify-write `cancelJob`
// performs, plus a scheduler activity receipt, in BOTH directions.
//
// The load-bearing detail is the `cancelledAt` tombstone. `ensureDefaultCycleJobs`
// (the passive bootstrap pass in SchedulerDueJobRunner) forces `enabled=true`
// on its default cycle jobs unless it can see the row was deliberately switched
// off — and the only signal it honors is `enabled=false` + `cancelledAt`. A
// bare `enabled=false` would give the user a switch that flips itself back.

private func setEnabledRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchedulerJobSetEnabledTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func setEnabledReadJobs(root: URL) throws -> [JSONValue] {
    let url = root.appendingPathComponent("scheduler", isDirectory: true)
        .appendingPathComponent("jobs.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    guard case .array(let arr) = try JSONValue.parse(try Data(contentsOf: url)) else { return [] }
    return arr
}

private func setEnabledReadActivity(root: URL) throws -> [JSONValue] {
    let url = root.appendingPathComponent("activity", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let text = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
        try? JSONValue.parse(Data($0.utf8))
    }
}

private func seobj(_ v: JSONValue?) -> [String: JSONValue] {
    if case .object(let o)? = v { return o }
    return [:]
}
private func sestr(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}

private let setEnabledNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_660_800) }

private final class SetEnabledCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

private func makeSetEnabledClient(root: URL) -> SwiftNativeTriggerScheduler {
    let counter = SetEnabledCounter()
    return SwiftNativeTriggerScheduler(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: setEnabledNow,
        uuid: { "set-enabled-uuid-\(counter.next())" }
    )
}

private func seedSetEnabledJobs(_ jobs: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("scheduler", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONValue.array(jobs).serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("jobs.json"))
}

private func setEnabledJob(id: String, name: String, enabled: Bool) -> JSONValue {
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

@Test func setJobEnabled_pauseWritesTheTombstoneTheBootstrapPassHonors() async throws {
    let root = try setEnabledRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedSetEnabledJobs([
        setEnabledJob(id: "job-1", name: "Agent Nightly Dream", enabled: true),
        setEnabledJob(id: "job-2", name: "Other", enabled: true),
    ], root: root)

    let result = try await makeSetEnabledClient(root: root)
        .setJobEnabled(jobId: "job-1", enabled: false)
    let r = seobj(result)
    #expect(r["ok"] == .bool(true))
    #expect(seobj(r["job"])["enabled"] == .bool(false))

    let jobs = try setEnabledReadJobs(root: root)
    let j1 = seobj(jobs.first { sestr(seobj($0)["id"]) == "job-1" })
    #expect(j1["enabled"] == .bool(false))
    // Without this stamp the passive bootstrap pass re-enables the row.
    #expect(sestr(j1["cancelledAt"]) != nil)
    let j2 = seobj(jobs.first { sestr(seobj($0)["id"]) == "job-2" })
    #expect(j2["enabled"] == .bool(true))
    #expect(j2["cancelledAt"] == nil)
}

@Test func setJobEnabled_resumeClearsTheTombstoneAndSurvivesAReRead() async throws {
    let root = try setEnabledRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedSetEnabledJobs([setEnabledJob(id: "job-1", name: "Reminder", enabled: true)], root: root)
    let client = makeSetEnabledClient(root: root)

    _ = try await client.setJobEnabled(jobId: "job-1", enabled: false)
    let resumed = seobj(seobj(try await client.setJobEnabled(jobId: "job-1", enabled: true))["job"])
    #expect(resumed["enabled"] == .bool(true))
    #expect(resumed["cancelledAt"] == nil)

    // A fresh client reading from disk sees the same thing — the switch is
    // durable, not an in-memory optimism.
    let reread = seobj(try setEnabledReadJobs(root: root)
        .first { sestr(seobj($0)["id"]) == "job-1" })
    #expect(reread["enabled"] == .bool(true))
    #expect(reread["cancelledAt"] == nil)
}

@Test func setJobEnabled_appendsASchedulerActivityReceiptInBothDirections() async throws {
    let root = try setEnabledRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedSetEnabledJobs([setEnabledJob(id: "job-1", name: "Reminder", enabled: true)], root: root)
    let client = makeSetEnabledClient(root: root)

    _ = try await client.setJobEnabled(jobId: "job-1", enabled: false)
    _ = try await client.setJobEnabled(jobId: "job-1", enabled: true)

    let events = try setEnabledReadActivity(root: root).map(seobj)
    let paused = try #require(events.first { sestr($0["title"]) == "Scheduled job paused" })
    #expect(sestr(paused["kind"]) == "scheduler")
    #expect(sestr(paused["detail"]) == "Reminder")
    #expect(sestr(paused["status"]) == "warn")
    #expect(seobj(paused["payload"])["enabled"] == .bool(false))

    let resumed = try #require(events.first { sestr($0["title"]) == "Scheduled job resumed" })
    #expect(sestr(resumed["status"]) == "ok")
    #expect(seobj(resumed["payload"])["enabled"] == .bool(true))
}

@Test func setJobEnabled_refusesABlankOrUnknownIdWithoutWriting() async throws {
    let root = try setEnabledRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedSetEnabledJobs([setEnabledJob(id: "job-1", name: "Reminder", enabled: true)], root: root)
    let client = makeSetEnabledClient(root: root)

    await #expect(throws: TriggerSchedulerError.self) {
        _ = try await client.setJobEnabled(jobId: "", enabled: false)
    }
    await #expect(throws: TriggerSchedulerError.self) {
        _ = try await client.setJobEnabled(jobId: "nope", enabled: false)
    }
    // The miss path throws inside the lock, before any write.
    let j1 = seobj(try setEnabledReadJobs(root: root).first)
    #expect(j1["enabled"] == .bool(true))
    #expect(j1["cancelledAt"] == nil)
    #expect(try setEnabledReadActivity(root: root).isEmpty)
}
