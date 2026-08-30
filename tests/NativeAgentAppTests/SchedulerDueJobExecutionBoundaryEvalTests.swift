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

private enum SchedulerActivityFeedFixtureError: LocalizedError {
    case injectedExecutionFailure

    var errorDescription: String? {
        "injected scheduler execution failure"
    }
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

private func schedulerActivityRows(_ root: URL) async throws -> [[String: JSONValue]] {
    let store = SwiftNativePersistenceCore()
    return try await store.readJSONL(
        root.appendingPathComponent("activity/events.jsonl")
    ).compactMap { value in
        guard case .object(let object) = value else { return nil }
        return object
    }
}

private func schedulerObject(_ value: JSONValue?) -> [String: JSONValue]? {
    guard case .object(let object)? = value else { return nil }
    return object
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

        let activity = try await schedulerActivityRows(root)
        let event = try #require(activity.first)
        #expect(activity.count == 1)
        #expect(event["kind"] == .string("scheduler"))
        #expect(event["title"] == .string("Scheduled job completed"))
        #expect(event["detail"] == .string("Job due-\(kind): recorded \(kind)"))
        #expect(event["status"] == .string("ok"))
        #expect(event["executionId"] == .null)
        guard case .string(let eventID)? = event["id"],
              case .string(let createdAt)? = event["createdAt"] else {
            Issue.record("scheduler activity receipt lacks its durable envelope identity")
            continue
        }
        #expect(!eventID.isEmpty)
        #expect(SchedulerDueJobRunner.parseISODate(createdAt) != nil)
        let payload = try #require(schedulerObject(event["payload"]))
        #expect(payload["jobId"] == .string("due-\(kind)"))
        #expect(payload["jobName"] == .string("Job due-\(kind)"))
        #expect(payload["kind"] == .string(kind))
        #expect(payload["status"] == .string("completed"))
        #expect(payload["occurrenceKey"] == settled["lastOccurrenceKey"])
        let output = try #require(schedulerObject(payload["output"]))
        #expect(output["effect"] == .string(kind))
        #expect(output["occurrenceKey"] == settled["lastOccurrenceKey"])

        // Once settled, the same one-shot occurrence cannot dispatch again.
        #expect((await runner.runDueJobs(maxJobs: 1)).isEmpty)
        #expect(await recorder.kinds() == [kind])
    }
}

@Test("scheduler activity feed durably records every due outcome")
func schedulerActivityFeed_recordsEveryDueOutcomeInProductionJSONL() async throws {
    let root = try schedulerExecutionBoundaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativePersistenceCore()
    let recoveredKey = SchedulerDueJobRunner.DueJob.makeOccurrenceKey(jobId: "recovered", dueEpoch: 1)
    let runner = SchedulerDueJobRunner(
        root: root,
        executionOverride: { _, job, _ in
            switch job.id {
            case "completed":
                return SchedulerDueJobRunner.JobResult(
                    status: "completed",
                    detail: "fixture completed",
                    output: .object(["marker": .string("completed")])
                )
            case "skipped":
                return SchedulerDueJobRunner.JobResult(
                    status: "skipped",
                    detail: "fixture skipped",
                    output: .object(["marker": .string("skipped")])
                )
            case "warned":
                return SchedulerDueJobRunner.JobResult(
                    status: "warn",
                    detail: "fixture warned",
                    output: .object(["marker": .string("warn")])
                )
            case "thrown":
                throw SchedulerActivityFeedFixtureError.injectedExecutionFailure
            default:
                throw SchedulerActivityFeedFixtureError.injectedExecutionFailure
            }
        }
    )
    try await store.writeJSON(.array(schedulerExecutionFixture([
        schedulerExecutionRow(id: "completed", kind: "notify"),
        schedulerExecutionRow(id: "skipped", kind: "connector_action"),
        schedulerExecutionRow(id: "warned", kind: "dream"),
        schedulerExecutionRow(id: "thrown", kind: "rem"),
        schedulerExecutionRow(id: "unsupported", kind: "not_a_scheduler_kind"),
        schedulerExecutionRow(
            id: "recovered",
            kind: "proactive_scan",
            activeOccurrence: .object([
                "key": .string(recoveredKey),
                "state": .string("claimed"),
            ])
        ),
    ])), to: runner.jobsPath)

    #expect(await runner.runDueJobs(maxJobs: 6) == ["Job completed", "Job warned"])

    // Read the production JSONL bytes as well as its decoded rows: deleting
    // appendActivity, redirecting it to an in-memory recorder, or coalescing
    // outcomes makes this exact six-receipt assertion fail. The per-branch
    // title/status/payload checks below also fail if error/warn mapping or
    // occurrence binding is weakened.
    let activityPath = root.appendingPathComponent("activity/events.jsonl")
    let rawLines = try String(contentsOf: activityPath, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
    #expect(rawLines.count == 6)
    let activity = try await schedulerActivityRows(root)
    #expect(activity.count == 6)

    let settledRows = try await schedulerExecutionRows(root)
    let settledByID: [String: [String: JSONValue]] = Dictionary(uniqueKeysWithValues: settledRows.compactMap { row -> (String, [String: JSONValue])? in
        guard case .string(let id)? = row["id"] else { return nil }
        return (id, row)
    })
    #expect(settledByID["completed"]?["lastRunStatus"] == .string("completed"))
    #expect(settledByID["skipped"]?["lastRunStatus"] == .string("skipped"))
    #expect(settledByID["warned"]?["lastRunStatus"] == .string("warn"))
    #expect(settledByID["thrown"]?["lastRunStatus"] == .string("error"))
    #expect(settledByID["unsupported"]?["lastRunStatus"] == .string("error"))
    #expect(settledByID["recovered"]?["lastRunStatus"] == .string("unknown"))

    let expectedTerminalReceipts: [(id: String, kind: String, result: String, feedStatus: String)] = [
        ("completed", "notify", "completed", "ok"),
        ("skipped", "connector_action", "skipped", "warn"),
        ("warned", "dream", "warn", "ok"),
        ("thrown", "rem", "error", "error"),
        ("unsupported", "not_a_scheduler_kind", "error", "error"),
    ]
    for expected in expectedTerminalReceipts {
        let event = try #require(activity.first { event in
            schedulerObject(event["payload"])?["jobId"] == .string(expected.id)
        })
        #expect(event["kind"] == .string("scheduler"))
        #expect(event["title"] == .string("Scheduled job \(expected.result)"))
        #expect(event["status"] == .string(expected.feedStatus))
        let payload = try #require(schedulerObject(event["payload"]))
        #expect(payload["kind"] == .string(expected.kind))
        #expect(payload["status"] == .string(expected.result))
        #expect(payload["occurrenceKey"] == settledByID[expected.id]?["lastOccurrenceKey"])
        let output = try #require(schedulerObject(payload["output"]))
        #expect(output["occurrenceKey"] == settledByID[expected.id]?["lastOccurrenceKey"])
    }

    let thrown = try #require(activity.first { event in
        schedulerObject(event["payload"])?["jobId"] == .string("thrown")
    })
    let thrownOutput = try #require(schedulerObject(schedulerObject(thrown["payload"])?["output"]))
    #expect(thrownOutput["error"] == .string("injected scheduler execution failure"))

    let unsupported = try #require(activity.first { event in
        schedulerObject(event["payload"])?["jobId"] == .string("unsupported")
    })
    let unsupportedOutput = try #require(schedulerObject(schedulerObject(unsupported["payload"])?["output"]))
    #expect(unsupportedOutput["error"] == .string("Unsupported scheduled job kind: not_a_scheduler_kind"))

    let recovered = try #require(activity.first { event in
        schedulerObject(event["payload"])?["jobId"] == .string("recovered")
    })
    #expect(recovered["title"] == .string("Scheduled job outcome needs reconciliation"))
    #expect(recovered["status"] == .string("warn"))
    let recoveredPayload = try #require(schedulerObject(recovered["payload"]))
    #expect(recoveredPayload["occurrenceKey"] == .string(recoveredKey))
    #expect(recoveredPayload["outcome"] == .string("unknown_after_restart"))
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
    let activity = try await schedulerActivityRows(root)
    let event = try #require(activity.first)
    #expect(activity.count == 1)
    #expect(event["title"] == .string("Scheduled job error"))
    #expect(event["status"] == .string("error"))
    #expect(event["detail"] == .string("Job unknown: Unsupported scheduled job kind: not_a_scheduler_kind"))
    let payload = try #require(schedulerObject(event["payload"]))
    #expect(payload["jobId"] == .string("unknown"))
    #expect(payload["kind"] == .string("not_a_scheduler_kind"))
    #expect(payload["status"] == .string("error"))
    #expect(payload["occurrenceKey"] == row["lastOccurrenceKey"])
    let output = try #require(schedulerObject(payload["output"]))
    #expect(output["error"] == .string("Unsupported scheduled job kind: not_a_scheduler_kind"))
    #expect(output["occurrenceKey"] == row["lastOccurrenceKey"])
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
    let retryActivity = try await schedulerActivityRows(root)
    let retryEvent = try #require(retryActivity.first)
    #expect(retryActivity.count == 1)
    #expect(retryEvent["title"] == .string("Scheduled job error"))
    #expect(retryEvent["status"] == .string("error"))
    #expect(retryEvent["detail"] == .string("Job retry: recorded retryable dream failure"))
    let retryPayload = try #require(schedulerObject(retryEvent["payload"]))
    #expect(retryPayload["jobId"] == .string("retry"))
    #expect(retryPayload["kind"] == .string("dream"))
    #expect(retryPayload["status"] == .string("error"))
    #expect(retryPayload["occurrenceKey"] == retryRow["lastOccurrenceKey"])
    let retryOutput = try #require(schedulerObject(retryPayload["output"]))
    #expect(retryOutput["failureKind"] == .string("recorded_failure"))
    #expect(retryOutput["retryable"] == .bool(true))
    #expect(retryOutput["occurrenceKey"] == retryRow["lastOccurrenceKey"])

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
    let reconciliationActivity = try await schedulerActivityRows(restartRoot)
    let reconciliationEvent = try #require(reconciliationActivity.first)
    #expect(reconciliationActivity.count == 1)
    #expect(reconciliationEvent["kind"] == .string("scheduler"))
    #expect(reconciliationEvent["title"] == .string("Scheduled job outcome needs reconciliation"))
    #expect(reconciliationEvent["status"] == .string("warn"))
    guard case .string(let reconciliationDetail)? = reconciliationEvent["detail"] else {
        Issue.record("scheduler reconciliation receipt lacks its bounded detail")
        return
    }
    #expect(reconciliationDetail.contains("external effect may have happened"))
    let reconciliationPayload = try #require(schedulerObject(reconciliationEvent["payload"]))
    #expect(reconciliationPayload["jobId"] == .string("recovered"))
    #expect(reconciliationPayload["occurrenceKey"] == .string(recoveryKey))
    #expect(reconciliationPayload["outcome"] == .string("unknown_after_restart"))
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
