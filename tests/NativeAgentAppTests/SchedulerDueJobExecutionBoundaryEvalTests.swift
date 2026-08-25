import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private actor SchedulerExecutionBoundaryRecorder {
    private var dispatchedKinds: [String] = []

    func dispatch(_ job: SchedulerDueJobRunner.DueJob) -> SchedulerDueJobRunner.JobResult {
        dispatchedKinds.append(job.kind)
        return SchedulerDueJobRunner.JobResult(
            status: "completed",
            detail: "recorded \(job.kind)",
            output: .object(["effect": .string(job.kind)])
        )
    }

    func retryableFailure(_ job: SchedulerDueJobRunner.DueJob) -> SchedulerDueJobRunner.JobResult {
        dispatchedKinds.append(job.kind)
        return SchedulerDueJobRunner.JobResult(
            status: "error",
            detail: "recorded retryable \(job.kind) failure",
            output: .object([
                "failureKind": .string("recorded_failure"),
                "retryable": .bool(true),
                "retryAfterSeconds": .int(60),
            ])
        )
    }

    func kinds() -> [String] { dispatchedKinds }
}

private func schedulerExecutionBoundaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scheduler-execution-boundary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func schedulerExecutionRow(
    id: String,
    kind: String,
    enabled: Bool = true,
    oneShot: Bool = true,
    dueEpoch: Double = 1,
    activeOccurrence: JSONValue? = nil
) -> JSONValue {
    var row: [String: JSONValue] = [
        "id": .string(id),
        "name": .string("Job \(id)"),
        "kind": .string(kind),
        "enabled": .bool(enabled),
        "oneShot": .bool(oneShot),
        "nextRunAtEpoch": .int(Int64(dueEpoch)),
        "payload": .object([:]),
    ]
    if let activeOccurrence { row["activeOccurrence"] = activeOccurrence }
    return .object(row)
}

/// `runDueJobs` also maintains the two user-visible default cycles. Tombstone
/// them in this hermetic fixture so an unrelated catch-up occurrence cannot
/// consume the bounded pass or replace the claim being asserted below.
private func schedulerExecutionFixture(_ rows: [JSONValue]) -> [JSONValue] {
    rows + [
        .object([
            "id": .string("nativeagent-nightly-dream"),
            "name": .string("Nightly Dream"),
            "kind": .string("dream"),
            "enabled": .bool(false),
            "oneShot": .bool(false),
            "cancelledAt": .string("2026-01-01T00:00:00Z"),
            "payload": .object([:]),
        ]),
        .object([
            "id": .string("nativeagent-weekly-rem"),
            "name": .string("Weekly REM"),
            "kind": .string("rem"),
            "enabled": .bool(false),
            "oneShot": .bool(false),
            "cancelledAt": .string("2026-01-01T00:00:00Z"),
            "payload": .object([:]),
        ]),
    ]
}

private func schedulerExecutionRows(_ root: URL) async throws -> [[String: JSONValue]] {
    let path = root.appendingPathComponent("scheduler/jobs.json")
    let value = try JSONValue.parse(Data(contentsOf: path))
    guard case .array(let rows) = value else {
        throw PersistenceCoreError.ioFailure("scheduler fixture unexpectedly stopped being an array")
    }
    return rows.compactMap { value in
        guard case .object(let object) = value else { return nil }
        return object
    }
}

@Test("scheduler executes every due kind once and persists the exact settlement under its injected root")
func schedulerExecutionBoundary_dispatchesAndSettlesEveryKind() async throws {
    let expectedKinds: Set<String> = [
        "notify", "connector_action", "dream", "rem", "improve",
        "harness_benchmark", "proactive_scan", "workshop",
    ]
    let kinds = SchedulerDueJobRunner.JobKind.allCases.map(\.rawValue)
    #expect(Set(kinds) == expectedKinds)
    let store = SwiftNativePersistenceCore()

    for kind in kinds {
        let root = try schedulerExecutionBoundaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SchedulerExecutionBoundaryRecorder()
        let runner = SchedulerDueJobRunner(
            root: root,
            executionOverride: { _, job, _ in await recorder.dispatch(job) }
        )
        try await store.writeJSON(
            .array(schedulerExecutionFixture([schedulerExecutionRow(id: "due-\(kind)", kind: kind)])),
            to: runner.jobsPath
        )

        #expect(await runner.runDueJobs(maxJobs: 1) == ["Job due-\(kind)"])
        #expect(await recorder.kinds() == [kind])

        let settledRows = try await schedulerExecutionRows(root)
        let settled = try #require(settledRows.first)
        #expect(settled["activeOccurrence"] == nil)
        #expect(settled["lastRunStatus"] == .string("completed"))
        #expect(settled["lastOccurrenceKey"] != nil)
        #expect(settled["enabled"] == .bool(false))

        let activity = try await store.readJSONL(
            root.appendingPathComponent("activity/events.jsonl")
        )
        #expect(activity.contains { event in
            guard case .object(let object) = event else { return false }
            return object["title"] == .string("Scheduled job completed")
        })

        // Once settled, the same one-shot occurrence cannot dispatch again.
        #expect((await runner.runDueJobs(maxJobs: 1)).isEmpty)
        #expect(await recorder.kinds() == [kind])
    }
}

@Test("unknown job kinds fail before an injected scheduler effect can run")
func schedulerExecutionBoundary_unknownKindDoesNotDispatch() async throws {
    let root = try schedulerExecutionBoundaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativePersistenceCore()
    let recorder = SchedulerExecutionBoundaryRecorder()
    let runner = SchedulerDueJobRunner(
        root: root,
        executionOverride: { _, job, _ in await recorder.dispatch(job) }
    )
    try await store.writeJSON(
        .array(schedulerExecutionFixture([schedulerExecutionRow(id: "unknown", kind: "not_a_scheduler_kind")])),
        to: runner.jobsPath
    )

    #expect((await runner.runDueJobs(maxJobs: 1)).isEmpty)
    #expect(await recorder.kinds().isEmpty)
    let rows = try await schedulerExecutionRows(root)
    let row = try #require(rows.first)
    #expect(row["lastRunStatus"] == .string("error"))
    guard case .string(let detail)? = row["lastRunDetail"] else {
        Issue.record("expected unknown-kind failure receipt")
        return
    }
    #expect(detail.contains("Unsupported scheduled job kind"))
}

@Test("not-due and disabled rows never cross the scheduler effect boundary")
func schedulerExecutionBoundary_notDueAndDisabledDoNotDispatch() async throws {
    let root = try schedulerExecutionBoundaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativePersistenceCore()
    let recorder = SchedulerExecutionBoundaryRecorder()
    let runner = SchedulerDueJobRunner(
        root: root,
        executionOverride: { _, job, _ in await recorder.dispatch(job) }
    )
    try await store.writeJSON(.array(schedulerExecutionFixture([
        schedulerExecutionRow(id: "future", kind: "notify", dueEpoch: Date().timeIntervalSince1970 + 86_400),
        schedulerExecutionRow(id: "disabled", kind: "notify", enabled: false),
    ])), to: runner.jobsPath)

    #expect((await runner.runDueJobs(maxJobs: 2)).isEmpty)
    #expect(await recorder.kinds().isEmpty)
    let rows = try await schedulerExecutionRows(root)
    #expect(rows.allSatisfy { $0["activeOccurrence"] == nil })
}

@Test("scheduler claim conflict, retry, and restart recovery stay durable and never duplicate an effect")
func schedulerExecutionBoundary_conflictRetryAndRestartRecovery() async throws {
    let root = try schedulerExecutionBoundaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativePersistenceCore()
    let recorder = SchedulerExecutionBoundaryRecorder()
    let runner = SchedulerDueJobRunner(
        root: root,
        executionOverride: { _, job, _ in await recorder.retryableFailure(job) }
    )
    try await store.writeJSON(
        .array(schedulerExecutionFixture([schedulerExecutionRow(id: "retry", kind: "dream", oneShot: false)])),
        to: runner.jobsPath
    )

    #expect((await runner.runDueJobs(maxJobs: 1)).isEmpty)
    #expect(await recorder.kinds() == ["dream"])
    var retryRows = try await schedulerExecutionRows(root)
    var retryRow = try #require(retryRows.first)
    #expect(retryRow["lastRunStatus"] == .string("error"))
    #expect(retryRow["retryPendingUntilEpoch"] != nil)
    #expect(retryRow["activeOccurrence"] == nil)

    // A stale claimant cannot settle a later occurrence over the durable key.
    let claimed = try #require((try await runner.claimDueJobs(now: Date(timeIntervalSince1970: 9_999_999_999), maxJobs: 1)).jobs.first)
    let conflicting = SchedulerDueJobRunner.DueJob(
        id: claimed.id,
        name: claimed.name,
        kind: claimed.kind,
        payload: claimed.payload,
        row: claimed.row,
        dueEpoch: claimed.dueEpoch,
        occurrenceKey: "different-occurrence"
    )
    await #expect(throws: (any Error).self) {
        try await runner.update(
            job: conflicting,
            result: SchedulerDueJobRunner.JobResult(status: "completed", detail: "wrong claimant", output: .object([:])),
            at: Date()
        )
    }
    retryRows = try await schedulerExecutionRows(root)
    retryRow = try #require(retryRows.first)
    #expect(retryRow["activeOccurrence"] != nil)

    let restartRoot = try schedulerExecutionBoundaryRoot()
    defer { try? FileManager.default.removeItem(at: restartRoot) }
    let recoveryKey = SchedulerDueJobRunner.DueJob.makeOccurrenceKey(jobId: "recovered", dueEpoch: 1)
    try await store.writeJSON(.array(schedulerExecutionFixture([
        schedulerExecutionRow(
            id: "recovered",
            kind: "connector_action",
            activeOccurrence: .object([
                "key": .string(recoveryKey),
                "state": .string("claimed"),
            ])
        ),
    ])), to: restartRoot.appendingPathComponent("scheduler/jobs.json"))
    let recoveryRecorder = SchedulerExecutionBoundaryRecorder()
    let restarted = SchedulerDueJobRunner(
        root: restartRoot,
        executionOverride: { _, job, _ in await recoveryRecorder.dispatch(job) }
    )
    #expect((await restarted.runDueJobs(maxJobs: 1)).isEmpty)
    #expect(await recoveryRecorder.kinds().isEmpty)
    let recoveredRows = try await schedulerExecutionRows(restartRoot)
    let recovered = try #require(recoveredRows.first)
    #expect(recovered["lastRunStatus"] == .string("unknown"))
    #expect(recovered["lastUnknownOccurrenceKey"] == .string(recoveryKey))
    #expect(recovered["enabled"] == .bool(false))
    let reconciliationActivity = try await store.readJSONL(
        restartRoot.appendingPathComponent("activity/events.jsonl")
    )
    #expect(reconciliationActivity.contains { event in
        guard case .object(let object) = event else { return false }
        return object["title"] == .string("Scheduled job outcome needs reconciliation")
    })
    let reconciliationInbox = try await store.readJSONL(
        restartRoot.appendingPathComponent("notifications/inbox.jsonl")
    )
    #expect(reconciliationInbox.contains { event in
        guard case .object(let object) = event else { return false }
        return object["source"] == .string("scheduler_reconciliation")
    })
}

@Test("a noncanonical root cannot fall through to process-global scheduler effects")
func schedulerExecutionBoundary_noncanonicalRootFailsLoudlyAndLeavesReceiptLocal() async throws {
    let root = try schedulerExecutionBoundaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativePersistenceCore()
    let runner = SchedulerDueJobRunner(root: root)
    try await store.writeJSON(
        .array(schedulerExecutionFixture([schedulerExecutionRow(id: "wrong-root", kind: "notify")])),
        to: runner.jobsPath
    )

    #expect((await runner.runDueJobs(maxJobs: 1)).isEmpty)
    let rows = try await schedulerExecutionRows(root)
    let row = try #require(rows.first)
    #expect(row["lastRunStatus"] == .string("error"))
    guard case .string(let detail)? = row["lastRunDetail"] else {
        Issue.record("expected a durable root-authority failure receipt")
        return
    }
    #expect(detail.contains("canonical data root"))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("activity/events.jsonl").path))
}
