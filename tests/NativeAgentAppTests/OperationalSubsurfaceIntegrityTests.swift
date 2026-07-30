import Foundation
import Testing
import NativeAgentCore
import BackgroundLoops
import PersistenceCore
@testable import NativeAgentApp

private enum ResearchFixtureError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Research service unavailable" }
}

@MainActor
@Test
func manualSelfImprovementRunReportsTypedOutcome() {
    #expect(SelfImprovementView.manualRunNote(for: .completed(result: "staged")).hasPrefix("Done"))
    #expect(SelfImprovementView.manualRunNote(for: .skipped(reason: "autonomy disabled")) == "Not run — autonomy disabled.")
    #expect(SelfImprovementView.manualRunNote(for: .failed(error: "provider unavailable")) == "Failed — provider unavailable.")
    #expect(SelfImprovementView.manualRunNote(for: .skipped(reason: "coalesced with active tick")) == "Already running — joined the active pass.")
}

@Test
func mcpQuickFixReportsStructuredPartialFailure() {
    let partial = MCPRestartPresentation.make([
        "ok": false,
        "restarted": 2,
        "errors": [["serverId": "third", "error": "unavailable"]],
    ])
    #expect(partial == MCPRestartPresentation(message: "Partial restart: 2 restarted, 1 failed", failed: true))
    #expect(MCPRestartPresentation.make(["ok": true, "restarted": 0]).failed == false)
    #expect(MCPRestartPresentation.make(["ok": false, "restarted": 0]).message == "MCP restart failed")
}

@MainActor
@Test
func researchSearch_rejectsBlankInputWithoutCallingTheOperation() async {
    let model = AppModel()
    let original = ResearchResult(
        title: "Existing",
        url: "https://example.com/existing",
        snippet: "Kept",
        source: nil
    )
    model.researchResults = [original]

    let result = await model.search("  \n  ") { _ in
        Issue.record("blank research search invoked its operation")
        return []
    }

    guard case .failure(.blankQuery) = result else {
        Issue.record("blank research search did not return blankQuery")
        return
    }
    #expect(model.researchResults == [original])
}

@MainActor
@Test
func researchSearch_preservesPriorResultsAndTrimmedQueryOnFailure() async {
    let model = AppModel()
    let original = ResearchResult(
        title: "Existing",
        url: "https://example.com/existing",
        snippet: "Kept",
        source: nil
    )
    model.researchResults = [original]

    let result = await model.search("  durable query  ") { query in
        #expect(query == "durable query")
        throw ResearchFixtureError.unavailable
    }

    guard case .failure(.requestFailed(let message)) = result else {
        Issue.record("failed research search did not return its local error")
        return
    }
    #expect(message == "Research service unavailable")
    #expect(model.researchResults == [original])
}

@MainActor
@Test
func researchSearch_returnsAndPublishesFreshResults() async {
    let model = AppModel()
    let fresh = ResearchResult(
        title: "Fresh",
        url: "https://example.com/fresh",
        snippet: "New",
        source: "fixture"
    )

    let result = await model.search("fresh") { _ in [fresh] }

    guard case .success(let rows) = result else {
        Issue.record("successful research search returned failure")
        return
    }
    #expect(rows == [fresh])
    #expect(model.researchResults == [fresh])
}

@Test
func nightlyReflectionRepair_migratesLegacyRowAndNeverAppendsADuplicate() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nextRun = now.addingTimeInterval(3_600).timeIntervalSince1970
    var rows: [JSONValue] = [
        .object([
            "id": .string("legacy-reflection"),
            "name": .string("Nightly Reflection"),
            "kind": .string("dream"),
            "enabled": .bool(true),
        ]),
    ]

    let firstChanged = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &rows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: nextRun,
        now: now
    )
    let secondChanged = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &rows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: nextRun,
        now: now
    )

    #expect(firstChanged)
    #expect(!secondChanged)
    #expect(rows.count == 1)
    guard case .object(let job) = rows[0] else {
        Issue.record("canonical nightly reflection row is not an object")
        return
    }
    #expect(job["id"] == .string("nativeagent-nightly-dream"))
    #expect(job["schedule"] == .object(NativeAgentDreamCycleSchedule.dreamSchedule))
    #expect(job["payload"] == .object([
        "objective": .string("Scheduled reflection"),
    ]))
}

@Test
func nightlyReflectionRepair_preservesPendingRetryAndCancelledJobs() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let retryEpoch = now.addingTimeInterval(900).timeIntervalSince1970
    let tomorrowEpoch = now.addingTimeInterval(86_400).timeIntervalSince1970

    // A cancelled default job (enabled=false + cancelledAt) must NOT be
    // resurrected by the repair upsert.
    var cancelledRows: [JSONValue] = [
        .object([
            "id": .string("nativeagent-nightly-dream"),
            "name": .string("Agent Nightly Dream"),
            "kind": .string("dream"),
            "enabled": .bool(false),
            "cancelledAt": .string("2027-01-01T00:00:00Z"),
        ]),
    ]
    let cancelledChanged = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &cancelledRows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: tomorrowEpoch,
        now: now
    )
    #expect(!cancelledChanged)
    guard case .object(let cancelledJob) = cancelledRows[0] else {
        Issue.record("cancelled row vanished")
        return
    }
    #expect(cancelledJob["enabled"] == .bool(false))
    #expect(cancelledJob["cancelledAt"] == .string("2027-01-01T00:00:00Z"))

    // An EARLIER existing nextRunAt (a 15-minute retry) must survive the
    // upsert's recomputed schedule (tomorrow).
    var retryRows: [JSONValue] = [
        .object([
            "id": .string("nativeagent-nightly-dream"),
            "name": .string("Agent Nightly Dream"),
            "kind": .string("dream"),
            "enabled": .bool(true),
            "nextRunAtEpoch": .int(Int64(retryEpoch)),
        ]),
    ]
    _ = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &retryRows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: tomorrowEpoch,
        now: now
    )
    guard case .object(let retryJob) = retryRows[0] else {
        Issue.record("retry row vanished")
        return
    }
    #expect(retryJob["nextRunAtEpoch"] == .int(Int64(retryEpoch)))

    // A LATER existing stamp still yields to the freshly computed schedule
    // (schedule moved earlier / stale-row repair).
    var staleRows: [JSONValue] = [
        .object([
            "id": .string("nativeagent-nightly-dream"),
            "name": .string("Agent Nightly Dream"),
            "kind": .string("dream"),
            "enabled": .bool(true),
            "nextRunAtEpoch": .int(Int64(tomorrowEpoch)),
        ]),
    ]
    _ = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &staleRows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: retryEpoch,
        now: now
    )
    guard case .object(let staleJob) = staleRows[0] else {
        Issue.record("stale row vanished")
        return
    }
    #expect(staleJob["nextRunAtEpoch"] == .int(Int64(retryEpoch)))
}

@Test
func explicitReactivation_reEnablesCancelledDreamJobAndStripsTombstone() {
    // F3-M1: the passive bootstrap pass must leave a user-cancelled job
    // cancelled, but the app's EXPLICIT re-enable action (createDreamJob →
    // ensureDefaultCycleJobs(reactivateCancelled: true)) must be able to clear
    // the tombstone — otherwise, because cancelledAt is never stripped
    // anywhere, a once-cancelled dream job could never be re-created.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tomorrowEpoch = now.addingTimeInterval(86_400).timeIntervalSince1970

    var rows: [JSONValue] = [
        .object([
            "id": .string("nativeagent-nightly-dream"),
            "name": .string("Agent Nightly Dream"),
            "kind": .string("dream"),
            "enabled": .bool(false),
            "cancelledAt": .string("2027-01-01T00:00:00Z"),
        ]),
    ]

    // Passive pass (default reactivateCancelled: false) still no-ops.
    let passiveChanged = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &rows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: tomorrowEpoch,
        now: now
    )
    #expect(!passiveChanged)
    guard case .object(let stillCancelled) = rows[0] else {
        Issue.record("cancelled row vanished under passive pass")
        return
    }
    #expect(stillCancelled["enabled"] == .bool(false))
    #expect(stillCancelled["cancelledAt"] == .string("2027-01-01T00:00:00Z"))

    // Explicit re-enable clears the tombstone and re-enables the job.
    let reactivated = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &rows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: tomorrowEpoch,
        now: now,
        reactivateCancelled: true
    )
    #expect(reactivated)
    #expect(rows.count == 1)
    guard case .object(let revived) = rows[0] else {
        Issue.record("reactivated row is not an object")
        return
    }
    #expect(revived["enabled"] == .bool(true))
    #expect(revived["cancelledAt"] == nil)
    #expect(revived["id"] == .string("nativeagent-nightly-dream"))

    // A subsequent passive pass no longer no-ops on a tombstone (there is
    // none) and keeps the job enabled.
    let afterRepair = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &rows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: tomorrowEpoch,
        now: now
    )
    #expect(!afterRepair)
    guard case .object(let finalJob) = rows[0] else {
        Issue.record("final row is not an object")
        return
    }
    #expect(finalJob["enabled"] == .bool(true))
    #expect(finalJob["cancelledAt"] == nil)
}

@Test
func failedDreamRunDoesNotCountAsRanToday_soCatchUpRearms() {
    // Live 2026-07-20/21: the 03:31 dream failed ("connection refused:
    // api.kimi.com"), and the FAILED attempt's lastRunAt then counted as
    // "ran today" — catch-up stayed disarmed all day and the dream was
    // simply lost. A failed run must never block its own recovery.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dateKey = NativeAgentDreamCycleSchedule.runDateKey(now)
    let iso = ISO8601DateFormatter().string(from: now)

    let failedRow: JSONValue = .object([
        "id": .string("nativeagent-nightly-dream"),
        "kind": .string("dream"),
        "lastRunAt": .string(iso),
        "lastRunStatus": .string("error"),
    ])
    #expect(!SchedulerDueJobRunner.containsLastRunToday(
        rows: [failedRow], kind: "dream", dateKey: dateKey))

    let completedRow: JSONValue = .object([
        "id": .string("nativeagent-nightly-dream"),
        "kind": .string("dream"),
        "lastRunAt": .string(iso),
        "lastRunStatus": .string("completed"),
    ])
    #expect(SchedulerDueJobRunner.containsLastRunToday(
        rows: [completedRow], kind: "dream", dateKey: dateKey))
}

// MARK: - FIX 1 (A4.1): the retry-storm — catch-up may not beat a retry floor.

@Test
func retryStorm_catchUpCannotPullEarlierThanPendingRetryFloor() {
    // During a provider outage the failed dream run stamps a backoff retry
    // (retryPendingUntilEpoch = T+15m). The next due-job pass recomputes a
    // catch-up nextRunEpoch ≈ now (a failed run does NOT count as "ran today",
    // so dreamCatchUp stays armed). Before FIX 1 the earlier-wins min() rule
    // pulled the job back to ≈now, collapsing the 15/30/60-minute backoff into
    // a ~60s all-day retry loop. A pending retry stamp must be an untouchable
    // FLOOR: the ensure/upsert pass may never pull the job earlier than it.
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let retryEpoch = base.addingTimeInterval(900).timeIntervalSince1970          // T+15m
    let ensurePass = base.addingTimeInterval(120)                               // T+2m
    let catchUpEpoch = ensurePass.timeIntervalSince1970                         // catch-up ≈ now

    var rows: [JSONValue] = [
        .object([
            "id": .string("nativeagent-nightly-dream"),
            "name": .string("Agent Nightly Dream"),
            "kind": .string("dream"),
            "enabled": .bool(true),
            "nextRunAtEpoch": .int(Int64(retryEpoch)),
            "retryPendingUntilEpoch": .int(Int64(retryEpoch)),
            "retryCount": .int(1),
            "retryDayKey": .string(NativeAgentDreamCycleSchedule.runDateKey(base)),
            "lastRunStatus": .string("error"),
        ]),
    ]
    _ = SchedulerDueJobRunner.upsertDefaultCycleJob(
        rows: &rows,
        id: "nativeagent-nightly-dream",
        legacyNames: ["nightly reflection"],
        name: "Agent Nightly Dream",
        kind: "dream",
        intervalSeconds: 86_400,
        schedule: NativeAgentDreamCycleSchedule.dreamSchedule,
        objective: "Scheduled reflection",
        extraPayload: [:],
        nextRunEpoch: catchUpEpoch,   // the catch-up path's ≈now candidate
        now: ensurePass
    )
    guard case .object(let job) = rows[0] else {
        Issue.record("dream row vanished")
        return
    }
    // Floored to the retry stamp, NOT pulled to the ≈now catch-up candidate.
    #expect(job["nextRunAtEpoch"] == .int(Int64(retryEpoch)))
    #expect(job["retryPendingUntilEpoch"] == .int(Int64(retryEpoch)))
}

// MARK: - FIX 2 (A4.4): retry backoff, cap, and park.

@Test
func retryBackoff_isExponentialWithHourCap() {
    #expect(SchedulerDueJobRunner.retryBackoffSeconds(attempt: 1) == 15 * 60)
    #expect(SchedulerDueJobRunner.retryBackoffSeconds(attempt: 2) == 30 * 60)
    #expect(SchedulerDueJobRunner.retryBackoffSeconds(attempt: 3) == 60 * 60)
    #expect(SchedulerDueJobRunner.retryBackoffSeconds(attempt: 9) == 60 * 60)
    #expect(SchedulerDueJobRunner.maxRetryAttemptsPerDay == 6)
}

@Test
func dreamRetryBacksOffPerAttemptThenParksWithReceipt() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-scheduler-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let runner = SchedulerDueJobRunner(root: tmp)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    let seed: JSONValue = .array([
        .object([
            "id": .string("nativeagent-nightly-dream"),
            "name": .string("Agent Nightly Dream"),
            "kind": .string("dream"),
            "enabled": .bool(true),
            "oneShot": .bool(false),
            "schedule": .object(NativeAgentDreamCycleSchedule.dreamSchedule),
            "nextRunAtEpoch": .int(Int64(base.timeIntervalSince1970)),
        ]),
    ])
    try await runner.persistence.writeJSON(seed, to: runner.jobsPath)

    let job = SchedulerDueJobRunner.DueJob(
        id: "nativeagent-nightly-dream",
        name: "Agent Nightly Dream",
        kind: "dream",
        payload: [:],
        row: .object([:]),
        dueEpoch: base.timeIntervalSince1970
    )
    func retryableError() -> SchedulerDueJobRunner.JobResult {
        SchedulerDueJobRunner.JobResult(
            status: "error",
            detail: "dream pass failed before writing; retry scheduled in 15 minutes",
            output: .object([
                "failureKind": .string("dream_failed_before_write"),
                "retryable": .bool(true),
                "retryAfterSeconds": .int(15 * 60),
            ])
        )
    }
    func firstJob() async -> [String: JSONValue] {
        let raw = await runner.persistence.readJSON(runner.jobsPath, defaultValue: .array([]))
        guard case .array(let rows) = raw, case .object(let obj)? = rows.first else { return [:] }
        return obj
    }
    func intField(_ obj: [String: JSONValue], _ key: String) -> Int? {
        if case .int(let n)? = obj[key] { return Int(n) }
        return nil
    }

    // Attempts 1…cap all back off (retryCount climbs, a retry floor is stamped,
    // never parked). Each attempt is a fresh due-job pass a few minutes apart,
    // same calendar day.
    for attempt in 1...SchedulerDueJobRunner.maxRetryAttemptsPerDay {
        let runDate = base.addingTimeInterval(Double(attempt) * 60)
        try await runner.update(job: job, result: retryableError(), at: runDate)
        let obj = await firstJob()
        #expect(intField(obj, "retryCount") == attempt)
        #expect(obj["retryPendingUntilEpoch"] != nil)
        #expect(obj["retryParkedDateKey"] == nil)
        // The stamped retry is at least the exponential backoff off the run.
        let expectedFloor = runDate
            .addingTimeInterval(Double(SchedulerDueJobRunner.retryBackoffSeconds(attempt: attempt)))
            .timeIntervalSince1970
        #expect(intField(obj, "retryPendingUntilEpoch").map(Double.init) == expectedFloor)
    }

    // One more retryable failure the same day trips the cap → PARK.
    let parkDate = base.addingTimeInterval(Double(SchedulerDueJobRunner.maxRetryAttemptsPerDay + 1) * 60)
    try await runner.update(job: job, result: retryableError(), at: parkDate)
    let parked = await firstJob()
    #expect(parked["retryParkedDateKey"] != nil)
    #expect(parked["retryPendingUntilEpoch"] == nil)   // no more retry floor today

    // Parking is never silent — a receipt lands in the notification inbox.
    let inboxPath = tmp.appendingPathComponent("notifications", isDirectory: true)
        .appendingPathComponent("inbox.jsonl")
    let inbox = (try? String(contentsOf: inboxPath, encoding: .utf8)) ?? ""
    #expect(inbox.contains("paused after repeated failures"))

    // A subsequent successful run clears the backoff state (self-heal).
    let success = SchedulerDueJobRunner.JobResult(
        status: "completed",
        detail: "dream pass wrote 1 entry",
        output: .object(["entriesWritten": .int(1)])
    )
    try await runner.update(job: job, result: success, at: parkDate.addingTimeInterval(3600))
    let healed = await firstJob()
    #expect(healed["retryCount"] == nil)
    #expect(healed["retryParkedDateKey"] == nil)
    #expect(healed["retryPendingUntilEpoch"] == nil)
}

// MARK: - FIX 3 (A4.5): completed oneShot pruning.

@Test
func pruneCompletedOneShotRows_dropsExpiredCompletedOneShotsOnly() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expired = SchedulerDueJobRunner.iso(now.addingTimeInterval(-8 * 86_400))   // 8d ago
    let recent = SchedulerDueJobRunner.iso(now.addingTimeInterval(-1 * 86_400))    // 1d ago

    let rows: [JSONValue] = [
        .object([
            "id": .string("old-oneshot"),
            "oneShot": .bool(true),
            "completedAt": .string(expired),
        ]),
        .object([
            "id": .string("recent-oneshot"),
            "oneShot": .bool(true),
            "completedAt": .string(recent),
        ]),
        .object([
            "id": .string("uncompleted-oneshot"),
            "oneShot": .bool(true),
        ]),
        .object([
            "id": .string("recurring-dream"),
            "oneShot": .bool(false),
            "completedAt": .string(expired),
        ]),
    ]
    let result = SchedulerDueJobRunner.pruneCompletedOneShotRows(rows, now: now)
    #expect(result.removed == 1)
    let ids = result.rows.compactMap { row -> String? in
        guard case .object(let obj) = row, case .string(let id)? = obj["id"] else { return nil }
        return id
    }
    #expect(ids == ["recent-oneshot", "uncompleted-oneshot", "recurring-dream"])
}
