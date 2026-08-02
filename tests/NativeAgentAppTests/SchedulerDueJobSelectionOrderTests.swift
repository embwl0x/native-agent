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
