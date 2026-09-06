import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
import TriggerScheduler
@testable import NativeAgentApp

// MARK: - Fable 5.1 sweep item 36 — the Scheduler's status is a control
//
// The screen used to render `job.enabled ? "enabled" : "paused"` as plain Text.
// These cover the client seam the switch is bound to and the receipt it shows:
// the row is repainted from the job the store actually persisted, so a refused
// write can never leave the switch in a position nothing accepted.

private func schedulerToggleRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchedulerJobToggleTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func seedJobsFile(_ root: URL, _ jobs: [JSONValue]) throws {
    let dir = root.appendingPathComponent("scheduler", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONValue.array(jobs).serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("jobs.json"), options: .atomic)
}

/// The rows the Scheduler screen lists from.
private func feedJobs(_ client: NativeClient) async throws -> [SchedulerJob] {
    switch await client.schedulerJobsFeed() {
    case .current(let rows): return rows
    case .partial(let rows, _): return rows
    case .sourceAbsent: return []
    case .unavailable(let detail):
        throw SchedulerJobsFeedError.unavailable(detail)
    }
}

private func toggleJobRow(id: String, name: String, enabled: Bool) -> JSONValue {
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

@Test
func setSchedulerJobEnabled_pausesAndResumesTheRealJobsFeed() async throws {
    let root = try schedulerToggleRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedJobsFile(root, [toggleJobRow(id: "job-1", name: "Reminder", enabled: true)])
    let client = NativeClient(baseURL: "", dataRootOverride: root)

    let paused = try await client.setSchedulerJobEnabled(id: "job-1", enabled: false)
    #expect(paused.id == "job-1")
    #expect(!paused.enabled)
    // The feed the view lists from agrees — the switch's new position is the
    // store's, not the click's.
    #expect(try #require(try await feedJobs(client).first).enabled == false)

    let resumed = try await client.setSchedulerJobEnabled(id: "job-1", enabled: true)
    #expect(resumed.enabled)
    #expect(try #require(try await feedJobs(client).first).enabled == true)
}

@Test
func setSchedulerJobEnabled_refusesAnUnknownJobInsteadOfReportingSuccess() async throws {
    let root = try schedulerToggleRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedJobsFile(root, [toggleJobRow(id: "job-1", name: "Reminder", enabled: true)])
    let client = NativeClient(baseURL: "", dataRootOverride: root)

    await #expect(throws: (any Error).self) {
        _ = try await client.setSchedulerJobEnabled(id: "job-missing", enabled: false)
    }
    #expect(try #require(try await feedJobs(client).first).enabled == true)
}

@Test
func schedulerToggleReceiptReportsThePersistedStateAndNamesAFailure() {
    let persisted = SchedulerJob(
        id: "job-1", name: "Reminder", kind: "notify",
        intervalSeconds: 3600, enabled: false, nextRunAt: nil, lastRunAt: nil)
    #expect(SchedulerJobTogglePresentation.receipt(
        jobName: "Reminder", requestedEnabled: false, outcome: .verified(persisted))
        == .init(text: "Reminder is paused.", isError: false))

    // The receipt reports what the STORE said, not what was clicked: a write
    // that came back still-enabled must not read as "paused".
    let refusedInEffect = SchedulerJob(
        id: "job-1", name: "Reminder", kind: "notify",
        intervalSeconds: 3600, enabled: true, nextRunAt: nil, lastRunAt: nil)
    #expect(SchedulerJobTogglePresentation.receipt(
        jobName: "Reminder", requestedEnabled: false, outcome: .verified(refusedInEffect))
        == .init(text: "Reminder is enabled.", isError: false))

    let failed = SchedulerJobTogglePresentation.receipt(
        jobName: "Reminder", requestedEnabled: false, outcome: .failed("jobs.json is unreadable"))
    #expect(failed.isError)
    #expect(failed.text == "Could not pause Reminder: jobs.json is unreadable")

    let blank = SchedulerJobTogglePresentation.receipt(
        jobName: "  ", requestedEnabled: true, outcome: .failed("  "))
    #expect(blank.text == "Could not enable job: the scheduler did not confirm the change")
}
