import Testing
import Foundation
import NativeAgentCore
@testable import NativeAgentApp

// selectDueJobs used to walk jobs.json in FILE ARRAY ORDER and `break` at
// maxJobs with no ordering by due time. With only a handful of enabled jobs
// that was harmless, but it means a tail row can starve behind head rows
// forever once the job list outgrows the cap — the most-overdue job is exactly
// the one that should run first. These tests pin earliest-due-first selection
// with a stable tiebreak.

private func selectionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("due-job-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeJobs(_ rows: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
}

@Test("due jobs are capped by earliest due time, not by position in jobs.json")
func selectDueJobs_capsByDueEpochNotFileOrder() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = SchedulerDueJobRunner(root: root)

    // Head rows are barely due; the LAST row has been due for a week. With a
    // cap of 2, file order would return head-a/head-b and starve "ancient"
    // on every pass.
    try writeJobs([
        ["id": "head-a", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 - 1],
        ["id": "head-b", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 - 2],
        ["id": "head-c", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 - 3],
        ["id": "ancient", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 - 604_800],
    ], to: runner.jobsPath)

    let due = try await runner.selectDueJobs(now: now, maxJobs: 2)
    #expect(due.map(\.id) == ["ancient", "head-c"])
}

@Test("all selected due jobs come back sorted earliest-first")
func selectDueJobs_sortsAscendingByDueEpoch() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = SchedulerDueJobRunner(root: root)

    try writeJobs([
        ["id": "third", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 - 10],
        ["id": "first", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 - 300],
        ["id": "not-due", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 + 60],
        ["id": "second", "enabled": true, "nextRunAtEpoch": now.timeIntervalSince1970 - 100],
        ["id": "disabled", "enabled": false, "nextRunAtEpoch": now.timeIntervalSince1970 - 9_999],
    ], to: runner.jobsPath)

    let due = try await runner.selectDueJobs(now: now, maxJobs: 10)
    // Ordering changed; every other selection semantic (enabled gate, future
    // rows excluded, boundary at `now`) is unchanged.
    #expect(due.map(\.id) == ["first", "second", "third"])
}

@Test("equal due times keep jobs.json file order")
func selectDueJobs_tiesKeepFileOrder() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = SchedulerDueJobRunner(root: root)
    let same = now.timeIntervalSince1970 - 5

    try writeJobs([
        ["id": "a", "enabled": true, "nextRunAtEpoch": same],
        ["id": "b", "enabled": true, "nextRunAtEpoch": same],
        ["id": "c", "enabled": true, "nextRunAtEpoch": same],
    ], to: runner.jobsPath)

    let due = try await runner.selectDueJobs(now: now, maxJobs: 10)
    #expect(due.map(\.id) == ["a", "b", "c"])
}

@Test("due occurrence is durably claimed before it is returned for execution")
func claimDueJobs_persistsStableOccurrenceIdentity() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let due = now.timeIntervalSince1970 - 15
    let runner = SchedulerDueJobRunner(root: root)
    try writeJobs([[
        "id": "claimed",
        "name": "Claimed",
        "kind": "notify",
        "enabled": true,
        "oneShot": true,
        "nextRunAtEpoch": due,
    ]], to: runner.jobsPath)

    let batch = try await runner.claimDueJobs(now: now, maxJobs: 5)
    let job = try #require(batch.jobs.first)
    #expect(batch.recoveredUnknown.isEmpty)
    #expect(job.occurrenceKey == SchedulerDueJobRunner.DueJob.makeOccurrenceKey(
        jobId: "claimed", dueEpoch: due
    ))

    let data = try Data(contentsOf: runner.jobsPath)
    let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let active = try #require(rows.first?["activeOccurrence"] as? [String: Any])
    #expect(active["key"] as? String == job.occurrenceKey)
    #expect(active["state"] as? String == "claimed")
}

@Test("a claim surviving restart becomes unknown and is never replayed")
func claimDueJobs_recoversAmbiguousOccurrenceWithoutRepeatingEffect() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let due = now.timeIntervalSince1970 - 15
    let key = SchedulerDueJobRunner.DueJob.makeOccurrenceKey(jobId: "ambiguous", dueEpoch: due)
    let runner = SchedulerDueJobRunner(root: root)
    try writeJobs([[
        "id": "ambiguous",
        "name": "Ambiguous",
        "kind": "connector_action",
        "enabled": true,
        "oneShot": true,
        "nextRunAtEpoch": due,
        "activeOccurrence": [
            "key": key,
            "claimedAt": SchedulerDueJobRunner.iso(now.addingTimeInterval(-30)),
            "state": "claimed",
        ],
    ]], to: runner.jobsPath)

    let batch = try await runner.claimDueJobs(now: now, maxJobs: 5)
    #expect(batch.jobs.isEmpty)
    #expect(batch.recoveredUnknown.map(\.occurrenceKey) == [key])

    let data = try Data(contentsOf: runner.jobsPath)
    let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let row = try #require(rows.first)
    #expect(row["activeOccurrence"] == nil)
    #expect(row["enabled"] as? Bool == false)
    #expect(row["lastRunStatus"] as? String == "unknown")
    #expect(row["lastUnknownOccurrenceKey"] as? String == key)
}

@Test("a malformed surviving claim fails closed instead of authorizing the effect")
func claimDueJobs_malformedClaimIsPreservedAndNotExecuted() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = SchedulerDueJobRunner(root: root)
    try writeJobs([[
        "id": "damaged-claim",
        "name": "Damaged claim",
        "kind": "notify",
        "enabled": true,
        "oneShot": true,
        "nextRunAtEpoch": now.timeIntervalSince1970 - 5,
        "activeOccurrence": ["state": "claimed"],
    ]], to: runner.jobsPath)

    let batch = try await runner.claimDueJobs(now: now, maxJobs: 1)
    #expect(batch.jobs.isEmpty)
    #expect(batch.recoveredUnknown.count == 1)
    let data = try Data(contentsOf: runner.jobsPath)
    let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let row = try #require(rows.first)
    #expect(row["enabled"] as? Bool == false)
    #expect(row["lastInvalidOccurrenceClaim"] != nil)
}

@Test("corrupt jobs.json fails closed and default repair preserves its bytes")
func schedulerCorruptStateIsNeverReplacedWithGenesisDefaults() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = SchedulerDueJobRunner(root: root)
    try FileManager.default.createDirectory(
        at: runner.jobsPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let corrupt = Data(#"[{"id":"keep-me"}, BROKEN]"#.utf8)
    try corrupt.write(to: runner.jobsPath)

    await #expect(throws: (any Error).self) {
        _ = try await runner.ensureDefaultCycleJobs(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
    await #expect(throws: (any Error).self) {
        _ = try await runner.claimDueJobs(
            now: Date(timeIntervalSince1970: 1_800_000_000), maxJobs: 1
        )
    }
    #expect(try Data(contentsOf: runner.jobsPath) == corrupt)
}

@Test("wrong top-level scheduler shape fails closed without rewriting")
func schedulerNonArrayStateIsPreserved() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = SchedulerDueJobRunner(root: root)
    try FileManager.default.createDirectory(
        at: runner.jobsPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let wrongShape = Data(#"{"jobs":[{"id":"keep-me"}]}"#.utf8)
    try wrongShape.write(to: runner.jobsPath)

    await #expect(throws: (any Error).self) {
        _ = try await runner.selectDueJobs(
            now: Date(timeIntervalSince1970: 1_800_000_000), maxJobs: 1
        )
    }
    #expect(try Data(contentsOf: runner.jobsPath) == wrongShape)
}

@Test("settlement requires the exact active occurrence and clears it atomically")
func update_requiresAndSettlesExactOccurrenceClaim() async throws {
    let root = try selectionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let due = now.timeIntervalSince1970 - 15
    let runner = SchedulerDueJobRunner(root: root)
    try writeJobs([[
        "id": "settle",
        "name": "Settle",
        "kind": "notify",
        "enabled": true,
        "oneShot": true,
        "nextRunAtEpoch": due,
    ]], to: runner.jobsPath)
    let batch = try await runner.claimDueJobs(now: now, maxJobs: 1)
    let job = try #require(batch.jobs.first)
    let result = SchedulerDueJobRunner.JobResult(
        status: "completed",
        detail: "done",
        output: .object([:])
    )

    try await runner.update(job: job, result: result, at: now)
    let data = try Data(contentsOf: runner.jobsPath)
    let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let row = try #require(rows.first)
    #expect(row["activeOccurrence"] == nil)
    #expect(row["lastOccurrenceKey"] as? String == job.occurrenceKey)
    #expect(row["enabled"] as? Bool == false)
}
