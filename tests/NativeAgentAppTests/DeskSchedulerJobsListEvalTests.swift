import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.scheduler.jobsList
//
// Runs the exact mounted Scheduler observation lifecycle against two clients
// sharing one canonical root. An external cancellation must alter the already
// mounted AppModel list; reopening the screen is not a refresh mechanism.

@Test @MainActor
func deskSchedulerJobsListRefreshesWhenTheCanonicalFeedChanges() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("desk-scheduler-list-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = NativeClient(baseURL: "", dataRootOverride: root)
    let created = try await writer.createJob(
        name: "Mounted scheduler job",
        kind: "dream",
        intervalSeconds: 120
    )
    let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
    let observation = Task { @MainActor in
        await SchedulerJobsLiveRefresh.observe(path: model.client.schedulerJobsPath) {
            _ = await model.refreshSchedulerJobs()
        }
    }
    defer { observation.cancel() }

    let initialDeadline = Date().addingTimeInterval(3)
    while Date() < initialDeadline {
        if model.jobs.first(where: { $0.id == created.id })?.enabled == true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.jobs.first(where: { $0.id == created.id })?.enabled == true)

    let externalWriter = NativeClient(baseURL: "", dataRootOverride: root)
    _ = try await externalWriter.cancelSchedulerJob(id: created.id)

    let updateDeadline = Date().addingTimeInterval(3)
    while Date() < updateDeadline {
        if model.jobs.first(where: { $0.id == created.id })?.enabled == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.jobs.first(where: { $0.id == created.id })?.enabled == false)
}
